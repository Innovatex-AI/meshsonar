// The map-owned adapter between whatever keeps the repeater lists (the startup-sync `RepeaterSync`, wired at
// integration) and the two clustered repeater layers: `network` (every MeshCore repeater, GET
// /api/cmh/network-repeaters) and `repeaters` (the viewed region's roster, GET region-repeaters?roles=roster).
// Design: stream-1-maps.md section 4.3.
//
// The map never fetches or parses either list. It sees them through [RepeaterMapFeed], a small interface the owner of
// the lists implements (or wraps in [StaticRepeaterMapFeed]); [RepeaterMapSource] turns each list into
// [RepeaterPoints] + a [ClusterIndex] (built off the UI isolate for big lists) only when the list's identity changes.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/cluster_index.dart';
import '../../../core/region_repeaters_api.dart' show RegionRepeater, RepeaterActivity;
import '../../../core/repeater_points.dart';
import 'map_layer.dart';

/// Layer id of the global "All MeshCore repeaters" layer (the website's `?show=network`).
const String kNetworkLayerId = 'network';

/// Layer id of the viewed region's roster layer (the website's `?show=repeaters`).
const String kRosterLayerId = 'repeaters';

/// Load state of one list, as the feed reports it.
enum MapFeedState {
  /// Nothing stored and nothing asked yet.
  idle,

  /// A request is out and nothing is stored yet.
  loading,

  /// Stored and confirmed by the server.
  ready,

  /// Stored copy; the newest refresh failed (offline or server error).
  stale,

  /// Nothing stored and the newest attempt failed.
  failed,

  /// The server does not offer this list (404).
  unsupported,
}

/// One list as the feed hands it over. [rows] must get a new identity on every change (the source rebuilds only then).
@immutable
class MapRepeaterSet {
  final List<MapRepeaterRow> rows;
  final MapFeedState state;

  /// The server's own "as of" (global: the newest upstream pull).
  final DateTime? asOf;

  /// When this phone last got the list confirmed.
  final DateTime? fetchedAt;

  /// Credit line to show with the rows (global list: "Data: MeshCore Map (map.meshcore.io)").
  final String? attribution;

  /// Repeaters the server counted but does not list (owners hide their position).
  final int hidden;

  /// "Offline - as of 2 h ago" style label from the feed's cache, when it has one.
  final String? freshnessLabel;

  const MapRepeaterSet({
    required this.rows,
    required this.state,
    this.asOf,
    this.fetchedAt,
    this.attribution,
    this.hidden = 0,
    this.freshnessLabel,
  });

  static const MapRepeaterSet idle = MapRepeaterSet(rows: [], state: MapFeedState.idle);
}

/// The viewed region a roster belongs to (for the "Open repeater page" link and the reason texts).
@immutable
class RosterRegion {
  final String slug;

  /// Display name ("CMH", "Columbus").
  final String name;

  /// The region host's base URL (what `openRepeaterDetail` needs).
  final String baseUrl;
  const RosterRegion({required this.slug, required this.name, required this.baseUrl});
}

/// What the map needs from the owner of the repeater lists. Notifies on any change.
abstract class RepeaterMapFeed implements Listenable {
  MapRepeaterSet get global;
  MapRepeaterSet get region;

  /// The region [region] is the roster of; null when no region is being viewed.
  RosterRegion? get rosterRegion;

  /// Full roster fields for a key in [region] (status, SNR, grade...), or null.
  RegionRepeater? rosterDetail(String key);
}

/// A feed whose values are set from outside (tests, and the integration wrapper around `RepeaterSync`).
class StaticRepeaterMapFeed extends ChangeNotifier implements RepeaterMapFeed {
  MapRepeaterSet _global;
  MapRepeaterSet _region;
  RosterRegion? _rosterRegion;
  Map<String, RegionRepeater> _detail;

  StaticRepeaterMapFeed({
    this._global = MapRepeaterSet.idle,
    this._region = MapRepeaterSet.idle,
    this._rosterRegion,
    Iterable<RegionRepeater> roster = const [],
  }) : _detail = {for (final r in roster) r.key: r};

  @override
  MapRepeaterSet get global => _global;
  @override
  MapRepeaterSet get region => _region;
  @override
  RosterRegion? get rosterRegion => _rosterRegion;
  @override
  RegionRepeater? rosterDetail(String key) => _detail[key.toLowerCase()];

  set global(MapRepeaterSet v) {
    _global = v;
    notifyListeners();
  }

  set region(MapRepeaterSet v) {
    _region = v;
    notifyListeners();
  }

  /// Replaces the roster (rows, detail and region) in one notification.
  void setRoster(RosterRegion? region, List<RegionRepeater> roster, {MapFeedState state = MapFeedState.ready, String? freshnessLabel}) {
    _rosterRegion = region;
    _detail = {for (final r in roster) r.key: r};
    _region = MapRepeaterSet(rows: rosterRows(roster), state: state, freshnessLabel: freshnessLabel);
    notifyListeners();
  }
}

/// Roster rows as map rows: positioned ones only, band = the roster status ordinal ([RepeaterActivity.index]),
/// last seen = last heard.
List<MapRepeaterRow> rosterRows(List<RegionRepeater> roster) => [
  for (final r in roster)
    if (r.hasPosition)
      MapRepeaterRow(
        key: r.key,
        name: r.name,
        lat: r.lat!,
        lon: r.lon!,
        isRoom: r.role == 'room',
        lastSeen: r.lastHeardAt,
        band: r.status.index,
      ),
];

/// Where a point came from.
enum RepeaterPointSource { global, roster }

/// One repeater for a detail sheet.
@immutable
class RepeaterPoint {
  final String layerId;
  final RepeaterPointSource source;
  final String key;

  /// Name, or the first 8 key characters.
  final String name;
  final bool isRoom;
  final double lat, lon;

  /// Last advert (global) or last heard (roster).
  final DateTime? lastSeen;
  final int band;

  /// Roster fields when this key is in the viewed region's roster (also for a global point).
  final RegionRepeater? roster;

  /// The region whose roster holds this key (enables "Open repeater page"); null when it is in no known roster.
  final RosterRegion? region;

  /// Credit line for the data.
  final String? attribution;

  const RepeaterPoint({
    required this.layerId,
    required this.source,
    required this.key,
    required this.name,
    required this.isRoom,
    required this.lat,
    required this.lon,
    required this.band,
    this.lastSeen,
    this.roster,
    this.region,
    this.attribution,
  });

  @override
  bool operator ==(Object other) => other is RepeaterPoint && other.layerId == layerId && other.key == key;
  @override
  int get hashCode => Object.hash(layerId, key);
}

/// Points + cluster index for one list, with the identity of the rows they were built from.
class _Built {
  final List<MapRepeaterRow> rows;
  final bool dedupe;
  final RepeaterPoints points;
  final ClusterIndex index;
  _Built(this.rows, this.dedupe, this.points, this.index);
}

/// Builds and caches the render-ready form of both lists. Notifies when a new index is ready.
class RepeaterMapSource extends ChangeNotifier {
  final RepeaterMapFeed feed;
  final DateTime Function() clock;

  /// Lists at least this long are clustered in a background isolate.
  final int isolateThreshold;

  _Built? _global, _roster;
  int _gen = 0;
  bool _dedupe = true;
  bool _disposed = false;
  Future<void>? _pending;

  RepeaterMapSource(this.feed, {DateTime Function()? clock, this.isolateThreshold = 2000}) : clock = clock ?? DateTime.now {
    feed.addListener(_onFeed);
    _onFeed();
  }

  /// Leave roster keys out of the global layer (both layers on: the roster draws them, with status colours).
  bool get dedupeAgainstRoster => _dedupe;
  set dedupeAgainstRoster(bool v) {
    if (v == _dedupe) return;
    _dedupe = v;
    _onFeed();
  }

  RepeaterPoints get globalPoints => _global?.points ?? RepeaterPoints.empty;
  RepeaterPoints get rosterPoints => _roster?.points ?? RepeaterPoints.empty;
  ClusterIndex? get globalIndex => _global?.index;
  ClusterIndex? get rosterIndex => _roster?.index;

  RepeaterPoints pointsOf(String layerId) => layerId == kNetworkLayerId ? globalPoints : rosterPoints;
  ClusterIndex? indexOf(String layerId) => layerId == kNetworkLayerId ? globalIndex : rosterIndex;

  /// Completes when the build started by the latest feed change is done (tests, and a host that wants to wait).
  Future<void> get settled => _pending ?? Future.value();

  void _onFeed() {
    final g = feed.global.rows, r = feed.region.rows;
    final needRoster = _roster == null || !identical(_roster!.rows, r);
    final needGlobal = _global == null || !identical(_global!.rows, g) || _global!.dedupe != _dedupe || (needRoster && _dedupe);
    if (!needRoster && !needGlobal) {
      // State or labels changed only: availability may differ.
      notifyListeners();
      return;
    }
    final gen = ++_gen;
    final now = clock();
    _pending = () async {
      _Built? roster = _roster;
      if (needRoster) {
        final pts = RepeaterPoints.fromRows(r, now: now);
        final idx = await ClusterIndex.build(pts.lat, pts.lon, band: pts.band, isolateThreshold: isolateThreshold);
        roster = _Built(r, false, pts, idx);
      }
      _Built? global = _global;
      if (needGlobal) {
        final skip = _dedupe ? roster!.points.key.toSet() : const <String>{};
        final pts = RepeaterPoints.fromRows(g, now: now, skipKeys: skip);
        final idx = await ClusterIndex.build(pts.lat, pts.lon, band: pts.band, isolateThreshold: isolateThreshold);
        global = _Built(g, _dedupe, pts, idx);
      }
      if (_disposed || gen != _gen) return;
      _roster = roster;
      _global = global;
      notifyListeners();
    }();
  }

  /// The sheet row for point [i] of [layerId].
  RepeaterPoint pointAt(String layerId, int i) {
    final p = pointsOf(layerId);
    final key = p.key[i];
    final detail = feed.rosterDetail(key);
    final region = detail == null ? null : feed.rosterRegion;
    final global = layerId == kNetworkLayerId;
    return RepeaterPoint(
      layerId: layerId,
      source: global ? RepeaterPointSource.global : RepeaterPointSource.roster,
      key: key,
      name: p.name[i],
      isRoom: p.isRoom(i),
      lat: p.lat[i],
      lon: p.lon[i],
      band: p.band[i],
      lastSeen: p.lastSeen(i),
      roster: detail,
      region: region,
      attribution: global ? feed.global.attribution : null,
    );
  }

  /// The switch state and the line under it for [layerId] (`network` or `repeaters`).
  LayerStatus statusOf(String layerId) {
    final global = layerId == kNetworkLayerId;
    final set = global ? feed.global : feed.region;
    final region = feed.rosterRegion;
    if (!global && region == null) {
      return const LayerStatus(LayerAvailability.empty, detail: 'Pick a region to see its repeaters');
    }
    final built = global ? _global : _roster;
    final ready = built != null && identical(built.rows, set.rows);
    final count = ready ? built.points.length + built.points.skipped : set.rows.length;
    String what(int n) => '$n ${global ? (n == 1 ? 'repeater' : 'repeaters') : (n == 1 ? 'repeater with a position' : 'repeaters with a position')}';
    String countLine() {
      final parts = <String>[
        what(count),
        if (global && set.hidden > 0) '${set.hidden} hidden by their owners',
        if (global && set.attribution != null) set.attribution!,
      ];
      return parts.join(' · ');
    }

    switch (set.state) {
      case MapFeedState.unsupported:
        return const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet');
      case MapFeedState.idle:
      case MapFeedState.loading:
        return LayerStatus(LayerAvailability.loading, detail: global ? 'Loading repeaters…' : 'Loading ${region!.name} repeaters…');
      case MapFeedState.failed:
        return const LayerStatus(LayerAvailability.failed, detail: "Couldn't load. Check the connection and retry.", canRetry: true);
      case MapFeedState.ready:
      case MapFeedState.stale:
        if (set.rows.isEmpty) {
          return LayerStatus(
            LayerAvailability.empty,
            detail: global ? 'No repeaters reported yet' : 'No repeaters with a position in ${region!.name}',
          );
        }
        if (!ready) return LayerStatus(LayerAvailability.loading, detail: 'Preparing ${what(set.rows.length)}…');
        if (set.state == MapFeedState.stale) {
          return LayerStatus(
            LayerAvailability.stale,
            detail: [countLine(), set.freshnessLabel ?? 'Offline copy'].join(' · '),
            canRetry: true,
          );
        }
        return LayerStatus(LayerAvailability.ready, detail: countLine());
    }
  }

  @override
  void dispose() {
    _disposed = true;
    feed.removeListener(_onFeed);
    super.dispose();
  }
}

/// Roster status for a band ordinal written by [rosterRows].
RepeaterActivity rosterActivityOfBand(int band) =>
    band >= 0 && band < RepeaterActivity.values.length ? RepeaterActivity.values[band] : RepeaterActivity.stale;
