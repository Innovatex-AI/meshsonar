import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/coverage_check.dart';

CoverageCell _c(double lat, double lon, int pings, int heard, {double? snr, int rep = 1, String at = '2026-10-30T12:00:00Z'}) =>
    CoverageCell(lat: lat, lon: lon, pings: pings, heard: heard, bestSnr: snr, medianSnr: snr, repeaters: rep, lastAt: at);

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

  test('driven but nothing heard is Dead; under half answered is Weak', () {
    expect(checkCoverage([_c(lat, lon, 6, 0)], lat, lon).verdict, CoverageVerdict.dead);
    expect(checkCoverage([_c(lat, lon, 10, 2)], lat, lon).verdict, CoverageVerdict.weak);
    expect(checkCoverage([_c(lat, lon, 10, 5)], lat, lon).verdict, CoverageVerdict.covered);
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
