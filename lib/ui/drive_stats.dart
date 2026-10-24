// Numbers about one saved drive, computed from its pings: distance, duration, heard %, SNR, repeaters.
// Pure functions (no widgets) so the drives list, the detail screen and tests share one definition.
import 'dart:math' as math;

import '../core/model.dart';

/// Great-circle distance in metres (haversine, mean Earth radius).
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// How often one repeater was heard during a drive.
class RepeaterCount {
  final String repeater; // hex key/prefix, lower case
  final int pings; // pings on which it was heard
  final double? bestSnr;
  const RepeaterCount(this.repeater, this.pings, this.bestSnr);
}

class DriveStats {
  final int pings;
  final int txPings;
  final int heard;
  final double distanceM;
  final Duration? duration;
  final double? bestSnr;
  final double? medianSnr;

  /// Echoes that came back through more than one repeater (hops > 1).
  final int multiHopEchoes;

  /// Most-heard first.
  final List<RepeaterCount> repeaters;

  /// One entry per tx ping in time order: true = something heard it.
  final List<bool> timeline;

  /// Best SNR per tx ping, same order as [timeline] (null = not heard or not measured).
  final List<double?> timelineSnr;

  const DriveStats({
    required this.pings,
    required this.txPings,
    required this.heard,
    required this.distanceM,
    required this.duration,
    required this.bestSnr,
    required this.medianSnr,
    required this.multiHopEchoes,
    required this.repeaters,
    required this.timeline,
    this.timelineSnr = const [],
  });

  int? get heardPercent => txPings == 0 ? null : (100 * heard / txPings).round();

  static DriveStats of(DriveSession session, List<DrivePing> pings) {
    final sorted = List.of(pings)..sort((a, b) => a.ts.compareTo(b.ts));
    var dist = 0.0;
    for (var i = 1; i < sorted.length; i++) {
      final a = sorted[i - 1], b = sorted[i];
      dist += haversineM(a.lat, a.lon, b.lat, b.lon);
    }

    final tx = sorted.where((p) => p.kind == PingKind.tx).toList();
    final heard = tx.where((p) => !p.heardNothing).length;

    // Per-ping best SNR (a ping's strongest echo), for best/median.
    final snrs = <double>[];
    final pingBestById = <String, double?>{};
    var multiHop = 0;
    final counts = <String, int>{};
    final best = <String, double>{};
    for (final p in sorted) {
      double? pingBest;
      final seen = <String>{};
      void hear(String rep, double? snr) {
        final k = rep.toLowerCase();
        if (seen.add(k)) counts[k] = (counts[k] ?? 0) + 1;
        if (snr != null) {
          if (best[k] == null || snr > best[k]!) best[k] = snr;
          if (pingBest == null || snr > pingBest!) pingBest = snr;
        }
      }

      for (final e in p.echoes) {
        hear(e.repeater, e.snrDb);
        if ((e.hops ?? 0) > 1) multiHop++;
      }
      if (p.neighbor != null) hear(p.neighbor!.repeater, p.neighbor!.localSnrDb);
      if (pingBest != null) snrs.add(pingBest!);
      pingBestById[p.id] = pingBest;
    }
    snrs.sort();
    double? median;
    if (snrs.isNotEmpty) {
      final m = snrs.length ~/ 2;
      median = snrs.length.isOdd ? snrs[m] : (snrs[m - 1] + snrs[m]) / 2;
    }
    final reps = [for (final e in counts.entries) RepeaterCount(e.key, e.value, best[e.key])]
      ..sort((a, b) => b.pings != a.pings ? b.pings.compareTo(a.pings) : a.repeater.compareTo(b.repeater));

    Duration? dur;
    final end = session.endedAt ?? (sorted.isEmpty ? null : sorted.last.ts);
    if (end != null && !end.isBefore(session.startedAt)) dur = end.difference(session.startedAt);

    return DriveStats(
      pings: sorted.length,
      txPings: tx.length,
      heard: heard,
      distanceM: dist,
      duration: dur,
      bestSnr: snrs.isEmpty ? null : snrs.last,
      medianSnr: median,
      multiHopEchoes: multiHop,
      repeaters: reps,
      timeline: [for (final p in tx) !p.heardNothing],
      timelineSnr: [for (final p in tx) pingBestById[p.id]],
    );
  }
}

/// "1 h 05 min" / "12 min" / "45 s".
String formatDuration(Duration? d) {
  if (d == null) return '—';
  if (d.inMinutes < 1) return '${d.inSeconds} s';
  if (d.inHours < 1) return '${d.inMinutes} min';
  return '${d.inHours} h ${(d.inMinutes % 60).toString().padLeft(2, '0')} min';
}
