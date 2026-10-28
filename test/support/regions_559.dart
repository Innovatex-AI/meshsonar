// A deterministic stand-in for the real 559-region `regions-index` (no network in tests): 559 regions on a world grid
// with wobbly ~230-vertex outlines (the real median is 228), country suffixes and accents like the live names, one
// nested zone, neighbours that overlap by a sliver, and a hole. Same shape as the wire: `{regions:[...], asOf}`.
import 'dart:convert';
import 'dart:math' as math;

import 'package:meshsonar/core/region_lookup.dart';

const _countries = ['US', 'US', 'US', 'DE', 'AU', 'CA', 'GB', 'SE', 'BR', 'CZ', 'PL', 'NL', 'FR', 'NZ', 'ES', 'RU', 'FI', 'IT', 'MD', 'KZ'];
const _places = [
  'Aachen', 'Düsseldorf', 'Chișinău', 'Gävleborgs län', 'São Paulo', 'Lübeck', 'Örebro län', 'Ottawa–Gatineau', 'Región de Murcia', 'Kärnten',
  'Columbus', 'Dayton', 'Cincinnati', 'Lima', 'Boston', 'Cebu & Bohol', 'Åre', 'Zürich', 'Łódź', 'Řež',
];

/// Region [i] (0-based): code is a stable three letter code, name "Place N, CC".
RegionIndexEntry syntheticRegion(int i, {int vertices = 230}) {
  final code = String.fromCharCodes([65 + (i ~/ 676) % 26, 65 + (i ~/ 26) % 26, 65 + i % 26]);
  final cc = _countries[i % _countries.length];
  final place = _places[i % _places.length];
  // One cell per region on a 28 x 20 grid, 2.4 x 1.6 degrees apart, a 0.9 degree radius.
  final col = i % 28, row = i ~/ 28;
  final lon = -168 + col * 12.0, lat = -48 + row * 4.8;
  return _ring(code, '$place ${i ~/ _places.length + 1}, $cc', lon, lat, 1.9, 1.5, vertices, seed: i);
}

RegionIndexEntry _ring(String code, String name, double lon, double lat, double rx, double ry, int n, {int seed = 0, bool hole = false}) {
  final rnd = math.Random(seed);
  final outer = <List<double>>[];
  for (var k = 0; k < n; k++) {
    final a = 2 * math.pi * k / n;
    final w = 1 + 0.12 * math.sin(5 * a + seed) + (rnd.nextDouble() - 0.5) * 0.04;
    outer.add([lon + rx * w * math.cos(a), lat + ry * w * math.sin(a)]);
  }
  outer.add(List.of(outer.first));
  final rings = <List<List<double>>>[outer];
  if (hole) {
    rings.add([for (var k = 0; k <= 8; k++) [lon + rx * 0.2 * math.cos(2 * math.pi * k / 8), lat + ry * 0.2 * math.sin(2 * math.pi * k / 8)]]);
  }
  double minX = 1e9, minY = 1e9, maxX = -1e9, maxY = -1e9;
  for (final p in outer) {
    minX = math.min(minX, p[0]);
    maxX = math.max(maxX, p[0]);
    minY = math.min(minY, p[1]);
    maxY = math.max(maxY, p[1]);
  }
  return RegionIndexEntry(
    code: code,
    slug: code.toLowerCase(),
    name: name,
    url: 'https://${code.toLowerCase()}.meshsonar.com',
    bbox: [minX, minY, maxX, maxY],
    boundary: {'type': 'Polygon', 'coordinates': rings},
  );
}

/// 559 synthetic regions, like production on Oct 28 2026.
List<RegionIndexEntry> syntheticIndex559({int vertices = 230}) => [for (var i = 0; i < 559; i++) syntheticRegion(i, vertices: vertices)];

/// The wire body of [index] (`{regions, asOf}`), as `GET /api/cmh/regions-index` sends it.
String regionsIndexBody(List<RegionIndexEntry> index, {String asOf = '2026-10-28T22:00:00.000Z'}) =>
    jsonEncode({'regions': [for (final r in index) r.toJson()..removeWhere((k, v) => v == null)], 'asOf': asOf});

/// A square region (degrees), for exact border tests.
RegionIndexEntry square(String code, double west, double south, double east, double north, {List<List<List<double>>>? holes}) => RegionIndexEntry(
      code: code,
      slug: code.toLowerCase(),
      name: '$code, US',
      url: 'https://${code.toLowerCase()}.meshsonar.com',
      bbox: [west, south, east, north],
      boundary: {
        'type': 'Polygon',
        'coordinates': [
          [[west, south], [east, south], [east, north], [west, north], [west, south]],
          ...?holes,
        ],
      },
    );
