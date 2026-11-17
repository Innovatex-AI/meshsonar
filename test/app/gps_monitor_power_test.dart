// GpsMonitor's battery side (build 70): the drive GPS mode it publishes, the seconds per GPS mode, and the auto-end callback.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/drive_power_governor.dart';
import 'package:meshsonar/app/drive_visibility.dart';
import 'package:meshsonar/app/gps_monitor.dart';
import 'package:meshsonar/core/drive_gps_tuning.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/radio/radio_api.dart';

final t0 = DateTime.utc(2026, 11, 17, 12);

class _Gps implements LocationSource {
  final c = StreamController<GeoFix>.broadcast();
  @override
  Stream<GeoFix> get fixes => c.stream;
  @override
  Future<GeoFix?> current() async => null;
  @override
  Future<bool> ensurePermission() async => true;
}

void main() {
  setUp(() {
    PowerProfile.debugReset();
    PowerCounters.debugReset();
    DriveVisibility.debugReset();
  });

  test('parked 3 min drops the drive GPS to parked, driving off restores it; seconds are counted per mode; parked 30 min ends the drive once', () {
    fakeAsync((fa) {
      final gps = _Gps();
      final tuning = DriveGpsTuning();
      final modes = <DriveGpsMode>[];
      tuning.addListener(() => modes.add(tuning.mode));
      final ends = <DriveAutoEnd>[];
      final m = GpsMonitor(
        location: gps,
        clock: () => t0.add(fa.elapsed),
        mono: () => fa.elapsed,
        tuning: tuning,
        radioConnected: () => true,
        onAutoEnd: ends.add,
      );
      m.start();
      expect(tuning.mode, DriveGpsMode.high, reason: 'Balanced = High, set before the stream opens');
      GeoFix fix(double northM, {double? speed}) =>
          GeoFix(lat: 39.76 + northM / 111320.0, lon: -84.19, accuracyM: 8, speedMps: speed, at: t0.add(fa.elapsed));
      gps.c.add(fix(0, speed: 0));
      fa.elapse(const Duration(minutes: 3, seconds: 1));
      expect(tuning.mode, DriveGpsMode.parked);
      expect(DriveVisibility.slow.value, isTrue);
      // Drive off: 60 m away at speed.
      gps.c.add(fix(60, speed: 12));
      fa.elapse(const Duration(seconds: 2));
      expect(tuning.mode, DriveGpsMode.high);
      expect(DriveVisibility.slow.value, isFalse);
      expect(modes, [DriveGpsMode.parked, DriveGpsMode.high]);
      expect(PowerCounters.get(PowerCounters.gpsHighSeconds), closeTo(3 * 60 + 2, 3));
      expect(PowerCounters.get(PowerCounters.gpsLowSeconds), closeTo(1, 2));
      // Parked for good: 30 min later the drive ends, once.
      fa.elapse(const Duration(minutes: 31));
      expect(ends, [const DriveAutoEnd(DriveAutoEndReason.parked, 30)]);
      unawaited(m.stop());
      fa.flushMicrotasks();
      expect(tuning.mode, DriveGpsMode.high, reason: 'after the drive: back to the profile');
    });
  });

  test('no radio: Max data is capped at High, back to Best on reconnect; 0 min = never ends', () {
    fakeAsync((fa) {
      PowerProfile.debugReset(PowerSettings.maxData);
      final tuning = DriveGpsTuning();
      var radio = true;
      final ends = <DriveAutoEnd>[];
      final m = GpsMonitor(
          location: _Gps(), mono: () => fa.elapsed, tuning: tuning, radioConnected: () => radio, onAutoEnd: ends.add);
      m.start();
      expect(tuning.mode, DriveGpsMode.best);
      radio = false;
      fa.elapse(const Duration(seconds: 2));
      expect(tuning.mode, DriveGpsMode.high);
      radio = true;
      fa.elapse(const Duration(seconds: 2));
      expect(tuning.mode, DriveGpsMode.best);
      radio = false;
      fa.elapse(const Duration(hours: 2));
      expect(ends, isEmpty);
      expect(PowerCounters.get(PowerCounters.gpsBestSeconds), closeTo(4, 2));
      unawaited(m.stop());
      fa.flushMicrotasks();
    });
  });

  test('Balanced: no radio for 15 min ends the drive', () {
    fakeAsync((fa) {
      final ends = <DriveAutoEnd>[];
      final m = GpsMonitor(
          location: _Gps(), mono: () => fa.elapsed, tuning: DriveGpsTuning(), radioConnected: () => false, onAutoEnd: ends.add);
      m.start();
      fa.elapse(const Duration(minutes: 14, seconds: 58));
      expect(ends, isEmpty);
      fa.elapse(const Duration(seconds: 3));
      expect(ends.single.message, 'Drive ended: no radio for 15 min');
      unawaited(m.stop());
      fa.flushMicrotasks();
    });
  });

  test('a profile change during a drive is applied within a second', () {
    fakeAsync((fa) {
      final tuning = DriveGpsTuning();
      final m = GpsMonitor(location: _Gps(), mono: () => fa.elapsed, tuning: tuning);
      m.start();
      expect(tuning.mode, DriveGpsMode.high);
      unawaited(PowerProfile.set(PowerSettings.saver));
      fa.elapse(const Duration(seconds: 1));
      expect(tuning.mode, DriveGpsMode.standard);
      unawaited(m.stop());
      fa.flushMicrotasks();
    });
  });
}
