// SensorsPlusBarometer (V-5, build 67): a barometer that never answers (no sensor, access refused, the simulator) becomes
// an error on the stream after the silence timeout, so the drive marks Air pressure unavailable; a live one never times out.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/platform/phone_sensors_plus.dart';

void main() {
  test('a silent barometer ends with BarometerUnavailable after the silence timeout', () {
    fakeAsync((async) {
      final raw = StreamController<double>();
      final b = SensorsPlusBarometer(source: () => raw.stream, silence: const Duration(seconds: 15));
      final errors = <Object>[];
      b.readings().listen((_) {}, onError: errors.add);
      async.elapse(const Duration(seconds: 14));
      expect(errors, isEmpty);
      async.elapse(const Duration(seconds: 2));
      async.flushMicrotasks();
      expect(errors.single, isA<BarometerUnavailable>());
      raw.close();
    });
  });

  test('readings once a second never time out', () {
    fakeAsync((async) {
      final raw = StreamController<double>();
      final b = SensorsPlusBarometer(source: () => raw.stream, silence: const Duration(seconds: 15));
      final got = <double>[];
      final errors = <Object>[];
      b.readings().listen(got.add, onError: errors.add);
      for (var i = 0; i < 60; i++) {
        raw.add(1013.0 + i);
        async.elapse(const Duration(seconds: 1));
      }
      expect(got, hasLength(60));
      expect(errors, isEmpty);
      raw.close();
    });
  });
}
