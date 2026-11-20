// The Nodes reads of the Network tab (AZ-3.4), on the `/v1` base client (v1_client.dart): the node directory for every
// role, a node's page with its sub-resources (activity, heard-by, neighbours, paths through, reach, clock, battery),
// the observers list, an observer's page and its metrics (analyzer-api-contract.md 8.3, 8.4). Three server states:
//   1. `/v1` live: the contract's answers; every directory filter goes to the server, which pages with cursors.
//   2. `/v1` not live (V1NotLive): falls back QUIETLY to today's region reads with what they carry:
//        directory  -> /api/cmh/region-repeaters?roles=all (one page, every role); role, status, last heard, silent
//                      for, the search text and "has a position" are applied on the phone; nothing is invented.
//        node page  -> /api/cmh/region-repeater?key= (identity, health figures, who heard it, neighbours, the daily SNR
//                      trend, packet types and the 7 x 24 heatmap); paths, reach, clock and battery do not exist there
//                      and stay null, so the page hides them.
//        observers  -> /api/cmh/region-observers; observer page -> /api/cmh/region-observer?key= (row, top nodes and
//                      its hourly charts turned into the metrics shape).
//   3. Offline: every read goes through the shared ETag client, which serves the stored copy of an answer fetched before;
//      [offlineAsOf] says when it was fetched ("Offline - as of ...").
// A sub-resource that fails or is absent is null (the page hides that section; never an empty box).
// Pure Dart: no Flutter imports.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../etag_client.dart';
import '../region_dataset_fetch.dart' show regionDatasetUri;
import '../region_observer_detail_api.dart';
import '../region_overview_api.dart' show RegionDataStatus, RegionObserver, RegionObservers;
import '../region_repeaters_api.dart' show RegionRepeater, RegionRepeaters, RepeaterActivity;
import '../repeater_detail_api.dart';
import 'network_api.dart' show NetworkReadSource;
import 'packet_models.dart' show PacketHop, PacketNode, PacketObserver, PacketPosition;
import 'v1_client.dart';

export 'network_api.dart' show NetworkReadSource;
export 'packet_models.dart' show PacketHop, PacketNode, PacketObserver, PacketPosition, HopConfidence;
export 'v1_client.dart';

String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _i(Object? v) => v is num && v.isFinite ? v.toInt() : null;
double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
List<String> _strs(Object? v) => [if (v is List) for (final e in v) if (e is String) e];
Map _m(Object? v) => v is Map ? v : const {};
List _l(Object? v) => v is List ? v : const [];

/// The node roles (contract 1.5), in display order.
const List<String> nodeRoles = ['repeater', 'room', 'companion', 'sensor'];

/// The node statuses (contract 1.5).
const List<String> nodeStatuses = ['active', 'degraded', 'silent', 'unknown'];

/// The directory's "heard within" choices and how long each is.
const Map<String, Duration> nodeHeardWindows = {
  '1h': Duration(hours: 1),
  '6h': Duration(hours: 6),
  '24h': Duration(hours: 24),
  '7d': Duration(days: 7),
  '30d': Duration(days: 30),
};

String nodeRoleLabel(String r) => switch (r) {
      'repeater' => 'Repeater',
      'room' => 'Room server',
      'companion' => 'Companion',
      'sensor' => 'Sensor',
      _ => 'Unknown role',
    };

String nodeStatusLabel(String s) => switch (s) {
      'active' => 'Active',
      'degraded' => 'Degraded',
      'silent' => 'Silent',
      _ => 'Unknown',
    };

/// The directory filters (contract 8.3 `GET /v1/nodes`).
class NodeQuery {
  final Set<String> roles, statuses;

  /// Heard within (`1h` .. `30d`).
  final String? lastHeard;

  /// Not heard for at least (`1h` .. `7d`).
  final String? silentFor;

  /// Name substring or key prefix.
  final String? q;
  final bool? hasLocation;
  final String sort;
  const NodeQuery({this.roles = const {}, this.statuses = const {}, this.lastHeard, this.silentFor, this.q, this.hasLocation, this.sort = 'lastHeard:desc'});

  static const NodeQuery all = NodeQuery();

  NodeQuery copyWith({Set<String>? roles, Set<String>? statuses, String? lastHeard, bool clearLastHeard = false, String? q, bool? hasLocation}) => NodeQuery(
        roles: roles ?? this.roles,
        statuses: statuses ?? this.statuses,
        lastHeard: clearLastHeard ? null : (lastHeard ?? this.lastHeard),
        silentFor: silentFor,
        q: q ?? this.q,
        hasLocation: hasLocation ?? this.hasLocation,
        sort: sort,
      );

  Map<String, String?> toV1Query() => {
        'role': roles.isEmpty ? null : (roles.toList()..sort()).join(','),
        'status': statuses.isEmpty ? null : (statuses.toList()..sort()).join(','),
        'lastHeard': lastHeard,
        'silentFor': silentFor,
        'q': (q ?? '').trim().isEmpty ? null : q!.trim(),
        'hasLocation': hasLocation?.toString(),
        'sort': sort,
      };

  /// The same filters applied on the phone (today's roster, which pages nothing and filters nothing).
  bool keeps(NodeRow r, DateTime now) {
    if (roles.isNotEmpty && !roles.contains(r.role)) return false;
    if (statuses.isNotEmpty && !statuses.contains(r.status)) return false;
    final heard = r.lastHeardAt;
    if (lastHeard != null) {
      final w = nodeHeardWindows[lastHeard];
      if (w != null && (heard == null || now.difference(heard) > w)) return false;
    }
    if (silentFor != null) {
      final w = nodeHeardWindows[silentFor];
      if (w != null && heard != null && now.difference(heard) < w) return false;
    }
    if (hasLocation != null && (r.position != null) != hasLocation) return false;
    final text = (q ?? '').trim().toLowerCase();
    if (text.isNotEmpty) {
      final hex = RegExp(r'^[0-9a-f]{2,64}$').hasMatch(text);
      final byName = (r.name ?? '').toLowerCase().contains(text);
      final byKey = hex && r.key.startsWith(text);
      if (!byName && !byKey) return false;
    }
    return true;
  }

  @override
  bool operator ==(Object other) =>
      other is NodeQuery &&
      _setEq(other.roles, roles) &&
      _setEq(other.statuses, statuses) &&
      other.lastHeard == lastHeard &&
      other.silentFor == silentFor &&
      other.q == q &&
      other.hasLocation == hasLocation &&
      other.sort == sort;
  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(roles), Object.hashAllUnordered(statuses), lastHeard, silentFor, q, hasLocation, sort);
}

bool _setEq(Set a, Set b) => a.length == b.length && a.containsAll(b);

/// One directory row (contract 8.3 `NodeRow`). Unknown values are null, never zero.
class NodeRow {
  final String key, prefix, role, status;
  final String? name, positionReason;
  final PacketPosition? position;
  final DateTime? lastHeardAt, lastAdvertAt, firstSeen;
  final int? adverts7d, hashSize, relayed24h;
  final double? offlineAfterH;
  final double? usefulnessScore;
  final String? usefulnessGrade;
  final int? batteryMv;
  final String? batteryStatus;
  final double? clockSkewS;
  final String? clockSeverity;
  final List<String> src;
  const NodeRow({
    required this.key,
    required this.prefix,
    this.role = 'unknown',
    this.status = 'unknown',
    this.name,
    this.positionReason,
    this.position,
    this.lastHeardAt,
    this.lastAdvertAt,
    this.firstSeen,
    this.adverts7d,
    this.hashSize,
    this.relayed24h,
    this.offlineAfterH,
    this.usefulnessScore,
    this.usefulnessGrade,
    this.batteryMv,
    this.batteryStatus,
    this.clockSkewS,
    this.clockSeverity,
    this.src = const [],
  });

  String get label => (name ?? '').trim().isEmpty ? 'Node ${prefix.isEmpty ? key.substring(0, 8) : prefix}' : name!.trim();

  static NodeRow? tryParse(Object? j) {
    if (j is! Map || j['key'] is! String) return null;
    final key = (j['key'] as String).toLowerCase();
    final u = j['usefulness'] is Map ? j['usefulness'] as Map : null;
    final b = j['battery'] is Map ? j['battery'] as Map : null;
    final c = j['clock'] is Map ? j['clock'] as Map : null;
    return NodeRow(
      key: key,
      prefix: _s(j['prefix'])?.toLowerCase() ?? key.substring(0, key.length.clamp(0, 2)),
      name: _s(j['name']),
      role: _s(j['role']) ?? 'unknown',
      status: _s(j['status']) ?? 'unknown',
      position: PacketPosition.tryParse(j['position']),
      positionReason: _s(j['positionReason']),
      lastHeardAt: v1Time(j['lastHeardAt']),
      lastAdvertAt: v1Time(j['lastAdvertAt']),
      firstSeen: v1Time(j['firstSeen']),
      adverts7d: _i(j['adverts7d']),
      offlineAfterH: _d(j['offlineAfterH']),
      hashSize: _i(j['hashSize']),
      relayed24h: _i(j['relayed24h']),
      usefulnessScore: u == null ? null : _d(u['score']),
      usefulnessGrade: u == null ? null : _s(u['grade']),
      batteryMv: b == null ? null : _i(b['mv']),
      batteryStatus: b == null ? null : _s(b['status']),
      clockSkewS: c == null ? null : _d(c['skewS']),
      clockSeverity: c == null ? null : _s(c['severity']),
      src: _strs(j['src']),
    );
  }

  /// Today's roster row in the directory shape. The roster's own buckets map to the contract's statuses: active and
  /// new are active, quiet is degraded, stale is silent.
  factory NodeRow.fromRoster(RegionRepeater r) => NodeRow(
        key: r.key,
        prefix: r.hashPrefix,
        name: r.name,
        role: r.role,
        status: switch (r.status) {
          RepeaterActivity.active || RepeaterActivity.fresh => 'active',
          RepeaterActivity.quiet => 'degraded',
          RepeaterActivity.stale => 'silent',
        },
        position: r.hasPosition ? PacketPosition(r.lat!, r.lon!, precision: 'as_published') : null,
        positionReason: r.hasPosition ? null : 'not_advertised',
        lastHeardAt: r.lastHeardAt,
        firstSeen: r.firstSeenAt,
        hashSize: r.hashSizeBytes,
        relayed24h: r.relays24h,
        usefulnessGrade: r.signalGrade,
      );
}

class NodeListPage {
  final List<NodeRow> rows;
  final String? next;
  final NetworkReadSource source;
  final DateTime? offlineAsOf;
  final RegionDataStatus? status;
  final Map<String, int> roleCounts, statusCounts;
  final Map<String, V1Source> sources;
  final int? approxTotal;
  const NodeListPage({
    required this.rows,
    this.next,
    this.source = NetworkReadSource.v1,
    this.offlineAsOf,
    this.status,
    this.roleCounts = const {},
    this.statusCounts = const {},
    this.sources = const {},
    this.approxTotal,
  });
}

Map<String, int> _ints(Object? v) => {
      if (v is Map)
        for (final e in v.entries)
          if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt()
    };

// ---------------------------------------------------------------- node page

class NodeHealth {
  final String status;
  final DateTime? lastHeardAt;

  /// `own_packet`, `relay_unique_prefix`, `relay_likely`.
  final String? lastHeardHow;
  final double? offlineAfterH;
  final String? thresholdKind;
  final int? packetsToday, relayed1h, relayed24h;
  final double? avgSnr, avgHops;

  /// Share of hours heard, 0..1 (the website's "Heard (7 d)").
  final double? heard24h, heard7d, heard30d;
  const NodeHealth({
    required this.status,
    this.lastHeardAt,
    this.lastHeardHow,
    this.offlineAfterH,
    this.thresholdKind,
    this.packetsToday,
    this.relayed1h,
    this.relayed24h,
    this.avgSnr,
    this.avgHops,
    this.heard24h,
    this.heard7d,
    this.heard30d,
  });

  static NodeHealth? tryParse(Object? j) {
    if (j is! Map) return null;
    final u = j['uptime'] is Map ? j['uptime'] as Map : const {};
    return NodeHealth(
      status: _s(j['status']) ?? 'unknown',
      lastHeardAt: v1Time(j['lastHeardAt']),
      lastHeardHow: _s(j['lastHeardHow']),
      offlineAfterH: _d(j['offlineAfterH']),
      thresholdKind: _s(j['thresholdKind']),
      packetsToday: _i(j['packetsToday']),
      relayed1h: _i(j['relayed1h']),
      relayed24h: _i(j['relayed24h']),
      avgSnr: _d(j['avgSnr']),
      avgHops: _d(j['avgHops']),
      heard24h: _d(u['h24']),
      heard7d: _d(u['d7']),
      heard30d: _d(u['d30']),
    );
  }
}

class NodeRadio {
  final String? firmware, model, preset;
  final double? freqMhz, bwKhz;
  final int? sf, cr;
  final bool differsFromNearby;
  const NodeRadio({this.firmware, this.model, this.preset, this.freqMhz, this.bwKhz, this.sf, this.cr, this.differsFromNearby = false});
  static NodeRadio? tryParse(Object? j) {
    if (j is! Map) return null;
    return NodeRadio(
      firmware: _s(j['firmware']),
      model: _s(j['model']),
      preset: _s(j['preset']),
      freqMhz: _d(j['freqMhz']),
      bwKhz: _d(j['bwKhz']),
      sf: _i(j['sf']),
      cr: _i(j['cr']),
      differsFromNearby: j['differsFromNearby'] == true,
    );
  }
}

class NodeAdvert {
  final String hash, route;
  final DateTime? at;
  final int? hops, observers;
  final bool? signatureValid;
  const NodeAdvert({required this.hash, this.route = 'UNKNOWN', this.at, this.hops, this.observers, this.signatureValid});
}

/// `GET /v1/nodes/{key}` (contract 8.3), or today's region-repeater mapped to it.
class NodeDetail {
  final String key;
  final Map<String, String> prefixes;
  final String? name;
  final List<String> aka;
  final String role;
  final PacketPosition? position;
  final String? positionReason, positionSource;
  final DateTime? firstSeen, lastAdvertAt, lastHeardAt;
  final NodeHealth? health;
  final int? hashSize;
  final List<int> hashSizesSeen;
  final bool hashInconsistent;
  final String? multibyte;

  /// Other relay-capable nodes sharing this node's prefix, by prefix size.
  final Map<String, int> collisions;
  final NodeRadio? radio;
  final String? scopeDefault;
  final List<String> scopesDeclared;
  final double? usefulnessScore;
  final String? usefulnessGrade;
  final int? batteryMv;
  final String? batteryStatus;
  final DateTime? batteryAt;
  final double? clockSkewS, clockDriftSPerDay;
  final String? clockSeverity;
  final int? clockSamples;
  final bool? claimed;
  final List<NodeAdvert> recentAdverts;
  final String? qr;
  final List<String> src;
  const NodeDetail({
    required this.key,
    this.prefixes = const {},
    this.name,
    this.aka = const [],
    this.role = 'unknown',
    this.position,
    this.positionReason,
    this.positionSource,
    this.firstSeen,
    this.lastAdvertAt,
    this.lastHeardAt,
    this.health,
    this.hashSize,
    this.hashSizesSeen = const [],
    this.hashInconsistent = false,
    this.multibyte,
    this.collisions = const {},
    this.radio,
    this.scopeDefault,
    this.scopesDeclared = const [],
    this.usefulnessScore,
    this.usefulnessGrade,
    this.batteryMv,
    this.batteryStatus,
    this.batteryAt,
    this.clockSkewS,
    this.clockDriftSPerDay,
    this.clockSeverity,
    this.clockSamples,
    this.claimed,
    this.recentAdverts = const [],
    this.qr,
    this.src = const [],
  });

  String get prefix => prefixes['1'] ?? key.substring(0, 2);
  String get label => (name ?? '').trim().isEmpty ? 'Node $prefix' : name!.trim();

  factory NodeDetail.fromJson(Object? d) {
    if (d is! Map || d['key'] is! String) throw const FormatException('node detail has no key');
    final h = _m(d['hash']);
    final sc = d['scope'] is Map ? d['scope'] as Map : null;
    final u = d['usefulness'] is Map ? d['usefulness'] as Map : null;
    final b = d['battery'] is Map ? d['battery'] as Map : null;
    final c = d['clock'] is Map ? d['clock'] as Map : null;
    final cl = d['claim'] is Map ? d['claim'] as Map : null;
    return NodeDetail(
      key: (d['key'] as String).toLowerCase(),
      prefixes: {for (final e in _m(d['prefix']).entries) if (e.key is String && e.value is String) e.key as String: (e.value as String).toLowerCase()},
      name: _s(d['name']),
      aka: _strs(d['aka']),
      role: _s(d['role']) ?? 'unknown',
      position: PacketPosition.tryParse(d['position']),
      positionReason: _s(d['positionReason']),
      positionSource: _s(d['positionSource']),
      firstSeen: v1Time(d['firstSeen']),
      lastAdvertAt: v1Time(d['lastAdvertAt']),
      lastHeardAt: v1Time(d['lastHeardAt']),
      health: NodeHealth.tryParse(d['health']),
      hashSize: _i(h['size']),
      hashSizesSeen: [for (final e in _l(h['sizesSeen'])) if (e is num) e.toInt()],
      hashInconsistent: h['inconsistent'] == true,
      multibyte: _s(h['multibyte']),
      collisions: _ints(h['collisions']),
      radio: NodeRadio.tryParse(d['radio']),
      scopeDefault: sc == null ? null : _s(sc['default']),
      scopesDeclared: sc == null ? const [] : _strs(sc['declared']),
      usefulnessScore: u == null ? null : _d(u['score']),
      usefulnessGrade: u == null ? null : _s(u['grade']),
      batteryMv: b == null ? null : _i(b['mv']),
      batteryStatus: b == null ? null : _s(b['status']),
      batteryAt: b == null ? null : v1Time(b['at']),
      clockSkewS: c == null ? null : _d(c['skewS']),
      clockDriftSPerDay: c == null ? null : _d(c['driftSPerDay']),
      clockSeverity: c == null ? null : _s(c['severity']),
      clockSamples: c == null ? null : _i(c['samples']),
      claimed: cl == null ? null : cl['claimed'] == true,
      recentAdverts: [
        for (final a in _l(d['recentAdverts']))
          if (a is Map && a['hash'] is String)
            NodeAdvert(
                hash: (a['hash'] as String).toLowerCase(),
                route: _s(a['route']) ?? 'UNKNOWN',
                at: v1Time(a['at']),
                hops: _i(a['hops']),
                observers: _i(a['observers']),
                signatureValid: a['signatureValid'] is bool ? a['signatureValid'] as bool : null)
      ],
      qr: _s(_m(d['links'])['qr']),
      src: _strs(d['src']),
    );
  }
}

class NodeActivity {
  /// (hour or day, packets, relayed|null)
  final List<(DateTime, int, int?)> timeline;

  /// (UTC day, mean SNR dB | null, samples)
  final List<(DateTime, double?, int)> snrTrend;
  final Map<String, int> types;
  final Map<String, int> hopDistribution;

  /// 7 x 24 packet counts, oldest day first, ending on [heatmapEnd].
  final List<List<int>>? heatmap;
  final DateTime? heatmapEnd;
  final double? availabilityPct, snrMeanDb, relayPct;
  final String? signalGrade;
  const NodeActivity({
    this.timeline = const [],
    this.snrTrend = const [],
    this.types = const {},
    this.hopDistribution = const {},
    this.heatmap,
    this.heatmapEnd,
    this.availabilityPct,
    this.snrMeanDb,
    this.relayPct,
    this.signalGrade,
  });

  bool get isEmpty => timeline.isEmpty && snrTrend.isEmpty && types.isEmpty && heatmap == null;

  factory NodeActivity.fromJson(Object? d) {
    final m = _m(d);
    final cols = _strs(m['timelineColumns']);
    final ir = cols.indexOf('relayed');
    final hm = _m(m['heatmap']);
    final rows = [for (final r in _l(hm['rows'])) if (r is List) [for (final c in r) c is num ? c.toInt() : 0]];
    final st = _m(m['stats']);
    return NodeActivity(
      timeline: [
        for (final r in _l(m['timeline']))
          if (r is List && r.length >= 2 && v1Time(r[0]) != null && r[1] is num)
            (v1Time(r[0])!, (r[1] as num).toInt(), ir > 0 && r.length > ir && r[ir] is num ? (r[ir] as num).toInt() : null)
      ],
      snrTrend: [
        for (final e in _l(m['snrTrend']))
          if (e is Map && DateTime.tryParse('${e['day']}') != null) (DateTime.parse('${e['day']}T00:00:00Z'), _d(e['meanDb']), _i(e['n']) ?? 0)
      ],
      types: _ints(m['types']),
      hopDistribution: _ints(m['hopDistribution']),
      heatmap: rows.length == 7 ? rows : null,
      heatmapEnd: DateTime.tryParse('${hm['endDay']}T00:00:00Z'),
      availabilityPct: _d(st['availabilityPct']),
      snrMeanDb: _d(st['snrMeanDb']),
      relayPct: _d(st['relayPct']),
      signalGrade: _s(st['signalGrade']),
    );
  }
}

class HeardByRow {
  final PacketObserver observer;
  final bool direct;
  final int packets;
  final double? avgSnr, avgRssi;

  /// Today's region read gives the best SNR, not the mean.
  final double? bestSnr;
  final DateTime? lastAt;
  const HeardByRow({required this.observer, this.direct = true, required this.packets, this.avgSnr, this.avgRssi, this.bestSnr, this.lastAt});
  static HeardByRow? tryParse(Object? j) {
    if (j is! Map) return null;
    final o = PacketObserver.tryParse(j['observer']);
    if (o == null) return null;
    return HeardByRow(observer: o, direct: j['direct'] != false, packets: _i(j['packets']) ?? 0, avgSnr: _d(j['avgSnr']), avgRssi: _d(j['avgRssi']), lastAt: v1Time(j['lastAt']));
  }
}

class NeighbourRow {
  final PacketNode? node;
  final String? prefix;
  final PacketPosition? position;

  /// `unique`, `likely`, `ambiguous`, `unknown` (contract 2.3).
  final String confidence;
  final int? count, observers;
  final double? score, avgSnr, distanceKm;
  final DateTime? lastAt;
  final List<PacketNode> candidates;
  final List<String> kinds;
  const NeighbourRow({
    this.node,
    this.prefix,
    this.position,
    this.confidence = 'unknown',
    this.count,
    this.observers,
    this.score,
    this.avgSnr,
    this.distanceKm,
    this.lastAt,
    this.candidates = const [],
    this.kinds = const [],
  });

  String get label => node?.label ?? 'Unresolved hop ${prefix ?? '?'}';

  static NeighbourRow? tryParse(Object? j) {
    if (j is! Map) return null;
    final n = PacketNode.tryParse(j['node']);
    if (n == null && j['prefix'] is! String) return null;
    return NeighbourRow(
      node: n,
      prefix: _s(j['prefix']) ?? n?.key.substring(0, 2),
      position: PacketPosition.tryParse(j['position']),
      confidence: _s(j['confidence']) ?? 'unknown',
      count: _i(j['count']),
      observers: _i(j['observers']),
      score: _d(j['score']),
      avgSnr: _d(j['avgSnr']),
      distanceKm: _d(j['distanceKm']),
      lastAt: v1Time(j['lastAt']),
      candidates: [for (final c in _l(j['candidates'])) if (c is Map) ?PacketNode.tryParse(c['node'])],
      kinds: _strs(j['kinds']),
    );
  }
}

class NodePathRow {
  final List<PacketHop> hops;
  final int count;
  final DateTime? lastAt;
  final String? sampleHash;
  const NodePathRow({required this.hops, this.count = 0, this.lastAt, this.sampleHash});
  static NodePathRow? tryParse(Object? j) {
    if (j is! Map) return null;
    return NodePathRow(
      hops: [for (final h in _l(j['hops'])) ?PacketHop.tryParse(h)],
      count: _i(j['count']) ?? 0,
      lastAt: v1Time(j['lastAt']),
      sampleHash: _s(j['sampleHash']),
    );
  }
}

class ReachLink {
  final PacketNode node;
  final int weHear, theyHear;
  final bool bidirectional;
  final double? distanceKm;
  const ReachLink({required this.node, this.weHear = 0, this.theyHear = 0, this.bidirectional = false, this.distanceKm});
}

class NodeReach {
  final List<ReachLink> links;
  final List<PacketObserver> directObservers;
  final int? degree, degreeRank;
  final double? importance;
  const NodeReach({this.links = const [], this.directObservers = const [], this.degree, this.degreeRank, this.importance});
  factory NodeReach.fromJson(Object? d) {
    final m = _m(d);
    return NodeReach(
      links: [
        for (final l in _l(m['links']))
          if (l is Map && PacketNode.tryParse(l['node']) != null)
            ReachLink(
                node: PacketNode.tryParse(l['node'])!,
                weHear: _i(l['weHear']) ?? 0,
                theyHear: _i(l['theyHear']) ?? 0,
                bidirectional: l['bidirectional'] == true,
                distanceKm: _d(l['distanceKm']))
      ],
      directObservers: [for (final o in _l(m['directObservers'])) ?PacketObserver.tryParse(o)],
      degree: _i(m['degree']),
      degreeRank: _i(m['degreeRank']),
      importance: _d(m['importance']),
    );
  }
}

class NodeClock {
  final String severity;
  final double? skewS, skewRecentS, driftSPerDay;
  final bool bimodal;
  final List<(DateTime, double)> samples;
  const NodeClock({required this.severity, this.skewS, this.skewRecentS, this.driftSPerDay, this.bimodal = false, this.samples = const []});
  factory NodeClock.fromJson(Object? d) {
    final m = _m(d);
    return NodeClock(
      severity: _s(m['severity']) ?? 'no_clock',
      skewS: _d(m['skewS']),
      skewRecentS: _d(m['skewRecentS']),
      driftSPerDay: _d(m['driftSPerDay']),
      bimodal: m['bimodal'] == true,
      samples: [
        for (final s in _l(m['samples']))
          if (s is Map && v1Time(s['at']) != null && _d(s['skewS']) != null) (v1Time(s['at'])!, _d(s['skewS'])!)
      ],
    );
  }
}

class NodeBattery {
  final int? latestMv;
  final DateTime? latestAt;
  final String status;
  final int lowBelowMv, criticalBelowMv;
  final List<(DateTime, int)> series;
  final String? source;
  const NodeBattery({this.latestMv, this.latestAt, this.status = 'unknown', this.lowBelowMv = 3300, this.criticalBelowMv = 3000, this.series = const [], this.source});
  bool get isEmpty => latestMv == null && series.isEmpty;
  factory NodeBattery.fromJson(Object? d) {
    final m = _m(d);
    final th = _m(m['thresholds']);
    return NodeBattery(
      latestMv: _i(m['latestMv']),
      latestAt: v1Time(m['latestAt']),
      status: _s(m['status']) ?? 'unknown',
      lowBelowMv: _i(th['lowBelowMv']) ?? 3300,
      criticalBelowMv: _i(th['criticalBelowMv']) ?? 3000,
      series: [
        for (final r in _l(m['series']))
          if (r is List && r.length >= 2 && v1Time(r[0]) != null && r[1] is num) (v1Time(r[0])!, (r[1] as num).toInt())
      ],
      source: _s(m['source']),
    );
  }
}

/// Everything a node page shows. Each section is null when the API did not supply it (the page hides it).
class NodePage {
  final NodeDetail detail;
  final NodeActivity? activity;
  final List<HeardByRow>? heardBy;

  /// Observers that heard it only as a relay (heard-by `meta.relayOnlyObservers`).
  final int? relayOnlyObservers;
  final List<NeighbourRow>? neighbours;
  final List<NodePathRow>? paths;
  final int? totalPaths;
  final NodeReach? reach;
  final NodeClock? clock;
  final NodeBattery? battery;
  final NetworkReadSource source;
  final DateTime? offlineAsOf;
  final RegionDataStatus? status;
  final Map<String, V1Source> sources;
  const NodePage({
    required this.detail,
    this.activity,
    this.heardBy,
    this.relayOnlyObservers,
    this.neighbours,
    this.paths,
    this.totalPaths,
    this.reach,
    this.clock,
    this.battery,
    this.source = NetworkReadSource.v1,
    this.offlineAsOf,
    this.status,
    this.sources = const {},
  });
}

/// Today's region-repeater in the node page's shape: only what it carries.
NodePage legacyNodePage(RepeaterDetailData d, String key, {DateTime? offlineAsOf}) {
  final r = d.row;
  final detail = NodeDetail(
    key: key.toLowerCase(),
    prefixes: r == null ? const {} : {'1': r.hashPrefix.substring(0, r.hashPrefix.length.clamp(0, 2))},
    name: r?.name,
    role: r?.role ?? 'unknown',
    position: r != null && r.hasPosition ? PacketPosition(r.lat!, r.lon!, precision: 'as_published') : null,
    positionReason: r != null && r.hasPosition ? null : 'not_advertised',
    firstSeen: r?.firstSeenAt,
    lastHeardAt: r?.lastHeardAt,
    health: r == null
        ? null
        : NodeHealth(
            status: switch (r.status) { 'active' || 'new' => 'active', 'quiet' => 'degraded', _ => 'silent' },
            lastHeardAt: r.lastHeardAt,
            relayed24h: r.relays24h,
            avgSnr: r.snrMeanDb,
            heard7d: r.heardHoursPct == null ? null : r.heardHoursPct! / 100,
          ),
    hashSize: r?.hashSizeBytes,
    usefulnessGrade: null,
  );
  final types = <String, int>{
    for (final t in d.packetTypes) _legacyTypeName(t.type): t.n,
  };
  final end = d.heatmapEnd == null ? null : DateTime.tryParse('${d.heatmapEnd}T00:00:00Z');
  final activity = NodeActivity(
    snrTrend: [for (final s in d.snrDaily ?? const <DailySnr>[]) (s.day, s.meanDb, s.n)],
    types: types,
    heatmap: d.heatmap != null && d.heatmap!.length == 7 ? d.heatmap : null,
    heatmapEnd: end,
    signalGrade: r?.signalGrade,
  );
  return NodePage(
    detail: detail,
    activity: activity.isEmpty ? null : activity,
    heardBy: [
      for (final o in d.observers)
        HeardByRow(observer: PacketObserver(id: o.key, name: o.name ?? '${o.key.substring(0, o.key.length.clamp(0, 8))}…'), packets: o.packets, bestSnr: o.bestSnrDb, lastAt: o.lastAt)
    ],
    neighbours: [
      for (final n in d.neighbours)
        NeighbourRow(
          node: PacketNode(key: n.key, name: n.name),
          prefix: n.key.substring(0, n.key.length.clamp(0, 2)),
          confidence: 'unique',
          count: n.packets,
          avgSnr: n.snrDb,
          distanceKm: n.distanceKm,
          lastAt: n.lastAt,
          kinds: [n.kind],
        )
    ],
    source: NetworkReadSource.legacy,
    offlineAsOf: offlineAsOf,
    status: RegionDataStatus(state: RegionDataStatus.fromJson({'state': d.status.state}).state, reason: d.status.reason, computedAt: d.status.computedAt),
  );
}

String _legacyTypeName(int t) => switch (t) {
      0 => 'REQ',
      1 => 'RESPONSE',
      2 => 'TXT_MSG',
      3 => 'ACK',
      4 => 'ADVERT',
      5 => 'GRP_TXT',
      6 => 'GRP_DATA',
      7 => 'ANON_REQ',
      8 => 'PATH',
      9 => 'TRACE',
      10 => 'MULTIPART',
      11 => 'CONTROL',
      15 => 'RAW_CUSTOM',
      _ => 'UNKNOWN',
    };

// ---------------------------------------------------------------- observers

/// One observer row (contract 8.4).
class ObserverRow {
  final String id, name, kind, status, src;
  final String? iata, firmware;
  final PacketPosition? position;
  final DateTime? lastSeen;
  final int? packets1h, packets24h, batteryMv;
  final double? noiseFloorDbm, clockOffsetS, airtimeTxPct1h, airtimeRxPct1h;
  final bool dutyCycleWarn;
  const ObserverRow({
    required this.id,
    required this.name,
    this.kind = 'fixed',
    this.status = 'offline',
    this.src = 'meshsonar',
    this.iata,
    this.firmware,
    this.position,
    this.lastSeen,
    this.packets1h,
    this.packets24h,
    this.batteryMv,
    this.noiseFloorDbm,
    this.clockOffsetS,
    this.airtimeTxPct1h,
    this.airtimeRxPct1h,
    this.dutyCycleWarn = false,
  });

  static ObserverRow? tryParse(Object? j) {
    if (j is! Map || j['id'] is! String) return null;
    final id = j['id'] as String;
    return ObserverRow(
      id: id,
      name: _s(j['name']) ?? id,
      kind: _s(j['kind']) ?? 'fixed',
      status: _s(j['status']) ?? 'offline',
      src: _s(j['src']) ?? 'meshsonar',
      iata: _s(j['iata']),
      firmware: _s(j['firmware']),
      position: PacketPosition.tryParse(j['position']),
      lastSeen: v1Time(j['lastSeen']),
      packets1h: _i(j['packets1h']),
      packets24h: _i(j['packets24h']),
      batteryMv: _i(j['batteryMv']),
      noiseFloorDbm: _d(j['noiseFloorDbm']),
      clockOffsetS: _d(j['clockOffsetS']),
      airtimeTxPct1h: _d(j['airtimeTxPct1h']),
      airtimeRxPct1h: _d(j['airtimeRxPct1h']),
      dutyCycleWarn: j['dutyCycleWarn'] == true,
    );
  }

  /// Today's region-observers row: phones are `phone`, our own stations `fixed`, everyone else's `outside`.
  factory ObserverRow.fromLegacy(RegionObserver o) => ObserverRow(
        id: o.key.toLowerCase(),
        name: o.displayName,
        kind: o.phone ? 'phone' : (o.source == 'meshsonar' ? 'fixed' : 'outside'),
        status: o.online ? 'online' : 'offline',
        src: o.phone ? 'meshsonar-phone' : (o.source == 'meshsonar' ? 'meshsonar' : 'outside'),
        firmware: o.firmware,
        // Phones never get a position (contract 11.4), even when an old row carries a cell centre.
        position: !o.phone && o.lat != null && o.lon != null ? PacketPosition(o.lat!, o.lon!, precision: 'as_published') : null,
        lastSeen: o.lastSeen,
        packets1h: o.packetsPerHour,
        batteryMv: o.batteryMv,
        noiseFloorDbm: o.noiseFloorDbm,
      );
}

class ObserverListPage {
  final List<ObserverRow> rows;
  final String? next;
  final NetworkReadSource source;
  final DateTime? offlineAsOf;
  final RegionDataStatus? status;
  final Map<String, V1Source> sources;
  const ObserverListPage({required this.rows, this.next, this.source = NetworkReadSource.v1, this.offlineAsOf, this.status, this.sources = const {}});
}

class ObserverNeighbour {
  final PacketNode node;
  final double? snr;
  final int? heardAgoS;
  const ObserverNeighbour(this.node, this.snr, this.heardAgoS);
}

/// `GET /v1/observers/{id}` (contract 8.4), or today's region-observer mapped to it.
class ObserverDetail {
  final ObserverRow row;
  final String? model, radio;
  final int? uptimeS, reboots7d;
  final DateTime? lastReboot;
  final DateTime? neighbourReportAt;
  final List<ObserverNeighbour> neighbours;
  final List<String> qualityFlags;
  final bool? trusted;
  final List<(PacketNode, int)> topNodes;
  const ObserverDetail({
    required this.row,
    this.model,
    this.radio,
    this.uptimeS,
    this.reboots7d,
    this.lastReboot,
    this.neighbourReportAt,
    this.neighbours = const [],
    this.qualityFlags = const [],
    this.trusted,
    this.topNodes = const [],
  });

  factory ObserverDetail.fromJson(Object? d) {
    final row = ObserverRow.tryParse(d);
    if (row == null || d is! Map) throw const FormatException('observer detail has no id');
    final r = d['radio'];
    String? radio;
    if (r is Map) {
      final f = _d(r['freqMhz']), bw = _d(r['bwKhz']), sf = _i(r['sf']), cr = _i(r['cr']);
      radio = [if (f != null) '$f MHz', if (bw != null) '$bw kHz', if (sf != null) 'SF$sf', if (cr != null) 'CR$cr'].join(' · ');
      if (radio.isEmpty) radio = null;
    } else {
      radio = _s(r);
    }
    final nr = d['neighborReport'] is Map ? d['neighborReport'] as Map : null;
    final q = _m(d['quality']);
    return ObserverDetail(
      row: row,
      model: _s(d['model']),
      radio: radio,
      uptimeS: _i(d['uptimeS']),
      reboots7d: _i(d['reboots7d']),
      lastReboot: v1Time(d['lastReboot']),
      neighbourReportAt: nr == null ? null : v1Time(nr['at']),
      neighbours: [
        if (nr != null)
          for (final n in _l(nr['neighbors']))
            if (n is Map && PacketNode.tryParse(n['node']) != null) ObserverNeighbour(PacketNode.tryParse(n['node'])!, _d(n['snr']), _i(n['heardAgoS']))
      ],
      qualityFlags: _strs(q['flags']),
      trusted: q['trusted'] is bool ? q['trusted'] as bool : null,
      topNodes: [
        for (final t in _l(d['topNodes']))
          if (t is Map && PacketNode.tryParse(t['node']) != null) (PacketNode.tryParse(t['node'])!, _i(t['packets']) ?? 0)
      ],
    );
  }
}

/// One sample of an observer's metrics; a missing sample has nulls, never zeros.
class ObserverSample {
  final DateTime at;
  final double? noiseFloorDbm, airtimeTxPct, airtimeRxPct, errorsPerMin;
  final int? batteryMv, packetsRx;
  final bool rebooted;
  const ObserverSample(this.at, {this.noiseFloorDbm, this.airtimeTxPct, this.airtimeRxPct, this.errorsPerMin, this.batteryMv, this.packetsRx, this.rebooted = false});
}

class ObserverMetrics {
  final String resolution;
  final List<ObserverSample> samples;
  final List<(DateTime, DateTime)> gaps;
  final double dutyCycleWarnPct;
  const ObserverMetrics({required this.resolution, this.samples = const [], this.gaps = const [], this.dutyCycleWarnPct = 10});

  /// True for the 5-minute series (else hourly or daily).
  bool get fiveMinute => resolution == '5m';

  bool get isEmpty => samples.every((s) => s.noiseFloorDbm == null && s.airtimeTxPct == null && s.airtimeRxPct == null && s.batteryMv == null && s.packetsRx == null);

  factory ObserverMetrics.fromJson(Object? d) {
    final m = _m(d);
    final cols = _strs(m['columns']);
    int ix(String c) => cols.indexOf(c);
    Object? at(List r, String c) => ix(c) >= 0 && ix(c) < r.length ? r[ix(c)] : null;
    return ObserverMetrics(
      resolution: _s(m['resolution']) ?? '5m',
      samples: [
        for (final r in _l(m['rows']))
          if (r is List && v1Time(at(r, 'at')) != null)
            ObserverSample(v1Time(at(r, 'at'))!,
                noiseFloorDbm: _d(at(r, 'noiseFloorDbm')),
                airtimeTxPct: _d(at(r, 'airtimeTxPct')),
                airtimeRxPct: _d(at(r, 'airtimeRxPct')),
                errorsPerMin: _d(at(r, 'errorsPerMin')),
                batteryMv: _i(at(r, 'batteryMv')),
                packetsRx: _i(at(r, 'packetsRx')),
                rebooted: at(r, 'rebooted') == true)
      ],
      gaps: [
        for (final g in _l(m['gaps']))
          if (g is List && g.length == 2 && v1Time(g[0]) != null && v1Time(g[1]) != null) (v1Time(g[0])!, v1Time(g[1])!)
      ],
      dutyCycleWarnPct: _d(m['dutyCycleWarnPct']) ?? 10,
    );
  }

  /// Today's hourly charts (region-observer) merged by hour into samples.
  factory ObserverMetrics.fromLegacy(ObserverDetailData d) {
    final by = <DateTime, Map<String, num?>>{};
    void put(List<HourPoint> s, String a, [String? b]) {
      for (final p in s) {
        final m = by.putIfAbsent(p.at, () => {});
        m[a] = p.a;
        if (b != null) m[b] = p.b;
      }
    }

    put(d.noiseFloor, 'nf');
    put(d.airtime, 'tx', 'rx');
    put(d.battery, 'mv');
    put(d.packetsPerHour, 'n');
    final times = by.keys.toList()..sort();
    return ObserverMetrics(resolution: '1h', samples: [
      for (final t in times)
        ObserverSample(t,
            noiseFloorDbm: by[t]!['nf']?.toDouble(),
            airtimeTxPct: by[t]!['tx']?.toDouble(),
            airtimeRxPct: by[t]!['rx']?.toDouble(),
            batteryMv: by[t]!['mv']?.toInt(),
            packetsRx: by[t]!['n']?.toInt())
    ]);
  }
}

class ObserverPage {
  final ObserverDetail detail;
  final ObserverMetrics? metrics;
  final NetworkReadSource source;
  final DateTime? offlineAsOf;
  final RegionDataStatus? status;
  final Map<String, V1Source> sources;
  const ObserverPage({required this.detail, this.metrics, this.source = NetworkReadSource.v1, this.offlineAsOf, this.status, this.sources = const {}});
}

// ---------------------------------------------------------------- the API

class NodesApi {
  final String baseUrl;
  final V1Client v1;
  final http.Client _legacy;
  final DateTime Function() clock;
  NodesApi(this.baseUrl, {http.Client? client, DateTime Function()? clock})
      : v1 = V1Client(baseUrl, client: client, clock: clock),
        _legacy = client ?? newRegionWireClient(),
        clock = clock ?? DateTime.now;

  /// One page of `GET /v1/nodes`, else today's whole roster filtered on the phone. Throws [V1Error].
  Future<NodeListPage> nodes(NodeQuery q, {String? cursor, bool legacyCursor = false, int limit = 100}) async {
    if (!legacyCursor) {
      try {
        final env = await v1.getPage('nodes', NodeRow.tryParse, query: q.toV1Query(), cursor: cursor, limit: limit);
        return NodeListPage(
          rows: env.data,
          next: env.page?.next,
          offlineAsOf: env.offlineAsOf,
          status: env.meta.status,
          roleCounts: _ints(env.meta.raw['counts']),
          statusCounts: _ints(env.meta.raw['statusCounts']),
          sources: env.meta.sources,
          approxTotal: env.page?.approxTotal,
        );
      } on V1NotLive {
        // fall through
      }
    }
    final (body, asOf) = await _legacyGet('region-repeaters', {'roles': 'all'});
    final roster = RegionRepeaters.fromJson(body);
    final now = clock().toUtc();
    final all = [for (final r in roster.rows) NodeRow.fromRoster(r)];
    final kept = all.where((r) => q.keeps(r, now)).toList()
      ..sort((a, b) => (b.lastHeardAt ?? DateTime(0)).compareTo(a.lastHeardAt ?? DateTime(0)));
    final roles = <String, int>{};
    final statuses = <String, int>{};
    for (final r in all) {
      roles[r.role] = (roles[r.role] ?? 0) + 1;
      statuses[r.status] = (statuses[r.status] ?? 0) + 1;
    }
    return NodeListPage(
      rows: kept,
      source: NetworkReadSource.legacy,
      offlineAsOf: asOf,
      status: RegionDataStatus(state: RegionDataStatus.fromJson({'state': roster.status.state}).state, reason: roster.status.reason, computedAt: roster.status.computedAt),
      roleCounts: roles,
      statusCounts: statuses,
    );
  }

  /// A node's page: `GET /v1/nodes/{key}` and its sub-resources in parallel (each null when it fails or is absent),
  /// else today's region-repeater. Throws [V1Error] (`not_found` for an unknown key).
  Future<NodePage> node(String key) async {
    final k = key.toLowerCase();
    try {
      final env = await v1.get('nodes/$k', NodeDetail.fromJson);
      Future<V1Envelope<T>?> sub<T>(String p, T Function(Object?) parse) async {
        try {
          return await v1.get('nodes/$k/$p', parse);
        } catch (_) {
          return null;
        }
      }

      final r = await Future.wait<Object?>([
        sub('activity', NodeActivity.fromJson),
        sub('heard-by', (d) => [for (final e in _l(d)) ?HeardByRow.tryParse(e)]),
        sub('neighbors', (d) => [for (final e in _l(d)) ?NeighbourRow.tryParse(e)]),
        sub('paths', (d) => [for (final e in _l(d)) ?NodePathRow.tryParse(e)]),
        sub('reach', NodeReach.fromJson),
        sub('clock', NodeClock.fromJson),
        sub('battery', NodeBattery.fromJson),
      ]);
      final act = r[0] as V1Envelope<NodeActivity>?;
      final hb = r[1] as V1Envelope<List<HeardByRow>>?;
      final nb = r[2] as V1Envelope<List<NeighbourRow>>?;
      final pa = r[3] as V1Envelope<List<NodePathRow>>?;
      final re = r[4] as V1Envelope<NodeReach>?;
      final cl = r[5] as V1Envelope<NodeClock>?;
      final ba = r[6] as V1Envelope<NodeBattery>?;
      return NodePage(
        detail: env.data,
        activity: act == null || act.data.isEmpty ? null : act.data,
        heardBy: hb?.data,
        relayOnlyObservers: hb == null ? null : _i(hb.meta.raw['relayOnlyObservers']),
        neighbours: nb?.data,
        paths: pa?.data,
        totalPaths: pa == null ? null : _i(pa.meta.raw['totalPaths']),
        reach: re?.data,
        clock: cl?.data,
        battery: ba == null || ba.data.isEmpty ? null : ba.data,
        offlineAsOf: env.offlineAsOf,
        status: env.meta.status,
        sources: env.meta.sources,
      );
    } on V1NotLive {
      try {
        final d = await fetchRepeaterDetail(baseUrl, k, client: _legacy);
        return legacyNodePage(d, k);
      } on RepeaterDetailException catch (e) {
        throw V1Error(
            status: e.kind == RepeaterDetailFailure.notFound ? 404 : null,
            code: switch (e.kind) {
              RepeaterDetailFailure.notFound => 'not_found',
              RepeaterDetailFailure.badKey => 'bad_param',
              RepeaterDetailFailure.network => 'offline',
              _ => 'legacy_failed',
            },
            message: e.message,
            offline: e.kind == RepeaterDetailFailure.network);
      }
    }
  }

  /// `GET /v1/observers`, else today's region-observers. Throws [V1Error].
  Future<ObserverListPage> observers({Set<String> kinds = const {}, Set<String> statuses = const {}, String? cursor, int limit = 200}) async {
    try {
      final env = await v1.getPage('observers', ObserverRow.tryParse,
          query: {'kind': kinds.isEmpty ? null : kinds.join(','), 'status': statuses.isEmpty ? null : statuses.join(',')}, cursor: cursor, limit: limit);
      return ObserverListPage(rows: env.data, next: env.page?.next, offlineAsOf: env.offlineAsOf, status: env.meta.status, sources: env.meta.sources);
    } on V1NotLive {
      final (body, asOf) = await _legacyGet('region-observers');
      final o = RegionObservers.fromJson(body);
      final rows = [
        for (final r in o.rows)
          if ((kinds.isEmpty || kinds.contains(ObserverRow.fromLegacy(r).kind)) && (statuses.isEmpty || statuses.contains(ObserverRow.fromLegacy(r).status)))
            ObserverRow.fromLegacy(r)
      ];
      return ObserverListPage(rows: rows, source: NetworkReadSource.legacy, offlineAsOf: asOf, status: o.status);
    }
  }

  /// An observer's page: `GET /v1/observers/{id}` and `.../metrics` (24 h), else today's region-observer.
  Future<ObserverPage> observer(String id, {String window = '24h'}) async {
    final enc = Uri.encodeComponent(id);
    try {
      final env = await v1.get('observers/$enc', ObserverDetail.fromJson);
      ObserverMetrics? metrics;
      try {
        final m = await v1.get('observers/$enc/metrics', ObserverMetrics.fromJson, query: {'window': window});
        metrics = m.data.isEmpty ? null : m.data;
      } catch (_) {
        metrics = null;
      }
      return ObserverPage(detail: env.data, metrics: metrics, offlineAsOf: env.offlineAsOf, status: env.meta.status, sources: env.meta.sources);
    } on V1NotLive {
      final f = await ObserverDetailApi(baseUrl, client: _legacy).fetch(id);
      if (f.notFound) throw const V1Error(status: 404, code: 'not_found', message: 'This region does not know that observer.');
      if (!f.ok) throw V1Error(code: 'legacy_failed', message: f.error ?? 'The observer did not load.', offline: f.status == null);
      final d = f.data!;
      final row = d.row;
      if (row == null) throw const V1Error(status: 404, code: 'not_found', message: 'This region does not know that observer.');
      final metrics = ObserverMetrics.fromLegacy(d);
      return ObserverPage(
        detail: ObserverDetail(
          row: ObserverRow.fromLegacy(row),
          model: row.model,
          radio: d.radio,
          trusted: row.trusted,
          topNodes: [for (final n in d.topNodes) (PacketNode(key: n.key.toLowerCase(), name: n.name), n.packets)],
        ),
        metrics: metrics.isEmpty ? null : metrics,
        source: NetworkReadSource.legacy,
        offlineAsOf: f.offlineAsOf,
        status: d.status,
      );
    }
  }

  Future<(Map<String, dynamic>, DateTime?)> _legacyGet(String name, [Map<String, String>? q]) async {
    final http.Response res;
    try {
      res = await _legacy.get(regionDatasetUri(baseUrl, name, q), headers: const {'accept': 'application/json'}).timeout(v1.timeout);
    } catch (e) {
      throw V1Error(code: 'offline', message: 'No connection to the server.', offline: isNetworkFailure(e));
    }
    Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (res.statusCode != 200 || body is! Map<String, dynamic>) {
      final msg = body is Map && body['error'] is String ? body['error'] as String : 'The server answered ${res.statusCode}.';
      throw V1Error(status: res.statusCode, code: res.statusCode == 429 ? 'rate_limited' : 'http_${res.statusCode}', message: msg);
    }
    return (body, offlineAsOfOf(res));
  }

  void close() {
    v1.close();
    _legacy.close();
  }
}

/// Tests replace this to inject a fake HTTP client; the Nodes screens build their API through it.
NodesApi Function(String baseUrl) nodesApiFactory = (b) => NodesApi(b);
