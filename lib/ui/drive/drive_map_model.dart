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
import '../../core/region_repeaters_api.dart';
import '../../radio/radio_api.dart';
import '../../radio/simulator.dart' show defaultSimulatedRepeaters;
import '../map/coverage_timeline_controller.dart';
import '../map/map_layers.dart';

class DriveMapModel extends ChangeNotifier {
  final AppState state;
  DriveMapModel(this.state) {
    state.addListener(_onState);
    _onState();
  }

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

  MapLayers _layers = const MapLayers();
  MapLayers get layers => _layers;
  set layers(MapLayers l) {
    if (l == _layers) return;
    final turnedOn = l.regionRepeaters && !_layers.regionRepeaters;
    _layers = l;
    notifyListeners();
    if (turnedOn && _regionRepeaters.isEmpty) unawaited(loadRegionRepeaters());
  }

  // The region's whole repeater roster for the "Region repeaters" layer. Fetched the first time the layer is
  // switched on (or by [loadRegionRepeaters] / [regionRepeaters]=, e.g. when the region switcher changes region).
  List<RegionRepeater> _regionRepeaters = const [];
  bool _regionRepeatersLoading = false;

  /// Test seam / wiring seam: how the roster is fetched.
  Future<RegionRepeaters> Function(String baseUrl, String regionSlug) regionRepeatersFetcher = fetchRegionRepeaters;

  /// Roster pins for the map; empty until loaded.
  List<RegionRepeater> get regionRepeaters => _regionRepeaters;
  set regionRepeaters(List<RegionRepeater> v) {
    _regionRepeaters = v;
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
    try {
      final r = await regionRepeatersFetcher(url, sl);
      _regionRepeaters = r.positioned;
    } catch (_) {
      // leave whatever was there
    } finally {
      _regionRepeatersLoading = false;
      if (!_disposed) notifyListeners();
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
    unawaited(_fixSub?.cancel());
    super.dispose();
  }
}
