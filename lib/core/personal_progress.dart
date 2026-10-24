// Personal progress (stream 5 D2 + D6): every drive stored on this phone rolled up into totals, ISO weeks, records and
// "my radio" figures. Only the phone's own drives: a drive deleted from the phone, or recorded on another phone, is not
// in here (the server-wide view needs the `driver-summary` endpoint, requested as P1-a in the stream 5 design doc).
//
// Rules:
//  - Weeks are ISO weeks (Monday start) in the phone's local time: a drive belongs to the week its start falls in.
//    The weeks run without holes from the first drive's week to the week of `now`, so a week with no drive is a 0 bar,
//    not a missing one.
//  - "New" grid cells and repeaters are new for this phone: drives are walked oldest first and a cell or repeater
//    counts once, on the drive that first had it. Cells are CMAT's coverage grid (drive_report.dart cellIndexOf, tx
//    pings only); repeater ids are whole-byte hex prefixes, so a shorter or longer prefix of an id seen earlier is the
//    same repeater (the drive report's rule).
//  - Distance, heard and SNR per drive are DriveStats (the drives list's own numbers).
//  - Noise floor and TX power come only from what the radio reported per ping (null = not reported, never guessed).
// Pure Dart (no Flutter imports).
import 'drive_report.dart' show cellIndexOf;
import 'drive_stats.dart';
import 'model.dart';

/// One drive in the roll-up.
class ProgressDrive {
  final DriveSession session;
  final DriveStats stats;

  /// Grid cells / repeaters this drive was the first on this phone to have.
  final int newCells;
  final int newRepeaters;

  /// Distinct grid cells this drive pinged in.
  final int cells;

  /// Median of the radio's noise floor readings on this drive (null = the radio reported none).
  final double? noiseMedianDbm;
  final int noiseReadings;

  /// The TX power most pings were sent at (null = not reported).
  final double? txDbm;

  const ProgressDrive({
    required this.session,
    required this.stats,
    required this.newCells,
    required this.newRepeaters,
    required this.cells,
    required this.noiseMedianDbm,
    required this.noiseReadings,
    required this.txDbm,
  });

  int? get heardPercent => stats.heardPercent;
}

/// One ISO week (Monday start, phone local time).
class ProgressWeek {
  /// The Monday, as a calendar date (UTC midnight of that local date: read year/month/day only).
  final DateTime monday;
  final int isoYear;
  final int isoWeek;
  int drives = 0;
  double distanceM = 0;
  int txPings = 0;
  int heard = 0;
  int newCells = 0;
  int newRepeaters = 0;

  /// Cells / repeaters on this phone up to the end of this week.
  int totalCells = 0;
  int totalRepeaters = 0;
  ProgressWeek(this.monday, this.isoYear, this.isoWeek);

  int? get heardPercent => txPings == 0 ? null : (100 * heard / txPings).round();
}

/// A personal record: which drive and the value.
class ProgressRecord {
  final String id; // longest-distance, longest-time, best-heard, most-new-cells, most-repeaters, best-snr
  final ProgressDrive drive;
  const ProgressRecord(this.id, this.drive);
}

/// Mean noise floor for one local hour of the day across all drives.
class NoiseHour {
  final int hour;
  final double meanDbm;
  final int n;
  const NoiseHour(this.hour, this.meanDbm, this.n);
}

/// Drives with fewer tx pings than this do not compete for "best heard %" (3 of 3 is not a record).
const int minPingsForHeardRecord = 10;

/// The calendar date of [d] (its year/month/day) as UTC midnight, so date arithmetic never meets a DST change.
DateTime calendarDate(DateTime d) => DateTime.utc(d.year, d.month, d.day);

/// The Monday of the ISO week containing calendar date [d] (UTC midnight, as [calendarDate]).
DateTime isoMonday(DateTime d) {
  final day = calendarDate(d);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// ISO 8601 week-numbering year and week of calendar date [d] (week 1 holds the year's first Thursday).
(int, int) isoWeekOf(DateTime d) {
  final thursday = isoMonday(d).add(const Duration(days: 3));
  final jan1 = DateTime.utc(thursday.year, 1, 1);
  return (thursday.year, thursday.difference(jan1).inDays ~/ 7 + 1);
}

double? _median(List<double> v) {
  if (v.isEmpty) return null;
  final s = List.of(v)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : (s[m - 1] + s[m]) / 2;
}

class PersonalProgress {
  /// Oldest first.
  final List<ProgressDrive> drives;

  /// Oldest first, contiguous.
  final List<ProgressWeek> weeks;
  final int totalCells;
  final int totalRepeaters;
  final List<ProgressRecord> records;

  /// 24 entries at most, only hours with readings, by local hour.
  final List<NoiseHour> noiseByHour;

  const PersonalProgress({
    required this.drives,
    required this.weeks,
    required this.totalCells,
    required this.totalRepeaters,
    required this.records,
    required this.noiseByHour,
  });

  bool get isEmpty => drives.isEmpty;
  double get distanceM => drives.fold(0.0, (a, d) => a + d.stats.distanceM);
  Duration get driveTime => drives.fold(Duration.zero, (a, d) => a + (d.stats.duration ?? Duration.zero));
  int get pings => drives.fold(0, (a, d) => a + d.stats.pings);
  int get txPings => drives.fold(0, (a, d) => a + d.stats.txPings);
  int get heard => drives.fold(0, (a, d) => a + d.stats.heard);
  int? get heardPercent => txPings == 0 ? null : (100 * heard / txPings).round();
  double? get bestSnr {
    double? b;
    for (final d in drives) {
      final s = d.stats.bestSnr;
      if (s != null && (b == null || s > b)) b = s;
    }
    return b;
  }

  ProgressRecord? record(String id) {
    for (final r in records) {
      if (r.id == id) return r;
    }
    return null;
  }

  List<ProgressDrive> get drivesWithNoise => [for (final d in drives) if (d.noiseMedianDbm != null) d];
  List<ProgressDrive> get drivesWithTxPower => [for (final d in drives) if (d.txDbm != null) d];

  /// [drives]: every drive on the phone with its pings, any order. [now] closes the week range (default: the newest
  /// drive). [wall] turns a UTC instant into the phone's wall clock (default `toLocal()`; tests pass a fixed offset).
  static PersonalProgress compute(
    List<(DriveSession, List<DrivePing>)> drives, {
    DateTime? now,
    DateTime Function(DateTime utc)? wall,
  }) {
    final local = wall ?? (DateTime t) => t.toLocal();
    final sorted = List.of(drives)..sort((a, b) => a.$1.startedAt.compareTo(b.$1.startedAt));
    final seenCells = <(int, int)>{};
    final seenIds = <String>{};
    bool seenId(String id) {
      if (seenIds.contains(id)) return true;
      for (final o in seenIds) {
        if (o.startsWith(id) || id.startsWith(o)) return true;
      }
      return false;
    }

    final out = <ProgressDrive>[];
    final noiseSum = List<double>.filled(24, 0), noiseN = List<int>.filled(24, 0);
    for (final (ses, pings) in sorted) {
      final stats = DriveStats.of(ses, pings);
      final cells = <(int, int)>{};
      var newCells = 0, newReps = 0;
      final noise = <double>[];
      final tx = <double, int>{};
      for (final p in pings) {
        if (p.kind == PingKind.tx) {
          final c = cellIndexOf(p.lat, p.lon);
          cells.add(c);
          if (seenCells.add(c)) newCells++;
        }
        final ids = [for (final e in p.echoes) e.repeater.toLowerCase(), if (p.neighbor != null) p.neighbor!.repeater.toLowerCase()];
        for (final id in ids) {
          if (id.isEmpty || seenId(id)) continue;
          seenIds.add(id);
          newReps++;
        }
        final nf = p.noiseFloorDbm;
        if (nf != null && nf.isFinite) {
          noise.add(nf);
          final h = local(p.ts).hour;
          noiseSum[h] += nf;
          noiseN[h]++;
        }
        final t = p.txDbm;
        if (t != null && t.isFinite && p.kind == PingKind.tx) tx[t] = (tx[t] ?? 0) + 1;
      }
      double? txMost;
      var txBest = 0;
      for (final e in tx.entries) {
        if (e.value > txBest || (e.value == txBest && txMost != null && e.key > txMost)) {
          txMost = e.key;
          txBest = e.value;
        }
      }
      out.add(ProgressDrive(
        session: ses,
        stats: stats,
        newCells: newCells,
        newRepeaters: newReps,
        cells: cells.length,
        noiseMedianDbm: _median(noise),
        noiseReadings: noise.length,
        txDbm: txMost,
      ));
    }

    // Weeks: first drive's week to the week of `now` (or of the newest drive), no holes.
    final weeks = <ProgressWeek>[];
    if (out.isNotEmpty) {
      final first = isoMonday(local(out.first.session.startedAt));
      final lastDrive = isoMonday(local(out.last.session.startedAt));
      final nowWeek = now == null ? lastDrive : isoMonday(local(now));
      final last = nowWeek.isAfter(lastDrive) ? nowWeek : lastDrive;
      final byMonday = <DateTime, ProgressWeek>{};
      for (var m = first; !m.isAfter(last); m = m.add(const Duration(days: 7))) {
        final (y, w) = isoWeekOf(m);
        final wk = ProgressWeek(m, y, w);
        weeks.add(wk);
        byMonday[m] = wk;
      }
      for (final d in out) {
        final wk = byMonday[isoMonday(local(d.session.startedAt))]!;
        wk
          ..drives += 1
          ..distanceM += d.stats.distanceM
          ..txPings += d.stats.txPings
          ..heard += d.stats.heard
          ..newCells += d.newCells
          ..newRepeaters += d.newRepeaters;
      }
      var cellsSoFar = 0, repsSoFar = 0;
      for (final wk in weeks) {
        cellsSoFar += wk.newCells;
        repsSoFar += wk.newRepeaters;
        wk
          ..totalCells = cellsSoFar
          ..totalRepeaters = repsSoFar;
      }
    }

    // Records: the first drive to reach the top value keeps it (ties go to the earlier drive).
    final records = <ProgressRecord>[];
    void best(String id, num? Function(ProgressDrive d) value, {bool Function(ProgressDrive d)? eligible}) {
      ProgressDrive? top;
      num? topV;
      for (final d in out) {
        if (eligible != null && !eligible(d)) continue;
        final v = value(d);
        if (v == null || v <= 0 && id != 'best-snr') continue;
        if (topV == null || v > topV) {
          top = d;
          topV = v;
        }
      }
      if (top != null) records.add(ProgressRecord(id, top));
    }

    best('longest-distance', (d) => d.stats.distanceM);
    best('longest-time', (d) => d.stats.duration?.inSeconds);
    best('best-heard', (d) => d.heardPercent, eligible: (d) => d.stats.txPings >= minPingsForHeardRecord);
    best('most-new-cells', (d) => d.newCells);
    best('most-repeaters', (d) => d.stats.repeaters.length);
    best('best-snr', (d) => d.stats.bestSnr);

    return PersonalProgress(
      drives: out,
      weeks: weeks,
      totalCells: seenCells.length,
      totalRepeaters: seenIds.length,
      records: records,
      noiseByHour: [
        for (var h = 0; h < 24; h++)
          if (noiseN[h] > 0) NoiseHour(h, noiseSum[h] / noiseN[h], noiseN[h]),
      ],
    );
  }
}
