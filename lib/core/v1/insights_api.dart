// Three `/v1` reads the app shows natively since build 77 (Round 2 N-U10, W6, W9), on the shared [V1Client]:
//   GET /v1/insights/overview?window=   the Overview's "Signal and traffic", packets per hour (or day), hop counts and
//                                        kinds of packets
//   GET /v1/insights/repeaters          My Repeaters: every repeater and room of the region with its figures. The app
//                                        reads the whole list and keeps the person's own nodes on the phone, so the
//                                        list of what they starred or claimed is never sent anywhere.
//   GET /v1/status                      Status: whether the data is arriving (sources, summaries, notices).
// Shapes follow the site (meshcore-insights src/server/v1/schemas-insights.ts InsightsOverview and InsightsRepeaters,
// src/server/v1/endpoints/network.ts status). Every field is optional: an older server, or one that leaves a field
// out, gives null or an empty list, never an exception and never a made-up zero.
//
// Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import '../region_overview_api.dart' show RegionDataStatus;
import 'v1_client.dart';

export 'v1_client.dart' show V1Error, V1NotLive;

String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _i(Object? v) => v is num && v.isFinite ? v.toInt() : null;
double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
Map _m(Object? v) => v is Map ? v : const {};
List _l(Object? v) => v is List ? v : const [];

/// The windows the Overview offers, as the server names them, with the words on the picker.
const List<(String, String)> overviewWindows = [('1h', '1 hour'), ('24h', '24 hours'), ('7d', '7 days'), ('30d', '30 days')];

/// A mean with its range, or just a mean.
class StatRange {
  final double mean;
  final double? min, max;
  const StatRange(this.mean, {this.min, this.max});

  static StatRange? tryParse(Object? j) {
    final m = _m(j);
    final mean = _d(m['mean']);
    return mean == null ? null : StatRange(mean, min: _d(m['min']), max: _d(m['max']));
  }
}

/// `GET /v1/insights/overview` for one window.
class InsightsOverview {
  /// `1h` (one point per hour) or `1d` (per day).
  final String bucket;
  final int? packets, observations, observationsWithSignal, uniqueNodes, activeChannels, decryptableChannels;
  final StatRange? snr, rssi, hops, packetSize;

  /// (start of the hour or day, packets), oldest first.
  final List<(DateTime, int)> perBucket;

  /// (hops, packets), fewest hops first.
  final List<(int, int)> hopDistribution;

  /// (type name as the server sends it, packets, share 0..1), most first.
  final List<(String, int, double?)> typeMix;
  final RegionDataStatus? status;
  final DateTime? dataAt;
  const InsightsOverview({
    this.bucket = '1h',
    this.packets,
    this.observations,
    this.observationsWithSignal,
    this.uniqueNodes,
    this.activeChannels,
    this.decryptableChannels,
    this.snr,
    this.rssi,
    this.hops,
    this.packetSize,
    this.perBucket = const [],
    this.hopDistribution = const [],
    this.typeMix = const [],
    this.status,
    this.dataAt,
  });

  bool get daily => bucket == '1d';

  static InsightsOverview parse(Object? d, {RegionDataStatus? status, DateTime? dataAt}) {
    final m = _m(d);
    final st = _m(m['stats']);
    final pb = _m(m['perBucket']);
    final cols = [for (final c in _l(pb['columns'])) '$c'];
    final at = cols.indexOf('at'), pk = cols.indexOf('packets');
    return InsightsOverview(
      bucket: _s(m['bucket']) ?? '1h',
      packets: _i(st['transmissions']),
      observations: _i(st['observations']),
      observationsWithSignal: _i(st['observationsWithSignal']),
      uniqueNodes: _i(st['uniqueNodes']),
      activeChannels: _i(st['activeChannels']),
      decryptableChannels: _i(st['decryptableChannels']),
      snr: StatRange.tryParse(st['snr']),
      rssi: StatRange.tryParse(st['rssi']),
      hops: StatRange.tryParse(st['hops']),
      packetSize: StatRange.tryParse(st['packetSize']),
      perBucket: [
        if (at >= 0 && pk >= 0)
          for (final r in _l(pb['rows']))
            if (r is List && r.length > at && r.length > pk && v1Time(r[at]) != null && _i(r[pk]) != null) (v1Time(r[at])!, _i(r[pk])!),
      ]..sort((a, b) => a.$1.compareTo(b.$1)),
      hopDistribution: [
        for (final r in _l(m['hopDistribution']))
          if (r is List && r.length >= 2 && _i(r[0]) != null && _i(r[1]) != null) (_i(r[0])!, _i(r[1])!),
      ]..sort((a, b) => a.$1.compareTo(b.$1)),
      typeMix: [
        for (final r in _l(m['typeMix']))
          if (_s(_m(r)['type']) != null && _i(_m(r)['packets']) != null) (_s(_m(r)['type'])!, _i(_m(r)['packets'])!, _d(_m(r)['share'])),
      ]..sort((a, b) => b.$2.compareTo(a.$2)),
      status: status,
      dataAt: dataAt,
    );
  }
}

/// One repeater or room of `GET /v1/insights/repeaters` (columns `REPEATER_COLUMNS` on the site).
class RepeaterInsight {
  final String key;
  final String? name;
  final String role, status;
  final DateTime? lastHeardAt;
  final int? relays1h, relays24h, relays7d, adverts7d, observers7d;
  final double? snrMean7d, trafficShare, bridge, uptime7d;
  final String? grade;
  const RepeaterInsight({
    required this.key,
    this.name,
    this.role = 'unknown',
    this.status = 'unknown',
    this.lastHeardAt,
    this.relays1h,
    this.relays24h,
    this.relays7d,
    this.adverts7d,
    this.observers7d,
    this.snrMean7d,
    this.trafficShare,
    this.bridge,
    this.uptime7d,
    this.grade,
  });

  /// The name, or the first 8 hex of the key.
  String get label => name ?? (key.length > 8 ? key.substring(0, 8) : key);
}

/// `GET /v1/insights/repeaters` read as rows (the server sends columns and rows to keep the answer small).
List<RepeaterInsight> parseRepeaterInsights(Object? d) {
  final m = _m(d);
  final cols = [for (final c in _l(m['columns'])) '$c'];
  int col(String n) => cols.indexOf(n);
  final iKey = col('key');
  if (iKey < 0) return const [];
  Object? at(List r, String n) {
    final i = col(n);
    return i >= 0 && i < r.length ? r[i] : null;
  }

  return [
    for (final r in _l(m['rows']))
      if (r is List && r.length > iKey && _s(r[iKey]) != null)
        RepeaterInsight(
          key: _s(r[iKey])!.toLowerCase(),
          name: _s(at(r, 'name')),
          role: _s(at(r, 'role')) ?? 'unknown',
          status: _s(at(r, 'status')) ?? 'unknown',
          lastHeardAt: v1Time(at(r, 'lastHeardAt')),
          relays1h: _i(at(r, 'relays1h')),
          relays24h: _i(at(r, 'relays24h')),
          relays7d: _i(at(r, 'relays7d')),
          adverts7d: _i(at(r, 'adverts7d')),
          observers7d: _i(at(r, 'observers7d')),
          snrMean7d: _d(at(r, 'snrMean7d')),
          trafficShare: _d(at(r, 'trafficShare')),
          bridge: _d(at(r, 'bridge')),
          uptime7d: _d(at(r, 'uptime7d')),
          grade: _s(at(r, 'grade')),
        ),
  ];
}

/// One source of packets on the Status screen.
class StatusSource {
  /// `first_party_mqtt`, `phones`, `outside_live` (or another the server adds).
  final String pipeline;

  /// The server's plain name; null from an older server (the app then names it, [statusSourceName]).
  final String? label;

  /// `ok`, `degraded`, `down` or `unknown`.
  final String state;
  final DateTime? lastAt;

  /// Packets in the newest full hour; null when the server did not count them (never shown as 0).
  final int? rate1h;
  final int? socketsConnected, socketsTotal;
  const StatusSource({required this.pipeline, this.label, this.state = 'unknown', this.lastAt, this.rate1h, this.socketsConnected, this.socketsTotal});
}

/// One summary the server builds (hourly counts, daily figures).
class StatusSummary {
  final String name;
  final String? label;

  /// `ok` or `stale`.
  final String state;
  final DateTime? lastAt;
  const StatusSummary({required this.name, this.label, this.state = 'ok', this.lastAt});
}

/// `GET /v1/status`.
class StatusReport {
  /// `ok`, `degraded` or `down`.
  final String overall;
  final List<StatusSource> sources;
  final List<StatusSummary> summaries;

  /// Plain sentences, each once.
  final List<String> notices;
  final DateTime? at;
  const StatusReport({this.overall = 'ok', this.sources = const [], this.summaries = const [], this.notices = const [], this.at});

  static StatusReport parse(Object? d, {DateTime? at}) {
    final m = _m(d);
    return StatusReport(
      overall: _s(m['overall']) ?? 'ok',
      sources: [
        for (final r in _l(m['ingest']))
          if (_s(_m(r)['pipeline']) != null)
            StatusSource(
              pipeline: _s(_m(r)['pipeline'])!,
              label: _s(_m(r)['label']),
              state: _s(_m(r)['state']) ?? 'unknown',
              lastAt: v1Time(_m(r)['lastAt']),
              rate1h: _i(_m(r)['rate1h']),
              socketsConnected: _i(_m(_m(r)['sockets'])['connected']),
              socketsTotal: _i(_m(_m(r)['sockets'])['total']),
            ),
      ],
      summaries: [
        for (final r in _l(m['rollups']))
          if (_s(_m(r)['name']) != null)
            StatusSummary(name: _s(_m(r)['name'])!, label: _s(_m(r)['label']), state: _s(_m(r)['state']) ?? 'ok', lastAt: v1Time(_m(r)['lastAt'])),
      ],
      notices: {
        for (final r in _l(m['incidents']))
          if (_s(_m(r)['text']) != null) _s(_m(r)['text'])!,
      }.toList(),
      at: at,
    );
  }
}

/// The name of a source of packets: the server's own words when it sent them, else the app's.
String statusSourceName(StatusSource s) =>
    s.label ??
    switch (s.pipeline) {
      'first_party_mqtt' => 'MeshSonar listening stations',
      'phones' => 'MeshSonar phones',
      'outside_live' => 'Outside feeds',
      _ => 'Another source',
    };

class InsightsApi {
  final String baseUrl;
  final V1Client v1;
  InsightsApi(this.baseUrl, {http.Client? client, DateTime Function()? clock}) : v1 = V1Client(baseUrl, client: client, clock: clock);

  /// The Overview's figures for one of [overviewWindows]. Throws [V1Error] / [V1NotLive].
  Future<InsightsOverview> overview({String window = '24h'}) async {
    final env = await v1.get('insights/overview', (d) => d, query: {'window': window});
    return InsightsOverview.parse(env.data, status: env.meta.status, dataAt: env.meta.dataAt);
  }

  /// Every repeater and room of the region (the person's own are picked out on the phone). Throws [V1Error] /
  /// [V1NotLive].
  Future<List<RepeaterInsight>> repeaters() async {
    final env = await v1.get('insights/repeaters', parseRepeaterInsights, query: const {'limit': '2000'});
    return env.data;
  }

  /// Whether the data is arriving. Throws [V1Error] / [V1NotLive].
  Future<StatusReport> status() async {
    final env = await v1.get('status', (d) => d);
    return StatusReport.parse(env.data, at: env.meta.dataAt ?? env.meta.generatedAt);
  }

  void close() => v1.close();
}

/// Replaced by widget tests.
InsightsApi Function(String baseUrl) insightsApiFactory = (b) => InsightsApi(b);
