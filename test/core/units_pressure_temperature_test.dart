import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/units.dart';

void main() {
  test('pressure: hPa with 1 decimal (metric), inHg with 2 decimals (imperial)', () {
    expect(Units.metric.pressure(987.42), '987.4 hPa');
    expect(Units.imperial.pressure(987.42), '29.16 inHg');
    expect(Units.metric.pressure(1013.25), '1013.3 hPa');
    expect(Units.imperial.pressure(1013.25), '29.92 inHg');
    expect(Units.imperial.pressure(33.8638866667), '1.00 inHg');
    expect(Units.metric.pressure(double.nan), '0.0 hPa');
    expect(Units.metric.pressureUnit, 'hPa');
    expect(Units.imperial.pressureUnit, 'inHg');
  });

  test('temperature: whole °C (metric) / °F (imperial)', () {
    expect(Units.metric.temperature(11.2), '11 °C');
    expect(Units.imperial.temperature(11.2), '52 °F');
    expect(Units.metric.temperature(-0.4), '0 °C');
    expect(Units.imperial.temperature(-40), '-40 °F');
    expect(Units.imperial.temperature(100), '212 °F');
    expect(Units.metric.temperature(double.infinity), '0 °C');
    expect(Units.metric.temperatureUnit, '°C');
    expect(Units.imperial.temperatureUnit, '°F');
  });
}
