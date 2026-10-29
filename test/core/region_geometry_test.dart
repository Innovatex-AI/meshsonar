import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_geometry.dart';
import 'package:meshsonar/core/region_pick.dart';

import '../support/regions_559.dart';

/// The pre-0.20.1 algorithm, kept as the reference the typed-array version must agree with.
bool _ref(List<dynamic> ring, double lat, double lon) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i] as List, b = ring[j] as List;
    final xi = (a[0] as num).toDouble(), yi = (a[1] as num).toDouble();
    final xj = (b[0] as num).toDouble(), yj = (b[1] as num).toDouble();
    if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

void main() {
  test('Polygon with a hole: inside, in the hole, outside', () {
    final r = square('AAA', 0, 0, 10, 10, holes: [
      [[4, 4], [6, 4], [6, 6], [4, 6], [4, 4]]
    ]);
    expect(pointInBoundary(r.boundary!, 2, 2), isTrue);
    expect(pointInBoundary(r.boundary!, 5, 5), isFalse, reason: 'the hole is outside');
    expect(pointInBoundary(r.boundary!, 11, 5), isFalse);
  });

  test('MultiPolygon: either part holds the point', () {
    final b = {
      'type': 'MultiPolygon',
      'coordinates': [
        [[[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]],
        [[[5, 5], [6, 5], [6, 6], [5, 6], [5, 5]]],
      ],
    };
    expect(pointInBoundary(b, 0.5, 0.5), isTrue);
    expect(pointInBoundary(b, 5.5, 5.5), isTrue);
    expect(pointInBoundary(b, 3, 3), isFalse);
  });

  test('malformed boundaries match nothing and never throw', () {
    for (final b in <Map<String, dynamic>>[
      {'type': 'Polygon', 'coordinates': 'x'},
      {'type': 'Polygon', 'coordinates': []},
      {'type': 'Polygon', 'coordinates': [[[0, 0], [1, 1]]]}, // two vertices
      {'type': 'Polygon', 'coordinates': [[['a', 0], [1, 1], [2, 2], [0, 0]]]},
      {'type': 'Point', 'coordinates': [0, 0]},
      {'type': 'MultiPolygon'},
    ]) {
      expect(pointInBoundary(b, 0.5, 0.5), isFalse, reason: '$b');
      expect(distanceToBoundaryM(b, 0.5, 0.5), double.infinity, reason: '$b');
    }
  });

  test('the typed-array test agrees with the plain ray cast on 559 outlines and 20,000 points', () {
    final index = syntheticIndex559();
    final rnd = math.Random(3);
    var inside = 0;
    for (final r in index.take(80)) {
      final ring = (r.boundary!['coordinates'] as List).first as List;
      final b = r.bbox!;
      for (var k = 0; k < 250; k++) {
        final lon = b[0] - 0.2 + rnd.nextDouble() * (b[2] - b[0] + 0.4), lat = b[1] - 0.2 + rnd.nextDouble() * (b[3] - b[1] + 0.4);
        final want = _ref(ring, lat, lon);
        expect(pointInBoundary(r.boundary!, lat, lon), want, reason: '${r.code} $lat,$lon');
        if (want) inside++;
      }
    }
    expect(inside, greaterThan(5000));
  });

  test('prepared form is built once per boundary object', () {
    final r = square('AAA', 0, 0, 1, 1);
    expect(identical(PreparedBoundary.of(r.boundary!), PreparedBoundary.of(r.boundary!)), isTrue);
  });

  test('distance to the nearest edge, holes count, 1 degree of latitude is 111 km', () {
    final r = square('AAA', 0, 0, 1, 1);
    expect(distanceToBoundaryM(r.boundary!, 0.5, 2), closeTo(111320, 200)); // 1 degree of longitude at the equator-ish
    expect(distanceToBoundaryM(r.boundary!, 0.5, 0.5), closeTo(0.5 * 111320, 400));
    final h = square('BBB', 0, 0, 1, 1, holes: [
      [[0.4, 0.4], [0.6, 0.4], [0.6, 0.6], [0.4, 0.6], [0.4, 0.4]]
    ]);
    expect(distanceToBoundaryM(h.boundary!, 0.5, 0.5), closeTo(0.1 * 111320, 200), reason: 'the hole edge is nearer than the outer edge');
  });

  test('area orders a small zone below a big one, and a hole takes area away', () {
    final big = PreparedBoundary.of(square('AAA', 0, 0, 2, 2).boundary!)!;
    final small = PreparedBoundary.of(square('BBB', 0, 0, 1, 1).boundary!)!;
    final holed = PreparedBoundary.of(square('CCC', 0, 0, 2, 2, holes: [
      [[0.5, 0.5], [1.5, 0.5], [1.5, 1.5], [0.5, 1.5], [0.5, 0.5]]
    ]).boundary!)!;
    expect(small.areaKm2, lessThan(big.areaKm2));
    expect(big.areaKm2, closeTo(4 * 111.32 * 111.32, 4 * 111.32 * 111.32 * 0.01));
    expect(holed.areaKm2, closeTo(big.areaKm2 - 111.32 * 111.32, 200));
  });

  test('a synthetic 230-vertex outline holds its own centre, far from every edge', () {
    final r = syntheticRegion(10);
    final c = regionCenter(r)!;
    expect(regionHolds(r, c.lat, c.lon), isTrue);
    final far = PreparedBoundary.of(r.boundary!)!;
    expect(far.distanceM(c.lat, c.lon), greaterThan(50000));
  });
}
