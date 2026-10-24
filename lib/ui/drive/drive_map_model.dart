// What the Drive screen's map and the full-screen map show, shared between them: the drive's pings, where we are,
// the heard snapshot, the selected repeater and the layer toggles.
//
// Built once by the Drive screen and handed to the full-screen route, so both stay in sync (select a repeater in
// one, it's selected in the other) and the GPS stream is subscribed once. Everything heavy is recomputed only when
// a ping finishes or the repeater list changes, never per frame.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:h3_flutter/h3_flutter.dart' show H3;
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../core/api.dart' show PublicCoverage;
import '../../core/coverage_query.dart';
import '../../core/heard.dart';
import '../../core/hex_cells.dart' show loadHexEngine;
import '../../core/model.dart';
import '../../core/coverage_timeline.dart';
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
import '../map/map_layers.dart';
import '../region/region_common.dart' show regionApiFactory;

class DriveMapModel extends ChangeNotifier {
  final AppState state;
  DriveMapModel(this.state, {int repeaterIsolateThreshold = 2000}) {
    repeaterFeed = AppStateRepeaterFeed(state, fallbackRoster: _fallbackRoster);
    repeaterSource = RepeaterMapSource(repeaterFeed, clock: state.services.clock, isolateThreshold: repeaterIsolateThreshold)
      ..dedupeAgainstRoster = _layerState.isOn(kRosterLayerId);
    state.addListener(_onState);
    _onState();
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

  GeoFix? _fix;

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

  bool get simulated => state.radioKind == RadioKind.simulator;

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
      _networkCells = _networkSrc == null ? const [] : buildNetworkCells(_networkSrc!, _h3, _colorBy);
      changed = true;
    }

    // Live position while driving (permission was granted by Start drive).
    final src = s.driving ? s.activeLocation : null;
    if (!identical(src, _fixSource)) {
      unawaited(_fixSub?.cancel());
      _fixSub = null;
      _fixSource = src;
      if (src == null) {
        _fix = null;
        changed = true;
      } else {
        try {
          _fixSub = src.fixes.listen((f) {
            _fix = f;
            notifyListeners();
          }, onError: (Object _) {});
        } catch (_) {}
      }
    }
    if (changed) notifyListeners();
  }

  // ---------- network-coverage layer controls (res by zoom, colour-by, since, source) ----------
  CoverageColorBy _colorBy = CoverageColorBy.snr;
  CoverageColorBy get colorBy => _colorBy;
  set colorBy(CoverageColorBy v) {
    if (v == _colorBy) return;
    _colorBy = v;
    _networkCells = _networkSrc == null ? const [] : buildNetworkCells(_networkSrc!, _h3, _colorBy);
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
      _fetchTimer = Timer(const Duration(milliseconds: 500), go);
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _fetchTimer?.cancel();
    timeline.dispose();
    state.removeListener(_onState);
    repeaterSource.dispose();
    repeaterFeed.dispose();
    unawaited(_fixSub?.cancel());
    super.dispose();
  }
}
