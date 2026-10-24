// Drive report v2: the radio side of one drive, from data only the phone has (the driver's raw pings):
//   - noise floor over the drive (DrivePing.noiseFloorDbm, tx and rx pings),
//   - strongest reply RSSI per tx ping (Echo.rssiDbm / Neighbor.localRssiDbm),
//   - TX power change points (DrivePing.txDbm),
//   - SNR by distance to the repeater, in the SAME bands as the server's repeater-reach (0-1, 1-2, 2-5, 5-10, 10-20,
//     20+ km; PLATFORM_CONTRACT `repeater-reach`), so app and site agree. Only DIRECT links are counted: echoes with
//     hops == 1 and neighbour replies (local SNR), whose repeater has a known position. A multi-hop echo's SNR is the
//     last hop's, not the named repeater's, so it would put a number in the wrong band;
//   - heard % by speed (tx pings with a speed), bands 0-5, 5-15, 15-25, 25+ m/s;
//   - GPS accuracy: median, 90th percentile, pings worse than 50 m.
// Everything is SI here; the UI and the text export convert through lib/core/units.dart.
// Pure Dart: no Flutter imports.
import 'dart:math' as math;

import 'heard.dart';
import 'model.dart';

/// Distance band edges in metres (repeater-reach bands). The last band is open-ended.
const List<double> distanceBandEdgesM = [0, 1000, 2000, 5000, 10000, 20000];

/// Speed band edges in m/s. The last band is open-ended.
const List<double> speedBandEdgesMps = [0, 5, 15, 25];

/// GPS fixes worse than this are counted as poor.
const double poorGpsAccuracyM = 50;

class DistanceBand {
  final double fromM;

  /// Null = open-ended (20 km and more).
  final double? toM;

  /// Direct-link SNR measurements in this band.
  final int n;
  final double? meanSnr, bestSnr;

  /// Distinct repeaters measured in this band.
  final int repeaters;
  const DistanceBand({required this.fromM, required this.toM, required this.n, this.meanSnr, this.bestSnr, required this.repeaters});
}

class SpeedBand {
  final double fromMps;
  final double? toMps;
  final int pings, heard;
  const SpeedBand({required this.fromMps, required this.toMps, required this.pings, required this.heard});
  int? get heardPercent => pings == 0 ? null : (100 * heard / pings).round();
}

class GpsQuality {
  /// Pings that carried an accuracy.
  final int n;
  final double medianM, p90M;

  /// Pings with accuracy worse than [poorGpsAccuracyM].
  final int poor;
  const GpsQuality({required this.n, required this.medianM, required this.p90M, required this.poor});
}

/// Index of the band [v] falls in ([edges] ascending, first is 0; a value on an edge belongs to the band above it).
int bandIndex(double v, List<double> edges) {
  for (var i = edges.length - 1; i >= 0; i--) {
    if (v >= edges[i]) return i;
  }
  return 0;
}

double? _median(List<double> sorted) {
  if (sorted.isEmpty) return null;
  final m = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[m] : (sorted[m - 1] + sorted[m]) / 2;
}

/// Nearest-rank percentile of an ascending list.
double? percentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return null;
  final rank = (p / 100 * sorted.length).ceil().clamp(1, sorted.length);
  return sorted[rank - 1];
}

class DriveRf {
  /// Time order. Empty when the radio reported no noise floor.
  final List<(DateTime, double)> noiseSeries;

  /// Strongest reply RSSI per tx ping that had one, time order.
  final List<(DateTime, double)> rssiSeries;

  /// The first known TX power and every change after it.
  final List<(DateTime, double)> txPowerChanges;

  /// Always six bands (zeros included) so tables line up.
  final List<DistanceBand> snrByDistance;

  /// Always four bands.
  final List<SpeedBand> heardBySpeed;
  final GpsQuality? gps;

  const DriveRf({
    required this.noiseSeries,
    required this.rssiSeries,
    required this.txPowerChanges,
    required this.snrByDistance,
    required this.heardBySpeed,
    required this.gps,
  });

  double? get noiseMedian => _median([for (final p in noiseSeries) p.$2]..sort());
  double? get noiseMin => noiseSeries.isEmpty ? null : noiseSeries.map((p) => p.$2).reduce(math.min);
  double? get noiseMax => noiseSeries.isEmpty ? null : noiseSeries.map((p) => p.$2).reduce(math.max);
  double? get rssiBest => rssiSeries.isEmpty ? null : rssiSeries.map((p) => p.$2).reduce(math.max);
  double? get rssiMedian => _median([for (final p in rssiSeries) p.$2]..sort());

  /// TX power was the same for every ping that recorded it.
  bool get txPowerConstant => txPowerChanges.length <= 1;
  bool get hasDistanceData => snrByDistance.any((b) => b.n > 0);
  bool get hasSpeedData => heardBySpeed.any((b) => b.pings > 0);

  /// [sorted]: the drive's pings in time order. [lookup] gives repeater positions.
  static DriveRf compute(List<DrivePing> sorted, RepeaterLookup lookup) {
    final noise = <(DateTime, double)>[];
    final rssi = <(DateTime, double)>[];
    final tx = <(DateTime, double)>[];
    final dN = List.filled(distanceBandEdgesM.length, 0);
    final dSum = List.filled(distanceBandEdgesM.length, 0.0);
    final dBest = List<double?>.filled(distanceBandEdgesM.length, null);
    final dReps = List.generate(distanceBandEdgesM.length, (_) => <String>{});
    final sPings = List.filled(speedBandEdgesMps.length, 0);
    final sHeard = List.filled(speedBandEdgesMps.length, 0);
    final acc = <double>[];

    void direct(DrivePing p, String repeater, double? snr) {
      if (snr == null || !snr.isFinite) return;
      final id = repeater.toLowerCase();
      final d = lookup.resolve(id).distanceFrom(p.lat, p.lon);
      if (d == null) return;
      final b = bandIndex(d, distanceBandEdgesM);
      dN[b]++;
      dSum[b] += snr;
      if (dBest[b] == null || snr > dBest[b]!) dBest[b] = snr;
      dReps[b].add(id);
    }

    for (final p in sorted) {
      final nf = p.noiseFloorDbm;
      if (nf != null && nf.isFinite) noise.add((p.ts, nf));
      final a = p.gpsAccuracyM;
      if (a != null && a.isFinite && a >= 0) acc.add(a);
      for (final e in p.echoes) {
        if (e.hops == 1) direct(p, e.repeater, e.snrDb);
      }
      if (p.neighbor != null) direct(p, p.neighbor!.repeater, p.neighbor!.localSnrDb);
      if (p.kind != PingKind.tx) continue;

      double? best;
      for (final e in p.echoes) {
        final r = e.rssiDbm;
        if (r != null && r.isFinite && (best == null || r > best)) best = r;
      }
      final nr = p.neighbor?.localRssiDbm;
      if (nr != null && nr.isFinite && (best == null || nr > best)) best = nr;
      if (best != null) rssi.add((p.ts, best));

      final t = p.txDbm;
      if (t != null && t.isFinite && (tx.isEmpty || tx.last.$2 != t)) tx.add((p.ts, t));

      final v = p.speedMps;
      if (v != null && v.isFinite && v >= 0) {
        final b = bandIndex(v, speedBandEdgesMps);
        sPings[b]++;
        if (!p.heardNothing) sHeard[b]++;
      }
    }
    acc.sort();
    return DriveRf(
      noiseSeries: noise,
      rssiSeries: rssi,
      txPowerChanges: tx,
      snrByDistance: [
        for (var i = 0; i < distanceBandEdgesM.length; i++)
          DistanceBand(
            fromM: distanceBandEdgesM[i],
            toM: i + 1 < distanceBandEdgesM.length ? distanceBandEdgesM[i + 1] : null,
            n: dN[i],
            meanSnr: dN[i] == 0 ? null : dSum[i] / dN[i],
            bestSnr: dBest[i],
            repeaters: dReps[i].length,
          ),
      ],
      heardBySpeed: [
        for (var i = 0; i < speedBandEdgesMps.length; i++)
          SpeedBand(
            fromMps: speedBandEdgesMps[i],
            toMps: i + 1 < speedBandEdgesMps.length ? speedBandEdgesMps[i + 1] : null,
            pings: sPings[i],
            heard: sHeard[i],
          ),
      ],
      gps: acc.isEmpty
          ? null
          : GpsQuality(n: acc.length, medianM: _median(acc)!, p90M: percentile(acc, 90)!, poor: acc.where((a) => a > poorGpsAccuracyM).length),
    );
  }
}
