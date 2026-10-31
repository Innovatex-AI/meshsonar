// The zoom -> H3 resolution table shared by the network coverage layer and the live drive's hexagons.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/coverage_query.dart';

/// Edge length of an H3 cell by resolution, metres (h3geo.org average edge lengths).
const _edgeM = {7: 1220.6, 8: 461.4, 9: 174.4, 10: 65.9, 11: 24.9};

/// Width of a cell (vertex to vertex) in screen px at [zoom] and [lat].
double _cellPx(int res, double zoom, double lat) {
  final metresPerPx = 156543.03392 * math.cos(lat * math.pi / 180) / math.pow(2, zoom);
  return 2 * _edgeM[res]! / metresPerPx;
}

void main() {
  test('the table is the documented one, band edges included', () {
    expect(kCoverageResBands, [(0.0, 7), (11.5, 8), (12.5, 9), (14.0, 10), (15.5, 11)]);
    final cases = <double, int>{
      0: 7, 3: 7, 9: 7, 11.49: 7,
      11.5: 8, 12.49: 8,
      12.5: 9, 13.6: 9, 13.99: 9,
      14: 10, 15.49: 10,
      15.5: 11, 18: 11, 22: 11,
    };
    cases.forEach((z, r) => expect(coverageResForZoom(z), r, reason: 'zoom $z'));
  });

  test('never decreases as you zoom in, stays inside what the server serves, NaN is the middle band', () {
    var last = 0;
    for (var z = 0.0; z <= 22; z += 0.05) {
      final r = coverageResForZoom(z);
      expect(r, greaterThanOrEqualTo(last), reason: 'zoom $z');
      expect(r, inInclusiveRange(coverageMinRes, coverageMaxRes));
      last = r;
    }
    expect(coverageResForZoom(double.nan), 9);
    expect(coverageResForZoom(-3), 7);
  });

  test('a cell is never a speck or a blob: 12-130 px across from zoom 11.5 up, at any latitude 0-60', () {
    for (final lat in [0.0, 20.0, 40.0, 60.0]) {
      for (var z = 11.5; z <= 17.5; z += 0.1) {
        final px = _cellPx(coverageResForZoom(z), z, lat);
        // At lat 60 the cells are half as wide on screen as at the equator (mercator), so the floor is lower there.
        expect(px, inInclusiveRange(lat >= 60 ? 9 : 12, 130), reason: 'lat $lat zoom ${z.toStringAsFixed(1)} -> ${px.toStringAsFixed(1)} px');
      }
    }
  });

  test('regression: the old fixed res 9 was a blob at street zoom', () {
    // What Andy saw on the drive: zoom ~16 draws res-9 cells of ~300 px while the network layer showed ~20 px cells.
    expect(_cellPx(9, 16, 40), greaterThan(150));
    expect(_cellPx(coverageResForZoom(16), 16, 40), lessThan(60));
  });
}
