// Radio preset explorer maths: time on air, sensitivity and link-budget change for every BW x SF. A port of the
// website's meshcore-insights `src/lib/tools/presets.ts` (sensitivityDbm, deltaDb, presetRows, shiftOdds); golden
// tests read numbers generated from that file. The website's "links that survive" columns need its in-browser
// terrain grid and the region's link list; the app does not have either, so it does not show them (see HANDOFF).
// Pure Dart.
import 'dart:math' as math;

import 'airtime_calc.dart';

const List<double> presetBw = [62.5, 125, 250, 500];
const List<int> presetSf = [7, 8, 9, 10, 11, 12];
const double noiseFigureDb = 6;
const Map<int, double> snrFloorDb = {7: -7.5, 8: -10, 9: -12.5, 10: -15, 11: -17.5, 12: -20};
const int presetPacketBytes = 50;

/// Terrain model weight on Bullington dB (website `TERRAIN_MODEL.w[2]`): log-odds per dB of link budget is its negative.
const double terrainWBull = -0.138551;
const double oddsPerDb = -terrainWBull;

double sensitivityDbm(int sf, double bwKHz, {double nf = noiseFigureDb}) {
  final floor = snrFloorDb[sf];
  if (floor == null) throw ArgumentError('no SNR floor for SF$sf');
  return -174 + 10 * (math.log(bwKHz * 1000) / math.ln10) + nf + floor;
}

/// Link-budget change against [base] (dB); positive = more margin than the base.
double deltaDb(int sf, double bwKHz, [AirRadio base = meshcoreUs]) => sensitivityDbm(base.sf, base.bwKHz) - sensitivityDbm(sf, bwKHz);

double _logit(double p) => math.log(p / (1 - p));
double _sigmoid(double z) => 1 / (1 + math.exp(-z));

/// Shift link odds by [delta] dB (Bullington-equivalent): sigmoid(logit(p) + 0.1386 x delta).
double shiftOdds(double p, double delta) {
  final q = math.min(math.max(p, 1e-9), 1 - 1e-9);
  return _sigmoid(_logit(q) + oddsPerDb * delta);
}

class PresetRow {
  final int sf;
  final double bwKHz;
  final int cr;

  /// This row is the base radio (same SF, BW and CR).
  final bool isBase;
  final double toaMs, sensitivity, delta;

  /// One packet flooded once by every repeater: repeaters x ToA (ms).
  final double floodLoadMs;
  const PresetRow({
    required this.sf,
    required this.bwKHz,
    required this.cr,
    required this.isBase,
    required this.toaMs,
    required this.sensitivity,
    required this.delta,
    required this.floodLoadMs,
  });
}

List<PresetRow> presetRows({int cr = 5, int bytes = presetPacketBytes, int repeaters = 0, AirRadio base = meshcoreUs}) {
  final rows = <PresetRow>[];
  for (final bw in presetBw) {
    for (final sf in presetSf) {
      final toa = timeOnAir(bytes, AirRadio(sf: sf, bwKHz: bw, cr: cr)).totalMs;
      rows.add(PresetRow(
        sf: sf,
        bwKHz: bw,
        cr: cr,
        isBase: sf == base.sf && bw == base.bwKHz && cr == base.cr,
        toaMs: toa,
        sensitivity: sensitivityDbm(sf, bw),
        delta: deltaDb(sf, bw, base),
        floodLoadMs: repeaters * toa,
      ));
    }
  }
  return rows;
}
