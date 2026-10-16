// After-drive report: everything the Drive report screen shows, computed once from the drive's pings, the earlier
// drives on this phone (for "new" grids and repeaters) and the repeater lookup (names, positions, "unknown to CMAT").
// Pure Dart (no Flutter imports) so it's unit-tested directly and could run in an isolate.
//
// Grid cells match CMAT's coverage grid (src/lib/drive/drive-read.ts): 0.002° lat × 0.0025° lon (≈220 m × 210 m in
// central Ohio), cell index = floor(lat / 0.002), floor(lon / 0.0025). Cells count tx pings only, like CMAT.
import 'dart:math' as math;

import '../../core/heard.dart';
import '../../core/model.dart';

/// CMAT's coverage grid cell size in degrees.
const double cellLatDeg = 0.002;
const double cellLonDeg = 0.0025;

/// Index of the grid cell a point falls in (same as CMAT's cellIndex).
(int, int) cellIndexOf(double lat, double lon) => ((lat / cellLatDeg).floor(), (lon / cellLonDeg).floor());

/// One grid cell the drive pinged in.
class ReportCell {
  final int i, j;
  int pings = 0;
  int heard = 0;
  double? bestSnr;

  /// No earlier drive on this phone pinged in this cell.
  bool isNew = false;
  ReportCell(this.i, this.j);

  double get south => i * cellLatDeg;
  double get west => j * cellLonDeg;
  double get north => (i + 1) * cellLatDeg;
  double get east => (j + 1) * cellLonDeg;
  double get centerLat => (i + 0.5) * cellLatDeg;
  double get centerLon => (j + 0.5) * cellLonDeg;
  double get heardFraction => pings == 0 ? 0 : heard / pings;
  int get heardPercent => (100 * heardFraction).round();
}

/// One repeater heard during the drive.
class ReportRepeater {
  /// Hex key/prefix as heard, lower case.
  final String id;
  final RepeaterMatch match;

  /// Pings on which it was heard (echo or neighbor).
  int timesHeard = 0;
  double? bestSnr;

  /// Farthest the phone was from it when it was heard (null when its position isn't known).
  double? farthestM;
  DateTime? firstHeardAt;

  /// Never heard on an earlier drive on this phone.
  bool isNew = false;

  /// Not in CMAT's repeater list (only meaningful when that list was loaded; see [DriveReport.cmatChecked]).
  bool unknownToCmat = false;
  ReportRepeater(this.id, this.match);

  String get label => match.label;
}

/// One point of the SNR-over-time chart (a tx ping). [snr] null = nothing heard (or not measured).
class SnrPoint {
  final DateTime ts;
  final double? snr;
  final bool heard;
  const SnrPoint(this.ts, this.snr, this.heard);
}

class DriveReport {
  final DriveSession session;
  final int pings; // all pings (tx + rx)
  final int txPings;
  final int heardPings; // tx pings something answered
  final double distanceM;
  final Duration? duration;
  final double? avgSpeedMps;
  final double? maxSpeedMps;

  /// Every grid cell with at least one tx ping, west→east then south→north.
  final List<ReportCell> cells;

  /// Most-heard first.
  final List<ReportRepeater> repeaters;

  /// Strongest cell (best SNR, then heard %), and the cell with the most unanswered pings.
  final ReportCell? bestCell;
  final ReportCell? worstCell;

  final List<SnrPoint> snrSeries;

  /// Echo counts by hops: 1 (direct), 2, 3 (3 or more), 0 = unknown.
  final Map<int, int> hops;

  /// How many earlier drives on this phone were compared for "new".
  final int earlierDrives;

  /// True when CMAT's repeater list was available, so "unknown to CMAT" means something.
  final bool cmatChecked;

  const DriveReport({
    required this.session,
    required this.pings,
    required this.txPings,
    required this.heardPings,
    required this.distanceM,
    required this.duration,
    required this.avgSpeedMps,
    required this.maxSpeedMps,
    required this.cells,
    required this.repeaters,
    required this.bestCell,
    required this.worstCell,
    required this.snrSeries,
    required this.hops,
    required this.earlierDrives,
    required this.cmatChecked,
  });

  int? get heardPercent => txPings == 0 ? null : (100 * heardPings / txPings).round();
  int get gridsMapped => cells.length;
  int get gridsWithCoverage => cells.where((c) => c.heard > 0).length;
  int get newGrids => cells.where((c) => c.isNew).length;
  List<ReportRepeater> get newRepeaters => repeaters.where((r) => r.isNew).toList();
  List<ReportRepeater> get unknownToCmat => repeaters.where((r) => r.unknownToCmat).toList();
  double? get bestSnr {
    double? b;
    for (final p in snrSeries) {
      if (p.snr != null && (b == null || p.snr! > b)) b = p.snr;
    }
    return b;
  }

  /// Farthest repeater heard (by distance, position known).
  ReportRepeater? get farthest {
    ReportRepeater? f;
    for (final r in repeaters) {
      if (r.farthestM != null && (f == null || r.farthestM! > f.farthestM!)) f = r;
    }
    return f;
  }

  /// Builds the report.
  ///
  /// [earlier]: pings of every earlier drive on this phone (one list per drive). [lookup] resolves names and
  /// positions; [cmatListLoaded] says whether CMAT's list was in it (otherwise nothing is flagged unknown to CMAT).
  static DriveReport compute({
    required DriveSession session,
    required List<DrivePing> pings,
    Iterable<List<DrivePing>> earlier = const [],
    RepeaterLookup? lookup,
    bool cmatListLoaded = false,
  }) {
    final l = lookup ?? RepeaterLookup.empty;
    final sorted = List.of(pings)..sort((a, b) => a.ts.compareTo(b.ts));

    // Distance and speed: sum of ping-to-ping great-circle distance.
    var dist = 0.0;
    double? maxSeg;
    double? maxReported;
    for (var i = 0; i < sorted.length; i++) {
      final b = sorted[i];
      if (b.speedMps != null && (maxReported == null || b.speedMps! > maxReported)) maxReported = b.speedMps;
      if (i == 0) continue;
      final a = sorted[i - 1];
      final d = haversineM(a.lat, a.lon, b.lat, b.lon);
      dist += d;
      final dt = b.ts.difference(a.ts).inMilliseconds / 1000;
      if (dt >= 5) {
        final v = d / dt;
        // Ignore GPS jumps (> 70 m/s ≈ 157 mph) as speeds.
        if (v <= 70 && (maxSeg == null || v > maxSeg)) maxSeg = v;
      }
    }
    Duration? dur;
    final end = session.endedAt ?? (sorted.isEmpty ? null : sorted.last.ts);
    if (end != null && !end.isBefore(session.startedAt)) dur = end.difference(session.startedAt);
    double? avg;
    if (sorted.length >= 2) {
      final span = sorted.last.ts.difference(sorted.first.ts).inMilliseconds / 1000;
      if (span > 0) avg = dist / span;
    }

    // History: cells and repeater ids seen on earlier drives.
    final oldCells = <(int, int)>{};
    final oldIds = <String>{};
    var earlierCount = 0;
    for (final drive in earlier) {
      earlierCount++;
      for (final p in drive) {
        if (p.kind == PingKind.tx) oldCells.add(cellIndexOf(p.lat, p.lon));
        for (final e in p.echoes) {
          oldIds.add(e.repeater.toLowerCase());
        }
        if (p.neighbor != null) oldIds.add(p.neighbor!.repeater.toLowerCase());
      }
    }
    // Ids are whole-byte hex prefixes of different lengths; a shorter or longer prefix of a known id counts as seen.
    bool seenBefore(String id) {
      if (oldIds.contains(id)) return true;
      for (final o in oldIds) {
        if (o.startsWith(id) || id.startsWith(o)) return true;
      }
      return false;
    }

    final cellMap = <(int, int), ReportCell>{};
    final reps = <String, ReportRepeater>{};
    final series = <SnrPoint>[];
    final hops = <int, int>{1: 0, 2: 0, 3: 0, 0: 0};
    var tx = 0, heard = 0;

    for (final p in sorted) {
      double? pingBest;
      final seen = <String>{};
      void hear(String rep, double? snr) {
        final id = rep.toLowerCase();
        final r = reps.putIfAbsent(id, () => ReportRepeater(id, l.resolve(id))..firstHeardAt = p.ts);
        if (seen.add(id)) r.timesHeard++;
        if (snr != null) {
          if (r.bestSnr == null || snr > r.bestSnr!) r.bestSnr = snr;
          if (pingBest == null || snr > pingBest!) pingBest = snr;
        }
        final d = r.match.distanceFrom(p.lat, p.lon);
        if (d != null && (r.farthestM == null || d > r.farthestM!)) r.farthestM = d;
      }

      for (final e in p.echoes) {
        hear(e.repeater, e.snrDb);
        final h = e.hops;
        final k = h == null || h <= 0 ? 0 : math.min(h, 3);
        hops[k] = hops[k]! + 1;
      }
      if (p.neighbor != null) hear(p.neighbor!.repeater, p.neighbor!.localSnrDb);

      if (p.kind != PingKind.tx) continue;
      tx++;
      final wasHeard = !p.heardNothing;
      if (wasHeard) heard++;
      series.add(SnrPoint(p.ts, pingBest, wasHeard));
      final key = cellIndexOf(p.lat, p.lon);
      final c = cellMap.putIfAbsent(key, () => ReportCell(key.$1, key.$2)..isNew = !oldCells.contains(key));
      c.pings++;
      if (wasHeard) c.heard++;
      if (pingBest != null && (c.bestSnr == null || pingBest! > c.bestSnr!)) c.bestSnr = pingBest;
    }

    for (final r in reps.values) {
      r.isNew = !seenBefore(r.id);
      r.unknownToCmat = cmatListLoaded && r.match.source != RepeaterSource.cmat;
    }
    final repList = reps.values.toList()
      ..sort((a, b) {
        final c = b.timesHeard.compareTo(a.timesHeard);
        if (c != 0) return c;
        final s = (b.bestSnr ?? -999).compareTo(a.bestSnr ?? -999);
        return s != 0 ? s : a.id.compareTo(b.id);
      });

    final cells = cellMap.values.toList()..sort((a, b) => a.i != b.i ? a.i.compareTo(b.i) : a.j.compareTo(b.j));

    ReportCell? best;
    for (final c in cells) {
      if (c.heard == 0) continue;
      if (best == null) {
        best = c;
        continue;
      }
      final cs = c.bestSnr ?? -999, bs = best.bestSnr ?? -999;
      if (cs > bs || (cs == bs && c.heardFraction > best.heardFraction)) best = c;
    }
    ReportCell? worst;
    for (final c in cells) {
      final silent = c.pings - c.heard;
      if (silent == 0) continue;
      if (worst == null) {
        worst = c;
        continue;
      }
      final ws = worst.pings - worst.heard;
      if (c.heardFraction < worst.heardFraction || (c.heardFraction == worst.heardFraction && silent > ws)) worst = c;
    }

    return DriveReport(
      session: session,
      pings: sorted.length,
      txPings: tx,
      heardPings: heard,
      distanceM: dist,
      duration: dur,
      avgSpeedMps: avg,
      maxSpeedMps: maxReported ?? maxSeg,
      cells: cells,
      repeaters: repList,
      bestCell: best,
      worstCell: worst,
      snrSeries: series,
      hops: hops,
      earlierDrives: earlierCount,
      cmatChecked: cmatListLoaded,
    );
  }

  /// Plain-text summary for sharing.
  String toText({String? title, String Function(double m)? distance, String Function(Duration? d)? duration}) {
    String km(double m) => m < 1000 ? '${m.round()} m' : '${(m / 1000).toStringAsFixed(1)} km';
    final dist = distance ?? km;
    String dur(Duration? d) {
      if (d == null) return '—';
      if (d.inMinutes < 1) return '${d.inSeconds} s';
      if (d.inHours < 1) return '${d.inMinutes} min';
      return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
    }

    final fmtDur = duration ?? dur;
    final b = StringBuffer()
      ..writeln(title ?? 'MeshSonar drive report')
      ..writeln('${dist(distanceM)} (${(distanceM / 1609.344).toStringAsFixed(1)} mi) in ${fmtDur(this.duration)}');
    if (avgSpeedMps != null) {
      b.writeln('Avg ${(avgSpeedMps! * 2.236936).toStringAsFixed(0)} mph'
          '${maxSpeedMps == null ? '' : ', max ${(maxSpeedMps! * 2.236936).toStringAsFixed(0)} mph'}');
    }
    b
      ..writeln('$txPings pings, ${heardPercent == null ? '—' : '$heardPercent%'} heard')
      ..writeln('$gridsMapped grid cells mapped ($gridsWithCoverage with coverage, $newGrids new)')
      ..writeln('${repeaters.length} repeaters heard (${newRepeaters.length} new)');
    if (bestSnr != null) b.writeln('Best SNR ${bestSnr!.toStringAsFixed(1)} dB');
    final f = farthest;
    if (f != null) b.writeln('Farthest: ${f.label} at ${dist(f.farthestM!)}');
    if (repeaters.isNotEmpty) {
      b.writeln('Top repeaters:');
      for (final r in repeaters.take(5)) {
        b.writeln('  ${r.label}: ${r.timesHeard}×${r.bestSnr == null ? '' : ', best ${r.bestSnr!.toStringAsFixed(1)} dB'}'
            '${r.isNew ? ' (new)' : ''}');
      }
    }
    b.writeln('Recorded with MeshSonar');
    return b.toString();
  }
}
