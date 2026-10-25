// Per-quantity unit choices (Andy, Oct 24 2026): Auto keeps following the phone locale; distance, speed, height,
// temperature and pressure can each have their own unit, "follow" by default. Settings JSON stays backward and forward
// compatible, and the helpers' existing API (Units.metric/imperial, pressure, temperature, isImperial) is unchanged.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/units.dart';

void main() {
  group('Units with overrides', () {
    test('no overrides: exactly the old behaviour', () {
      const m = Units(UnitSystem.metric);
      expect(m.distance(2345), '2.3 km');
      expect(m.speed(10), '36 km/h');
      expect(m.height(1.8), '1.8 m');
      expect(m.temperature(11.2), '11 °C');
      expect(m.pressure(1013.25), '1013.3 hPa');
      expect(Units.imperial.pressure(1013.25), '29.92 inHg');
      expect(Units.imperial.isImperial, isTrue);
      expect(Units.metric.isMixed, isFalse);
      expect(Units.imperial.description, 'imperial');
      expect(Units.metric.description, 'metric');
    });

    test('each quantity follows its own choice and only that one', () {
      const u = Units(UnitSystem.metric, UnitOverrides(speed: UnitChoice.imperial));
      expect(u.speed(10), '22 mph');
      expect(u.speedUnit, 'mph');
      expect(u.distance(2345), '2.3 km', reason: 'distance still follows metric');
      expect(u.height(1.8), '1.8 m');
      expect(u.temperature(20), '20 °C');
      expect(u.isMixed, isTrue);
      expect(u.description, 'metric, with speed in mph');

      const v = Units(UnitSystem.imperial, UnitOverrides(temperature: UnitChoice.metric, height: UnitChoice.metric));
      expect(v.temperature(20), '20 °C');
      expect(v.height(1.8), '1.8 m');
      expect(v.heightNumber(1.8), '1.8');
      expect(v.parseHeightToM('2'), 2, reason: 'a bare number is in the height unit');
      expect(v.distance(1609.344), '1.0 mi');
      expect(v.description, 'imperial, with height in m and temperature in °C');
    });

    test('distance override drives every distance helper (rings, slider, short lengths) and isImperial', () {
      const u = Units(UnitSystem.metric, UnitOverrides(distance: UnitChoice.imperial));
      expect(u.isImperial, isTrue, reason: 'isImperial is the distance wording ("Miles driven", ring labels)');
      expect(u.rangeRingLabels, ['0.5 mi', '1 mi']);
      expect(u.shortLength(12.4), '41 ft');
      expect(u.lengthUnit, 'ft');
      expect(u.longDistanceUnit, 'mi');
      expect(u.metresPerLongUnit, metresPerMile);
      expect(u.sliderDistance(100), '330 ft');
      expect(u.speed(10), '36 km/h');
      expect(u.total(16093.44, (n) => '$n'), '10 mi');
    });

    test('pressure: follow, hPa, inHg and mmHg', () {
      expect(const Units(UnitSystem.imperial, UnitOverrides(pressure: PressureChoice.hPa)).pressure(1013.25), '1013.3 hPa');
      expect(const Units(UnitSystem.metric, UnitOverrides(pressure: PressureChoice.inHg)).pressure(1013.25), '29.92 inHg');
      const mm = Units(UnitSystem.metric, UnitOverrides(pressure: PressureChoice.mmHg));
      expect(mm.pressure(1013.25), '760 mmHg');
      expect(mm.pressureUnit, 'mmHg');
      expect(mm.pressure(double.nan), '0 mmHg');
      expect(mm.description, 'metric, with pressure in mmHg');
      expect(const Units(UnitSystem.metric, UnitOverrides(pressure: PressureChoice.hPa)).isMixed, isFalse,
          reason: 'picking what metric already uses is not an exception');
    });

    test('resolve: Auto still follows the locale, then the overrides apply', () {
      const o = UnitOverrides(temperature: UnitChoice.metric);
      final us = Units.resolve(UnitsPreference.auto, localeName: 'en_US', overrides: o);
      expect(us.distance(1609.344), '1.0 mi');
      expect(us.temperature(20), '20 °C');
      final de = Units.resolve(UnitsPreference.auto, localeName: 'de_DE', overrides: o);
      expect(de.distance(1609.344), '1.6 km');
      expect(Units.resolve(UnitsPreference.imperial).temperature(100), '212 °F');
    });

    test('joinAnd', () {
      expect(joinAnd([]), '');
      expect(joinAnd(['a']), 'a');
      expect(joinAnd(['a', 'b']), 'a and b');
      expect(joinAnd(['a', 'b', 'c']), 'a, b and c');
    });
  });

  group('UnitOverrides JSON', () {
    test('only non-follow quantities are written; round trip', () {
      expect(const UnitOverrides().toJson(), isEmpty);
      const o = UnitOverrides(speed: UnitChoice.imperial, pressure: PressureChoice.mmHg);
      expect(o.toJson(), {'speed': 'imperial', 'pressure': 'mmHg'});
      expect(UnitOverrides.fromJson(jsonDecode(jsonEncode(o.toJson()))), o);
    });

    test('missing, wrong-typed, unknown keys and unknown values all mean "follow"', () {
      expect(UnitOverrides.fromJson(null), const UnitOverrides());
      expect(UnitOverrides.fromJson('imperial'), const UnitOverrides());
      expect(UnitOverrides.fromJson([1, 2]), const UnitOverrides());
      final o = UnitOverrides.fromJson({'speed': 'imperial', 'wind': 'knots', 'distance': 'nautical', 'height': 3});
      expect(o, const UnitOverrides(speed: UnitChoice.imperial));
    });
  });

  group('Settings file', () {
    test('an old file (no unit_overrides) loads with every quantity following Units', () {
      final s = Settings.fromJson({'units': 'imperial', 'channel': '#wardriving'});
      expect(s.units, UnitsPreference.imperial);
      expect(s.unitOverrides.isEmpty, isTrue);
      expect(s.toJson().containsKey('unit_overrides'), isFalse, reason: 'nothing new written while unused');
    });

    test('overrides are saved and read back; copyWith keeps and replaces them', () {
      const o = UnitOverrides(temperature: UnitChoice.imperial);
      final s = const Settings().copyWith(unitOverrides: o);
      expect(s.toJson()['unit_overrides'], {'temperature': 'imperial'});
      final back = Settings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(back.unitOverrides, o);
      expect(back.copyWith(heardHoldPings: 5).unitOverrides, o);
      expect(back.copyWith(unitOverrides: const UnitOverrides()).toJson().containsKey('unit_overrides'), isFalse);
    });

    test('a newer file (unknown keys anywhere) still loads', () {
      final s = Settings.fromJson({
        'units': 'metric',
        'unit_overrides': {'speed': 'imperial', 'wind_speed': 'knots'},
        'some_future_setting': {'x': 1},
      });
      expect(s.unitOverrides.speed, UnitChoice.imperial);
      expect(s.units, UnitsPreference.metric);
    });

    test('through the real settings store on disk', () async {
      final dir = await Directory.systemTemp.createTemp('ms-units');
      addTearDown(() => dir.delete(recursive: true));
      final store = FileSettingsStore(File('${dir.path}/settings.json'));
      await store.save(const Settings(unitOverrides: UnitOverrides(pressure: PressureChoice.inHg)));
      expect((await store.load()).unitOverrides.pressure, PressureChoice.inHg);
      // An old file written before this setting existed.
      await File('${dir.path}/settings.json').writeAsString(jsonEncode({'units': 'imperial'}));
      final old = await store.load();
      expect(old.units, UnitsPreference.imperial);
      expect(old.unitOverrides.isEmpty, isTrue);
    });
  });
}
