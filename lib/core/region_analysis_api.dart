// Region "Analysis" data: the public, region-scoped reads behind the website's /analysis page.
// Pure Dart (lib/core rule). Endpoints are `<region host>/api/cmh/<name>` (verified live 2026-10-23 on cmh/day/cvg;
// the region is chosen by HOST, a `?region=` query is ignored): region-activity (hourly packets by type),
// region-hash-stats (hash-size mix + prefix collisions), region-path-stats (hop histogram, flood share, top carriers),
// region-repeaters (role + status mix). Every payload carries `status {state, reason, computedAt, source}`;
// unknown is null, never 0. Firmware mix has no public endpoint yet (region-ext-growth is not served), so it is not shown.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Server-reported data state: ready | partial | pending | unavailable | stale | not_found.
class RegionStatus {
  final String state;
  final String? reason;
  final String? computedAt;
  final String source;
  const RegionStatus({required this.state, this.reason, this.computedAt, this.source = ''});

  static RegionStatus parse(Object? j) {
    if (j is! Map) return const RegionStatus(state: 'unavailable', reason: 'The server sent no status.');
    return RegionStatus(
      state: j['state'] is String ? j['state'] as String : 'unavailable',
      reason: j['reason'] is String ? j['reason'] as String : null,
      computedAt: j['computedAt'] is String ? j['computedAt'] as String : null,
      source: j['source'] is String ? j['source'] as String : '',
    );
  }

  bool get isReady => state == 'ready';
}

int? _int(Object? v) => v is num && v.isFinite ? v.toInt() : null;
double? _dbl(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
List<Map> _maps(Object? v) => v is List ? v.whereType<Map>().toList() : const [];

class ActivityRow {
  final DateTime at; // UTC
  final int total;
  const ActivityRow(this.at, this.total);
}

class HashSize {
  final int bytes;
  final int nodes;
  const HashSize(this.bytes, this.nodes);
}

class Carrier {
  final String key;
  final String? name;
  final double share; // 0..1
  const Carrier(this.key, this.name, this.share);
}

class RegionActivity {
  final RegionStatus status;
  final List<ActivityRow> rows;
  const RegionActivity(this.status, this.rows);

  static RegionActivity parse(Object? j) {
    final m = j is Map ? j : const {};
    final rows = <ActivityRow>[];
    for (final r in _maps(m['rows'])) {
      final at = r['at'] is String ? DateTime.tryParse(r['at'] as String) : null;
      final total = _int(r['total']);
      if (at != null && total != null) rows.add(ActivityRow(at.toUtc(), total));
    }
    return RegionActivity(RegionStatus.parse(m['status']), rows);
  }

  /// 7 (Sunday=0 .. Saturday=6) x 24 grid of packet counts in [zone] hours. [toZone] defaults to the phone's local time.
  List<List<int>> heatmap({DateTime Function(DateTime utc)? toZone}) {
    final z = toZone ?? (DateTime t) => t.toLocal();
    final g = List.generate(7, (_) => List.filled(24, 0));
    for (final r in rows) {
      final t = z(r.at);
      g[t.weekday % 7][t.hour] += r.total;
    }
    return g;
  }

  int get total => rows.fold(0, (a, r) => a + r.total);
}

class HashStats {
  final RegionStatus status;
  final List<HashSize> sizes;
  final int collisionPrefixes;
  const HashStats(this.status, this.sizes, this.collisionPrefixes);

  static HashStats parse(Object? j) {
    final m = j is Map ? j : const {};
    final sizes = <HashSize>[];
    for (final s in _maps(m['sizes'])) {
      final b = _int(s['bytes']), n = _int(s['nodes']);
      if (b != null && n != null) sizes.add(HashSize(b, n));
    }
    sizes.sort((a, b) => a.bytes.compareTo(b.bytes));
    return HashStats(RegionStatus.parse(m['status']), sizes, _maps(m['collisions']).length);
  }
}

class PathStats {
  final RegionStatus status;
  final Map<int, int> hopHistogram; // hops -> packets
  final double? floodShare;
  final List<Carrier> carriers;
  const PathStats(this.status, this.hopHistogram, this.floodShare, this.carriers);

  static PathStats parse(Object? j) {
    final m = j is Map ? j : const {};
    final h = <int, int>{};
    for (final r in _maps(m['hopHistogram'])) {
      final hops = _int(r['hops']), n = _int(r['n']);
      if (hops != null && n != null) h[hops] = n;
    }
    final c = <Carrier>[];
    for (final r in _maps(m['carryShare'])) {
      final k = r['key'], s = _dbl(r['share']);
      if (k is String && s != null) c.add(Carrier(k, r['name'] is String ? r['name'] as String : null, s));
    }
    c.sort((a, b) => b.share.compareTo(a.share));
    return PathStats(RegionStatus.parse(m['status']), h, _dbl(m['floodShare']), c);
  }

  int get totalPackets => hopHistogram.values.fold(0, (a, b) => a + b);
  double? get meanHops {
    final t = totalPackets;
    if (t == 0) return null;
    return hopHistogram.entries.fold<double>(0, (a, e) => a + e.key * e.value) / t;
  }
}

class RoleMix {
  final RegionStatus status;
  final Map<String, int> roles; // role -> nodes
  final Map<String, int> states; // active/quiet/new/stale -> nodes
  const RoleMix(this.status, this.roles, this.states);

  static RoleMix parse(Object? j) {
    final m = j is Map ? j : const {};
    final roles = <String, int>{};
    for (final r in _maps(m['rows'])) {
      final role = r['role'] is String ? r['role'] as String : 'unknown';
      roles[role] = (roles[role] ?? 0) + 1;
    }
    final states = <String, int>{};
    final c = m['counts'];
    if (c is Map) {
      for (final e in c.entries) {
        final n = _int(e.value);
        if (e.key is String && n != null) states[e.key as String] = n;
      }
    }
    return RoleMix(RegionStatus.parse(m['status']), roles, states);
  }

  int get total => roles.values.fold(0, (a, b) => a + b);
}

/// One section's outcome: data, or the reason it could not load (a failed section never hides the others).
class Section<T> {
  final T? data;
  final String? error;
  const Section.ok(T this.data) : error = null;
  const Section.failed(String this.error) : data = null;
}

class RegionAnalysis {
  final Section<RegionActivity> activity;
  final Section<HashStats> hash;
  final Section<PathStats> paths;
  final Section<RoleMix> roles;
  const RegionAnalysis({required this.activity, required this.hash, required this.paths, required this.roles});

  List<Section> get _all => [activity, hash, paths, roles];
  bool get allFailed => _all.every((s) => s.data == null);
  bool get anyFailed => _all.any((s) => s.data == null);
}

class RegionAnalysisApi {
  final Uri baseUrl;
  final http.Client? client;
  final Duration timeout;
  final DateTime Function() now;
  RegionAnalysisApi(String baseUrl, {this.client, this.timeout = const Duration(seconds: 15), DateTime Function()? now})
      : baseUrl = Uri.parse(baseUrl),
        now = now ?? DateTime.now;

  Uri endpoint(String name, [Map<String, String>? query]) {
    final base = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/api/cmh/$name').replace(queryParameters: query);
  }

  /// Hourly buckets for the last 7 days, hour-aligned (server max for hourly is 7 days).
  Map<String, String> activityQuery() {
    final until = DateTime.fromMillisecondsSinceEpoch(
        ((now().millisecondsSinceEpoch + 3599999) ~/ 3600000) * 3600000,
        isUtc: true);
    return {
      'bucket': 'hour',
      'since': until.subtract(const Duration(days: 7)).toIso8601String(),
      'until': until.toIso8601String(),
    };
  }

  Future<Section<T>> _get<T>(http.Client c, String name, T Function(Object?) parse, [Map<String, String>? q]) async {
    try {
      final res = await c.get(endpoint(name, q), headers: {'accept': 'application/json'}).timeout(timeout);
      if (res.statusCode != 200) return Section.failed('The server answered ${res.statusCode}.');
      return Section.ok(parse(jsonDecode(utf8.decode(res.bodyBytes))));
    } on TimeoutException {
      return const Section.failed('The server took too long to answer.');
    } on SocketException {
      return const Section.failed('No connection to the server.');
    } on http.ClientException {
      return const Section.failed('No connection to the server.');
    } on FormatException {
      return const Section.failed('The server sent something unreadable.');
    }
  }

  Future<RegionAnalysis> fetch() async {
    final c = client ?? http.Client();
    try {
      final r = await Future.wait<Object>([
        _get(c, 'region-activity', RegionActivity.parse, activityQuery()),
        _get(c, 'region-hash-stats', HashStats.parse),
        _get(c, 'region-path-stats', PathStats.parse),
        _get(c, 'region-repeaters', RoleMix.parse),
      ]);
      return RegionAnalysis(
        activity: r[0] as Section<RegionActivity>,
        hash: r[1] as Section<HashStats>,
        paths: r[2] as Section<PathStats>,
        roles: r[3] as Section<RoleMix>,
      );
    } finally {
      if (client == null) c.close();
    }
  }
}
