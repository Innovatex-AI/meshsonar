// The phone's compass for the stopped-car direction arrow: accelerometer + magnetometer (sensors_plus, BSD-3-Clause, already a
// dependency for the barometer) combined into a tilt-compensated bearing by lib/core/heading.dart. About ten readings a second,
// low-pass filtered. The streams only run while a drive is on screen. Errors (a simulator or desktop without sensors) end the
// stream quietly: the arrow then keeps the last course.
import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../core/heading.dart';

class SensorsPlusCompass implements CompassSource {
  @override
  Stream<double> get headings {
    late StreamController<double> c;
    StreamSubscription<AccelerometerEvent>? a;
    StreamSubscription<MagnetometerEvent>? m;
    var ax = 0.0, ay = 0.0, az = 0.0, mx = 0.0, my = 0.0, mz = 0.0;
    var haveA = false, haveM = false;
    Timer? out;
    c = StreamController<double>(
      onListen: () {
        const period = Duration(milliseconds: 100);
        a = accelerometerEventStream(samplingPeriod: period).listen((e) {
          ax = haveA ? ax * 0.8 + e.x * 0.2 : e.x;
          ay = haveA ? ay * 0.8 + e.y * 0.2 : e.y;
          az = haveA ? az * 0.8 + e.z * 0.2 : e.z;
          haveA = true;
        }, onError: (Object _) {});
        m = magnetometerEventStream(samplingPeriod: period).listen((e) {
          mx = haveM ? mx * 0.8 + e.x * 0.2 : e.x;
          my = haveM ? my * 0.8 + e.y * 0.2 : e.y;
          mz = haveM ? mz * 0.8 + e.z * 0.2 : e.z;
          haveM = true;
        }, onError: (Object _) {});
        out = Timer.periodic(period, (_) {
          if (!haveA || !haveM) return;
          final h = compassHeading(ax: ax, ay: ay, az: az, mx: mx, my: my, mz: mz);
          if (h != null) c.add(h);
        });
      },
      onCancel: () async {
        out?.cancel();
        await a?.cancel();
        await m?.cancel();
      },
    );
    return c.stream;
  }
}
