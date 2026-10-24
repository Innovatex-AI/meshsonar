// "Your drives" for one repeater (stream 5 D7): how often, where and how well the drives stored on this phone heard it.
// Where = CMAT coverage grid cells (drive_report.dart cellIndexOf, about 220 m x 210 m), never the raw track.
//
// Matching: a heard id is a whole-byte hex prefix of a repeater key. An id matches [key] when either is a prefix of the
// other, case-insensitive (the server's rule). An id the repeater lookup resolves to a DIFFERENT known repeater is not
// counted. An id several known repeaters share is counted but reported apart ([sharedIdHearings]), because those
// hearings may be another repeater.
// Pure Dart (no Flutter imports).
import 'drive_report.dart' show cellIndexOf, cellLatDeg, cellLonDeg;
import 'heard.dart';
import 'model.dart';

/// Either id is a prefix of the other (case-insensitive, both non-empty).
bool idMatchesKey(String id, String key) {
  final a = id.toLowerCase(), b = key.toLowerCase();
  if (a.isEmpty || b.isEmpty) return false;
  return a.startsWith(b) || b.startsWith(a);
}

/// One drive that heard the repeater.
class RepeaterDriveHit {
  final DriveSession session;
  int hearings = 0;
  int direct = 0;
  double? bestSnr;
  late DateTime lastAt;
  final Set<(int, int)> cells = {};
  RepeaterDriveHit(this.session);
}

/// One grid cell where it was heard.
class RepeaterCellHit {
  final int i, j;
  int hearings = 0;
  double? bestSnr;
  RepeaterCellHit(this.i, this.j);
  double get south => i * cellLatDeg;
  double get west => j * cellLonDeg;
  double get north => (i + 1) * cellLatDeg;
  double get east => (j + 1) * cellLonDeg;
  double get centerLat => (i + 0.5) * cellLatDeg;
  double get centerLon => (j + 0.5) * cellLonDeg;
}

class RepeaterHistory {
  final String key;

  /// Pings on which it was heard (an echo or a neighbour reply; once per ping).
  final int hearings;

  /// Of [hearings]: heard directly (1 hop or a neighbour reply).
  final int direct;

  /// Of [hearings]: by an id other known repeaters share too.
  final int sharedIdHearings;
  final double? bestSnr;
  final DateTime? bestSnrAt;
  final DateTime? firstAt;
  final DateTime? lastAt;

  /// Farthest ping from the repeater's position when it was heard (null without a position).
  final double? farthestM;

  /// Newest first.
  final List<RepeaterDriveHit> drives;

  /// Most hearings first, then best SNR.
  final List<RepeaterCellHit> cells;

  /// Drives searched.
  final int drivesSearched;

  const RepeaterHistory({
    required this.key,
    required this.hearings,
    required this.direct,
    required this.sharedIdHearings,
    required this.bestSnr,
    required this.bestSnrAt,
    required this.firstAt,
    required this.lastAt,
    required this.farthestM,
    required this.drives,
    required this.cells,
    required this.drivesSearched,
  });

  bool get isEmpty => hearings == 0;

  /// [lat]/[lon]: the repeater's position when known (for [farthestM]).
  static RepeaterHistory compute(
    String key,
    List<(DriveSession, List<DrivePing>)> drives, {
    RepeaterLookup? lookup,
    double? lat,
    double? lon,
  }) {
    final k = key.toLowerCase();
    final l = lookup ?? RepeaterLookup.empty;
    final verdict = <String, int>{}; // id -> 0 not this repeater, 1 this one, 2 shared id
    int judge(String id) => verdict.putIfAbsent(id, () {
          if (!idMatchesKey(id, k)) return 0;
          final m = l.resolve(id);
          if (m.ref != null) return idMatchesKey(m.ref!.key, k) ? 1 : 0;
          if (m.candidates.length > 1) return 2;
          return 1;
        });

    var hearings = 0, direct = 0, shared = 0;
    double? best, far;
    DateTime? bestAt, first, last;
    final hits = <RepeaterDriveHit>[];
    final cells = <(int, int), RepeaterCellHit>{};
    for (final (ses, pings) in drives) {
      RepeaterDriveHit? hit;
      for (final p in pings) {
        var heard = false, isDirect = false, isShared = false;
        double? pingBest;
        void take(String id, double? snr, bool d) {
          final v = judge(id.toLowerCase());
          if (v == 0) return;
          heard = true;
          if (v == 2) isShared = true;
          if (d) isDirect = true;
          if (snr != null && snr.isFinite && (pingBest == null || snr > pingBest!)) pingBest = snr;
        }

        for (final e in p.echoes) {
          take(e.repeater, e.snrDb, e.hops == 1);
        }
        final n = p.neighbor;
        if (n != null) take(n.repeater, n.localSnrDb, true);
        if (!heard) continue;
        hearings++;
        if (isDirect) direct++;
        if (isShared) shared++;
        if (first == null || p.ts.isBefore(first)) first = p.ts;
        if (last == null || p.ts.isAfter(last)) last = p.ts;
        if (pingBest != null && (best == null || pingBest! > best)) {
          best = pingBest;
          bestAt = p.ts;
        }
        if (lat != null && lon != null) {
          final d = haversineM(p.lat, p.lon, lat, lon);
          if (far == null || d > far) far = d;
        }
        final ci = cellIndexOf(p.lat, p.lon);
        final c = cells.putIfAbsent(ci, () => RepeaterCellHit(ci.$1, ci.$2));
        c.hearings++;
        if (pingBest != null && (c.bestSnr == null || pingBest! > c.bestSnr!)) c.bestSnr = pingBest;
        hit ??= RepeaterDriveHit(ses)..lastAt = p.ts;
        hit.hearings++;
        if (isDirect) hit.direct++;
        if (pingBest != null && (hit.bestSnr == null || pingBest! > hit.bestSnr!)) hit.bestSnr = pingBest;
        if (p.ts.isAfter(hit.lastAt)) hit.lastAt = p.ts;
        hit.cells.add(ci);
      }
      if (hit != null) hits.add(hit);
    }
    hits.sort((a, b) => b.lastAt.compareTo(a.lastAt));
    final cellList = cells.values.toList()
      ..sort((a, b) {
        final c = b.hearings.compareTo(a.hearings);
        if (c != 0) return c;
        return (b.bestSnr ?? -999).compareTo(a.bestSnr ?? -999);
      });
    return RepeaterHistory(
      key: k,
      hearings: hearings,
      direct: direct,
      sharedIdHearings: shared,
      bestSnr: best,
      bestSnrAt: bestAt,
      firstAt: first,
      lastAt: last,
      farthestM: far,
      drives: hits,
      cells: cellList,
      drivesSearched: drives.length,
    );
  }
}
