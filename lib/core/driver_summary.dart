// "Your progress" beyond this phone: `GET /api/cmh/driver-summary` (capability `driverSummary`, x-driver-key).
//   200 {v: 1, asOf, stats{drives, pings, heardPings, km, cells, repeatersHeard, firstDriveAt, lastDriveAt, settledPings,
//        confirmedPings}, weeks[{week 'YYYY-MM-DD' (Monday, UTC), drives, pings, heardPings, km, newCells}] (<= 104,
//        oldest first), drives[DriveSummary, newest first, <= 200]}
// Scope on the server: every driver linked to the key's account (or just this driver when the key is not linked), all
// regions, the owner's own untrimmed view. Contract: meshcore-insights docs/PLATFORM_CONTRACT.md "driver-summary".
//
// Parsing is tolerant: a row that cannot be read is skipped and counted, a missing or malformed number is null (shown as
// "not available", never as 0). Every number stays SI here (km as the server sends it); lib/core/units.dart makes text.
// Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'api.dart' show CmatException;

int? _int(Object? v) => v is num && v.isFinite && v >= 0 ? v.round() : null;
double? _dbl(Object? v) => v is num && v.isFinite && v >= 0 ? v.toDouble() : null;
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
String? _str(Object? v, [int max = 120]) => v is String && v.isNotEmpty ? (v.length > max ? v.substring(0, max) : v) : null;

/// Account totals. A field the server did not send is null.
class ServerStats {
  final int? drives, pings, heardPings, cells, repeatersHeard, settledPings, confirmedPings;
  final double? km;
  final DateTime? firstDriveAt, lastDriveAt;
  const ServerStats({
    this.drives,
    this.pings,
    this.heardPings,
    this.km,
    this.cells,
    this.repeatersHeard,
    this.firstDriveAt,
    this.lastDriveAt,
    this.settledPings,
    this.confirmedPings,
  });

  /// Heard share of all pings, whole percent; null when either number is missing or there are no pings.
  int? get heardPercent => pings == null || heardPings == null || pings == 0 ? null : (100 * heardPings! / pings!).round();

  /// Share of SETTLED pings (older than the server's confirmation wait) that the mesh confirmed; pings still waiting are
  /// in neither number. Null with no settled pings.
  int? get confirmedPercent =>
      settledPings == null || confirmedPings == null || settledPings == 0 ? null : (100 * confirmedPings! / settledPings!).round();

  static ServerStats parse(Object? j) {
    if (j is! Map) return const ServerStats();
    return ServerStats(
      drives: _int(j['drives']),
      pings: _int(j['pings']),
      heardPings: _int(j['heardPings']),
      km: _dbl(j['km']),
      cells: _int(j['cells']),
      repeatersHeard: _int(j['repeatersHeard']),
      firstDriveAt: _time(j['firstDriveAt']),
      lastDriveAt: _time(j['lastDriveAt']),
      settledPings: _int(j['settledPings']),
      confirmedPings: _int(j['confirmedPings']),
    );
  }
}

/// One UTC ISO week (Monday start) with at least what the server counted for it.
class ServerWeek {
  /// The Monday, UTC midnight.
  final DateTime monday;
  final int? drives, pings, heardPings, newCells;
  final double? km;

  /// True for a week the server did not list that the app fills in for the chart axis (no drive that week).
  final bool filled;
  const ServerWeek(this.monday, {this.drives, this.pings, this.heardPings, this.km, this.newCells, this.filled = false});

  int? get heardPercent => pings == null || heardPings == null || pings == 0 ? null : (100 * heardPings! / pings!).round();
}

/// One drive of the account as the server lists it (owner view).
class ServerDrive {
  final String id;
  final String? callsign, label, review;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int? pings, heardPings, repeaters, settledPings, confirmedPings;
  final double? km, bestSnr;
  final List<String> flags;
  const ServerDrive({
    required this.id,
    required this.startedAt,
    this.callsign,
    this.label,
    this.review,
    this.endedAt,
    this.pings,
    this.heardPings,
    this.repeaters,
    this.settledPings,
    this.confirmedPings,
    this.km,
    this.bestSnr,
    this.flags = const [],
  });

  /// One drive row of `driver-summary` / `driver-drive`; null for a row without an id or a start time.
  static ServerDrive? tryParse(Object? d) {
    final id = d is Map ? _str(d['id'], 64) : null;
    final start = d is Map ? _time(d['startedAt']) : null;
    if (d is! Map || id == null || start == null) return null;
    return ServerDrive(
      id: id,
      startedAt: start,
      endedAt: _time(d['endedAt']),
      callsign: _str(d['callsign'], 40),
      label: _str(d['label'], 80),
      review: _str(d['review'], 12),
      pings: _int(d['pings']),
      heardPings: _int(d['heardPings']),
      repeaters: _int(d['repeaters']),
      settledPings: _int(d['settledPings']),
      confirmedPings: _int(d['confirmedPings']),
      km: _dbl(d['km']),
      bestSnr: d['bestSnr'] is num && (d['bestSnr'] as num).isFinite ? (d['bestSnr'] as num).toDouble() : null,
      flags: [if (d['flags'] is List) for (final f in (d['flags'] as List).take(8)) ?_str(f, 40)],
    );
  }

  int? get heardPercent => pings == null || heardPings == null || pings == 0 ? null : (100 * heardPings! / pings!).round();

  /// Plain words for the review state; null for a normal drive.
  String? get reviewWords => switch (review) {
        'hidden' => 'Hidden from the public maps',
        'flagged' => 'Flagged for review',
        _ => null,
      };
}

class DriverSummary {
  final DateTime? asOf;
  final ServerStats stats;
  final List<ServerWeek> weeks;
  final List<ServerDrive> drives;

  /// Rows the parser could not read (weeks and drives), so the screen can say so.
  final int skipped;

  /// The answer as received, for the on-disk copy.
  final Map<String, dynamic> raw;
  const DriverSummary({this.asOf, required this.stats, required this.weeks, required this.drives, this.skipped = 0, this.raw = const {}});

  /// Throws [FormatException] for a body that is not a v1 summary.
  static DriverSummary parse(Map<String, dynamic> j) {
    if (j['v'] != 1) throw const FormatException('unsupported driver-summary version');
    var skipped = 0;
    final byWeek = <int, ServerWeek>{};
    final wk = j['weeks'];
    if (wk is List) {
      for (final w in wk.take(104)) {
        final d = w is Map && w['week'] is String ? DateTime.tryParse('${w['week']}T00:00:00Z') : null;
        if (w is! Map || d == null || d.weekday != DateTime.monday) {
          skipped++;
          continue;
        }
        byWeek[d.millisecondsSinceEpoch] = ServerWeek(d,
            drives: _int(w['drives']), pings: _int(w['pings']), heardPings: _int(w['heardPings']), km: _dbl(w['km']), newCells: _int(w['newCells']));
      }
    }
    final weeks = byWeek.values.toList()..sort((a, b) => a.monday.compareTo(b.monday));
    final drives = <ServerDrive>[];
    final seen = <String>{};
    final dr = j['drives'];
    if (dr is List) {
      for (final d in dr.take(200)) {
        final x = ServerDrive.tryParse(d);
        if (x == null || !seen.add(x.id)) {
          skipped++;
          continue;
        }
        drives.add(x);
      }
    }
    drives.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return DriverSummary(asOf: _time(j['asOf']), stats: ServerStats.parse(j['stats']), weeks: weeks, drives: drives, skipped: skipped, raw: j);
  }

  bool get isEmpty => (stats.drives ?? drives.length) == 0 && drives.isEmpty;

  /// The listed weeks plus, for the chart axis only, empty weeks between them and up to [now]'s week. Those are marked
  /// [ServerWeek.filled]: no drive that week as far as the server's list says.
  List<ServerWeek> weeksFilled(DateTime now) {
    if (weeks.isEmpty) return const [];
    final n = now.toUtc();
    var last = DateTime.utc(n.year, n.month, n.day).subtract(Duration(days: n.weekday - 1));
    if (last.isBefore(weeks.last.monday)) last = weeks.last.monday;
    final byMs = {for (final w in weeks) w.monday.millisecondsSinceEpoch: w};
    final out = <ServerWeek>[];
    for (var d = weeks.first.monday; !d.isAfter(last); d = DateTime.utc(d.year, d.month, d.day + 7)) {
      out.add(byMs[d.millisecondsSinceEpoch] ?? ServerWeek(d, drives: 0, pings: 0, heardPings: 0, km: 0, newCells: 0, filled: true));
    }
    return out;
  }
}

/// One answer for the screen: the summary, when it was fetched, and why it may be a stored copy.
class DriverSummaryResult {
  final DriverSummary summary;
  final DateTime fetchedAt;

  /// True when the server could not be reached (or refused) and [summary] is the stored copy.
  final bool stale;

  /// The error that made this a stored copy ([CmatException] 429 = the server asked for a pause), else null.
  final Object? staleBecause;
  const DriverSummaryResult({required this.summary, required this.fetchedAt, this.stale = false, this.staleBecause});

  bool get offline => stale && !(staleBecause is CmatException && (staleBecause as CmatException).status == 429);
  bool get paused => stale && !offline;
}

/// Stored copy of the last answer, one file per server host and driver key (the file name carries a short SHA-256 of the
/// key; the key itself is never stored). Memory only when [dir] is null. Rules:
///  - an answer younger than [freshFor] (5 min) is served without asking; a forced refresh (pull to refresh) is floored
///    at [forceFloor] (10 s) so a swipe loop cannot hammer the server (30 per minute per driver);
///  - a failed ask serves the stored copy flagged stale (offline, or paused for a 429); with nothing stored it throws;
///  - 401 / 403 mean the key is no longer good on that server: the stored copy is deleted and the error thrown.
class DriverSummaryCache {
  final Directory? dir;
  final DateTime Function() clock;
  final Duration freshFor, forceFloor;
  DriverSummaryCache({this.dir, DateTime Function()? clock, this.freshFor = const Duration(minutes: 5), this.forceFloor = const Duration(seconds: 10)})
      : clock = clock ?? DateTime.now;

  final Map<String, DriverSummaryResult> _mem = {};
  final Map<String, Future<DriverSummaryResult>> _inflight = {};

  /// How many times the server was asked (tests, diagnostics).
  int serverAsks = 0;

  static String tagOf(String host, String driverKey) {
    final h = sha256.convert(utf8.encode('$host|$driverKey')).toString().substring(0, 16);
    return h;
  }

  File? _file(String tag) => dir == null || !RegExp(r'^[0-9a-f]{16}$').hasMatch(tag) ? null : File('${dir!.path}${Platform.pathSeparator}ds_$tag.json');

  Future<DriverSummaryResult> get(String tag, Future<DriverSummary> Function() fetch, {bool force = false}) {
    final running = _inflight[tag];
    if (running != null) return running;
    final f = _get(tag, fetch, force).whenComplete(() {
      _inflight.remove(tag);
    });
    return _inflight[tag] = f;
  }

  /// The stored copy without asking the server (null when none).
  Future<DriverSummaryResult?> stored(String tag) async => _mem[tag] ?? await _read(tag);

  Future<DriverSummaryResult> _get(String tag, Future<DriverSummary> Function() fetch, bool force) async {
    final st = await stored(tag);
    if (st != null) {
      _mem[tag] = st;
      final age = clock().difference(st.fetchedAt);
      if (!age.isNegative && age < (force ? forceFloor : freshFor) && !st.stale) return st;
    }
    serverAsks++;
    try {
      final s = await fetch();
      final r = DriverSummaryResult(summary: s, fetchedAt: clock());
      _mem[tag] = r;
      await _write(tag, r);
      return r;
    } on CmatException catch (e) {
      if (e.status == 401 || e.status == 403) {
        await forget(tag);
        rethrow;
      }
      if (st == null) rethrow;
      return DriverSummaryResult(summary: st.summary, fetchedAt: st.fetchedAt, stale: true, staleBecause: e);
    } catch (e) {
      if (st == null) rethrow;
      return DriverSummaryResult(summary: st.summary, fetchedAt: st.fetchedAt, stale: true, staleBecause: e);
    }
  }

  Future<void> forget(String tag) async {
    _mem.remove(tag);
    try {
      final f = _file(tag);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Drops every stored copy. Returns the files removed. Never throws.
  Future<int> clear() async {
    _mem.clear();
    var n = 0;
    try {
      final d = dir;
      if (d == null || !await d.exists()) return 0;
      await for (final e in d.list()) {
        if (e is File && e.uri.pathSegments.last.startsWith('ds_')) {
          try {
            await e.delete();
            n++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return n;
  }

  Future<DriverSummaryResult?> _read(String tag) async {
    try {
      final f = _file(tag);
      if (f == null || !await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map || j['v'] != 1 || j['body'] is! Map) return null;
      final at = _time(j['at']);
      if (at == null) return null;
      return DriverSummaryResult(summary: DriverSummary.parse((j['body'] as Map).cast<String, dynamic>()), fetchedAt: at);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String tag, DriverSummaryResult r) async {
    try {
      final f = _file(tag);
      if (f == null) return;
      await dir!.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'at': r.fetchedAt.toUtc().toIso8601String(), 'body': r.summary.raw}), flush: true);
      await tmp.rename(f.path);
    } catch (_) {
      // A full or read-only disk only costs the stored copy.
    }
  }
}
