// The Network tab's `/v1` reads (AZ-3.1): `summary`, `pulse`, `regions` (analyzer-api-contract.md 8.1), on the base
// client in v1_client.dart. Each read tries `/v1` first and falls back SILENTLY to today's `/api/cmh/*` read while the
// server has no `/v1` route there yet (V1NotLive):
//   summary -> /api/cmh/region-overview (the figures it has; the rest stay null, never a fake zero)
//   pulse   -> nothing (the server has no pulse read before AZ-1.11): null, so the pulse chip hides
//   regions -> /api/cmh/regions-index
// Later AZ-3.x items add their reads (packets, nodes, observers, insights, channels, search) to this file or next to it.
// Pure Dart: no Flutter imports.

import 'package:http/http.dart' as http;

import '../etag_client.dart';
import '../region_dataset_fetch.dart' show regionDatasetUri;
import '../region_lookup.dart' show RegionIndexEntry, parseRegionsIndexBody;
import '../region_overview_api.dart';
import 'v1_client.dart';

export 'v1_client.dart';

/// Where an answer came from: the `/v1` API, or today's endpoint while `/v1` is not live.
enum NetworkReadSource { v1, legacy }

/// `GET /v1/summary` `data` (contract 8.1). Counts the server does not know are null.
class NetworkSummary {
  final Map<String, int> nodesActive24h, nodesTotal;
  final int? nodesNoLocation, nodesNew7d, nodesSilent;
  final Map<String, int> observersOnline, observersTotal;
  final int? packetsLastHour, packets24h, observations24h;
  final List<(DateTime, int)> packetsPerHour;
  final Map<String, int> byType24h;
  final int? channelMessages24h, activeChannels24h;

  /// Share of packets per hash size `1`, `2`, `3` (0..1).
  final Map<String, double> hashSize;
  final int? pulseOpen;
  final String? pulseTopKind, pulseTopSeverity;
  final DateTime? lastPacketAt;
  final NetworkReadSource source;
  const NetworkSummary({
    this.nodesActive24h = const {},
    this.nodesTotal = const {},
    this.nodesNoLocation,
    this.nodesNew7d,
    this.nodesSilent,
    this.observersOnline = const {},
    this.observersTotal = const {},
    this.packetsLastHour,
    this.packets24h,
    this.observations24h,
    this.packetsPerHour = const [],
    this.byType24h = const {},
    this.channelMessages24h,
    this.activeChannels24h,
    this.hashSize = const {},
    this.pulseOpen,
    this.pulseTopKind,
    this.pulseTopSeverity,
    this.lastPacketAt,
    this.source = NetworkReadSource.v1,
  });

  static int? _sum(Map<String, int> m) => m.isEmpty ? null : m.values.fold<int>(0, (a, b) => a + b);

  /// Observers online over every kind; null when unknown.
  int? get observersOnlineTotal => _sum(observersOnline);
  int? get observersTotalAll => _sum(observersTotal);

  /// Repeaters heard in the last 24 h; null when unknown.
  int? get repeatersActive24h => nodesActive24h['repeater'];

  static Map<String, int> _ints(Object? v) => {
        if (v is Map)
          for (final e in v.entries)
            if (e.key is String && e.value is num) e.key as String: (e.value as num).toInt()
      };

  factory NetworkSummary.fromJson(Object? data) {
    if (data is! Map) throw const FormatException('summary data is not an object');
    int? i(Object? v) => v is num ? v.toInt() : null;
    final nodes = data['nodes'] is Map ? data['nodes'] as Map : const {};
    final obs = data['observers'] is Map ? data['observers'] as Map : const {};
    final pk = data['packets'] is Map ? data['packets'] as Map : const {};
    final ch = data['channels'] is Map ? data['channels'] as Map : const {};
    final pulse = data['pulse'] is Map ? data['pulse'] as Map : const {};
    final top = pulse['top'] is Map ? pulse['top'] as Map : null;
    final perHour = <(DateTime, int)>[
      if (pk['perHour'] is List)
        for (final r in pk['perHour'] as List)
          if (r is List && r.length >= 2 && v1Time(r[0]) != null && r[1] is num) (v1Time(r[0])!, (r[1] as num).toInt())
    ];
    final hs = <String, double>{
      if (data['hashSize'] is Map)
        for (final e in (data['hashSize'] as Map).entries)
          if (e.key is String && e.value is num) e.key as String: (e.value as num).toDouble()
    };
    return NetworkSummary(
      nodesActive24h: _ints(nodes['active24h']),
      nodesTotal: _ints(nodes['total']),
      nodesNoLocation: i(nodes['noLocation']),
      nodesNew7d: i(nodes['new7d']),
      nodesSilent: i(nodes['silent']),
      observersOnline: _ints(obs['online']),
      observersTotal: _ints(obs['total']),
      packetsLastHour: i(pk['lastHour']),
      packets24h: i(pk['last24h']),
      observations24h: i(pk['observations24h']),
      packetsPerHour: perHour,
      byType24h: _ints(data['byType24h']),
      channelMessages24h: i(ch['messages24h']),
      activeChannels24h: i(ch['activeChannels24h']),
      hashSize: hs,
      pulseOpen: i(pulse['open']),
      pulseTopKind: top?['kind'] is String ? top!['kind'] as String : null,
      pulseTopSeverity: top?['severity'] is String ? top!['severity'] as String : null,
      lastPacketAt: v1Time(data['lastPacketAt']),
    );
  }

  /// Today's `region-overview` in the summary's shape: what it carries, nothing invented.
  factory NetworkSummary.fromOverview(RegionOverview o) {
    final last = o.packetsPerHour.isEmpty ? null : o.packetsPerHour.last;
    return NetworkSummary(
      nodesActive24h: {if (o.repeatersHeard24h != null) 'repeater': o.repeatersHeard24h!},
      nodesTotal: {if (o.repeaters != null) 'repeater': o.repeaters!},
      // region-overview does not split observers by kind; the total sits under one key so the sums stay right.
      observersOnline: {if (o.observersOnline != null) 'all': o.observersOnline!},
      observersTotal: {if (o.observersTotal != null) 'all': o.observersTotal!},
      packets24h: o.packets24h,
      packetsLastHour: last != null && DateTime.now().toUtc().difference(last.at) < const Duration(hours: 2) ? last.n : null,
      packetsPerHour: [for (final h in o.packetsPerHour) (h.at, h.n)],
      lastPacketAt: o.lastPacketAt,
      source: NetworkReadSource.legacy,
    );
  }
}

/// One `GET /v1/pulse` event (contract 8.1). [kind] and [severity] are open sets: unknown values are kept as sent.
class PulseEvent {
  final String id, kind, severity, state, title, detail;
  final DateTime? startedAt, endedAt;
  final List<({String key, String? name, String role})> subjects;
  final Uri? webLink;
  const PulseEvent({
    required this.id,
    required this.kind,
    required this.severity,
    required this.state,
    required this.title,
    required this.detail,
    this.startedAt,
    this.endedAt,
    this.subjects = const [],
    this.webLink,
  });

  /// Rank for "the most serious first": alert 2, warn 1, everything else 0.
  int get rank => switch (severity) { 'alert' => 2, 'warn' => 1, _ => 0 };

  static PulseEvent? tryParse(Object? j) {
    if (j is! Map || j['id'] is! String || j['title'] is! String) return null;
    String s(String k, [String d = '']) => j[k] is String ? j[k] as String : d;
    final links = j['links'] is Map ? j['links'] as Map : const {};
    return PulseEvent(
      id: j['id'] as String,
      kind: s('kind', 'other'),
      severity: s('severity', 'info'),
      state: s('state', 'open'),
      title: j['title'] as String,
      detail: s('detail'),
      startedAt: v1Time(j['startedAt']),
      endedAt: v1Time(j['endedAt']),
      subjects: [
        if (j['subjects'] is List)
          for (final n in j['subjects'] as List)
            if (n is Map && n['key'] is String)
              (key: n['key'] as String, name: n['name'] is String ? n['name'] as String : null, role: n['role'] is String ? n['role'] as String : 'unknown')
      ],
      webLink: links['web'] is String ? Uri.tryParse(links['web'] as String) : null,
    );
  }
}

/// One region of `GET /v1/regions` (or of `regions-index` when `/v1` is not live).
class NetworkRegion {
  final String code, slug, name, url;
  final String? status, group, timezone;
  const NetworkRegion({required this.code, required this.slug, required this.name, required this.url, this.status, this.group, this.timezone});
}

/// A group of `GET /v1/regions` (members are region codes).
class NetworkRegionGroup {
  final String code, slug, name, url;
  final List<String> members;
  const NetworkRegionGroup({required this.code, required this.slug, required this.name, required this.url, this.members = const []});
}

class NetworkRegions {
  final List<NetworkRegion> regions;
  final List<NetworkRegionGroup> groups;
  final NetworkReadSource source;
  final DateTime? offlineAsOf;
  const NetworkRegions({this.regions = const [], this.groups = const [], this.source = NetworkReadSource.v1, this.offlineAsOf});

  /// The bare `/v1/regions` body `{regions, groups}` (contract 7: no envelope). Null when it is not that shape.
  static NetworkRegions? tryParseV1(Map<String, dynamic> j) {
    if (j['regions'] is! List) return null;
    String? s(Map e, String k) => e[k] is String && (e[k] as String).isNotEmpty ? e[k] as String : null;
    final regions = <NetworkRegion>[
      for (final e in j['regions'] as List)
        if (e is Map && s(e, 'code') != null && s(e, 'url') != null)
          NetworkRegion(
            code: s(e, 'code')!,
            slug: s(e, 'slug') ?? s(e, 'code')!.toLowerCase(),
            name: s(e, 'name') ?? s(e, 'code')!,
            url: s(e, 'url')!,
            status: s(e, 'status'),
            group: s(e, 'group'),
            timezone: s(e, 'timezone'),
          )
    ];
    final groups = <NetworkRegionGroup>[
      if (j['groups'] is List)
        for (final e in j['groups'] as List)
          if (e is Map && s(e, 'code') != null)
            NetworkRegionGroup(
              code: s(e, 'code')!,
              slug: s(e, 'slug') ?? s(e, 'code')!.toLowerCase(),
              name: s(e, 'name') ?? s(e, 'code')!,
              url: s(e, 'url') ?? '',
              members: [if (e['members'] is List) for (final m in e['members'] as List) if (m is String) m],
            )
    ];
    return NetworkRegions(regions: regions, groups: groups);
  }

  factory NetworkRegions.fromIndex(List<RegionIndexEntry> index, {DateTime? offlineAsOf}) => NetworkRegions(
        regions: [for (final r in index) NetworkRegion(code: r.code, slug: r.slug, name: r.name, url: r.url)],
        source: NetworkReadSource.legacy,
        offlineAsOf: offlineAsOf,
      );
}

/// A summary with where it came from and, when it is the stored copy, its "as of" time.
class NetworkRead<T> {
  final T data;
  final V1Meta? meta;
  final DateTime? offlineAsOf;
  final NetworkReadSource source;
  const NetworkRead(this.data, {this.meta, this.offlineAsOf, this.source = NetworkReadSource.v1});
}

/// The Network tab's reads for one host (the viewed region's own host, which sets the default scope).
class NetworkApi {
  final String baseUrl;
  final V1Client v1;
  final http.Client _legacy;
  NetworkApi(this.baseUrl, {http.Client? client, DateTime Function()? clock})
      : v1 = V1Client(baseUrl, client: client, clock: clock),
        _legacy = client ?? newRegionWireClient();

  /// `GET /v1/summary` (24 h), else today's `region-overview`. Throws [V1Error] when both fail.
  Future<NetworkRead<NetworkSummary>> summary() async {
    try {
      final env = await v1.get('summary', NetworkSummary.fromJson, query: const {'window': '24h'});
      return NetworkRead(env.data, meta: env.meta, offlineAsOf: env.offlineAsOf);
    } on V1NotLive {
      try {
        final o = await RegionOverviewApi(baseUrl, client: _legacy).overview();
        return NetworkRead(NetworkSummary.fromOverview(o), offlineAsOf: o.offlineAsOf, source: NetworkReadSource.legacy);
      } on RegionApiException catch (e) {
        throw V1Error(code: e.offline ? 'offline' : 'legacy_failed', message: e.message, offline: e.offline);
      }
    }
  }

  /// Open pulse events, most serious first; null when the server has no pulse read yet (the chip hides).
  Future<NetworkRead<List<PulseEvent>>?> pulse({String state = 'open'}) async {
    try {
      final env = await v1.getPage('pulse', PulseEvent.tryParse, query: {'state': state});
      final list = [...env.data]..sort((a, b) => b.rank.compareTo(a.rank));
      return NetworkRead(list, meta: env.meta, offlineAsOf: env.offlineAsOf);
    } on V1NotLive {
      return null;
    }
  }

  /// `GET /v1/regions` (bare body), else today's `regions-index`.
  Future<NetworkRegions> regions() async {
    try {
      final (r, asOf) = await v1.getBare('regions', NetworkRegions.tryParseV1);
      return asOf == null ? r : NetworkRegions(regions: r.regions, groups: r.groups, offlineAsOf: asOf);
    } on V1NotLive {
      final http.Response res;
      try {
        res = await _legacy.get(regionDatasetUri(baseUrl, 'regions-index'), headers: const {'accept': 'application/json'}).timeout(v1.timeout);
      } catch (e) {
        throw V1Error(code: 'offline', message: 'No connection to the server.', offline: isNetworkFailure(e));
      }
      if (res.statusCode != 200) throw V1Error(status: res.statusCode, code: 'http_${res.statusCode}', message: 'The server answered ${res.statusCode}.');
      try {
        return NetworkRegions.fromIndex(parseRegionsIndexBody(res.body), offlineAsOf: offlineAsOfOf(res));
      } on FormatException {
        throw const V1Error(code: 'unreadable', message: 'The server sent something unreadable.');
      }
    }
  }

  void close() {
    v1.close();
    _legacy.close();
  }
}

/// Tests replace this to inject a fake HTTP client; the Network shell builds its API through it.
NetworkApi Function(String baseUrl) networkApiFactory = (b) => NetworkApi(b);
