// The phone's compass for the stopped-car direction arrow: accelerometer + magnetometer (sensors_plus, BSD-3-Clause, already a
// dependency for the barometer) combined into a tilt-compensated bearing by lib/core/heading.dart, low-pass filtered.
//
// Battery (build 70, plan A2): the Drive map listens to [headings] for the whole drive, on every tab, but the SENSORS only run while
// the battery profile's compass mode allows it:
//  * always: for the whole drive;
//  * auto (default): only while the Drive tab is shown, the app is in front and the GPS speed is under ~2 m/s (with a usable course
//    the puck follows the GPS course and never reads the compass);
//  * off: never (the puck uses the GPS course only).
// Readings come at 5 Hz and a bearing is emitted on the magnetometer event itself (no timer), only when it moved at least
// [deadbandDeg] (2°) from the last one sent, so sensor jitter cannot keep the map loop awake. Seconds with the sensors on are
// counted into PowerCounters.compassSeconds. Errors (a simulator or desktop without sensors) end the readings quietly: the arrow
// then keeps the last course.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../app/drive_visibility.dart';
import '../core/heading.dart';
import '../core/power_profile.dart';

/// A raw accelerometer / magnetometer reading (x, y, z).
typedef Vec3 = ({double x, double y, double z});

/// Whether the compass sensors should run for [mode].
bool compassWanted(CompassMode mode, {required bool driveVisible, required bool slow}) => switch (mode) {
      CompassMode.always => true,
      CompassMode.auto => driveVisible && slow,
      CompassMode.off => false,
    };

class SensorsPlusCompass implements CompassSource {
  /// Sensor sampling period (5 Hz).
  static const Duration period = Duration(milliseconds: 200);

  /// Smallest change of bearing that is emitted.
  static const double deadbandDeg = 2.0;

  final Stream<Vec3> Function() _accel;
  final Stream<Vec3> Function() _mag;
  final CompassMode Function() _mode;
  final ValueListenable<bool> _visible;
  final ValueListenable<bool> _slow;
  final Duration Function() _mono;

  SensorsPlusCompass({
    @visibleForTesting Stream<Vec3> Function()? accelerometer,
    @visibleForTesting Stream<Vec3> Function()? magnetometer,
    @visibleForTesting CompassMode Function()? mode,
    @visibleForTesting ValueListenable<bool>? visible,
    @visibleForTesting ValueListenable<bool>? slow,
    @visibleForTesting Duration Function()? mono,
  })  : _accel = accelerometer ??
            (() => accelerometerEventStream(samplingPeriod: period).map((e) => (x: e.x, y: e.y, z: e.z))),
        _mag = magnetometer ??
            (() => magnetometerEventStream(samplingPeriod: period).map((e) => (x: e.x, y: e.y, z: e.z))),
        _mode = mode ?? (() => PowerProfile.current.compass),
        _visible = visible ?? DriveVisibility.visible,
        _slow = slow ?? DriveVisibility.slow,
        _mono = mono ?? _stopwatch();

  static Duration Function() _stopwatch() {
    final sw = Stopwatch()..start();
    return () => sw.elapsed;
  }

  /// How many times the sensors were started (tests and diagnostics).
  int sensorStarts = 0;

  /// True while the sensors run for any listener.
  bool get sensorsOn => _running > 0;
  int _running = 0;

  @override
  Stream<double> get headings {
    late StreamController<double> c;
    var ax = 0.0, ay = 0.0, az = 0.0, mx = 0.0, my = 0.0, mz = 0.0;
    var haveA = false, haveM = false;
    double? sent;
    Duration? onSince;
    var countUs = 0;
    StreamSubscription<Vec3>? sa;
    StreamSubscription<Vec3>? sm;

    void count() {
      final from = onSince;
      if (from == null) return;
      final now = _mono();
      onSince = now;
      countUs += (now - from).inMicroseconds;
      final whole = countUs ~/ Duration.microsecondsPerSecond;
      if (whole > 0) {
        countUs -= whole * Duration.microsecondsPerSecond;
        PowerCounters.inc(PowerCounters.compassSeconds, whole);
      }
    }

    void stopSensors() {
      count();
      onSince = null;
      final a = sa, m = sm;
      if (a != null) _running--;
      sa = null;
      sm = null;
      unawaited(a?.cancel());
      unawaited(m?.cancel());
    }

    void startSensors() {
      if (sa != null) return;
      sensorStarts++;
      _running++;
      haveA = false;
      haveM = false;
      onSince = _mono();
      sa = _accel().listen((e) {
        ax = haveA ? ax * 0.8 + e.x * 0.2 : e.x;
        ay = haveA ? ay * 0.8 + e.y * 0.2 : e.y;
        az = haveA ? az * 0.8 + e.z * 0.2 : e.z;
        haveA = true;
      }, onError: (Object _) {});
      sm = _mag().listen((e) {
        mx = haveM ? mx * 0.8 + e.x * 0.2 : e.x;
        my = haveM ? my * 0.8 + e.y * 0.2 : e.y;
        mz = haveM ? mz * 0.8 + e.z * 0.2 : e.z;
        haveM = true;
        if (!haveA) return;
        final h = compassHeading(ax: ax, ay: ay, az: az, mx: mx, my: my, mz: mz);
        if (h == null) return;
        final last = sent;
        if (last != null && shortestArc(last, h).abs() < deadbandDeg) return;
        sent = h;
        count();
        if (!c.isClosed) c.add(h);
      }, onError: (Object _) {});
    }

    void reconcile() {
      if (compassWanted(_mode(), driveVisible: _visible.value, slow: _slow.value)) {
        startSensors();
      } else if (sa != null) {
        stopSensors();
      }
    }

    c = StreamController<double>(
      onListen: () {
        _visible.addListener(reconcile);
        _slow.addListener(reconcile);
        PowerProfile.addListener(reconcile);
        reconcile();
      },
      onCancel: () {
        _visible.removeListener(reconcile);
        _slow.removeListener(reconcile);
        PowerProfile.removeListener(reconcile);
        stopSensors();
      },
    );
    return c.stream;
  }
}
