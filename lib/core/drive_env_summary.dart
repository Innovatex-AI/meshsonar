// Numbers the weather block shows, worked out from the server's hourly snapshots (stream 7 WP6). Pure Dart. Every value
// stays SI here (°C, hPa, mm, m/s); lib/core/units.dart turns it into text. Nothing is invented: a quantity the source
// did not give for any hour is null.
import 'dart:math' as math;

import 'api.dart';

class WeatherSummary {
  final int hours;
  final double? tempMinC, tempMaxC;
  final double? dewPointMinC, dewPointMaxC;
  final double? humidityMinPct, humidityMaxPct;
  final double? windMeanMs, windMaxMs;

  /// Direction the wind comes FROM, degrees, averaged over the hours weighted by wind speed; null with no wind data.
  final double? windMeanDirDeg;

  /// Sum over the hours that gave a value.
  final double? precipTotalMm;
  final double? cloudMeanPct;
  final double? pressureMinHpa, pressureMaxHpa;
  const WeatherSummary({
    required this.hours,
    this.tempMinC,
    this.tempMaxC,
    this.dewPointMinC,
    this.dewPointMaxC,
    this.humidityMinPct,
    this.humidityMaxPct,
    this.windMeanMs,
    this.windMaxMs,
    this.windMeanDirDeg,
    this.precipTotalMm,
    this.cloudMeanPct,
    this.pressureMinHpa,
    this.pressureMaxHpa,
  });
}

(double, double)? _range(Iterable<double?> v) {
  final x = v.whereType<double>().toList();
  if (x.isEmpty) return null;
  return (x.reduce(math.min), x.reduce(math.max));
}

double? _mean(Iterable<double?> v) {
  final x = v.whereType<double>().toList();
  return x.isEmpty ? null : x.reduce((a, b) => a + b) / x.length;
}

/// Null when there are no snapshots.
WeatherSummary? summarizeWeather(List<WeatherSnapshot> s) {
  if (s.isEmpty) return null;
  final t = _range(s.map((e) => e.temperatureC));
  final dp = _range(s.map((e) => e.dewPointC));
  final h = _range(s.map((e) => e.humidityPct));
  final w = _range(s.map((e) => e.windMs));
  final p = _range(s.map((e) => e.pressureHpa));
  final rain = s.map((e) => e.precipMm).whereType<double>().toList();
  // Vector mean of the "from" directions, weighted by speed (a calm hour does not turn the average).
  double? dir;
  var x = 0.0, y = 0.0;
  for (final e in s) {
    final d = e.windDirDeg, v = e.windMs;
    if (d == null || v == null || v <= 0) continue;
    final r = d * math.pi / 180;
    x += v * math.sin(r);
    y += v * math.cos(r);
  }
  if (x != 0 || y != 0) dir = (math.atan2(x, y) * 180 / math.pi + 360) % 360;
  return WeatherSummary(
    hours: s.length,
    tempMinC: t?.$1,
    tempMaxC: t?.$2,
    dewPointMinC: dp?.$1,
    dewPointMaxC: dp?.$2,
    humidityMinPct: h?.$1,
    humidityMaxPct: h?.$2,
    windMeanMs: _mean(s.map((e) => e.windMs)),
    windMaxMs: w?.$2,
    windMeanDirDeg: dir,
    precipTotalMm: rain.isEmpty ? null : rain.reduce((a, b) => a + b),
    cloudMeanPct: _mean(s.map((e) => e.cloudPct)),
    pressureMinHpa: p?.$1,
    pressureMaxHpa: p?.$2,
  );
}

const _points = [
  'N',
  'NNE',
  'NE',
  'ENE',
  'E',
  'ESE',
  'SE',
  'SSE',
  'S',
  'SSW',
  'SW',
  'WSW',
  'W',
  'WNW',
  'NW',
  'NNW',
];

/// "SW" for 225 degrees: the compass point the wind comes from (16 points).
String compassPoint(double deg) {
  final d = deg.isFinite ? ((deg % 360) + 360) % 360 : 0.0;
  return _points[((d + 11.25) / 22.5).floor() % 16];
}

/// Phone barometer against the model's station pressure, over the hours both have a value.
class PressureComparison {
  /// Hours with both a station value and at least one phone reading.
  final int hours;

  /// Mean of (phone hourly mean - station value) in hPa; positive = the phone read higher.
  final double meanDiffHpa;
  const PressureComparison({required this.hours, required this.meanDiffHpa});
}

/// [phone] is (time, hPa) readings; each snapshot covers the hour starting at its `at`. Null when no hour pairs up.
PressureComparison? comparePressure(
  List<WeatherSnapshot> snaps,
  List<(DateTime, double)> phone,
) {
  var n = 0;
  var sum = 0.0;
  for (final s in snaps) {
    final station = s.pressureHpa;
    if (station == null) continue;
    final from = s.at.toUtc(), to = from.add(const Duration(hours: 1));
    final vs = [
      for (final r in phone)
        if (!r.$1.toUtc().isBefore(from) && r.$1.toUtc().isBefore(to)) r.$2,
    ];
    if (vs.isEmpty) continue;
    sum += vs.reduce((a, b) => a + b) / vs.length - station;
    n++;
  }
  return n == 0 ? null : PressureComparison(hours: n, meanDiffHpa: sum / n);
}
