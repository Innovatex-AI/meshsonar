import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_pick.dart';
import 'package:meshsonar/core/units.dart';

const _square = {
  'type': 'Polygon',
  'coordinates': [
    [[-84.0, 39.0], [-83.0, 39.0], [-83.0, 40.0], [-84.0, 40.0], [-84.0, 39.0]],
    [[-83.6, 39.4], [-83.4, 39.4], [-83.4, 39.6], [-83.6, 39.6], [-83.6, 39.4]],
  ],
};

void main() {
  test('point in polygon honours holes', () {
    expect(pointInBoundary(_square, 39.2, -83.8), isTrue);
    expect(pointInBoundary(_square, 39.5, -83.5), isFalse); // in the hole
    expect(pointInBoundary(_square, 41, -83.5), isFalse);
  });

  const a = RegionIndexEntry(code: 'AAA', slug: 'a', name: 'A', url: 'https://a.example', bbox: [-84.0, 39.0, -83.0, 40.0]);
  const b = RegionIndexEntry(code: 'BBB', slug: 'b', name: 'B', url: 'https://b.example', bbox: [-82.0, 39.0, -81.0, 40.0]);
  const holey = RegionIndexEntry(code: 'HOL', slug: 'h', name: 'H', url: 'https://h.example', bbox: [-84.0, 39.0, -83.0, 40.0], boundary: _square);

  test('regionContaining uses the boundary when there is one, smallest bbox wins overlaps', () {
    expect(regionContaining([holey], 39.5, -83.5), isNull);
    expect(regionContaining([holey, b], 39.2, -83.8)?.code, 'HOL');
    expect(regionContaining([a, b], 39.5, -83.5)?.code, 'AAA');
  });

  test('switcher lists every region: GPS region first, then nearest', () {
    final out = regionsForSwitcher([b, a], gpsRegion: a, lat: 39.5, lon: -83.5);
    expect(out.map((r) => r.code), ['AAA', 'BBB']);
    final far = regionsForSwitcher([a, b], lat: 39.5, lon: -81.2);
    expect(far.map((r) => r.code), ['BBB', 'AAA']);
    expect(nearestRegion([a, b], 39.5, -82.9)?.code, 'AAA');
  });

  test('units: locale, distance, speed, height parse', () {
    expect(Units.resolve(UnitsPreference.auto, localeName: 'en_US').isImperial, isTrue);
    expect(Units.resolve(UnitsPreference.auto, localeName: 'de_DE').isImperial, isFalse);
    expect(Units.metric.distance(949, approx: true), '950 m');
    expect(Units.metric.distance(1500), '1.5 km');
    expect(Units.imperial.distance(100), '330 ft');
    expect(Units.imperial.distance(3000), '1.9 mi');
    expect(Units.imperial.speed(10), '22 mph');
    expect(Units.imperial.parseHeightToM('6ft'), closeTo(1.8288, 1e-4));
    expect(Units.metric.parseHeightToM('1,8'), 1.8);
  });
}
