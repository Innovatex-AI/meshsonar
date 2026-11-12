// The Analyze view's data contract and pure model (AN-1, app side). Mirrors the website's `src/lib/region/analyze.ts`
// (meshcore-insights docs/analyze-contract.md): the app reads the SAME engine endpoints with the SAME rules, so the Analyze
// tab shows the same sections and numbers as the website. Each figure has ONE value (the endpoint's number, formatted
// here); nothing older than 36 h is shown as live; a source chip says where packets came from. No I/O, no Flutter.
//
// Endpoints (all `GET <region host>/api/cmh/<fn>`): region-insights (E9), region-repeater-health (E6), region-overview
// (E8 recentEvents), region-traffic?hours=24 (E3), region-node-gate?days=30 (E4), region-status (DEF-2 states).

const Duration staleAfter = Duration(hours: 36);

int? _int(Object? v) => v is num && v.isFinite ? v.round() : null;
double? _dbl(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
String? _str(Object? v) => v is String ? v : null;
List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? [
        for (final e in v)
          if (e is Map) e.cast<String, dynamic>(),
      ]
    : const [];
List<double> _nums(Object? v) => v is List ? [for (final e in v) e is num ? e.toDouble() : 0.0] : const [];

// ---- the engine's status block ({state, reason, computedAt, source}), as every region read sends it
class EngineStatus {
  /// ready | partial | pending | unavailable | stale | not_found
  final String state;
  final String? reason;
  const EngineStatus(this.state, this.reason);

  /// A missing or unreadable block is treated as unavailable, never as ready.
  static EngineStatus parse(Object? j) {
    if (j is! Map) return const EngineStatus('unavailable', 'The server sent no status.');
    return EngineStatus(_str(j['state']) ?? 'unavailable', _str(j['reason']));
  }
}

// ---- E9 findings
class Finding {
  final String code, severity, section, title, detail;
  final List<String> refs;
  const Finding({
    required this.code,
    required this.severity,
    required this.section,
    required this.title,
    required this.detail,
    this.refs = const [],
  });
}

class InsightsRead {
  final EngineStatus status;
  final DateTime? builtAt;
  final List<Finding> rows;
  const InsightsRead(this.status, this.builtAt, this.rows);
  static InsightsRead parse(Map<String, dynamic> j) =>
      InsightsRead(EngineStatus.parse(j['status']), _time(j['builtAt']), [
        for (final r in _maps(j['rows']))
          if (_str(r['title']) != null)
            Finding(
              code: _str(r['code']) ?? '',
              severity: _str(r['severity']) ?? 'info',
              section: _str(r['section']) ?? 'network',
              title: r['title'] as String,
              detail: _str(r['detail']) ?? '',
              refs: [
                for (final k in (r['refs'] is List ? r['refs'] as List : const []))
                  if (k is String) k,
              ],
            ),
      ]);
}

DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

// ---- E3 traffic
class SourceShare {
  final int packets;
  final int observations;
  final double? share; // a fraction 0..1
  final int? observers;
  const SourceShare(this.packets, this.observations, this.share, this.observers);
  static SourceShare parse(Object? j) {
    final m = j is Map ? j.cast<String, dynamic>() : const <String, dynamic>{};
    return SourceShare(_int(m['packets']) ?? 0, _int(m['observations']) ?? 0, _dbl(m['share']), _int(m['observers']));
  }
}

class TrafficRow {
  final DateTime? at;
  final String source;
  final int packets;
  final List<double> byType, hopObs, snrHist;
  const TrafficRow({
    required this.at,
    required this.source,
    required this.packets,
    required this.byType,
    required this.hopObs,
    required this.snrHist,
  });
}

class TrafficRead {
  final EngineStatus status;
  final String bucket;
  final DateTime? builtAt;
  final SourceShare all, ours, phone, outside;
  final double? snrMeanDb, rssiMeanDbm;
  final int obsFlagged;
  final List<TrafficRow> rows;
  const TrafficRead({
    required this.status,
    required this.bucket,
    required this.builtAt,
    required this.all,
    required this.ours,
    required this.phone,
    required this.outside,
    required this.snrMeanDb,
    required this.rssiMeanDbm,
    required this.obsFlagged,
    required this.rows,
  });
  static TrafficRead parse(Map<String, dynamic> j) {
    final s = j['sources'] is Map ? (j['sources'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    return TrafficRead(
      status: EngineStatus.parse(j['status']),
      bucket: _str(j['bucket']) ?? 'hour',
      builtAt: _time(j['builtAt']),
      all: SourceShare.parse(s['all']),
      ours: SourceShare.parse(s['ours']),
      phone: SourceShare.parse(s['phone']),
      outside: SourceShare.parse(s['outside']),
      snrMeanDb: _dbl(j['snrMeanDb']),
      rssiMeanDbm: _dbl(j['rssiMeanDbm']),
      obsFlagged: _int(j['obsFlagged']) ?? 0,
      rows: [
        for (final r in _maps(j['rows']))
          TrafficRow(
            at: _time(r['at']),
            source: _str(r['source']) ?? 'all',
            packets: _int(r['packets']) ?? 0,
            byType: _nums(r['byType']),
            hopObs: _nums(r['hopObs']),
            snrHist: _nums(r['snrHist']),
          ),
      ],
    );
  }
}

// ---- E4 node-list gate
class NodeListGate {
  final String state; // complete | partial | stale | unknown
  final bool trusted;
  final String reason;
  final int known, total;
  final double? ratio, packetRatio;
  final int windowH;
  final DateTime? computedAt;
  const NodeListGate({
    required this.state,
    required this.trusted,
    required this.reason,
    required this.known,
    required this.total,
    required this.ratio,
    required this.packetRatio,
    required this.windowH,
    required this.computedAt,
  });
  static NodeListGate? parse(Object? j) {
    if (j is! Map) return null;
    final c = j['coverage'] is Map ? (j['coverage'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final p = c['packets'] is Map ? (c['packets'] as Map) : const {};
    return NodeListGate(
      state: _str(j['state']) ?? 'unknown',
      trusted: j['trusted'] == true,
      reason: _str(j['reason']) ?? '',
      known: _int(c['known']) ?? 0,
      total: _int(c['total']) ?? 0,
      ratio: _dbl(c['ratio']),
      packetRatio: _dbl(p['ratio']),
      windowH: _int(c['windowH']) ?? 24,
      computedAt: _time(j['computedAt']),
    );
  }
}

class GateDay {
  final String day, state;
  final int codes, known;
  final double? ratio;
  final DateTime? builtAt;
  const GateDay({
    required this.day,
    required this.state,
    required this.codes,
    required this.known,
    required this.ratio,
    required this.builtAt,
  });
}

class NodeGateRead {
  final NodeListGate? gate;
  final List<GateDay> history;
  final String hopsFrom; // e3 | own observers
  const NodeGateRead(this.gate, this.history, this.hopsFrom);
  static NodeGateRead parse(Map<String, dynamic> j) => NodeGateRead(NodeListGate.parse(j['gate']), [
    for (final r in _maps(j['history']))
      if (_str(r['day']) != null)
        GateDay(
          day: r['day'] as String,
          state: _str(r['state']) ?? '',
          codes: _int(r['codes']) ?? 0,
          known: _int(r['known']) ?? 0,
          ratio: _dbl(r['ratio']),
          builtAt: _time(r['builtAt']),
        ),
  ], _str(j['hopsFrom']) ?? 'e3');
}

// ---- E6 repeater health and E8 events
class RepeaterHealthRow {
  final String key;
  final String? name;
  final DateTime? lastHeardAt;
  final int trafficHours7d;
  final double? uptime7d, snrMean7d;
  final int? relays24h;
  const RepeaterHealthRow({
    required this.key,
    required this.name,
    required this.lastHeardAt,
    required this.trafficHours7d,
    required this.uptime7d,
    required this.snrMean7d,
    required this.relays24h,
  });
}

class HealthCounts {
  final int nodes, heard24h, relaying24h;
  const HealthCounts(this.nodes, this.heard24h, this.relaying24h);

  /// `silent = nodes - heard24h`, never below 0.
  int get silent24h => nodes - heard24h < 0 ? 0 : nodes - heard24h;
}

class RepeaterHealthRead {
  final EngineStatus status;
  final DateTime? builtAt;
  final HealthCounts? counts;
  final List<RepeaterHealthRow> rows;
  const RepeaterHealthRead(this.status, this.builtAt, this.counts, this.rows);
  static RepeaterHealthRead parse(Map<String, dynamic> j) {
    final c = j['counts'];
    HealthCounts? counts;
    if (c is Map) {
      final n = _int(c['nodes']), h = _int(c['heard24h']), r = _int(c['relaying24h']);
      if (n != null && h != null && r != null) counts = HealthCounts(n, h, r);
    }
    return RepeaterHealthRead(EngineStatus.parse(j['status']), _time(j['builtAt']), counts, [
      for (final r in _maps(j['rows']))
        if (_str(r['key']) != null)
          RepeaterHealthRow(
            key: r['key'] as String,
            name: _str(r['name']),
            lastHeardAt: _time(r['lastHeardAt']),
            trafficHours7d: _int(r['trafficHours7d']) ?? 0,
            uptime7d: _dbl(r['uptime7d']),
            snrMean7d: _dbl(r['snrMean7d']),
            relays24h: _int(r['relays24h']),
          ),
    ]);
  }
}

class AnalyzeEvent {
  final String type, detail;
  final String? key;
  final DateTime? at;
  const AnalyzeEvent(this.type, this.key, this.detail, this.at);
}

/// `region-overview.recentEvents[]`; events without a detail sentence are left out.
List<AnalyzeEvent> parseRecentEvents(Map<String, dynamic> j) => [
  for (final e in _maps(j['recentEvents']))
    if (_str(e['detail']) != null)
      AnalyzeEvent(_str(e['type']) ?? '', _str(e['key']), e['detail'] as String, _time(e['at'])),
];

const Map<String, String> eventWord = {
  'repeater_new': 'New repeater',
  'repeater_quiet': 'Repeater went quiet',
  'repeater_renamed': 'Repeater renamed',
  'repeater_moved': 'Repeater moved',
  'link_new': 'New link',
  'link_lost': 'Link lost',
};

// ---- region-status (DEF-2): one entry per dataset key
class DatasetStatus {
  final String key, state; // state: ready | stale | none | error (others tolerated)
  final String? reason;
  final DateTime? computedAt;
  const DatasetStatus(this.key, this.state, this.reason, this.computedAt);
}

/// `region-status` answers a JSON array. Anything else gives an empty list (the sections then rely on their own reads).
List<DatasetStatus> parseRegionStatus(Object? j) => [
  for (final e in (j is List ? j : const []))
    if (e is Map && e['key'] is String && e['state'] is String)
      DatasetStatus(e['key'] as String, e['state'] as String, _str(e['reason']), _time(e['computedAt'])),
];

DatasetStatus? datasetFor(List<DatasetStatus> all, String key) {
  for (final d in all) {
    if (d.key == key) return d;
  }
  return null;
}

// ---- section state (DEF-2): loading | ready | stale | none | error, one honest look each
enum SectionState { loading, ready, stale, none, error }

class SectionVerdict {
  final SectionState state;
  final String? reason;
  final DateTime? builtAt;
  const SectionVerdict(this.state, this.reason, this.builtAt);
}

/// The age rule: a unit that has not rebuilt for 36 h is stale, whatever the endpoint said when it was cached.
bool isOlderThan36h(DateTime? builtAt, DateTime now) => builtAt != null && now.difference(builtAt) > staleAfter;

/// One section's state from its read and the region-status entry, in the contract's order:
/// loading; read failed or region-status error -> error; region-status none or read pending/unavailable/not_found -> none;
/// read stale, region-status stale or built over 36 h ago -> stale; otherwise ready.
SectionVerdict sectionVerdict({
  required bool loading,
  required bool failed,
  required EngineStatus? status,
  required DateTime? builtAt,
  required DatasetStatus? dataset,
  required DateTime now,
}) {
  if (loading) return const SectionVerdict(SectionState.loading, null, null);
  if (failed || status == null) return const SectionVerdict(SectionState.error, null, null);
  final ds = dataset;
  if (ds != null && (ds.state == 'error' || ds.state == 'failed')) {
    return SectionVerdict(SectionState.error, ds.reason, builtAt ?? ds.computedAt);
  }
  if (ds != null && ds.state == 'none') return SectionVerdict(SectionState.none, ds.reason ?? status.reason, null);
  if (const {'pending', 'unavailable', 'not_found'}.contains(status.state)) {
    return SectionVerdict(SectionState.none, status.reason, null);
  }
  final built = builtAt ?? ds?.computedAt;
  if (status.state == 'stale' || (ds != null && ds.state == 'stale') || isOlderThan36h(built, now)) {
    return SectionVerdict(SectionState.stale, status.reason ?? ds?.reason, built);
  }
  return SectionVerdict(SectionState.ready, null, built);
}

// ---- formatters: the same rounding as the website's lib/format
/// JS `Math.round` (half rounds up), so 0.5 -> 1 and -0.5 -> -0 like the web.
double _jsRound(double x) => (x + 0.5).floorToDouble();

/// Whole number with thousands separators; null shows "—".
String formatInt(num? n) {
  if (n == null || !n.isFinite) return '—';
  final r = _jsRound(n.toDouble()).toInt();
  final s = r.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return r < 0 ? '-$b' : b.toString();
}

/// A share (0..1) as a percent with [digits] decimals; null shows "—".
String formatPct(double? share, [int digits = 1]) {
  if (share == null || !share.isFinite) return '—';
  var f = 1.0;
  for (var i = 0; i < digits; i++) {
    f *= 10;
  }
  return '${(_jsRound(share * 100 * f) / f).toStringAsFixed(digits)}%';
}

/// `uptime7d` / `uptime30d` are percent numbers (0-100), not shares.
String uptimeText(double? u) => u == null ? '—' : formatPct(u / 100, 0);

/// Mean SNR with 1 decimal, null "—" (never 0).
String snrText(double? v) => v == null ? '—' : v.toStringAsFixed(1);

/// Mean RSSI with 0 decimals, null "—".
String rssiText(double? v) => v == null ? '—' : v.toStringAsFixed(0);

// ---- findings
const _severityRank = {'alert': 0, 'warn': 1, 'info': 2};
const Map<String, String> severityWord = {'alert': 'Problem', 'warn': 'Watch', 'info': 'Note'};
const Map<String, String> sectionWord = {
  'network': 'Network health',
  'traffic': 'Traffic',
  'links': 'Links',
  'coverage': 'Coverage',
  'data': 'Data',
};

/// Most severe first, the engine's own order inside a severity.
List<Finding> sortFindings(List<Finding> rows) {
  final idx = <Finding, int>{for (var i = 0; i < rows.length; i++) rows[i]: i};
  final out = [...rows];
  out.sort((a, b) {
    final c = (_severityRank[a.severity] ?? 3).compareTo(_severityRank[b.severity] ?? 3);
    return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
  });
  return out;
}

// ---- traffic
/// "ours 38% · outside 60% · phones 2%": each source's `share` as the endpoint gives it. A source with 0 packets (or no share) is left
/// out. Order: ours, outside, phones. A packet heard by two sources counts for both, so the shares can add past 100%.
String? sourceChip(TrafficRead t) {
  final parts = <String>[
    for (final (word, s) in [('ours', t.ours), ('outside', t.outside), ('phones', t.phone)])
      if (s.packets > 0 && s.share != null) '$word ${formatPct(s.share, 0)}',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// The union rows (source "all"); a payload without that marker (older server) is taken as the union.
List<TrafficRow> allRows(List<TrafficRow> rows) => rows.any((r) => r.source == 'all')
    ? [
        for (final r in rows)
          if (r.source == 'all') r,
      ]
    : rows;

class TrafficFigures {
  final String packets, observations, observers, snr, rssi;
  const TrafficFigures(this.packets, this.observations, this.observers, this.snr, this.rssi);
}

TrafficFigures trafficFigures(TrafficRead t) => TrafficFigures(
  formatInt(t.all.packets),
  formatInt(t.all.observations),
  t.all.observers == null ? '—' : formatInt(t.all.observers),
  snrText(t.snrMeanDb),
  rssiText(t.rssiMeanDbm),
);

List<double> _sum(List<TrafficRow> rows, List<double> Function(TrafficRow) pick, int n) {
  final out = List<double>.filled(n, 0);
  for (final r in rows) {
    final a = pick(r);
    for (var i = 0; i < a.length && i < n; i++) {
      out[i] += a[i];
    }
  }
  return out;
}

/// Observations per hop count 0..16 (all three route groups), only the counts that occur: bar N = hopObs[N] + hopObs[17+N] + hopObs[34+N].
List<({int hops, int n})> hopHistogram(List<TrafficRow> rows) {
  final h = _sum(allRows(rows), (r) => r.hopObs, 51);
  return [
    for (var k = 0; k <= 16; k++)
      if (h[k] + h[17 + k] + h[34 + k] > 0) (hops: k, n: (h[k] + h[17 + k] + h[34 + k]).round()),
  ];
}

/// Share of observations on flood routes (bins 0..16 over all bins); null with no observations.
double? floodShare(List<TrafficRow> rows) {
  final h = _sum(allRows(rows), (r) => r.hopObs, 51);
  final total = h.fold<double>(0, (a, b) => a + b);
  if (total == 0) return null;
  return h.sublist(0, 17).fold<double>(0, (a, b) => a + b) / total;
}

/// SNR of received packets in 1 dB bins from -30 dB, empty edge bins trimmed.
List<({int snr, int n})> snrBars(List<TrafficRow> rows) {
  final h = _sum(allRows(rows), (r) => r.snrHist, 51);
  final first = h.indexWhere((n) => n > 0);
  if (first < 0) return const [];
  final last = h.lastIndexWhere((n) => n > 0);
  return [for (var i = first; i <= last; i++) (snr: -30 + i, n: h[i].round())];
}

/// Packets by type across the window: type id -> packets, only the types that occur.
Map<int, int> packetsByType(List<TrafficRow> rows) {
  final h = _sum(allRows(rows), (r) => r.byType, 16);
  return {
    for (var t = 0; t < 16; t++)
      if (h[t] > 0) t: h[t].round(),
  };
}

const Map<int, String> _typeNames = {
  0: 'Request',
  1: 'Response',
  2: 'Direct message',
  3: 'Ack',
  4: 'Advert',
  5: 'Group text',
  6: 'Group data',
  7: 'Anonymous request',
  8: 'Path',
  9: 'Trace',
  10: 'Multipart',
  11: 'Control',
  15: 'Raw custom',
};
String packetTypeName(int t) => _typeNames[t] ?? 'Type $t';

// ---- repeater health
/// The repeaters that carry the most traffic: relays in 24 h, only where the node's hop code is its own (null is left out).
List<RepeaterHealthRow> busiest(List<RepeaterHealthRow> rows, [int n = 8]) {
  final out = [
    for (final r in rows)
      if ((r.relays24h ?? 0) > 0) r,
  ];
  out.sort((a, b) {
    final c = (b.relays24h ?? 0).compareTo(a.relays24h ?? 0);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return out.take(n).toList();
}

/// The least reliable repeaters: lowest 7-day uptime among those the region had traffic to judge them on.
List<RepeaterHealthRow> leastReliable(List<RepeaterHealthRow> rows, [int n = 5]) {
  final out = [
    for (final r in rows)
      if (r.uptime7d != null && r.trafficHours7d > 0) r,
  ];
  out.sort((a, b) {
    final c = a.uptime7d!.compareTo(b.uptime7d!);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return out.take(n).toList();
}

// ---- node-list check
const String noHopTrafficReason =
    'No relayed packets with hop codes have been heard in this region in the last 24 h, so there are no routes to draw and nothing to check the node list against yet.';
bool isNoHopTraffic(NodeListGate g) => g.state == 'unknown' && g.total == 0 && g.reason.startsWith(noHopTrafficReason);

/// The partial notice (headline + the server's measured sentence); only used when the list is not trusted.
({String title, String body}) describeNodeList(NodeListGate g) {
  if (isNoHopTraffic(g)) return (title: 'No route data yet', body: g.reason);
  final title = g.state == 'stale'
      ? 'Partial: node list out of date'
      : g.state == 'unknown'
      ? 'Partial: node list not verified'
      : 'Partial: node list incomplete';
  return (title: title, body: g.reason);
}
