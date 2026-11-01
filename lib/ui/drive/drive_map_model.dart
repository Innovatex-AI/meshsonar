// What the Drive screen's map and the full-screen map show, shared between them: the drive's pings, where we are,
// the heard snapshot, the selected repeater and the layer toggles.
//
// Built once by the Drive screen and handed to the full-screen route, so both stay in sync (select a repeater in
// one, it's selected in the other) and the GPS stream is subscribed once. Everything heavy is recomputed only when
// a ping finishes or the repeater list changes, never per frame.
import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui show FrameTiming;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding;
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:h3_flutter/h3_flutter.dart' show H3;
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../core/api.dart' show PublicCoverage;
import '../../core/coverage_query.dart';
import '../../core/heard.dart';
import '../../core/hex_cells.dart' show loadHexEngine;
import '../../core/map_filter.dart';
import '../../core/map_styles.dart';
import '../../core/model.dart';
import '../../core/coverage_timeline.dart';
import '../../core/drive_store.dart' show MapHealthStore;
import '../../core/frame_stats.dart';
import '../../core/heading.dart' show CompassSource;
import '../../core/map_health.dart';
import '../../core/region_timeline_api.dart';
import '../../core/network_coverage.dart';
import '../../core/region_overview_api.dart' show RegionObserver, RegionObservers;
import '../../core/region_repeaters_api.dart';
import '../../core/repeater_sync.dart' show SyncTrigger;
import '../../radio/radio_api.dart';
import '../../radio/simulator.dart' show defaultSimulatedRepeaters;
import '../map/coverage_timeline_controller.dart';
import '../map/layers/app_repeater_feed.dart';
import '../map/layers/map_layer.dart';
import '../map/layers/map_layers_adapter.dart';
import '../map/layers/observer_layer.dart' show positionedObservers;
import '../map/layers/registry.dart';
import '../map/layers/repeater_map_source.dart';
import '../map/cell_raster_layer.dart' show CellRasterLayer;
import '../map/live_puck.dart';
import '../map/tile_source.dart' show MapTileStats;
import '../map/tile_source.dart' as tiles show currentMapSource;
import '../map/map_layers.dart';
import '../region/region_common.dart' show regionApiFactory;

class DriveMapModel extends ChangeNotifier {
  final AppState state;
  DriveMapModel(this.state, {int repeaterIsolateThreshold = 2000, this.cellIsolateThreshold = 600, CompassSource? compass, MapHealthSink? healthSink})
    // ignore: prefer_initializing_formals
    : _compass = compass,
      health = MapHealthRecorder(
        sink: healthSink ?? _sinkFor(state),
        clock: state.services.clock,
      ) {
    _wireHealth();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // The one persisted layer choice: repeater names on/off (Settings.mapRepeaterLabels, default on).
    _layerState = kDefaultLayerState.toggle(kLabelsLayerId, state.settings.mapRepeaterLabels);
    repeaterFeed = AppStateRepeaterFeed(state, fallbackRoster: _fallbackRoster);
    repeaterSource = RepeaterMapSource(repeaterFeed, clock: state.services.clock, isolateThreshold: repeaterIsolateThreshold)
      ..dedupeAgainstRoster = _layerState.isOn(kRosterLayerId);
    state.addListener(_onState);
    _onState();
  }

  /// Widget tests and the benchmark feed fixes through the fake location instead of the engine's [AppState.rawFixes].
  @visibleForTesting
  static Stream<GeoFix> Function(AppState state)? debugFixes;

  /// Network cell sets bigger than this are built (H3 boundaries) off the UI isolate.
  final int cellIsolateThreshold;

  /// "Map and GPS health": per-10-second samples written into the drive folder (map_health.jsonl). The ping engine can write to
  /// the same sink with its own `kind` (see lib/core/map_health.dart).
  final MapHealthRecorder health;

  /// What the map's camera reports (mode, zoom, frames driven); the health sample reads it.
  final CameraTelemetry telemetry = CameraTelemetry();

  final CompassSource? _compass;
  StreamSubscription<double>? _compassSub;

  static MapHealthSink _sinkFor(AppState state) {
    final store = state.services.store;
    if (store is MapHealthStore) return DriveStoreHealthSink(store as MapHealthStore, () => state.currentSession?.id);
    return MemoryHealthSink();
  }

  /// Bumped after each health sample (the on-screen overlay listens).
  final ValueNotifier<int> healthTick = ValueNotifier<int>(0);

  int _lastCellPaints = 0;

  void _wireHealth() {
    health.onSample = (_) => healthTick.value++;
    health.providers['puck'] = (w) {
      final j = puck.stats.toJson(w);
      puck.stats.reset();
      return j;
    };
    health.providers['camera'] = telemetry.cameraJson;
    health.providers['tiles'] = (w) {
      final j = <String, Object?>{...MapTileStats.instance.takeWindow()};
      j['source'] = ((j['pack_hit'] as int?) ?? 0) > 0
          ? 'offline_pack'
          : tiles.currentMapSource(MapTileStats.instance, state.services.clock(), packActive: false).name;
      return j;
    };
    health.providers['layers'] = (w) {
      final n = CellRasterLayer.totalPaints;
      final d = n - _lastCellPaints;
      _lastCellPaints = n;
      return {'cell_paints': d};
    };
  }

  void _onTimings(List<ui.FrameTiming> ts) {
    if (!health.running) return;
    var worst = 0.0, late = 0;
    for (final f in ts) {
      final c = math.max(f.buildDuration.inMicroseconds, f.rasterDuration.inMicroseconds) / 1000;
      if (c > 50) {
        late++;
        worst = math.max(worst, c);
      }
    }
    // A frame over 50 ms is what can make a ping late: it goes into the drive's trace (the sink limits it to 4 a second).
    if (late > 0) state.driveHealthSink.record('frame', {'late_ms': worst.round(), 'worst_ms': worst.round(), 'n': late});
    for (final f in ts) {
      health.onFrame(FrameSample(f.buildDuration.inMicroseconds / 1000, f.rasterDuration.inMicroseconds / 1000, f.totalSpan.inMicroseconds / 1000));
    }
  }

  /// The two repeater lists the map draws (`network`: every MeshCore repeater; `repeaters`: the viewed region's roster),
  /// read from the repeater sync through AppState.
  late final AppStateRepeaterFeed repeaterFeed;

  /// Render-ready points + cluster indexes for both repeater layers (built off the UI isolate for big lists).
  late final RepeaterMapSource repeaterSource;

  List<DrivePing> _pings = const [];

  /// Every ping of the drive on screen (the current drive, or the last one after Stop).
  List<DrivePing> get pings => _pings;

  List<HeardView> _heard = const [];

  /// Who's in range, frozen at the last ping (live first).
  List<HeardView> get heard => _heard;

  /// The live puck: the dot's motion and the ping rings/lines animation (lib/ui/map/live_puck.dart). Every GPS fix goes to
  /// it directly; it repaints its own layers per frame, so a fix does NOT rebuild the map (see [_onFix]).
  late final PuckController puck = PuckController(clock: state.services.clock);

  GeoFix? _fix;
  GeoFix? _notifiedFix;
  DateTime? _notifiedAt;
  EngineState _engineState = EngineState.idle;
  int _pingsResolved = -1;

  /// The live fix behind [position] (continuous while driving, via the same subscription), for callers that
  /// need more than lat/lon -- e.g. its reported accuracy for a live GPS-accuracy indicator.
  GeoFix? get fix => _fix ?? (state.driving ? state.status.lastFix : null);
  LatLng? get position {
    final f = fix;
    return f == null ? null : LatLng(f.lat, f.lon);
  }

  String? _selected;

  /// Map key of the repeater picked in the heard box or on the map.
  String? get selected => _selected;
  void select(String? key) {
    if (key == _selected) return;
    _selected = key;
    notifyListeners();
  }

  // Which layers are on (registry ids, lib/ui/map/layers/registry.dart) plus their modes. [layers] is the old bool bag
  // view of the same state, kept for one release (stream-1-maps.md 4.1).
  MapLayerState _layerState = kDefaultLayerState;
  MapLayerState get layerState => _layerState;
  set layerState(MapLayerState n) {
    if (n == _layerState) return;
    final was = _layerState;
    _layerState = n;
    _layersView = null;
    repeaterSource.dedupeAgainstRoster = n.isOn(kRosterLayerId);
    notifyListeners();
    if (n.isOn(kLabelsLayerId) != was.isOn(kLabelsLayerId) && n.isOn(kLabelsLayerId) != state.settings.mapRepeaterLabels) {
      unawaited(state.updateSettings(state.settings.copyWith(mapRepeaterLabels: n.isOn(kLabelsLayerId))));
    }
    bool turnedOn(String id) => n.isOn(id) && !was.isOn(id);
    if (turnedOn(kRosterLayerId) || turnedOn(kNetworkLayerId)) repeaterSource.refreshAges();
    if (turnedOn(kRosterLayerId) && _regionRepeaters.isEmpty && repeaterFeed.region.rows.isEmpty) unawaited(loadRegionRepeaters());
    if (turnedOn('observers')) unawaited(loadObservers());
  }

  /// Turns one registry layer on or off.
  void setLayer(String id, bool on) => layerState = _layerState.toggle(id, on);

  MapLayers? _layersView;
  MapLayers get layers => _layersView ??= mapLayersFromState(_layerState);
  set layers(MapLayers l) {
    if (l == layers) return;
    // Layers the bool bag has no field for (network, observers, neighbours) keep their state.
    final keep = {for (final id in _layerState.on) if (!_layersIds.contains(id)) id};
    final next = l.toLayerState(mode: _layerState.mode);
    layerState = MapLayerState(on: Set.unmodifiable({...next.on, ...keep}), mode: next.mode);
  }

  static const Set<String> _layersIds = {'measured', 'hexes', 'repeaters', 'links', 'heard', 'pings', 'rings'};

  // The region's whole repeater roster for the "Region repeaters" layer. Fetched the first time the layer is
  // switched on (or by [loadRegionRepeaters] / [regionRepeaters]=, e.g. when the region switcher changes region).
  List<RegionRepeater> _regionRepeaters = const [];
  bool _regionRepeatersLoading = false;
  bool _regionRepeatersFailed = false;
  bool _regionRepeatersLoaded = false;
  RosterRegion? _regionRepeatersRegion;

  FallbackRoster _fallbackRoster() => FallbackRoster(
    region: _regionRepeatersRegion,
    rows: _regionRepeaters,
    state: _regionRepeatersLoading
        ? MapFeedState.loading
        : (_regionRepeatersFailed ? MapFeedState.failed : (_regionRepeatersLoaded ? MapFeedState.ready : MapFeedState.idle)),
  );

  /// Test seam / wiring seam: how the roster is fetched.
  Future<RegionRepeaters> Function(String baseUrl, String regionSlug) regionRepeatersFetcher = fetchRegionRepeaters;

  /// Roster pins for the map; empty until loaded.
  List<RegionRepeater> get regionRepeaters => _regionRepeaters;
  set regionRepeaters(List<RegionRepeater> v) {
    _regionRepeaters = v;
    _regionRepeatersLoaded = true;
    repeaterFeed.refresh();
    notifyListeners();
  }

  bool get regionRepeatersLoading => _regionRepeatersLoading;

  /// Loads the roster of [slug] at [baseUrl], defaulting to the region the phone is in (else the server's active
  /// region). Failures leave the layer empty (it is a bonus layer, never an error screen).
  Future<void> loadRegionRepeaters({String? baseUrl, String? slug}) async {
    final region = state.currentRegion;
    final site = state.siteConfig?.region;
    final url = baseUrl ?? region?.url ?? site?.url;
    final sl = slug ?? region?.slug ?? site?.slug;
    if (url == null || sl == null || _regionRepeatersLoading) return;
    _regionRepeatersLoading = true;
    _regionRepeatersRegion = RosterRegion(slug: sl, name: region?.name ?? sl.toUpperCase(), baseUrl: url);
    repeaterFeed.refresh();
    try {
      final r = await regionRepeatersFetcher(url, sl);
      _regionRepeaters = r.positioned;
      _regionRepeatersFailed = false;
      _regionRepeatersLoaded = true;
    } catch (_) {
      // leave whatever was there; the layers sheet says it failed (with Retry)
      _regionRepeatersFailed = true;
    } finally {
      _regionRepeatersLoading = false;
      if (!_disposed) {
        repeaterFeed.refresh();
        notifyListeners();
      }
    }
  }

  // ---------- observers layer (the viewed region's `region-observers` rows with a public position) ----------
  List<RegionObserver> _observers = const [];
  MapFeedState _observersState = MapFeedState.idle;
  String? _observersSlug;
  int _observersSeq = 0;

  /// Test seam: how a region's observers are fetched (the same client the Observers panel uses).
  Future<RegionObservers> Function(String baseUrl) observersFetcher = (b) async {
    final api = regionApiFactory(b);
    try {
      return await api.observers();
    } finally {
      api.close();
    }
  };

  /// The viewed region's observers that have a public position (what the layer draws).
  List<RegionObserver> get observers => _observers;
  MapFeedState get observersState => _observersState;

  /// Fetches the viewed region's observers (once per region unless [force]). Failures leave what was there and show
  /// as failed in the layers sheet.
  Future<void> loadObservers({bool force = false}) async {
    final v = state.viewingRegion;
    if (v == null) return;
    if (!force && _observersSlug == v.slug && (_observersState == MapFeedState.ready || _observersState == MapFeedState.loading)) return;
    final seq = ++_observersSeq;
    if (_observersSlug != v.slug) _observers = const [];
    _observersSlug = v.slug;
    _observersState = _observers.isEmpty ? MapFeedState.loading : _observersState;
    notifyListeners();
    try {
      final r = await observersFetcher(v.url);
      if (_disposed || seq != _observersSeq) return;
      _observers = List.unmodifiable(positionedObservers(r.rows));
      _observersState = MapFeedState.ready;
    } catch (_) {
      if (_disposed || seq != _observersSeq) return;
      _observersState = _observers.isEmpty ? MapFeedState.failed : MapFeedState.stale;
    }
    notifyListeners();
  }

  // ---------- layer availability (the generated layers sheet) ----------
  MapFeedState get _coverageState {
    if (state.networkCoverage != null) return state.networkCoverageFailed ? MapFeedState.stale : MapFeedState.ready;
    if (state.networkCoverageLoading) return MapFeedState.loading;
    return state.networkCoverageFailed ? MapFeedState.failed : MapFeedState.idle;
  }

  /// The switch state and the line under it for registry layer [id].
  LayerStatus statusOf(String id) => layerStatus(
    id,
    MapLayerInputs(
      coverageState: _coverageState,
      coverageCells: _networkCells.length,
      observersState: _observersSlug == state.viewingRegion?.slug ? _observersState : MapFeedState.idle,
      observersWithPosition: _observers.length,
      regionName: state.viewingRegion?.name,
      repeaterSelected: _selected != null,
      regionIndexLoaded: state.regionIndexLoaded,
      regionNeighbours: state.regionNeighbours?.neighbours.length ?? 0,
    ),
    repeaters: repeaterSource,
  );

  /// Retry for a layer whose status says it can be retried.
  Future<void> retry(String id) async {
    switch (id) {
      case 'measured':
        await state.refreshNetworkCoverage();
      case 'observers':
        await loadObservers(force: true);
      case kRosterLayerId:
        if (state.repeaterSync == null || (repeaterFeed.region.rows.isEmpty && _regionRepeatersRegion != null)) {
          await loadRegionRepeaters();
        } else {
          await state.syncRepeaterLists(SyncTrigger.force);
        }
      case kNetworkLayerId:
        await state.syncRepeaterLists(SyncTrigger.force);
    }
  }

  // Network-wide coverage (every driver's measured cells, not just this drive's pings): the background
  // "where hasn't this been driven" layer. Recomputed only when AppState's own fetch identity changes (see
  // _onState below), same memoise-on-identity convention as [repeaters].
  static final H3? _h3 = loadHexEngine();
  PublicCoverage? _networkSrc;
  List<NetworkCell> _networkCells = const [];

  /// Network-wide measured coverage cells for the map's background layer; empty until the first fetch answers.
  List<NetworkCell> get networkCells => _networkCells;

  int _cellsSeq = 0;

  /// Builds [networkCells] from the fetched coverage: in place for a small set (returns true), on another isolate for a big one
  /// (H3 boundaries for thousands of cells would stall the UI; the map keeps the old cells until the new ones land).
  bool _rebuildNetworkCells() {
    final src = _networkSrc;
    final seq = ++_cellsSeq;
    if (src == null) {
      _networkCells = const [];
      return true;
    }
    final by = _colorBy;
    final now = state.services.clock();
    if (src.cells.length < cellIsolateThreshold) {
      _networkCells = buildNetworkCells(src, _h3, by, now: now);
      return true;
    }
    unawaited(
      Isolate.run(() => buildNetworkCells(src, loadHexEngine(), by, now: now)).then<void>((r) {
        if (_disposed || seq != _cellsSeq) return;
        _networkCells = r;
        notifyListeners();
      }, onError: (Object _) {
        if (_disposed || seq != _cellsSeq) return;
        _networkCells = buildNetworkCells(src, _h3, by, now: now); // no isolate here: do it in place
        notifyListeners();
      }),
    );
    return false;
  }

  bool get simulated => state.radioKind == RadioKind.simulator;

  /// Overlays the Drive screen and the full-screen map draw over their maps (heard box, button column): the map keeps
  /// repeater names out from under them. Separate sets because both screens can be alive at once.
  final List<GlobalKey> driveOverlayKeys = [GlobalKey(debugLabel: 'drive-heard'), GlobalKey(debugLabel: 'drive-controls')];
  /// Height of the GPS health banner over the top of whichever map shows it (0 when it shows nothing), so the heard box and
  /// the button column start below it instead of under it.
  final ValueNotifier<double> gpsBannerHeight = ValueNotifier(0);
  final List<GlobalKey> fullscreenOverlayKeys = [GlobalKey(debugLabel: 'full-heard'), GlobalKey(debugLabel: 'full-controls')];

  /// Height of the credit stack the map draws bottom-left (OpenStreetMap credit, the SIMULATED tag, the repeater age
  /// legend with MeshCore Map's credit), so overlays that sit above it (the result flash, the report card) clear it
  /// instead of covering it.
  double get attributionStackHeight =>
      64 + (simulated ? 28 : 0) + (layerState.isOn(kNetworkLayerId) && repeaterSource.globalPoints.length > 0 ? 64 : 0);

  /// The simulator's own (made-up) repeaters, so a Simulator drive shows where they are like a real one would.
  static final List<RepeaterRef> simulatorRepeaters = [
    for (final r in defaultSimulatedRepeaters()) RepeaterRef(key: r.keyHex, name: r.name, lat: r.lat, lon: r.lon),
  ];
  static final RepeaterLookup _simLookup = RepeaterLookup([(RepeaterSource.none, simulatorRepeaters)]);

  List<RepeaterRef>? _repSrc;
  bool _repSim = false;
  List<RepeaterRef> _repeaters = const [];

  /// Repeaters to draw: the CMAT list, plus the simulator's in Simulator mode.
  List<RepeaterRef> get repeaters {
    final src = state.repeaters;
    final sim = simulated;
    if (!identical(src, _repSrc) || sim != _repSim) {
      _repSrc = src;
      _repSim = sim;
      _repeaters = sim ? [...src, ...simulatorRepeaters] : src;
    }
    return _repeaters;
  }

  List<HeardView> _snapshot() {
    final list = heardSnapshot(state.heard);
    if (!simulated) return list;
    final last = state.recentPings.isEmpty ? null : state.recentPings.first;
    return [
      for (final h in list)
        if (h.ref != null)
          h
        else
          () {
            final m = _simLookup.resolve(h.id);
            final ref = m.ref;
            if (ref == null) return h;
            return HeardView(
              id: h.id,
              label: ref.name,
              ref: ref,
              snrDb: h.snrDb,
              bestSnrDb: h.bestSnrDb,
              rssiDbm: h.rssiDbm,
              timesHeard: h.timesHeard,
              distanceM: last == null ? null : haversineM(last.lat, last.lon, ref.lat, ref.lon),
              phase: h.phase,
              pingsAgo: h.pingsAgo,
              holdLeft: h.holdLeft,
              lastPingIndex: h.lastPingIndex,
            );
          }(),
    ];
  }

  /// Display name for a heard id: the heard list's label (covers the simulator's repeaters), else AppState's.
  String labelFor(String id) {
    final k = id.toLowerCase();
    for (final h in _heard) {
      if (h.id == k) return h.label;
    }
    return state.repeaterLabel(k);
  }

  int _pingsSeen = -1;
  int _pingCount = -1;
  RepeaterLookup? _lookup;
  bool _driving = false;
  int _hold = -1;
  bool _sim = false;

  StreamSubscription<GeoFix>? _fixSub;
  LocationSource? _fixSource;

  void _onState() {
    final s = state;
    var changed = false;

    // Pings: refetch only when the count changes (a new ping, a new drive, or the drive was deleted).
    final emptyNow = s.recentPings.isEmpty && !s.driving;
    final count = emptyNow ? 0 : s.pingCount;
    if (count != _pingCount || s.driving != _driving) {
      _pingCount = count;
      final all = emptyNow ? const <DrivePing>[] : s.drivePings;
      if (all.length != _pings.length || (all.isNotEmpty && _pings.isNotEmpty && all.last.id != _pings.last.id)) {
        _pings = all;
        changed = true;
      } else if (all.isEmpty && _pings.isNotEmpty) {
        _pings = const [];
        changed = true;
      }
    }

    // Heard snapshot: once per ping, or when names/positions or the hold change.
    final seen = s.heard.pingsSeen;
    if (seen != _pingsSeen ||
        !identical(s.lookup, _lookup) ||
        s.heard.holdPings != _hold ||
        s.driving != _driving ||
        simulated != _sim) {
      _sim = simulated;
      _pingsSeen = seen;
      _lookup = s.lookup;
      _hold = s.heard.holdPings;
      _heard = _snapshot();
      if (_selected != null && s.driving && !_driving) _selected = null;
      changed = true;
    }
    if (s.driving != _driving) {
      _driving = s.driving;
      changed = true;
    }
    if (s.settings.baseMapStyle != _styleId) {
      _styleId = s.settings.baseMapStyle;
      changed = true;
    }

    // The viewed region changed: the timeline's first-data date is per region, so go back to live and reload it.
    final rc = s.viewingRegion?.code;
    if (rc != _timelineRegion) {
      final first = _timelineRegion == null;
      _timelineRegion = rc;
      if (!first) timeline.regionChanged();
      if (!first && _layerState.isOn('observers')) unawaited(loadObservers());
    }

    // Network-wide coverage: a new fetch (initial, or after a server change) redraws the background layer even
    // if nothing else about the drive changed (most often: the fetch lands before anyone has started driving).
    if (!identical(s.networkCoverage, _networkSrc)) {
      _networkSrc = s.networkCoverage;
      if (_rebuildNetworkCells()) changed = true;
    }

    // Live position while driving (permission was granted by Start drive).
    final src = s.driving ? s.activeLocation : null;
    if (!identical(src, _fixSource)) {
      unawaited(_fixSub?.cancel());
      _fixSub = null;
      _fixSource = src;
      if (src == null) {
        _fix = null;
        puck.reset();
        health.stop();
        unawaited(_compassSub?.cancel());
        _compassSub = null;
        changed = true;
      } else {
        puck.reset();
        health.start();
        unawaited(_compassSub?.cancel());
        _compassSub = _compass?.headings.listen(puck.onCompass, onError: (Object _) {});
        _notifiedFix = null;
        _notifiedAt = null;
        try {
          _fixSub = (debugFixes?.call(state) ?? state.rawFixes).listen(_onFix, onError: (Object _) {});
        } catch (_) {}
      }
    }

    // Ping animation: rings when the engine starts a ping, the answer when it is saved.
    final es = s.status.state;
    if (es == EngineState.pinging && _engineState != EngineState.pinging && s.driving) puck.pingSent();
    _engineState = es;
    if (s.driving) {
      final n = s.pingCount;
      if (_pingsResolved >= 0 && n > _pingsResolved) {
        final newest = s.recentPings.isEmpty ? null : s.recentPings.first;
        puck.pingResolved(heard: newest != null && !newest.heardNothing);
      }
      _pingsResolved = n;
    } else {
      _pingsResolved = -1;
    }
    if (changed) notifyListeners();
  }

  /// A live GPS fix. The dot moves on every one (it repaints itself); the model, and with it the whole map and the
  /// numbers beside it, is only told when the phone moved [_slowStepM] or [_slowEvery] has passed: rebuilding thousands
  /// of hexagons and markers once a second is what made the dot hop and stutter.
  static const double _slowStepM = 100;
  static const Duration _slowEvery = Duration(seconds: 6);

  void _onFix(GeoFix f) {
    _fix = f;
    puck.onFix(f);
    final was = _notifiedFix;
    final now = state.services.clock();
    health.maybeSample(now);
    final due = was == null ||
        _notifiedAt == null ||
        now.difference(_notifiedAt!) >= _slowEvery ||
        (f.lat - was.lat).abs() * 111320 + (f.lon - was.lon).abs() * 85000 >= _slowStepM;
    if (due) {
      _notifiedFix = f;
      _notifiedAt = now;
      notifyListeners();
    }
  }

  // ---------- base map style (street / dark / topo), the filter drawer and the coverage % of what is in view ----------
  late String _styleId = state.settings.baseMapStyle;

  /// The base map drawn under everything (Settings.baseMapStyle, saved).
  BaseMapStyle get baseStyle => BaseMapStyle.parse(state.settings.baseMapStyle);
  void setBaseStyle(BaseMapStyle v) {
    if (v == baseStyle) return;
    unawaited(state.updateSettings(state.settings.copyWith(baseMapStyle: v.id)));
  }

  /// The cycler button: the next style.
  void cycleBaseStyle() => setBaseStyle(baseStyle.next);

  MapFilter _filter = MapFilter.none;
  MapFilter get filter => _filter;
  set filter(MapFilter f) {
    if (f == _filter) return;
    _filter = f;
    notifyListeners();
  }

  List<DrivePing>? _vpSrc;
  MapFilter? _vpFilter;
  List<DrivePing> _vp = const [];

  /// [pings] with the filter applied: what the map draws (the hexagons follow it too). [pings] itself stays whole.
  List<DrivePing> get visiblePings {
    if (_filter.isNone) return _pings;
    if (!identical(_pings, _vpSrc) || _filter != _vpFilter) {
      _vpSrc = _pings;
      _vpFilter = _filter;
      _vp = _filter.pings(_pings, state.services.clock());
    }
    return _vp;
  }

  List<NetworkCell>? _vcSrc;
  MapFilter? _vcFilter;
  List<NetworkCell> _vc = const [];

  /// [networkCells] with the filter applied.
  List<NetworkCell> get visibleNetworkCells {
    if (_filter.isNone) return _networkCells;
    if (!identical(_networkCells, _vcSrc) || _filter != _vcFilter) {
      _vcSrc = _networkCells;
      _vcFilter = _filter;
      _vc = _filter.cells(_networkCells, state.services.clock());
    }
    return _vc;
  }

  GeoBounds? _bounds;

  /// The part of the world the map shows now (null until the map reports it).
  GeoBounds? get visibleBounds => _bounds;
  Timer? _boundsTimer;

  /// The map reports its view as it moves; the figures settle 250 ms after the last move.
  void onMapBounds(GeoBounds b) {
    if (b == _bounds) return;
    final first = _bounds == null;
    _bounds = b;
    _boundsTimer?.cancel();
    if (first) {
      notifyListeners();
      return;
    }
    _boundsTimer = Timer(const Duration(milliseconds: 250), () {
      if (!_disposed) notifyListeners();
    });
  }

  CoverageSummary? _sum;
  Object? _sumKey;

  /// Coverage of what is drawn inside the view: share of mapped cells with something heard, and of your tx pings heard.
  CoverageSummary get coverageSummary {
    final cells = layers.networkCoverage ? visibleNetworkCells : const <NetworkCell>[];
    final key = Object.hash(identityHashCode(cells), identityHashCode(visiblePings), _bounds, cells.length);
    if (_sumKey != key || _sum == null) {
      _sumKey = key;
      _sum = summariseCoverage(cells: cells, pings: visiblePings, bounds: _bounds);
    }
    return _sum!;
  }

  // ---------- network-coverage layer controls (res by zoom, colour-by, since, source) ----------
  CoverageColorBy _colorBy = CoverageColorBy.snr;
  CoverageColorBy get colorBy => _colorBy;
  set colorBy(CoverageColorBy v) {
    if (v == _colorBy) return;
    _colorBy = v;
    _rebuildNetworkCells();
    notifyListeners();
  }

  CoverageQuery _query = const CoverageQuery();

  /// The layer's filters; `res == null` means automatic by zoom.
  CoverageQuery get coverageQuery => _query;
  set coverageQuery(CoverageQuery q) {
    if (q == _query) return;
    _query = q;
    notifyListeners();
    _scheduleCoverageFetch(immediate: true);
  }

  /// The coverage-growth slider ("as of" date). Owned here so the layer sheet and the map label share one state.
  late final CoverageTimelineController timeline = CoverageTimelineController(
    getQuery: () => _query,
    setQuery: (q) => coverageQuery = q,
    baseUrl: () => state.viewingRegion?.url ?? state.siteConfig?.region.url ?? state.client.baseUrl.toString(),
    fetchTimeline: (u) => timelineFetcher(u),
    clock: state.services.clock,
    budget: RateBudget(),
  )..addListener(notifyListeners);
  String? _timelineRegion;

  /// Test seam: how the region's first-data date is fetched.
  Future<RegionTimeline?> Function(String baseUrl) timelineFetcher = fetchRegionTimeline;

  double? _zoom;

  /// The resolution actually requested: the pinned one, else the one for the map's zoom (res 9 until the map reports).
  int get effectiveRes => _query.res ?? (_zoom == null ? 9 : coverageResForZoom(_zoom!));

  /// Called by the map as it zooms; in automatic mode a new resolution band re-fetches (debounced).
  void onMapZoom(double zoom) {
    _zoom = zoom;
    if (_query.res == null) _scheduleCoverageFetch();
  }

  Timer? _fetchTimer;
  void _scheduleCoverageFetch({bool immediate = false}) {
    _fetchTimer?.cancel();
    void go() {
      if (_disposed) return;
      final res = effectiveRes;
      final shown = state.networkCoverage?.grid.res;
      final asked = state.coverageQuery;
      if (!immediate && shown == res && asked.since == _query.since && asked.source == _query.source && asked.until == _query.until) return;
      unawaited(state.refreshNetworkCoverage(query: CoverageQuery(res: res, since: _query.since, source: _query.source, until: _query.until)));
    }

    if (immediate) {
      go();
    } else {
      _fetchTimer = Timer(const Duration(milliseconds: 250), go);
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _fetchTimer?.cancel();
    _boundsTimer?.cancel();
    timeline.dispose();
    gpsBannerHeight.dispose();
    state.removeListener(_onState);
    repeaterSource.dispose();
    repeaterFeed.dispose();
    unawaited(_fixSub?.cancel());
    unawaited(_compassSub?.cancel());
    health.stop(flush: false);
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    puck.dispose();
    healthTick.dispose();
    super.dispose();
  }
}
