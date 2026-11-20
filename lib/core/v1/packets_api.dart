// The Packets reads of the Network tab (AZ-3.2), on the `/v1` base client (v1_client.dart): the list grouped by hash,
// the detail with bytes and resolved paths, more observations, the filter catalogue and `POST /v1/decode`
// (analyzer-api-contract.md 8.2). Three server states, each read handles all three:
//   1. `/v1` live: the contract's answer, every filter sent to the server.
//   2. `/v1` not live (V1NotLive): falls back QUIETLY to today's region reads, `/api/cmh/region-packets` and
//      `region-packet?hash=`, with their reduced field set: one type, one route, one observer key, one node, a whole
//      hash and a time window go to the server; several types or routes, a hash prefix, hops and SNR are filtered on
//      the phone page by page; channel, scope, source, node prefix and the filter text cannot be applied, and the list
//      names them ([PacketListPage.unapplied]). The detail then has who heard it and the paths, but no bytes.
//   3. Offline: both go through the shared ETag client (etag_client.dart), which serves the stored copy of a page that
//      was fetched before, with its "as of" time ([PacketListPage.offlineAsOf], [PacketDetail.offlineAsOf]).
// Pure Dart: no Flutter imports.
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../etag_client.dart';
import '../region_dataset_fetch.dart' show regionDatasetUri;
import '../region_overview_api.dart' show RegionDataStatus;
import '../region_packet_detail_api.dart';
import '../region_packets_api.dart' as legacy;
import 'filter_language.dart';
import 'network_api.dart' show NetworkReadSource;
import 'packet_filter.dart';
import 'packet_models.dart';
import 'v1_client.dart';

export 'filter_language.dart';
export 'packet_filter.dart';
export 'packet_models.dart';
export 'v1_client.dart';

/// The named windows of the list and how long each is (contract 3.2; the list reads at most 7 days, 90 with a
/// narrowing filter: 3.3).
const Map<String, Duration> packetWindows = {
  '15m': Duration(minutes: 15),
  '1h': Duration(hours: 1),
  '3h': Duration(hours: 3),
  '6h': Duration(hours: 6),
  '24h': Duration(hours: 24),
  '7d': Duration(days: 7),
  '30d': Duration(days: 30),
  '90d': Duration(days: 90),
};

/// The list's time window: a named one, or `since` / `until`.
class PacketWindow {
  final String? name;
  final DateTime? since, until;
  const PacketWindow.named(String this.name)
      : since = null,
        until = null;
  const PacketWindow.range(DateTime this.since, [this.until]) : name = null;

  static const PacketWindow defaultWindow = PacketWindow.named('1h');

  /// True for windows the server allows only with a narrowing filter (over 7 days).
  bool get long => name == '30d' || name == '90d' || (since != null && (until ?? DateTime.now().toUtc()).difference(since!) > const Duration(days: 7));

  Map<String, String> toQuery() => name != null
      ? {'window': name!}
      : {'since': since!.toUtc().toIso8601String(), if (until != null) 'until': until!.toUtc().toIso8601String()};

  (DateTime, DateTime) resolve(DateTime now) {
    if (name != null) {
      final to = now.toUtc();
      return (to.subtract(packetWindows[name!] ?? const Duration(hours: 1)), to);
    }
    return (since!.toUtc(), (until ?? now).toUtc());
  }

  @override
  bool operator ==(Object other) => other is PacketWindow && other.name == name && other.since == since && other.until == until;
  @override
  int get hashCode => Object.hash(name, since, until);
}

/// One page of the list.
class PacketListPage {
  final List<PacketListRow> rows;

  /// Cursor of the next (older) page; null at the end. Opaque; only valid with the same filters and [source].
  final String? next;

  /// Cursor of newer rows (`/v1` only), for live catch-up.
  final String? prev;
  final NetworkReadSource source;
  final DateTime? offlineAsOf;
  final RegionDataStatus? status;
  final Map<String, V1Source> sources;

  /// Filters this server could not apply (today's region read): plain names for the banner.
  final List<String> unapplied;
  final int? approxTotal;

  /// False when the node list behind hop resolution is not complete (contract 2.4).
  final bool? nodeListTrusted;
  final String? nodeListReason;
  const PacketListPage({
    required this.rows,
    this.next,
    this.prev,
    this.source = NetworkReadSource.v1,
    this.offlineAsOf,
    this.status,
    this.sources = const {},
    this.unapplied = const [],
    this.approxTotal,
    this.nodeListTrusted,
    this.nodeListReason,
  });
}

/// A page of observations of one packet.
class ObservationPage {
  final List<PacketObservation> rows;
  final String? next;
  const ObservationPage(this.rows, this.next);
}

/// A detail with the source meta (attribution lines).
class PacketDetailRead {
  final PacketDetail detail;
  final Map<String, V1Source> sources;
  final bool? nodeListTrusted;
  final String? nodeListReason;
  const PacketDetailRead(this.detail, {this.sources = const {}, this.nodeListTrusted, this.nodeListReason});
}

/// Today's `region-packets` row in the contract's shape: what it carries, nothing invented.
PacketListRow legacyRowToV1(legacy.PacketRow r) => PacketListRow(
      hash: r.hash.toLowerCase(),
      firstSeen: r.firstAt,
      lastSeen: r.firstAt,
      type: r.type,
      typeName: packetTypeWireName(r.type),
      route: packetRouteWireName(r.route),
      hashSize: r.hashSize,
      hops: r.minHops,
      observerCount: r.observers,
      bestSnr: r.bestSnrDb,
      origin: r.originName == null ? null : PacketNode(key: '', name: r.originName),
    );

/// Today's `region-packet` answer in the contract's shape (no bytes; hop confidence from its tree).
PacketDetail legacyDetailToV1(PacketDetailData d, String hash, {DateTime? offlineAsOf}) {
  final byHop = <String, PacketTreeNodeData>{};
  void walk(PacketTreeNodeData n) {
    if (n.hop.isNotEmpty) byHop.putIfAbsent(n.hop.toLowerCase(), () => n);
    for (final c in n.children) {
      walk(c);
    }
  }

  if (d.tree != null) walk(d.tree!);
  PacketHop hop(int i, String prefix) {
    final n = byHop[prefix];
    if (n == null) return PacketHop(index: i, prefix: prefix, confidence: HopConfidence.unknown, evidence: const ['no_known_node']);
    if (n.ambiguous) return PacketHop(index: i, prefix: prefix, confidence: HopConfidence.ambiguous, evidence: const ['prefix_collision']);
    if (n.key != null || n.name != null) {
      final low = n.confidence == 'low';
      return PacketHop(
        index: i,
        prefix: prefix,
        confidence: low ? HopConfidence.likely : HopConfidence.unique,
        node: PacketNode(key: n.key ?? '', name: n.name, role: 'repeater'),
        score: low ? null : 1.0,
        evidence: [low ? 'node_list_untrusted' : 'unique_prefix'],
      );
    }
    return PacketHop(index: i, prefix: prefix, confidence: HopConfidence.unknown, evidence: [n.outside ? 'outside_region' : 'no_known_node']);
  }

  final paths = <String, PacketPath>{};
  final obs = <PacketObservation>[];
  final direct = d.route == 2 || d.route == 3;
  for (final o in d.observations) {
    final key = o.path.map((p) => p.toLowerCase()).join('>');
    final pid = paths[key]?.id ?? 'p${paths.length + 1}';
    final oid = '${o.observer}@${o.at?.toIso8601String() ?? obs.length}';
    paths.putIfAbsent(
        key,
        () => PacketPath(
            id: pid, hops: [for (var i = 0; i < o.path.length; i++) hop(i, o.path[i].toLowerCase())], direction: direct ? 'remaining' : 'travelled'));
    obs.add(PacketObservation(
      id: oid,
      observer: PacketObserver(id: o.observer, name: o.who, kind: o.via != null ? 'outside' : 'fixed', src: o.via ?? 'meshsonar'),
      at: o.at,
      snr: o.snrDb,
      rssi: o.rssiDbm,
      pathId: pid,
      path: [for (final p in o.path) p.toLowerCase()],
      src: o.via ?? 'meshsonar',
    ));
  }
  return PacketDetail(
    source: PacketSource.legacy,
    hash: (d.hash ?? hash).toLowerCase(),
    type: d.type,
    typeName: packetTypeWireName(d.type),
    route: packetRouteWireName(d.route),
    firstSeen: d.firstAt,
    lastSeen: obs.isEmpty ? d.firstAt : obs.map((o) => o.at).whereType<DateTime>().fold<DateTime?>(null, (m, t) => m == null || t.isAfter(m) ? t : m),
    origin: d.originKey == null && d.originName == null ? null : PacketNode(key: d.originKey ?? '', name: d.originName),
    observationCount: obs.length,
    observerCount: d.observers,
    observations: obs,
    paths: paths.values.toList(),
    missing: const [
      'This server does not send packet bytes yet, so the decoded fields and the byte inspector are not shown. They arrive with the new packet service.',
    ],
    offlineAsOf: offlineAsOf,
  );
}

class PacketsApi {
  final String baseUrl;
  final V1Client v1;
  final http.Client _legacy;
  final DateTime Function() clock;
  PacketsApi(this.baseUrl, {http.Client? client, DateTime Function()? clock})
      : v1 = V1Client(baseUrl, client: client, clock: clock),
        _legacy = client ?? newRegionWireClient(),
        clock = clock ?? DateTime.now;

  /// One page of `GET /v1/packets` (grouped by hash), else of today's `region-packets`. [legacyCursor] says the
  /// cursor came from the fallback (paging stays on the source the first page came from). Throws [V1Error].
  Future<PacketListPage> list(PacketFilter filter, PacketWindow window, {String? cursor, bool legacyCursor = false, int limit = 100}) async {
    if (!legacyCursor) {
      try {
        final env = await v1.getPage('packets', PacketListRow.tryParse,
            query: {...filter.toV1Query(), ...window.toQuery(), 'groupBy': 'hash'}, cursor: cursor, limit: limit);
        final nl = env.meta.raw['nodeList'];
        return PacketListPage(
          rows: env.data,
          next: env.page?.next,
          prev: env.page?.prev,
          offlineAsOf: env.offlineAsOf,
          status: env.meta.status,
          sources: env.meta.sources,
          approxTotal: env.page?.approxTotal,
          nodeListTrusted: nl is Map && nl['trusted'] is bool ? nl['trusted'] as bool : null,
          nodeListReason: nl is Map && nl['reason'] is String ? nl['reason'] as String : null,
        );
      } on V1NotLive {
        // fall through to today's read
      }
    }
    return _legacyList(filter, window, cursor: legacyCursor ? cursor : null, limit: limit);
  }

  Future<PacketListPage> _legacyList(PacketFilter filter, PacketWindow window, {String? cursor, int limit = 100}) async {
    final lq = filter.toLegacy();
    final (since, until) = window.resolve(clock());
    final q = {
      ...lq.query,
      'since': since.toIso8601String(),
      if (window.until != null) 'until': until.toIso8601String(),
      'limit': '${limit.clamp(1, 200)}',
      'cursor': ?cursor,
    };
    final http.Response res;
    try {
      res = await _legacy.get(regionDatasetUri(baseUrl, 'region-packets', q), headers: const {'accept': 'application/json'}).timeout(v1.timeout);
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
    final page = legacy.PacketPage.fromJson(body, offlineAsOf: offlineAsOfOf(res));
    return PacketListPage(
      rows: [for (final r in page.rows) legacyRowToV1(r)].where(lq.keep).toList(),
      next: page.nextCursor,
      source: NetworkReadSource.legacy,
      offlineAsOf: page.offlineAsOf,
      status: RegionDataStatus.fromJson(body['status']),
      unapplied: lq.unapplied,
    );
  }

  /// `GET /v1/packets/{hash}`, else today's `region-packet`. Throws [V1Error] (`not_found` when nobody heard it).
  Future<PacketDetailRead> detail(String hash, {int observations = 50}) async {
    final h = hash.toLowerCase();
    try {
      final env = await v1.get('packets/$h', (d) => d, query: {'observations': '$observations'});
      final nl = env.meta.raw['nodeList'];
      return PacketDetailRead(
        PacketDetail.fromV1(env.data, offlineAsOf: env.offlineAsOf),
        sources: env.meta.sources,
        nodeListTrusted: nl is Map && nl['trusted'] is bool ? nl['trusted'] as bool : null,
        nodeListReason: nl is Map && nl['reason'] is String ? nl['reason'] as String : null,
      );
    } on V1NotLive {
      final f = await PacketDetailApi(baseUrl, client: _legacy).fetch(h);
      if (f.notFound) throw const V1Error(status: 404, code: 'not_found', message: 'Nobody on this server heard this packet.');
      if (!f.ok) throw V1Error(code: 'legacy_failed', message: f.error ?? 'The packet did not load.', offline: f.status == null && (f.error ?? '').contains('connection'));
      final d = f.data!;
      if (!d.hasRow) throw const V1Error(status: 404, code: 'not_found', message: 'No observer in this region has this packet on record.');
      return PacketDetailRead(legacyDetailToV1(d, h, offlineAsOf: f.offlineAsOf));
    }
  }

  /// `GET /v1/packets/{hash}/observations` (more rows than the detail inlines). Throws [V1Error] / [V1NotLive].
  Future<ObservationPage> observations(String hash, {String? cursor, int limit = 200}) async {
    final env = await v1.getPage('packets/${hash.toLowerCase()}/observations', PacketObservation.tryParse, cursor: cursor, limit: limit);
    return ObservationPage(env.data, env.page?.next);
  }

  /// The observations of [hash] for an expanded list row: `/v1` observations, else today's `region-packet` rows.
  Future<List<PacketObservation>> observationsForRow(String hash) async {
    try {
      return (await observations(hash, limit: 50)).rows;
    } on V1NotLive {
      return (await detail(hash)).detail.observations;
    }
  }

  /// The filter catalogue, else the copy built into the app (never throws).
  Future<FilterCatalogue> filterFields() async {
    try {
      return (await v1.get('filters/fields', FilterCatalogue.fromJson)).data;
    } catch (_) {
      return FilterCatalogue.builtin;
    }
  }

  /// `POST /v1/decode` for bytes the phone could not decode. Null when `/v1` is not live. Throws [V1Error].
  Future<({PacketDetail detail, bool known})?> decode(String hex) async {
    try {
      final env = await v1.post('decode', {'hex': hex}, (d) => d);
      final data = env.data;
      return (detail: PacketDetail.fromV1(data, source: PacketSource.serverDecode), known: data is Map && data['known'] == true);
    } on V1NotLive {
      return null;
    }
  }

  void close() {
    v1.close();
    _legacy.close();
  }
}

/// Tests replace this to inject a fake HTTP client; the Packets screens build their API through it.
PacketsApi Function(String baseUrl) packetsApiFactory = (b) => PacketsApi(b);
