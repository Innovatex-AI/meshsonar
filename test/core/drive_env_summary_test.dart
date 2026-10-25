import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_env_summary.dart';

WeatherSnapshot s(int h, {double? t, double? p, double? mm, double? wind, double? dir, double? cloud, double? rh, double? dew}) =>
    WeatherSnapshot(
        at: DateTime.utc(2026, 10, 24, h),
        temperatureC: t,
        pressureHpa: p,
        precipMm: mm,
        windMs: wind,
        windDirDeg: dir,
        cloudPct: cloud,
        humidityPct: rh,
        dewPointC: dew);

void main() {
  test('summary: ranges, total rain, mean cloud, wind; a quantity nobody gave stays null', () {
    final r = summarizeWeather([
      s(10, t: 11.2, p: 1012.4, mm: 0.2, wind: 4, dir: 230, cloud: 90, rh: 81, dew: 8),
      s(11, t: 13.0, p: 1011.0, mm: 0.0, wind: 6, dir: 250, cloud: 70, rh: 70, dew: 7),
      s(12, t: 12.0, wind: 2, cloud: 80),
    ])!;
    expect(r.hours, 3);
    expect([r.tempMinC, r.tempMaxC], [11.2, 13.0]);
    expect([r.pressureMinHpa, r.pressureMaxHpa], [1011.0, 1012.4]);
    expect(r.precipTotalMm, closeTo(0.2, 1e-9));
    expect(r.cloudMeanPct, 80);
    expect(r.windMeanMs, 4);
    expect(r.windMaxMs, 6);
    expect([r.humidityMinPct, r.humidityMaxPct], [70, 81]);
    expect([r.dewPointMinC, r.dewPointMaxC], [7, 8]);
    expect(compassPoint(r.windMeanDirDeg!), 'WSW');
    final bare = summarizeWeather([s(10), s(11)])!;
    expect(bare.tempMinC, isNull);
    expect(bare.precipTotalMm, isNull);
    expect(bare.windMeanDirDeg, isNull);
    expect(summarizeWeather(const []), isNull);
  });

  test('wind direction is a speed-weighted circular mean (350 and 10 degrees give north, not south)', () {
    final r = summarizeWeather([s(10, wind: 5, dir: 350), s(11, wind: 5, dir: 10), s(12, wind: 0, dir: 180)])!;
    final d = r.windMeanDirDeg!;
    expect(d < 1 || d > 359, isTrue, reason: '$d');
  });

  test('compass points', () {
    expect(compassPoint(0), 'N');
    expect(compassPoint(360), 'N');
    expect(compassPoint(11.2), 'N');
    expect(compassPoint(11.3), 'NNE');
    expect(compassPoint(90), 'E');
    expect(compassPoint(225), 'SW');
    expect(compassPoint(348.75), 'N');
    expect(compassPoint(-90), 'W');
    expect(compassPoint(double.nan), 'N');
  });

  test('pressure comparison: phone hourly mean against the station value, only for hours that pair up', () {
    final snaps = [s(10, p: 1012.0), s(11, p: 1010.0), s(12, p: 1009.0), s(13)];
    final phone = [
      (DateTime.utc(2026, 10, 24, 10, 5), 1013.0),
      (DateTime.utc(2026, 10, 24, 10, 45), 1015.0), // hour 10 mean 1014 -> +2
      (DateTime.utc(2026, 10, 24, 11, 0), 1011.0), // hour 11 -> +1 (the hour starts at :00)
      (DateTime.utc(2026, 10, 24, 13, 10), 1000.0), // hour 13 has no station value
    ];
    final c = comparePressure(snaps, phone)!;
    expect(c.hours, 2);
    expect(c.meanDiffHpa, closeTo(1.5, 1e-9));
    expect(comparePressure(snaps, const []), isNull);
    expect(comparePressure([s(10)], phone), isNull);
  });
}
