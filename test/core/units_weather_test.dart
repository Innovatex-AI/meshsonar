// Weather quantities through Units: wind speed numbers for chart axes, precipitation (mm / in, follows the distance
// choice), and pressure differences, honouring per-quantity overrides.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/units.dart';

void main() {
  test('precipitation: mm with at most one decimal, inches with two', () {
    expect(Units.metric.precipitation(0), '0 mm');
    expect(Units.metric.precipitation(0.04), '0 mm');
    expect(Units.metric.precipitation(0.2), '0.2 mm');
    expect(Units.metric.precipitation(12.34), '12.3 mm');
    expect(Units.metric.precipitation(10), '10 mm');
    expect(Units.imperial.precipitation(0), '0.00 in');
    expect(Units.imperial.precipitation(25.4), '1.00 in');
    expect(Units.imperial.precipitation(0.5), '0.02 in');
    expect(Units.metric.precipitation(double.nan), '0 mm');
    expect(Units.metric.precipitation(-1), '0 mm');
    expect(Units.metric.precipitationUnit, 'mm');
    expect(Units.imperial.precipitationUnit, 'in');
    expect(Units.imperial.precipitationValue(50.8), closeTo(2, 1e-9));
    expect(Units.metric.precipitationValue(3.5), 3.5);
  });

  test('precipitation follows the distance override, not the Units setting', () {
    const u = Units(UnitSystem.metric, UnitOverrides(distance: UnitChoice.imperial));
    expect(u.precipitation(25.4), '1.00 in');
    const v = Units(UnitSystem.imperial, UnitOverrides(distance: UnitChoice.metric));
    expect(v.precipitation(25.4), '25.4 mm');
  });

  test('wind: speedValue matches the speed text and honours the speed override', () {
    expect(Units.metric.speedValue(10), closeTo(36, 1e-9));
    expect(Units.metric.speed(10), '36 km/h');
    expect(Units.imperial.speedValue(10), closeTo(22.36936, 1e-6));
    expect(Units.imperial.speed(10), '22 mph');
    const u = Units(UnitSystem.metric, UnitOverrides(speed: UnitChoice.imperial));
    expect(u.speed(4.1), '9 mph');
    expect(u.speedUnit, 'mph');
  });

  test('pressure difference in the chosen pressure unit, never signed', () {
    expect(Units.metric.pressureDelta(1.26), '1.3 hPa');
    expect(Units.metric.pressureDelta(-1.26), '1.3 hPa');
    expect(Units.imperial.pressureDelta(3.386), '0.10 inHg');
    const u = Units(UnitSystem.metric, UnitOverrides(pressure: PressureChoice.mmHg));
    expect(u.pressureDelta(1.33322387415), '1.0 mmHg');
  });

  test('temperature override flows through the numbers a weather chart plots', () {
    const u = Units(UnitSystem.metric, UnitOverrides(temperature: UnitChoice.imperial));
    expect(u.temperature(11.2), '52 °F');
    expect(u.temperatureValue(10), 50);
    expect(u.temperatureUnit, '°F');
  });
}
