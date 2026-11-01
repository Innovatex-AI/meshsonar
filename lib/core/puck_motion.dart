// The motion of the "you are here" dot on the live map. DISPLAY ONLY: nothing here ever reaches a recorded ping (pings
// keep the GPS fix the engine took; see FilteredLocationSource for the position every ping uses). Pure Dart.
//
// GPS fixes arrive about once a second, late and noisy. The dot has to look like a car, not like a GPS: it moves at the
// display refresh rate, never hops, never runs backwards and does not wander when parked. How:
//
//  1. Outlier gate ([add]). A fix is dropped when it is not finite, is older than the newest accepted one, is worse than
//     [PuckConfig.maxAccuracyM] while a better one arrived in the last [PuckConfig.acceptPoorAfter], or is a teleport (implies
//     more than [PuckConfig.maxSpeedMps] and further than the accuracies explain). A teleport is only believed when
//     [PuckConfig.relockFixes] in a row agree with each other; then the dot snaps.
//  2. Fusion. The newest fix is blended with where the previous fix + its velocity said the car would be (a one-state Kalman
//     step: process noise grows with the time between fixes, measurement noise is the reported accuracy). Jitter of a poor fix
//     is damped; a real change (turn, brake) is believed at once because a large innovation turns the gain up.
//  3. Parked lock. Below walking pace the dot is held on a weighted average of the fixes; it only moves when two fixes in a
//     row are clearly outside both the lock and the accuracy, or the reported speed says the car is moving. No wandering.
//  4. Dead reckoning. Every frame the target is the fused fix pushed forward along its course at its speed for the time
//     since it arrived, for at most [PuckConfig.coastMax] (a signal dip: the car keeps going). After that the dot decelerates
//     and holds, and the pose says `frozen`. From [PuckConfig.weakAfter] it says `weak` so the UI can dim it.
//  5. Velocity-matched chase. The shown dot has a velocity of its own: the target's velocity plus a spring toward the target
//     (tau ~1.4 s, faster when far), with acceleration limited and the component against the course removed. So a late or early
//     fix bends the path and changes the pace a little, but position and velocity are continuous: no hop, no oscillation, no
//     reversing.
//
// Reduced motion skips 4 and 5: the dot goes to the newest fix.
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

  /// How long the dot keeps going on its own after the last fix (a signal dip). Then it holds.
  final Duration coastMax;

  /// The pose reports `weak` this long after the last fix.
  final Duration weakAfter;

  /// At or above this speed the car is moving (the course is trusted, the dot is pushed along it).
  final double minMovingSpeedMps;

  /// A moving car is parked again below this speed (hysteresis against flicker).
  final double stopSpeedMps;

  /// Spring time constant toward the target when close, and when far (> [farM]).
  final double tauNear;
  final double tauFar;
  final double farM;

  /// Acceleration limit of the shown dot, m/s^2.
  final double maxAccel;

  /// A shown dot further than this from the target snaps instead of sliding.
  final double snapDistanceM;

  /// Fusion: fix-to-fix process noise (metres) = base + perSecond * seconds between fixes; the gain never drops below [minGain].
  final double processBaseM;
  final double processPerSecM;
  final double minGain;

  /// An innovation bigger than this many sigmas sets the gain to 1 (believe the fix).
  final double gateSigmas;

  const PuckConfig({
    this.maxAccuracyM = 100,
    this.acceptPoorAfter = const Duration(seconds: 10),
    this.maxSpeedMps = 90,
    this.relockFixes = 3,
    this.coastMax = const Duration(seconds: 5),
    this.weakAfter = const Duration(milliseconds: 2500),
    this.minMovingSpeedMps = 1.5,
    this.stopSpeedMps = 0.9,
    this.tauNear = 1.4,
    this.tauFar = 0.6,
    this.farM = 15,
    this.maxAccel = 9,
    this.snapDistanceM = 250,
    this.processBaseM = 4,
    this.processPerSecM = 2,
    this.minGain = 0.3,
    this.gateSigmas = 2.5,
  });
}

/// Where to draw the dot at one instant.
class PuckPose {
  final double lat;
  final double lon;

  /// Direction of travel in degrees clockwise from north; null while parked or unknown.
  final double? courseDeg;
  final double speedMps;

  /// Horizontal accuracy to draw the ring with (metres): the newest fix's, growing while the signal is down. Null when unknown.
  final double? accuracyM;

  /// False once the dot has reached its target and nothing will move: the ticker can sleep.
  final bool settled;

  /// Seconds since the newest accepted fix arrived.
  final double fixAgeS;

  /// No fix for [PuckConfig.weakAfter]: draw the dot as uncertain.
  final bool weak;

  /// No fix for [PuckConfig.coastMax]: the dot stopped coasting and holds its place.
  final bool frozen;

  /// The car is parked (the dot is held on the lock).
  final bool parked;
  const PuckPose({
    required this.lat,
    required this.lon,
    required this.courseDeg,
    required this.speedMps,
    required this.accuracyM,
    required this.settled,
    this.fixAgeS = 0,
    this.weak = false,
    this.frozen = false,
    this.parked = false,
  });

  bool get moving => courseDeg != null;
}

const double _mPerDegLat = 111320.0;

double _distM(double lat1, double lon1, double lat2, double lon2) {
  final dy = (lat2 - lat1) * _mPerDegLat;
  final dx = (lon2 - lon1) * _mPerDegLat * math.cos((lat1 + lat2) / 2 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

double _mPerDegLon(double lat) => _mPerDegLat * math.cos(lat * math.pi / 180);

class PuckMotion {
  final PuckConfig config;
  PuckMotion([this.config = const PuckConfig()]);

  // ---- the newest accepted fix and what it says ----
  GeoFix? _fix;
  DateTime? _arrived;
  double _fLat = 0, _fLon = 0; // fused position at the fix
  double _vE = 0, _vN = 0; // velocity of the fix, m/s east / north
  double _speed = 0;
  double? _course; // travel course while moving
  bool _moving = false;
  double _acc = 10;
  double _latencyS = 0; // how old the fix already was when it arrived (GPS clock vs phone clock), 0 when implausible

  // ---- parked lock ----
  bool _parked = false;
  double _lockLat = 0, _lockLon = 0, _lockW = 0;
  int _away = 0;

  // ---- the shown dot ----
  double? _sLat, _sLon;
  double _svE = 0, _svN = 0;
  DateTime? _shownAt;

  final List<GeoFix> _suspects = [];
  DateTime? _lastGoodAt;
  int _rejected = 0;

  /// How many fixes the gate has dropped (tests, diagnostics).
  int get rejectedCount => _rejected;

  /// The newest accepted fix (what the dot is heading for), null before the first.
  GeoFix? get lastAccepted => _fix;

  /// True while the car is held on the parked lock (tests, diagnostics).
  bool get parked => _parked;

  void reset() {
    _fix = _arrived = _lastGoodAt = null;
    _suspects.clear();
    _course = null;
    _speed = 0;
    _vE = _vN = 0;
    _moving = false;
    _parked = false;
    _away = 0;
    _sLat = _sLon = null;
    _svE = _svN = 0;
    _shownAt = null;
  }

  double _accOf(GeoFix f) => (f.accuracyM == null || f.accuracyM!.isNaN || f.accuracyM! <= 0) ? 10 : f.accuracyM!;

  /// Feed a fix as it arrives ([now] is the phone clock, not the GPS clock). True when it was accepted.
  bool add(GeoFix f, DateTime now) {
    if (!f.lat.isFinite || !f.lon.isFinite || f.lat.abs() > 90 || f.lon.abs() > 180) return _reject();
    final cur = _fix;
    if (cur != null && !f.at.isAfter(cur.at)) return _reject();

    // Accuracy gate.
    if (_accOf(f) > config.maxAccuracyM) {
      final good = _lastGoodAt;
      if (good != null && now.difference(good) < config.acceptPoorAfter) return _reject();
    } else {
      _lastGoodAt = now;
    }

    // Teleport gate.
    if (cur != null) {
      final dt = f.at.difference(cur.at).inMicroseconds / 1e6;
      final d = _distM(cur.lat, cur.lon, f.lat, f.lon);
      final explained = 3 * (_accOf(cur) + _accOf(f)) + 30;
      final implied = dt <= 0 ? double.infinity : d / dt;
      if (implied > config.maxSpeedMps && d > explained) {
        if (_suspects.isNotEmpty) {
          final s = _suspects.last;
          if (_distM(s.lat, s.lon, f.lat, f.lon) > 2 * (_accOf(s) + _accOf(f)) + 10) _suspects.clear();
        }
        _suspects.add(f);
        if (_suspects.length < config.relockFixes) return _reject();
        _suspects.clear();
        _snapTo(f, now);
        return true;
      }
    }
    _suspects.clear();
    _accept(f, now);
    return true;
  }

  /// Fix age at arrival, trusted only when plausible (the phone clock and the GPS clock agree to within a second or so).
  double _latencyOf(GeoFix f, DateTime now) {
    final l = now.difference(f.at).inMicroseconds / 1e6;
    return (l >= 0 && l <= 1.0) ? l : 0;
  }

  bool _reject() {
    _rejected++;
    return false;
  }

  void _setVelocity(GeoFix f, GeoFix? prev) {
    var speed = f.speedMps;
    if (speed != null && (!speed.isFinite || speed < 0)) speed = null;
    double? course = f.courseDeg;
    if (course != null && (!course.isFinite || course < 0 || course > 360)) course = null;
    if (course != null && f.courseAccuracyDeg != null && f.courseAccuracyDeg! > 60) course = null;
    if (prev != null) {
      final dt = f.at.difference(prev.at).inMicroseconds / 1e6;
      if (dt > 0.05 && dt < 10) {
        final d = _distM(prev.lat, prev.lon, f.lat, f.lon);
        speed ??= d / dt;
        if (course == null && d > math.max(3.0, _accOf(f) * 0.5)) {
          final dy = (f.lat - prev.lat) * _mPerDegLat;
          final dx = (f.lon - prev.lon) * _mPerDegLon(f.lat);
          course = (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
        }
      }
    }
    _speed = speed ?? 0;
    _moving = _moving ? _speed >= config.stopSpeedMps : _speed >= config.minMovingSpeedMps;
    if (_moving) {
      _course = course ?? _course;
    } else {
      _course = null;
    }
    if (_moving && _course != null) {
      final r = _course! * math.pi / 180;
      _vE = math.sin(r) * _speed;
      _vN = math.cos(r) * _speed;
    } else {
      _vE = _vN = 0;
    }
  }

  void _snapTo(GeoFix f, DateTime now) {
    _fix = f;
    _arrived = now;
    _latencyS = _latencyOf(f, now);
    _acc = _accOf(f);
    _fLat = f.lat;
    _fLon = f.lon;
    _moving = false;
    _setVelocity(f, null);
    _parked = !_moving;
    _lockLat = f.lat;
    _lockLon = f.lon;
    _lockW = 1 / (_acc * _acc);
    _away = 0;
    _sLat = f.lat;
    _sLon = f.lon;
    _svE = _vE;
    _svN = _vN;
    _shownAt = now;
  }

  void _accept(GeoFix f, DateTime now) {
    final cur = _fix;
    final acc = _accOf(f);
    if (cur == null) {
      _snapTo(f, now);
      return;
    }
    final dtFix = f.at.difference(cur.at).inMicroseconds / 1e6;
    final wasMoving = _moving;
    final prevVE = _vE, prevVN = _vN;
    final prevLat = _fLat, prevLon = _fLon;
    _setVelocity(f, cur);

    if (_moving) {
      // Where the previous fix and its velocity said we would be now.
      var pLat = prevLat, pLon = prevLon;
      var gainFloor = config.minGain;
      if (wasMoving && dtFix < 10) {
        pLat += prevVN * dtFix / _mPerDegLat;
        pLon += prevVE * dtFix / _mPerDegLon(prevLat);
      } else if (_parked) {
        pLat = _lockLat;
        pLon = _lockLon;
      } else {
        gainFloor = 1; // a long gap: the old prediction is worthless
      }
      final sp = config.processBaseM + config.processPerSecM * dtFix.clamp(0.0, 10.0);
      final sm = math.max(3.0, acc);
      var k = (sp * sp) / (sp * sp + sm * sm);
      k = math.max(k, gainFloor).clamp(0.0, 1.0);
      final inn = _distM(pLat, pLon, f.lat, f.lon);
      if (inn > config.gateSigmas * math.sqrt(sp * sp + sm * sm)) k = 1;
      _fLat = pLat + (f.lat - pLat) * k;
      _fLon = pLon + (f.lon - pLon) * k;
      _parked = false;
      _away = 0;
    } else {
      // Parked (or crawling): hold a weighted mean of the fixes; leave the lock only for a clear, repeated move.
      if (!_parked) {
        _parked = true;
        _lockLat = _fLat;
        _lockLon = _fLon;
        _lockW = 1 / (math.max(3.0, _acc) * math.max(3.0, _acc));
        _away = 0;
      }
      final away = _distM(_lockLat, _lockLon, f.lat, f.lon);
      if (away > math.max(2 * acc, 12.0)) {
        _away++;
      } else {
        _away = 0;
        final w = 1 / (math.max(3.0, acc) * math.max(3.0, acc));
        _lockLat = (_lockLat * _lockW + f.lat * w) / (_lockW + w);
        _lockLon = (_lockLon * _lockW + f.lon * w) / (_lockW + w);
        _lockW = math.min(_lockW + w, 4.0); // forget slowly, so a drifting receiver is followed
      }
      if (_away >= 2) {
        _lockLat = f.lat;
        _lockLon = f.lon;
        _lockW = 1 / (math.max(3.0, acc) * math.max(3.0, acc));
        _away = 0;
      }
      _fLat = _lockLat;
      _fLon = _lockLon;
    }
    _fix = f;
    _arrived = now;
    _latencyS = _latencyOf(f, now);
    _acc = acc;
    _sLat ??= _fLat;
    _sLon ??= _fLon;
    _shownAt ??= now;
  }

  /// The pose to draw at [now]. Call once per frame; null before the first accepted fix. [reducedMotion] shows the newest fix
  /// as it is (no coasting, no ease).
  PuckPose? poseAt(DateTime now, {bool reducedMotion = false}) {
    final f = _fix;
    if (f == null) return null;
    final arrived = _arrived!;
    var age = now.difference(arrived).inMicroseconds / 1e6;
    if (age < 0) age = 0;
    final rawAge = age; // time since arrival (weak / frozen are about this, not the latency)
    age += _latencyS;
    final coast = config.coastMax.inMicroseconds / 1e6;
    final weak = rawAge >= config.weakAfter.inMicroseconds / 1e6;
    final frozen = age >= coast;

    if (reducedMotion) {
      _sLat = _fLat;
      _sLon = _fLon;
      _svE = _svN = 0;
      _shownAt = now;
      return PuckPose(
        lat: _fLat,
        lon: _fLon,
        courseDeg: _course,
        speedMps: _speed,
        accuracyM: f.accuracyM,
        settled: true,
        fixAgeS: rawAge,
        weak: weak,
        frozen: frozen,
        parked: _parked,
      );
    }

    // Target: the fused fix pushed along its velocity for the time since it arrived (capped at the coast limit).
    final coasting = _moving && !_parked && _course != null;
    // Coasting tapers to a stop over the last [taper] seconds of the coast window, so the dot does not overshoot when it holds.
    const taper = 0.8;
    final ageEff = age <= coast - taper ? age : (age >= coast ? coast - taper / 2 : (coast - taper) + (age - (coast - taper)) * (1 - (age - (coast - taper)) / (2 * taper)));
    var tLat = _fLat, tLon = _fLon;
    if (coasting) {
      tLat += _vN * ageEff / _mPerDegLat;
      tLon += _vE * ageEff / _mPerDegLon(_fLat);
    }
    final fade = !coasting ? 0.0 : (age <= coast - taper ? 1.0 : (age >= coast ? 0.0 : (coast - age) / taper));
    final ffE = _vE * fade;
    final ffN = _vN * fade;

    var sLat = _sLat ?? tLat, sLon = _sLon ?? tLon;
    final last = _shownAt ?? now;
    var dt = now.difference(last).inMicroseconds / 1e6;
    if (dt < 0) dt = 0;
    if (coasting && frozen) {
      // Holding after a dip: if the dot already went a little past the point it should hold at, it stays where it is.
      final r = _course! * math.pi / 180;
      final along = (tLon - sLon) * _mPerDegLon(sLat) * math.sin(r) + (tLat - sLat) * _mPerDegLat * math.cos(r);
      if (along < 0) {
        tLat = sLat;
        tLon = sLon;
      }
    }
    final away0 = _distM(sLat, sLon, tLat, tLon);
    if (away0 > config.snapDistanceM || dt > 1.5) {
      // A huge gap (backgrounded, resumed) or a believed jump: go there.
      sLat = tLat;
      sLon = tLon;
      _svE = ffE;
      _svN = ffN;
    } else if (dt > 0) {
      dt = math.min(dt, 0.1);
      final mLon = _mPerDegLon(sLat);
      final eE = (tLon - sLon) * mLon; // error, metres east / north
      final eN = (tLat - sLat) * _mPerDegLat;
      final err = math.sqrt(eE * eE + eN * eN);
      final tau = err > config.farM ? config.tauFar : config.tauNear;
      var vdE = ffE + eE / tau;
      var vdN = ffN + eN / tau;
      final vmax = _speed * 1.8 + 6;
      final vd = math.sqrt(vdE * vdE + vdN * vdN);
      if (vd > vmax) {
        vdE *= vmax / vd;
        vdN *= vmax / vd;
      }
      // Accelerate toward the desired velocity, no faster than the limit.
      var dE = vdE - _svE, dN = vdN - _svN;
      final dm = math.sqrt(dE * dE + dN * dN);
      final cap = config.maxAccel * dt;
      if (dm > cap) {
        dE *= cap / dm;
        dN *= cap / dm;
      }
      _svE += dE;
      _svN += dN;
      // Never backwards along the course.
      if (coasting) {
        final r = _course! * math.pi / 180;
        final dirE = math.sin(r), dirN = math.cos(r);
        final along = _svE * dirE + _svN * dirN;
        if (along < 0) {
          _svE -= along * dirE;
          _svN -= along * dirN;
        }
      }
      if (err < 0.08 && _svE.abs() < 0.06 && _svN.abs() < 0.06) {
        _svE = _svN = 0;
        sLat = tLat;
        sLon = tLon;
      } else {
        sLat += _svN * dt / _mPerDegLat;
        sLon += _svE * dt / mLon;
      }
    }
    _sLat = sLat;
    _sLon = sLon;
    _shownAt = now;

    final still = _svE.abs() < 0.06 && _svN.abs() < 0.06 && _distM(sLat, sLon, tLat, tLon) < 0.1;
    final settled = still && (!coasting || frozen) && (frozen || !weak && age > 0 || _parked);
    // Ring: the fix's accuracy, growing once the signal has been down a while.
    var acc = f.accuracyM;
    if (acc != null && age > 1.5) acc = acc + (age - 1.5) * math.max(2.0, _speed * 0.5);

    return PuckPose(
      lat: sLat,
      lon: sLon,
      courseDeg: _course,
      speedMps: _speed,
      accuracyM: acc,
      settled: settled,
      fixAgeS: rawAge,
      weak: weak,
      frozen: frozen,
      parked: _parked,
    );
  }
}
