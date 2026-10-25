// Where ALL MeshSonar drivers heard one repeater: `GET repeater-reach?key=<hex>[&lat&lon]` with an approved
// `x-driver-key` (capability `reachDriverKey`). The server answers from the visible pings of PUBLIC drives only (each
// drive's start/end trim and privacy zones applied), direct echoes, in 0.0025 degree cells (about 270 m by 200 m), times
// rounded down to the hour. Shape: meshcore-insights src/lib/platform/types.ts `RepeaterReach`. Parsing is tolerant: a
// bad row is skipped, an unknown number is null (never 0). Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:io';

import 'api.dart' show CmatException;

num? _num(Object? v) => v is num && v.isFinite ? v : null;
double? _d(Object? v) => _num(v)?.toDouble();
int? _i(Object? v) => _num(v)?.round();
DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

/// One cell where drivers heard the repeater directly.
class ReachCell {
  final double lat, lon; // centre
  final int pings;
  final double? bestSnr, medianSnr;
  final DateTime? lastAt;
  const ReachCell({required this.lat, required this.lon, required this.pings, this.bestSnr, this.medianSnr, this.lastAt});
}

/// The six distance bands of the server, in km: 0-1, 1-2, 2-5, 5-10, 10-20, 20+.
const List<(String label, double fromKm, double? toKm)> reachBands = [
  ('0-1', 0, 1),
  ('1-2', 1, 2),
  ('2-5', 2, 5),
  ('5-10', 5, 10),
  ('10-20', 10, 20),
  ('20+', 20, null),
];

class ReachBandRow {
  final String label;
  final double fromKm;
  final double? toKm; // null = open ended
  final int pings;
  final double? medianSnr;
  const ReachBandRow({required this.label, required this.fromKm, required this.toKm, required this.pings, this.medianSnr});
}

class ReachTotals {
  final int heardPings, drives, drivers;
  final double? bestSnr, medianSnr;

  /// From the repeater's position (sent with the request); null when unknown.
  final double? farthestKm;
  final DateTime? lastHeardAt;
  const ReachTotals({
    required this.heardPings,
    required this.drives,
    required this.drivers,
    this.bestSnr,
    this.medianSnr,
    this.farthestKm,
    this.lastHeardAt,
  });
}

class RepeaterReach {
  final String key;
  final double cellDeg;
  final List<ReachCell> cells;
  final ReachTotals totals;

  /// All six bands when the request carried the repeater's position and it was heard, else empty.
  final List<ReachBandRow> snrByDistance;
  final DateTime? asOf;
  const RepeaterReach({
    required this.key,
    required this.cellDeg,
    required this.cells,
    required this.totals,
    required this.snrByDistance,
    this.asOf,
  });

  /// Nothing heard this repeater directly in a public drive.
  bool get isEmpty => totals.heardPings == 0 && cells.isEmpty;

  /// Throws [FormatException] when the body is not a reach answer at all.
  static RepeaterReach parse(Map<String, dynamic> j) {
    final cellsRaw = j['cells'];
    final totalsRaw = j['totals'];
    if (cellsRaw is! List || totalsRaw is! Map) throw const FormatException('not a repeater-reach answer');
    final cells = <ReachCell>[
      for (final c in cellsRaw)
        if (c is Map && _d(c['lat']) != null && _d(c['lon']) != null && _i(c['pings']) != null)
          ReachCell(
            lat: _d(c['lat'])!,
            lon: _d(c['lon'])!,
            pings: _i(c['pings'])!,
            bestSnr: _d(c['bestSnr']),
            medianSnr: _d(c['medianSnr']),
            lastAt: _t(c['lastAt']),
          ),
    ];
    final bands = <ReachBandRow>[];
    final br = j['snrByDistance'];
    if (br is List) {
      for (final b in br) {
        if (b is! Map) continue;
        final def = reachBands.where((x) => x.$1 == b['km']).firstOrNull;
        final n = _i(b['pings']);
        if (def == null || n == null) continue;
        bands.add(ReachBandRow(label: def.$1, fromKm: def.$2, toKm: def.$3, pings: n, medianSnr: _d(b['medianSnr'])));
      }
    }
    final t = totalsRaw.cast<String, dynamic>();
    return RepeaterReach(
      key: j['key'] is String ? j['key'] as String : '',
      cellDeg: _d(j['cellDeg']) ?? 0.0025,
      cells: cells,
      totals: ReachTotals(
        heardPings: _i(t['heardPings']) ?? 0,
        drives: _i(t['drives']) ?? 0,
        drivers: _i(t['drivers']) ?? 0,
        bestSnr: _d(t['bestSnr']),
        medianSnr: _d(t['medianSnr']),
        farthestKm: _d(t['farthestKm']),
        lastHeardAt: _t(t['lastHeardAt']),
      ),
      snrByDistance: bands,
      asOf: _t(j['asOf']),
    );
  }
}

/// One answer: the reach, when we last asked the server, and whether the live ask failed (stored copy shown).
class ReachResult {
  final RepeaterReach reach;
  final DateTime fetchedAt;
  final bool offline;
  const ReachResult({required this.reach, required this.fetchedAt, required this.offline});
}

/// Stored answers, one JSON file per server host + repeater key (+ whether the position was sent). Fresh for [ttl]
/// (the server caches 10 minutes too); a failed ask (no network, 429, 5xx) serves the stored copy flagged offline; a
/// refused key (401/403) or an unknown answer never serves a stored copy. The driver key is never stored. Atomic
/// writes, at most [maxEntries] files (oldest dropped), at most [maxPerMinute] asks a minute (the server allows 60).
class RepeaterReachCache {
  final Directory? dir;
  final DateTime Function() clock;
  final Duration ttl;
  final int maxEntries, maxPerMinute;
  RepeaterReachCache({this.dir, DateTime Function()? clock, this.ttl = const Duration(minutes: 10), this.maxEntries = 40, this.maxPerMinute = 50})
      : clock = clock ?? DateTime.now;

  final Map<String, ReachResult> _mem = {};
  final Map<String, Future<ReachResult>> _inflight = {};
  final List<DateTime> _asked = [];
  int serverAsks = 0;

  static final _safeKey = RegExp(r'^[0-9a-f]{8,64}$');

  String _name(String host, String key, bool withPos) => 'rr_${host.toLowerCase().replaceAll(RegExp(r'[^a-z0-9.-]'), '_')}_${key}_${withPos ? 'p' : 'n'}';

  /// The reach of [key] on [host]. Several callers at once share one ask. Throws what [fetch] throws when there is
  /// nothing stored to fall back on (or the failure must not fall back).
  Future<ReachResult> get(String host, String key, {required bool withPosition, required Future<RepeaterReach> Function() fetch}) {
    final k = key.toLowerCase();
    if (!_safeKey.hasMatch(k)) return Future.error(const CmatException('not a repeater key'));
    final id = _name(host, k, withPosition);
    final running = _inflight[id];
    if (running != null) return running;
    final f = _get(id, fetch).whenComplete(() {
      _inflight.remove(id);
    });
    return _inflight[id] = f;
  }

  bool isFresh(ReachResult r) {
    final age = clock().difference(r.fetchedAt);
    return !age.isNegative && age < ttl;
  }

  Future<ReachResult> _get(String id, Future<RepeaterReach> Function() fetch) async {
    final stored = _mem[id] ?? await _read(id);
    if (stored != null) {
      _mem[id] = stored;
      if (isFresh(stored)) return stored;
    }
    final now = clock();
    _asked.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (_asked.length >= maxPerMinute) {
      return _fallback(stored, const CmatException('Too many lookups just now. Try again in a minute.', status: 429));
    }
    _asked.add(now);
    serverAsks++;
    try {
      final r = ReachResult(reach: await fetch(), fetchedAt: clock(), offline: false);
      _mem[id] = r;
      await _write(id, r);
      return r;
    } on CmatException catch (e) {
      if (e.status == 401 || e.status == 403 || e.status == 404 || e.status == 400) {
        _mem.remove(id);
        await _delete(id);
        rethrow;
      }
      return _fallback(stored, e);
    } catch (e) {
      return _fallback(stored, e);
    }
  }

  ReachResult _fallback(ReachResult? stored, Object error) {
    if (stored == null) throw error;
    return ReachResult(reach: stored.reach, fetchedAt: stored.fetchedAt, offline: true);
  }

  File? _file(String id) => dir == null ? null : File('${dir!.path}${Platform.pathSeparator}$id.json');

  /// Drops everything stored (Settings "Clear", key removed). Never throws.
  Future<void> clear() async {
    _mem.clear();
    try {
      final d = dir;
      if (d == null || !await d.exists()) return;
      await for (final e in d.list()) {
        if (e is File && e.uri.pathSegments.last.startsWith('rr_')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _delete(String id) async {
    try {
      final f = _file(id);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<ReachResult?> _read(String id) async {
    try {
      final f = _file(id);
      if (f == null || !await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['v'] != 1 || j['body'] is! Map) return null;
      final at = DateTime.tryParse('${j['at']}');
      if (at == null) return null;
      return ReachResult(reach: RepeaterReach.parse((j['body'] as Map).cast<String, dynamic>()), fetchedAt: at.toUtc(), offline: false);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String id, ReachResult r) async {
    try {
      final f = _file(id);
      if (f == null) return;
      await dir!.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'at': r.fetchedAt.toUtc().toIso8601String(), 'body': encodeReach(r.reach)}), flush: true);
      await tmp.rename(f.path);
      await _evict();
    } catch (_) {}
  }

  Future<void> _evict() async {
    final files = <(File, DateTime)>[];
    await for (final e in dir!.list()) {
      if (e is File && e.path.endsWith('.json') && e.uri.pathSegments.last.startsWith('rr_')) files.add((e, (await e.stat()).modified));
    }
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final f in files.take(files.length - maxEntries)) {
      try {
        await f.$1.delete();
      } catch (_) {}
    }
  }
}

/// The wire form again (what the cache stores and [RepeaterReach.parse] reads back).
Map<String, dynamic> encodeReach(RepeaterReach r) => {
      'key': r.key,
      'cellDeg': r.cellDeg,
      'cells': [
        for (final c in r.cells)
          {'lat': c.lat, 'lon': c.lon, 'pings': c.pings, 'bestSnr': c.bestSnr, 'medianSnr': c.medianSnr, 'lastAt': c.lastAt?.toIso8601String()},
      ],
      'totals': {
        'heardPings': r.totals.heardPings,
        'drives': r.totals.drives,
        'drivers': r.totals.drivers,
        'bestSnr': r.totals.bestSnr,
        'medianSnr': r.totals.medianSnr,
        'farthestKm': r.totals.farthestKm,
        'lastHeardAt': r.totals.lastHeardAt?.toIso8601String(),
      },
      'snrByDistance': [for (final b in r.snrByDistance) {'km': b.label, 'pings': b.pings, 'medianSnr': b.medianSnr}],
      'asOf': r.asOf?.toIso8601String(),
    };
