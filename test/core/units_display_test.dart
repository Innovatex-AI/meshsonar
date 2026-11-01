import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/units.dart';

void main() {
  group('distance boundaries', () {
    test('metric: 949 / 950 / 999 / 1000 m', () {
      expect(Units.metric.distance(949), '949 m');
      expect(Units.metric.distance(949, approx: true), '950 m');
      expect(Units.metric.distance(950, approx: true), '1.0 km');
      expect(Units.metric.distance(999), '999 m');
      expect(Units.metric.distance(1000), '1.0 km');
      expect(Units.metric.distance(2345), '2.3 km');
      expect(Units.metric.distance(14200), '14 km');
    });
    test('imperial: feet under 0.1 mi, then miles', () {
      expect(Units.imperial.distance(100), '330 ft');
      expect(Units.imperial.distance(160), '520 ft');
      expect(Units.imperial.distance(1609.344 / 10), '0.1 mi');
      expect(Units.imperial.distance(1609.344), '1.0 mi');
      expect(Units.imperial.distance(30000), '19 mi');
    });
  });

  test('speed, short length and height in both systems', () {
    expect(Units.metric.speed(10), '36 km/h');
    expect(Units.imperial.speed(10), '22 mph');
    expect(Units.metric.shortLength(12.4), '12 m');
    expect(Units.imperial.shortLength(12.4), '41 ft');
    expect(Units.metric.height(1.8), '1.8 m');
    expect(Units.imperial.height(1.8), '6 ft');
  });

  test('height text round-trips and parses variants', () {
    expect(Units.imperial.parseHeightToM('6'), closeTo(1.8288, 1e-4));
    expect(Units.imperial.parseHeightToM('1.8 m'), 1.8);
    expect(Units.metric.parseHeightToM('1,8'), 1.8);
    expect(Units.metric.parseHeightToM('6ft'), closeTo(1.8288, 1e-4));
    expect(Units.metric.parseHeightToM('abc'), isNull);
    expect(Units.metric.heightNumber(1.8), '1.8');
    expect(Units.imperial.heightNumber(1.8288), '6');
  });

  test('rings, slider stops and labels follow the system', () {
    expect(Units.metric.rangeRingLabels, ['1 km', '2 km']);
    expect(Units.imperial.rangeRingLabels, ['0.5 mi', '1 mi']);
    expect(Units.imperial.rangeRingMetres, [804.672, 1609.344]);
    const metric = [15, 25, 50, 75, 100, 125, 150, 200, 250, 300, 400, 500];
    expect(Units.metric.minDistanceStops(metric), metric);
    final imp = Units.imperial.minDistanceStops(metric);
    expect(imp.length, metric.length);
    expect(Units.imperial.sliderDistance(imp.first), '50 ft');
    expect(Units.imperial.sliderDistance(imp.last), '1600 ft');
    expect(Units.imperial.sliderDistance(100), '330 ft');
    expect(Units.metric.sliderDistance(100), '100 m');
    // the chip and the slider agree: a stored 100 m sits on the 300 ft stop
    expect(Units.imperial.minDistanceLabel(100, metric), '300 ft');
    expect(Units.metric.minDistanceLabel(100, metric), '100 m');
  });

  test('antenna summary uses the chosen height unit; plain summary stays metric', () {
    final p = AntennaProfile(mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8288, updatedAt: DateTime.utc(2026));
    expect(p.summary, endsWith('1.83 m'));
    expect(p.summaryIn(Units.imperial), endsWith('6 ft'));
  });

  test('Auto follows the phone region', () {
    expect(Units.resolve(UnitsPreference.auto, localeName: 'en_US').isImperial, isTrue);
    expect(Units.resolve(UnitsPreference.auto, localeName: 'en_GB').isImperial, isFalse);
    expect(Units.resolve(UnitsPreference.metric, localeName: 'en_US').isImperial, isFalse);
  });
}
