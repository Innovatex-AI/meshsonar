// The compass gate and output (battery plan A2): sensors only while the mode allows, event-driven 5 Hz output, 2° deadband.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/platform/compass_sensors_plus.dart';

class _Rig {
  final accel = StreamController<Vec3>.broadcast();
  final mag = StreamController<Vec3>.broadcast();
  final visible = ValueNotifier<bool>(true);
  final slow = ValueNotifier<bool>(true);
  CompassMode mode;
  Duration t = Duration.zero;
  late final SensorsPlusCompass compass = SensorsPlusCompass(
    accelerometer: () => accel.stream,
    magnetometer: () => mag.stream,
    mode: () => mode,
    visible: visible,
    slow: slow,
    mono: () => t,
  );
  _Rig(this.mode);

  // Phone flat (gravity on +z); magnetic field pointing to [deg] clockwise from north (along the top edge at 0).
  void sample(double deg) {
    accel.add((x: 0.0, y: 0.0, z: 9.8));
    final r = deg * 3.141592653589793 / 180;
    mag.add((x: -30 * _sin(r), y: 30 * _cos(r), z: -40.0));
  }
}

double _sin(double r) => r - r * r * r / 6 + r * r * r * r * r / 120 - r * r * r * r * r * r * r / 5040;
double _cos(double r) => 1 - r * r / 2 + r * r * r * r / 24 - r * r * r * r * r * r / 720;

void main() {
  setUp(() {
    PowerProfile.debugReset();
    PowerCounters.debugReset();
  });

  test('compassWanted: always / auto (Drive visible and slow) / off', () {
    expect(compassWanted(CompassMode.always, driveVisible: false, slow: false), isTrue);
    expect(compassWanted(CompassMode.auto, driveVisible: true, slow: true), isTrue);
    expect(compassWanted(CompassMode.auto, driveVisible: false, slow: true), isFalse);
    expect(compassWanted(CompassMode.auto, driveVisible: true, slow: false), isFalse);
    expect(compassWanted(CompassMode.off, driveVisible: true, slow: true), isFalse);
  });

  test('auto: sensors stop when the Drive tab is hidden or the car is fast, and restart; off never starts them', () async {
    final r = _Rig(CompassMode.auto);
    final sub = r.compass.headings.listen((_) {});
    expect(r.compass.sensorsOn, isTrue);
    expect(r.accel.hasListener && r.mag.hasListener, isTrue);
    r.visible.value = false;
    await pumpEventQueue();
    expect(r.compass.sensorsOn, isFalse);
    expect(r.mag.hasListener, isFalse);
    r.visible.value = true;
    expect(r.compass.sensorsOn, isTrue);
    r.slow.value = false;
    expect(r.compass.sensorsOn, isFalse);
    r.slow.value = true;
    expect(r.compass.sensorStarts, 3);
    await sub.cancel();
    expect(r.compass.sensorsOn, isFalse);

    final off = _Rig(CompassMode.off);
    final s2 = off.compass.headings.listen((_) {});
    expect(off.compass.sensorsOn, isFalse);
    expect(off.compass.sensorStarts, 0);
    await s2.cancel();

    final always = _Rig(CompassMode.always);
    final s3 = always.compass.headings.listen((_) {});
    always.visible.value = false;
    always.slow.value = false;
    expect(always.compass.sensorsOn, isTrue, reason: 'Always runs for the whole drive');
    await s3.cancel();
  });

  test('emits on the magnetometer event (no timer) and only past the 2° deadband; counts compass seconds', () async {
    final r = _Rig(CompassMode.always);
    final out = <double>[];
    final sub = r.compass.headings.listen(out.add);
    r.sample(90);
    await pumpEventQueue();
    expect(out, hasLength(1));
    // Jitter well under 2°: nothing new (the low-pass filter makes it even smaller).
    for (var i = 0; i < 20; i++) {
      r.t += const Duration(milliseconds: 200);
      r.sample(i.isEven ? 90.5 : 89.5);
    }
    await pumpEventQueue();
    expect(out, hasLength(1));
    // A real turn: new bearings.
    for (var i = 0; i < 20; i++) {
      r.t += const Duration(milliseconds: 200);
      r.sample(120);
    }
    await pumpEventQueue();
    expect(out.length, greaterThan(1));
    expect(out.last, closeTo(120, 3));
    await sub.cancel();
    expect(PowerCounters.get(PowerCounters.compassSeconds), 8); // 40 readings x 200 ms
  });

  test('a battery mode change is applied at once', () async {
    final r = SensorsPlusCompass(
      accelerometer: () => const Stream.empty(),
      magnetometer: () => const Stream.empty(),
      visible: ValueNotifier(true),
      slow: ValueNotifier(true),
    );
    final sub = r.headings.listen((_) {});
    expect(r.sensorsOn, isTrue); // Balanced = Auto, visible and slow
    await PowerProfile.set(PowerSettings.saver); // compass Off
    expect(r.sensorsOn, isFalse);
    await PowerProfile.set(PowerSettings.maxData);
    expect(r.sensorsOn, isTrue);
    await sub.cancel();
  });
}
