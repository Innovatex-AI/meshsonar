// The app's [RepeaterMapFeed]: the two repeater lists the map draws, read from AppState (Stream 3's repeater sync:
// `AppState.globalRepeaterSet` = GET <server>/api/cmh/network-repeaters, the viewed region's stored roster =
// `repeaterSync.roster(slug)`). RepeaterSync is pure Dart and not a Listenable; AppState notifies on every change, so
// this feed listens to AppState and passes a notification on only when something the map uses changed (row identity,
// state, as-of, counts or labels), not on every ping.
//
// Without a sync (custom builds, older tests) or before it holds the viewed region's roster, the roster comes from
// [fallbackRoster] (the Drive map model's own `region-repeaters` fetch, the layer's behaviour before the sync existed).
//
// Scope of the global layer (Andy, Oct 24 2026: default ON): when a region is detected (the phone is in it), picked
// (manual), or remembered from the last time one was, the global rows are limited to that region's bbox grown by
// [kRegionRepeaterMarginKm] on every side; otherwise (new visitor, phone outside every region, nothing picked) the whole
// list is drawn as count clusters that split as you zoom. Why bbox + 40 km and not the boundary polygon: border
// repeaters are what a driver near the edge hears (MeshCore repeater links of 30-60 km between hilltops are common), the
// bbox is in the regions index offline, and the test is a few comparisons per row (55.6k rows: ~2 ms).
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../../../app/app_state.dart';
import '../../../core/region_lookup.dart' show RegionIndexEntry;
import '../../../core/startup_location.dart' show MapStartKind;
import '../../../core/network_repeaters.dart' show NetworkRepeater;
import '../../../core/region_repeaters_api.dart' show RegionRepeater;
import '../../../core/repeater_points.dart' show MapRepeaterRow;
import '../../../core/repeater_sync.dart' show SyncState;
import 'repeater_map_source.dart';

/// A roster the host fetched itself (used when the sync has none).
@immutable
class FallbackRoster {
  final RosterRegion? region;
  final List<RegionRepeater> rows;
  final MapFeedState state;
  const FallbackRoster({required this.region, required this.rows, required this.state});
  static const none = FallbackRoster(region: null, rows: [], state: MapFeedState.idle);
}

MapFeedState mapFeedStateOf(SyncState s) => switch (s) {
  SyncState.idle => MapFeedState.idle,
  SyncState.loading => MapFeedState.loading,
  SyncState.ready => MapFeedState.ready,
  SyncState.stale => MapFeedState.stale,
  SyncState.failed => MapFeedState.failed,
  SyncState.unsupported => MapFeedState.unsupported,
};

/// Network list rows as map rows (key, name, position, room server, last advert).
List<MapRepeaterRow> networkMapRows(List<NetworkRepeater> rows) => List.unmodifiable([
  for (final x in rows) MapRepeaterRow(key: x.key, name: x.name, lat: x.lat, lon: x.lon, isRoom: x.isRoom, lastSeen: x.lastAdvert),
]);

/// Margin around the viewed region's bbox for the global layer (see the header).
const double kRegionRepeaterMarginKm = 40;

/// `[west, south, east, north]` of [bbox] grown by [marginKm] (latitude clamped to +-85).
List<double> grownBbox(List<double> bbox, double marginKm) {
  final dLat = marginKm / 111.32;
  final midLat = (bbox[1] + bbox[3]) / 2;
  final dLon = marginKm / (111.32 * math.max(0.05, math.cos(midLat * math.pi / 180)));
  return [bbox[0] - dLon, math.max(-85, bbox[1] - dLat), bbox[2] + dLon, math.min(85, bbox[3] + dLat)];
}

/// The rows inside [box] (`[west, south, east, north]`, west > east = crosses the antimeridian).
List<MapRepeaterRow> rowsInBox(List<MapRepeaterRow> rows, List<double> box) {
  final w = box[0], s = box[1], e = box[2], n = box[3];
  final wraps = w > e;
  return List.unmodifiable([
    for (final r in rows)
      if (r.lat >= s && r.lat <= n && (wraps ? (r.lon >= w || r.lon <= e) : (r.lon >= w && r.lon <= e))) r,
  ]);
}

class AppStateRepeaterFeed extends ChangeNotifier implements RepeaterMapFeed {
  final AppState state;

  /// The host's own roster fetch, used when the sync holds nothing for the viewed region.
  FallbackRoster Function() fallbackRoster;

  AppStateRepeaterFeed(this.state, {FallbackRoster Function()? fallbackRoster}) : fallbackRoster = fallbackRoster ?? (() => FallbackRoster.none) {
    state.addListener(_onState);
    _recompute();
  }

  MapRepeaterSet _global = MapRepeaterSet.idle;
  MapRepeaterSet _region = MapRepeaterSet.idle;
  RosterRegion? _rosterRegion;

  // Conversions memoised on source identity, so MapRepeaterSet.rows keeps its identity between notifications and the
  // map source rebuilds only on a real change.
  List<NetworkRepeater>? _gSrc;
  List<MapRepeaterRow> _gAll = const [];
  List<MapRepeaterRow> _gRows = const [];
  String? _gScopeCode;
  List<RegionRepeater>? _rSrc;
  List<MapRepeaterRow> _rRows = const [];

  /// Roster rows by lower-case key (O(1) detail lookup for the sheets; the roster can hold hundreds of rows).
  Map<String, RegionRepeater> _detail = const {};

  @override
  MapRepeaterSet get global => _global;
  @override
  MapRepeaterSet get region => _region;
  @override
  RosterRegion? get rosterRegion => _rosterRegion;
  @override
  RegionRepeater? rosterDetail(String key) => _detail[key.toLowerCase()];

  /// Re-reads the lists (the host calls it after its fallback roster changed).
  void refresh() => _recompute();

  void _onState() => _recompute();

  void _recompute() {
    final sync = state.repeaterSync;
    // Global list.
    final gs = state.globalRepeaterSet;
    final scope = scopeRegion(state);
    if (!identical(gs.rows, _gSrc) || scope?.code != _gScopeCode) {
      if (!identical(gs.rows, _gSrc)) _gAll = networkMapRows(gs.rows);
      _gSrc = gs.rows;
      _gScopeCode = scope?.code;
      _gRows = scope == null ? _gAll : rowsInBox(_gAll, grownBbox(scope.bbox!, kRegionRepeaterMarginKm));
    }
    final global = MapRepeaterSet(
      rows: _gRows,
      // No sync in this build (custom builds, tests): the list cannot exist, so the layer says it is not available.
      state: sync == null ? MapFeedState.unsupported : mapFeedStateOf(gs.state),
      asOf: gs.asOf,
      fetchedAt: gs.fetchedAt,
      attribution: gs.attribution,
      hidden: sync?.network?.data.hidden ?? 0,
      freshnessLabel: sync?.networkLabel,
      scope: scope?.name,
    );

    // The viewed region's roster: the sync's stored copy, else the host's own fetch.
    final v = state.viewingRegion;
    final stored = (sync == null || v == null) ? null : sync.roster(v.slug);
    RosterRegion? region;
    List<RegionRepeater> rows;
    MapFeedState rState;
    DateTime? rFetched;
    String? rLabel;
    final setState = v == null ? null : state.regionRepeaterSet;
    if (stored != null) {
      region = RosterRegion(slug: v!.slug, name: v.name, baseUrl: stored.baseUrl.isEmpty ? v.url : stored.baseUrl);
      rows = stored.data.rows;
      rState = mapFeedStateOf(setState!.state);
      rFetched = stored.checkedAt;
      rLabel = sync!.rosterLabel(v.slug);
    } else {
      final f = fallbackRoster();
      final syncBusy = setState != null && (setState.state == SyncState.loading || setState.state == SyncState.failed);
      if (f.region != null || f.rows.isNotEmpty) {
        region = f.region;
        rows = f.rows;
        rState = f.state;
      } else {
        region = v == null ? null : RosterRegion(slug: v.slug, name: v.name, baseUrl: v.url);
        rows = const [];
        rState = syncBusy ? mapFeedStateOf(setState.state) : f.state;
      }
    }
    if (!identical(rows, _rSrc)) {
      _rSrc = rows;
      _rRows = rosterRows(rows);
      _detail = {for (final r in rows) r.key.toLowerCase(): r};
    }
    final regionSet = MapRepeaterSet(rows: _rRows, state: rState, fetchedAt: rFetched, freshnessLabel: rLabel);

    final changed = !_same(global, _global) || !_same(regionSet, _region) || region?.slug != _rosterRegion?.slug || region?.baseUrl != _rosterRegion?.baseUrl;
    _global = global;
    _region = regionSet;
    _rosterRegion = region;
    if (changed) notifyListeners();
  }

  static bool _same(MapRepeaterSet a, MapRepeaterSet b) =>
      identical(a.rows, b.rows) &&
      a.state == b.state &&
      a.asOf == b.asOf &&
      a.fetchedAt == b.fetchedAt &&
      a.attribution == b.attribution &&
      a.hidden == b.hidden &&
      a.freshnessLabel == b.freshnessLabel &&
      a.scope == b.scope;

  /// The region the global layer is limited to: the viewed region when the phone is in it, it was picked, or (phone
  /// position unknown) it is the remembered last region; null (whole world) when it is only a guess (nearest region, first in the index) or has
  /// no bbox.
  static RegionIndexEntry? scopeRegion(AppState s) {
    final v = s.viewingRegion;
    if (v == null || v.bbox == null || v.bbox!.length != 4) return null;
    // Remembered counts only while the phone's position is unknown: a phone known to be outside every region views the
    // nearest one (and remembers it), which is not "this is my region".
    final phoneKnown = s.mapStart.kind == MapStartKind.phone;
    final known = s.currentRegion?.code == v.code || s.viewingIsManual || (!phoneKnown && s.settings.regionLast == v.code);
    return known ? v : null;
  }

  @override
  void dispose() {
    state.removeListener(_onState);
    super.dispose();
  }
}
