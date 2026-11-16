// The verify loop (release 0.38 improvement 20, A9): an installed node's plan-verify prediction against measured coverage
// cells, read from the answer's own 0.5 dB grid, with the "not enough data" state under the minimum cell count.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_analysis.dart';
import 'package:meshsonar/core/plan_contract.dart';

const _site = PlanPoint(40.0, -83.0);

/// A prediction decoding (margin >= 0) out to 2 km: margin 20 - j dB at sample j (100 m apart), 36 radials, 3 km sweep.
PlanVerifyResult _prediction({bool grid = true}) {
  final b = Int8List(36 * 30);
  for (var r = 0; r < 36; r++) {
    for (var j = 1; j <= 30; j++) {
      b[r * 30 + j - 1] = ((20 - j) * 2).clamp(-128, 127);
    }
  }
  return PlanVerifyResult.parse({
    'coveredKm2': 12.6,
    'bands': const [],
    'params': {'lat': _site.lat, 'lon': _site.lon},
    'model': {'sf': 7, 'snrFloorDb': -7.5},
    if (grid) 'grid': {'radials': 36, 'n': 30, 'stepM': 100, 'margin': base64.encode(Uint8List.sublistView(b)), 'scale': 0.5},
  });
}

PlanMeasuredCell _cell(double northM, double eastM, {required bool heard, double? snr}) => PlanMeasuredCell(offsetM(_site, northM, eastM), heard: heard, snr: snr);

void main() {
  test('reads the margin from the answer\'s grid', () {
    final m = predictedMarginSampler(_prediction())!;
    expect(m(offsetM(_site, 500, 0)), 15);
    expect(m(offsetM(_site, 0, 2500)), -5);
    expect(m(offsetM(_site, 9000, 0)), isNull, reason: 'outside the sweep');
    expect(predictedMarginSampler(_prediction(grid: false)), isNull);
  });

  test('counts covered-and-heard, covered-but-silent, heard outside the prediction and the SNR bias', () {
    final cells = [
      _cell(300, 0, heard: true, snr: 4), // margin 17: predicted SNR 9.5
      _cell(0, 1000, heard: true, snr: 0), // margin 10: predicted 2.5
      _cell(-500, 0, heard: true, snr: null), // covered, heard, no reading
      _cell(0, -1500, heard: false), // covered, silent
      _cell(2500, 0, heard: true, snr: -10), // outside the prediction (margin -5), heard: predicted -12.5
      _cell(-2800, 0, heard: false), // outside and quiet
      _cell(9000, 0, heard: true, snr: 1), // outside the sweep: not compared
    ];
    final v = compareVerifyWithMeasured(_prediction(), cells);
    expect(v.enough, isTrue);
    expect(v.compared, 6);
    expect(v.coveredHeard, 3);
    expect(v.coveredSilent, 1);
    expect(v.heardOutside, 1);
    expect(v.quietOutside, 1);
    expect(v.agreePct, closeTo(100 * 4 / 6, 1e-9));
    expect(v.measuredSnr, closeTo((4 + 0 - 10) / 3, 1e-9));
    expect(v.predictedSnr, closeTo((9.5 + 2.5 - 12.5) / 3, 1e-9));
    expect(v.biasDb, closeTo(v.predictedSnr! - v.measuredSnr!, 1e-9));
  });

  test('under the minimum cell count it is "not enough data"; no grid compares nothing', () {
    final few = [_cell(300, 0, heard: true, snr: 4), _cell(0, 1000, heard: false)];
    final v = compareVerifyWithMeasured(_prediction(), few);
    expect(v.compared, 2);
    expect(v.enough, isFalse);
    expect(v.minCells, verifyMinCells);
    expect(compareVerifyWithMeasured(_prediction(), few, minCells: 2).enough, isTrue);
    final none = compareVerifyWithMeasured(_prediction(grid: false), few);
    expect(none.compared, 0);
    expect(none.enough, isFalse);
    expect(none.biasDb, isNull);
  });

  test('a caller\'s sampler and SNR floor win (the stored estimate re-styled for another spreading factor)', () {
    final v = compareVerifyWithMeasured(PlanVerifyResult.parse(const {'coveredKm2': 1}), [for (var i = 0; i < 5; i++) _cell(i * 10.0, 0, heard: true, snr: -15)],
        marginAt: (_) => 2, snrFloorDb: -20);
    expect(v.coveredHeard, 5);
    expect(v.predictedSnr, -18);
    expect(v.biasDb, closeTo(-3, 1e-9));
  });
}
