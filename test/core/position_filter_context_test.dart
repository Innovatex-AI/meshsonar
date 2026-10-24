// Drive context (stream 7): the filtered fix keeps the platform's altitude, course and accuracies.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/position_filter.dart';
import 'package:meshsonar/radio/radio_api.dart';

void main() {
  test('altitude, course and accuracies pass through the filter unchanged', () {
    final f = PositionFilter();
    final t = DateTime.utc(2026, 10, 24, 20);
    GeoFix? out;
    for (var i = 0; i < 6; i++) {
      out = f.add(GeoFix(
        lat: 40.12 + i * 0.0003,
        lon: -82.93,
        at: t.add(Duration(seconds: i * 2)),
        accuracyM: 5,
        speedMps: 15,
        altitudeM: 251.3,
        altitudeAccuracyM: 6,
        courseDeg: 0,
        courseAccuracyDeg: 12,
        speedAccuracyMps: 0.6,
      ));
    }
    expect(out, isNotNull);
    expect(out!.altitudeM, 251.3);
    expect(out.altitudeAccuracyM, 6);
    expect(out.courseDeg, 0);
    expect(out.courseAccuracyDeg, 12);
    expect(out.speedAccuracyMps, 0.6);
  });
}
