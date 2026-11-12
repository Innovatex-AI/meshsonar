import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/coverage_v2.dart';
import 'package:meshsonar/core/plan/coverage_check.dart';

CoverageCell _c(double lat, double lon, int pings, int heard, {double? snr, int rep = 1, String at = '2026-10-30T12:00:00Z'}) =>
    CoverageCell(lat: lat, lon: lon, pings: pings, heard: heard, bestSnr: snr, medianSnr: snr, repeaters: rep, lastAt: at);

/// A coverage v2 cell (`metric=mean`): the mean SNR of the successful results, how many succeeded / failed.
CoverageCell _v2(double lat, double lon, {required int nOk, required int nFail, double? mean, int rep = 1}) => CoverageCell(
  lat: lat, lon: lon, pings: nOk + nFail, heard: nOk, bestSnr: mean, medianSnr: mean, repeaters: rep, lastAt: '2026-11-01T12:00:00Z',
  snrMean: mean, nOk: nOk, nFail: nFail, band: coverageBandOf(snrMean: mean, nOk: nOk, nSnr: mean == null ? 0 : nOk));

void main() {
  const lat = 39.96, lon = -82.99;
  test('a place with answered pings around it is Covered, with the numbers behind it', () {
    final r = checkCoverage([_c(lat, lon, 10, 9, snr: 8.5, rep: 3), _c(lat + 0.001, lon, 4, 1, snr: -3, at: '2026-10-31T09:00:00Z'), _c(lat + 0.5, lon, 99, 0)], lat, lon);
    expect(r.verdict, CoverageVerdict.covered);
    expect((r.cells, r.heardCells, r.pings, r.heardPings), (2, 2, 14, 10));
    expect(r.bestSnr, 8.5);
    expect(r.maxRepeaters, 3);
    expect(r.lastAt, DateTime.utc(2026, 10, 31, 9));
    expect(r.nearestM, isNull);
    expect(r.cellsLoaded, 3);
  });

  test('driven but nothing heard is Dead (band 0)', () {
    final r = checkCoverage([_c(lat, lon, 6, 0)], lat, lon);
    expect(r.verdict, CoverageVerdict.dead);
    expect(r.band, CoverageBand.noReply);
    expect(r.meanSnr, isNull);
  });

  group('DEF-3: the verdict is the mean SNR band, not the share of pings answered', () {
    test('few pings answered but strong is still Covered; the heard share no longer decides', () {
      // 2 of 10 answered (the old rule: under half = Weak) at +9 dB mean = 16.5 dB over the SF7 floor = Excellent
      final r = checkCoverage([_v2(lat, lon, nOk: 2, nFail: 8, mean: 9)], lat, lon);
      expect(r.verdict, CoverageVerdict.covered);
      expect(r.band, CoverageBand.excellent);
      expect(r.meanSnr, 9);
    });
    test('every ping answered but at the floor is Weak; the heard share no longer decides', () {
      // 10 of 10 answered (the old rule: Covered) at -6 dB mean = 1.5 dB over the floor = Weak
      final r = checkCoverage([_v2(lat, lon, nOk: 10, nFail: 0, mean: -6)], lat, lon);
      expect(r.verdict, CoverageVerdict.weak);
      expect(r.band, CoverageBand.weak);
      // under the floor = Edge, also Weak
      expect(checkCoverage([_v2(lat, lon, nOk: 10, nFail: 0, mean: -9)], lat, lon).band, CoverageBand.edge);
      expect(checkCoverage([_v2(lat, lon, nOk: 10, nFail: 0, mean: -9)], lat, lon).verdict, CoverageVerdict.weak);
    });
    test('band edges follow the SQL rule: margin < 5 Weak, < 10 Fair, < 15 Good, else Excellent (SF7 floor -7.5)', () {
      CoverageCheck at(double mean) => checkCoverage([_v2(lat, lon, nOk: 5, nFail: 0, mean: mean)], lat, lon);
      expect(at(-2.6).band, CoverageBand.weak); // margin 4.9
      expect(at(-2.5).band, CoverageBand.fair); // margin 5.0
      expect(at(2.4).band, CoverageBand.fair);
      expect(at(2.5).band, CoverageBand.good);
      expect(at(7.5).band, CoverageBand.excellent);
      expect(at(-2.5).verdict, CoverageVerdict.covered);
      // a longer-range preset has a lower floor: -6 dB is 9 dB over the SF10 floor (-15) = Fair, Covered (1.5 dB over the SF7 floor would be Weak)
      final sf10 = checkCoverage([_v2(lat, lon, nOk: 5, nFail: 0, mean: -6)], lat, lon, sf: 10);
      expect(sf10.band, CoverageBand.fair);
      expect(sf10.floorDb, -15);
    });
    test('the mean pools every successful result in range (weighted by n_ok), not a mean of cell means', () {
      final r = checkCoverage([_v2(lat, lon, nOk: 9, nFail: 0, mean: 0), _v2(lat + 0.001, lon, nOk: 1, nFail: 5, mean: -10)], lat, lon);
      expect(r.meanSnr, closeTo(-1, 1e-9)); // (9 x 0 + 1 x -10) / 10
      expect((r.nOk, r.nFail), (10, 5));
    });
    test('heard without any SNR is Covered (band 6), said as such', () {
      final r = checkCoverage([_v2(lat, lon, nOk: 3, nFail: 1)], lat, lon);
      expect(r.band, CoverageBand.heardNoSnr);
      expect(r.verdict, CoverageVerdict.covered);
      expect(r.meanSnr, isNull);
    });
    test('an older server (no mean): heard pings stand in for n_ok and the median SNR for the mean', () {
      final r = checkCoverage([_c(lat, lon, 10, 2, snr: -9)], lat, lon);
      expect(r.meanSnr, -9);
      expect(r.band, CoverageBand.edge);
      expect(r.verdict, CoverageVerdict.weak);
      expect((r.nOk, r.nFail), (2, 8));
    });
    test('verdictForBand groups the bands', () {
      expect([for (final b in [0, 1, 2, 3, 4, 5, 6]) verdictForBand(b)], [
        CoverageVerdict.dead, CoverageVerdict.weak, CoverageVerdict.weak, CoverageVerdict.covered, CoverageVerdict.covered, CoverageVerdict.covered, CoverageVerdict.covered,
      ]);
    });
  });

  test('nobody has driven there: Unmeasured, with the distance to the nearest measured cell', () {
    final r = checkCoverage([_c(lat + 0.02, lon, 5, 5)], lat, lon);
    expect(r.verdict, CoverageVerdict.unmeasured);
    expect(r.nearestM, closeTo(2224, 5));
    expect(checkCoverage(const [], lat, lon).nearestM, isNull);
  });

  test('a coarse grid still finds the cell a point sits in (cell reach is added to the radius)', () {
    final cell = _c(lat + 0.006, lon, 8, 8); // about 670 m away: the centre of an res-8 hexagon the point is inside
    expect(checkCoverage([cell], lat, lon).verdict, CoverageVerdict.unmeasured);
    expect(checkCoverage([cell], lat, lon, reachM: cellReachM(const CoverageGrid.h3(res: 8, cellDeg: 0.004))).verdict, CoverageVerdict.covered);
    expect(cellReachM(const CoverageGrid.h3(res: 11, cellDeg: 0.0002)), 25);
    expect(cellReachM(const CoverageGrid.square(cellDeg: 0.01)), closeTo(556.6, 0.1));
  });

  test('a wider radius reaches cells a narrow one misses; empty cells are ignored', () {
    final cells = [_c(lat + 0.01, lon, 8, 8), _c(lat, lon, 0, 0)];
    expect(checkCoverage(cells, lat, lon, radiusM: 500).verdict, CoverageVerdict.unmeasured);
    expect(checkCoverage(cells, lat, lon, radiusM: 2000).verdict, CoverageVerdict.covered);
  });
}
