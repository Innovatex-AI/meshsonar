// Direction maths for the "which way am I facing" arrow. Pure Dart.
//
//  * [shortestArc] / [normalizeDeg]: angles in degrees, wrapped so 359 -> 1 is a 2 degree turn, never a 358 degree spin.
//  * [HeadingSmoother]: eases a displayed heading toward a target along the shortest arc (the value is kept unwrapped, so a
//    long drive through north never makes the arrow spin the long way round).
//  * [compassHeading]: a tilt-compensated compass bearing from raw accelerometer + magnetometer vectors, for the arrow when the
//    car is stopped (GPS course is meaningless below walking pace).
import 'dart:math' as math;

/// [deg] wrapped to [0, 360).
double normalizeDeg(double deg) {
  final m = deg % 360;
  return m < 0 ? m + 360 : m;
}

/// The signed turn from [from] to [to] along the shortest way round, in (-180, 180].
double shortestArc(double from, double to) {
  var d = (to - from) % 360;
  if (d < 0) d += 360;
  return d > 180 ? d - 360 : d;
}

class HeadingSmoother {
  /// Time constant of the ease, in seconds.
  final double tau;

  /// The arrow never turns faster than this (degrees per second): a corner is followed, a compass glitch is not.
  final double maxRateDegPerS;
  HeadingSmoother({this.tau = 0.22, this.maxRateDegPerS = 540});

  double? _value; // unwrapped
  double? get value => _value == null ? null : normalizeDeg(_value!);

  void reset() => _value = null;

  /// Jumps to [deg] (first reading).
  void set(double deg) => _value = deg;

  /// Advances [dtS] seconds toward [target] (degrees clockwise from north). Returns the new heading in [0, 360).
  double step(double target, double dtS) {
    final v = _value;
    if (v == null) {
      _value = target;
      return normalizeDeg(target);
    }
    final diff = shortestArc(v, target);
    if (dtS <= 0) return normalizeDeg(v);
    final a = 1 - math.exp(-dtS / tau);
    var move = diff * a;
    final cap = maxRateDegPerS * dtS;
    if (move.abs() > cap) move = cap * move.sign;
    _value = v + move;
    return normalizeDeg(_value!);
  }
}

/// Compass bearing (degrees clockwise from magnetic north) of the direction the phone faces, from the raw accelerometer
/// [ax],[ay],[az] (any unit; at rest it points up through the phone) and magnetometer [mx],[my],[mz] in the device frame
/// (x right, y up the screen, z out of the screen). Lying flat it reports where the top edge points; upright (a dash mount) it
/// reports where the back of the phone points (the direction the driver faces). Null when the readings are unusable.
double? compassHeading({
  required double ax,
  required double ay,
  required double az,
  required double mx,
  required double my,
  required double mz,
}) {
  final gn = math.sqrt(ax * ax + ay * ay + az * az);
  final mn = math.sqrt(mx * mx + my * my + mz * mz);
  if (!gn.isFinite || !mn.isFinite || gn < 1e-6 || mn < 1e-6) return null;
  // up = gravity direction as the accelerometer reads it.
  final ux = ax / gn, uy = ay / gn, uz = az / gn;
  // east = magnetic field x up
  var ex = my * uz - mz * uy;
  var ey = mz * ux - mx * uz;
  var ez = mx * uy - my * ux;
  final en = math.sqrt(ex * ex + ey * ey + ez * ez);
  if (en < 1e-6) return null; // field parallel to gravity: no horizontal component to read
  ex /= en;
  ey /= en;
  ez /= en;
  // north = up x east
  final nx = uy * ez - uz * ey;
  final ny = uz * ex - ux * ez;
  final nz = ux * ey - uy * ex;
  // The axis the phone "faces": top edge (+y) when flat, back (-z) when upright.
  final flat = uz.abs() > 0.7;
  final fx = 0.0, fy = flat ? 1.0 : 0.0, fz = flat ? 0.0 : -1.0;
  final e = fx * ex + fy * ey + fz * ez;
  final n = fx * nx + fy * ny + fz * nz;
  if (e.abs() < 1e-9 && n.abs() < 1e-9) return null;
  return normalizeDeg(math.atan2(e, n) * 180 / math.pi);
}

/// A stream of compass bearings (degrees clockwise from north), about ten a second, from the phone's sensors. The platform
/// adapter is lib/platform/compass_sensors_plus.dart; tests give the model a fake or none.
abstract interface class CompassSource {
  Stream<double> get headings;
}
