// The motion of the "you are here" dot on the live map. DISPLAY ONLY: nothing here ever reaches a recorded ping (pings
// keep the GPS fix the engine took; see FilteredLocationSource for the position every ping uses). Pure Dart.
//
// Why it exists: GPS fixes arrive about once a second. Moving the dot straight to each fix makes it hop 10 to 30 m
// every second at driving speed. [PuckMotion] keeps the dot sliding like a sonar contact instead:
//
//  1. Outlier gate ([add]). A fix is dropped when
//       - it is not a finite coordinate, or is older than the last accepted fix;
//       - its accuracy is worse than [PuckConfig.maxAccuracyM] while a better fix arrived in the last
//         [PuckConfig.acceptPoorAfter] (a phone that only ever gets poor fixes still shows a dot);
//       - it is a teleport: it implies more than [PuckConfig.maxSpeedMps] from the last accepted fix AND is further
//         away than the two fixes' accuracies explain. A teleport is only believed when [PuckConfig.relockFixes] in
//         a row agree with each other (a real jump, e.g. GPS regained after a tunnel); then the dot snaps.
//  2. Prediction. The target is the last accepted fix pushed forward along its course at its speed for at most
//     [PuckConfig.extrapolateMax]. No course or speed below [PuckConfig.minMovingSpeedMps] means no push (parked
//     phones do not drift). Course comes from the fix, else from the last two accepted fixes.
//  3. Smoothing. The shown dot chases the target with an exponential ease ([PuckConfig.followTau]), so a late or early
//     fix bends the path instead of snapping it. Reduced motion skips 2 and 3: the dot goes to the newest fix.
import 'dart:math' as math;

import '../radio/radio_api.dart';

class PuckConfig {
  /// Fixes worse than this are dropped while a better one is recent.
  final double maxAccuracyM;

  /// After this long without a good fix, poor ones are shown anyway.
  final Duration acceptPoorAfter;

  /// Faster than this between two accepted fixes is a teleport (about 324 km/h).
  final double maxSpeedMps;

  /// Teleporting fixes that agree with each other (within twice their accuracy) this many times in a row are real.
  final int relockFixes;

  /// How far ahead of the last fix the target may be pushed.
  final Duration extrapolateMax;

  /// Below this speed the dot is not pushed along the course.
  final double minMovingSpeedMps;

  /// Time constant of the ease toward the target.
  final Duration followTau;

  /// A shown dot further than this from the target snaps instead of sliding.
  final double snapDistanceM;

  const PuckConfig({
    this.maxAccuracyM = 100,
    this.acceptPoorAfter = const Duration(seconds: 10),
    this.maxSpeedMps = 90,
    this.relockFixes = 3,
    this.extrapolateMax = const Duration(milliseconds: 1200),
    this.minMovingSpeedMps = 1.5,
    this.followTau = const Duration(milliseconds: 320),
    this.snapDistanceM = 250,
  });
}

/// Where to draw the dot at one instant.
class PuckPose {
  final double lat;
  final double lon;

  /// Direction of travel in degrees clockwise from north; null while parked or unknown.
  final double? courseDeg;
  final double speedMps;

  /// Horizontal accuracy of the newest accepted fix (metres), null when unknown.
  final double? accuracyM;

  /// False once the dot has reached its target and nothing will move: the ticker can sleep.
  final bool settled;
  const PuckPose({
    required this.lat,
    required this.lon,
    required this.courseDeg,
    required this.speedMps,
    required this.accuracyM,
    required this.settled,
  });

  bool get moving => courseDeg != null;
}

const double _mPerDegLat = 111320.0;

double _distM(double lat1, double lon1, double lat2, double lon2) {
  final dy = (lat2 - lat1) * _mPerDegLat;
  final dx = (lon2 - lon1) * _mPerDegLat * math.cos((lat1 + lat2) / 2 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

class PuckMotion {
  final PuckConfig config;
  PuckMotion([this.config = const PuckConfig()]);

  GeoFix? _fix; // newest accepted
  DateTime? _arrived; // wall time the newest accepted fix arrived
  DateTime? _lastGoodAt; // wall time of the last fix within maxAccuracyM
  final List<GeoFix> _suspects = []; // consecutive teleport candidates
  double? _course; // last known course (kept while moving)
  double _speed = 0;

  double? _shownLat, _shownLon;
  DateTime? _shownAt;

  int _rejected = 0;

  /// How many fixes the gate has dropped (tests, diagnostics).
  int get rejectedCount => _rejected;

  /// The newest accepted fix (what the dot is heading for), null before the first.
  GeoFix? get lastAccepted => _fix;

  void reset() {
    _fix = _arrived = _lastGoodAt = null;
    _suspects.clear();
    _course = null;
    _speed = 0;
    _shownLat = _shownLon = _shownAt = null;
  }

  double _acc(GeoFix f) => (f.accuracyM == null || f.accuracyM!.isNaN || f.accuracyM! <= 0) ? 10 : f.accuracyM!;

  /// Feed a fix as it arrives ([now] is the phone clock, not the GPS clock). True when it was accepted.
  bool add(GeoFix f, DateTime now) {
    if (!f.lat.isFinite || !f.lon.isFinite || f.lat.abs() > 90 || f.lon.abs() > 180) return _reject();
    final cur = _fix;
    if (cur != null && f.at.isBefore(cur.at)) return _reject();

    // Accuracy gate.
    if (_acc(f) > config.maxAccuracyM) {
      final good = _lastGoodAt;
      if (good != null && now.difference(good) < config.acceptPoorAfter) return _reject();
    } else {
      _lastGoodAt = now;
    }

    // Teleport gate.
    if (cur != null) {
      final dt = f.at.difference(cur.at).inMicroseconds / 1e6;
      final d = _distM(cur.lat, cur.lon, f.lat, f.lon);
      final explained = 3 * (_acc(cur) + _acc(f)) + 30;
      final implied = dt <= 0 ? double.infinity : d / dt;
      if (implied > config.maxSpeedMps && d > explained) {
        if (_suspects.isNotEmpty) {
          final s = _suspects.last;
          if (_distM(s.lat, s.lon, f.lat, f.lon) > 2 * (_acc(s) + _acc(f)) + 10) _suspects.clear();
        }
        _suspects.add(f);
        if (_suspects.length < config.relockFixes) return _reject();
        // Believed: a real jump. Start over from here.
        _suspects.clear();
        _snapTo(f, now);
        return true;
      }
    }
    _suspects.clear();
    _accept(f, now);
    return true;
  }

  bool _reject() {
    _rejected++;
    return false;
  }

  void _snapTo(GeoFix f, DateTime now) {
    _fix = f;
    _arrived = now;
    _course = f.courseDeg;
    _speed = f.speedMps ?? 0;
    _shownLat = f.lat;
    _shownLon = f.lon;
    _shownAt = now;
  }

  void _accept(GeoFix f, DateTime now) {
    final cur = _fix;
    _fix = f;
    _arrived = now;
    // Speed: reported, else derived from the last two accepted fixes.
    var speed = f.speedMps;
    double? course = f.courseDeg;
    if (cur != null) {
      final dt = f.at.difference(cur.at).inMicroseconds / 1e6;
      if (dt > 0.05 && dt < 10) {
        final d = _distM(cur.lat, cur.lon, f.lat, f.lon);
        speed ??= d / dt;
        // Derived course only from a displacement that is real, not the noise of a parked phone.
        if (course == null && d > math.max(3.0, _acc(f) * 0.5)) {
          final dy = (f.lat - cur.lat) * _mPerDegLat;
          final dx = (f.lon - cur.lon) * _mPerDegLat * math.cos(f.lat * math.pi / 180);
          course = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
        }
      }
    }
    _speed = speed ?? 0;
    if (_speed < config.minMovingSpeedMps) {
      _course = null;
    } else {
      _course = course ?? _course;
    }
    if (_shownLat == null) {
      _shownLat = f.lat;
      _shownLon = f.lon;
      _shownAt = now;
    }
  }

  ({double lat, double lon}) _target(DateTime now) {
    final f = _fix!;
    final c = _course;
    if (c == null || _speed < config.minMovingSpeedMps) return (lat: f.lat, lon: f.lon);
    final age = now.difference(_arrived!);
    final secs = (age < config.extrapolateMax ? age : config.extrapolateMax).inMicroseconds / 1e6;
    if (secs <= 0) return (lat: f.lat, lon: f.lon);
    final r = c * math.pi / 180;
    final dyM = math.cos(r) * _speed * secs;
    final dxM = math.sin(r) * _speed * secs;
    return (lat: f.lat + dyM / _mPerDegLat, lon: f.lon + dxM / (_mPerDegLat * math.cos(f.lat * math.pi / 180)));
  }

  /// The pose to draw at [now]. Call once per frame; null before the first accepted fix. [reducedMotion] shows the
  /// newest fix as it is (no push ahead, no ease).
  PuckPose? poseAt(DateTime now, {bool reducedMotion = false}) {
    final f = _fix;
    if (f == null) return null;
    if (reducedMotion) {
      _shownLat = f.lat;
      _shownLon = f.lon;
      _shownAt = now;
      return PuckPose(
        lat: f.lat,
        lon: f.lon,
        courseDeg: _course,
        speedMps: _speed,
        accuracyM: f.accuracyM,
        settled: true,
      );
    }
    final tgt = _target(now);
    var lat = _shownLat ?? tgt.lat, lon = _shownLon ?? tgt.lon;
    final last = _shownAt ?? now;
    var dt = now.difference(last).inMicroseconds / 1e6;
    if (dt < 0) dt = 0;
    final away = _distM(lat, lon, tgt.lat, tgt.lon);
    if (away > config.snapDistanceM) {
      lat = tgt.lat;
      lon = tgt.lon;
    } else if (dt > 0) {
      final a = 1 - math.exp(-dt / (config.followTau.inMicroseconds / 1e6));
      lat += (tgt.lat - lat) * a;
      lon += (tgt.lon - lon) * a;
    }
    _shownLat = lat;
    _shownLon = lon;
    _shownAt = now;
    final stillAway = _distM(lat, lon, tgt.lat, tgt.lon);
    final extrapolating =
        _course != null && _speed >= config.minMovingSpeedMps && now.difference(_arrived!) < config.extrapolateMax;
    return PuckPose(
      lat: lat,
      lon: lon,
      courseDeg: _course,
      speedMps: _speed,
      accuracyM: f.accuracyM,
      settled: !extrapolating && stillAway < 0.05,
    );
  }
}
