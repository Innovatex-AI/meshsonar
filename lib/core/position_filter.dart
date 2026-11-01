// Cleans up raw GPS fixes before the app uses them: no wandering dot while parked, no fake "movement" that would
// trigger distance-based pings, and little lag while driving. Pure Dart.
//
// What it does, per fix:
//  1. Rejects fixes whose reported accuracy is poor (> maxAccuracyM, 100 m: a Wi-Fi/cell guess) — unless nothing better has
//     arrived for a while, so a phone that only gets poor fixes still has a position. 35-60 m fixes (what a phone in a car
//     reports all day) pass: the ping policy (lib/core/fix_window.dart) decides what to do with them.
//  2. Smooths with an accuracy-weighted alpha-beta (constant-velocity Kalman) filter: each step PREDICTS the position forward by the
//     estimated velocity, then blends in the new fix. The old position-only blend lagged a car by 40-60 m at 35-46 m accuracy (a
//     6% gain with no prediction trails a moving target); the prediction removes that systematic lag and the gain floor keeps it
//     following turns.
//  3. Stationary hold: when the car is parked, keeps reporting one "anchor" position (speed 0) and ignores jitter
//     inside max(2 × accuracy, minAnchorRadiusM) — and even outside it, unless the movement is consistent:
//       - reported speed ≥ movingSpeedMps on 2 fixes in a row, or ≥ fastSpeedMps once (driving off), or
//       - 3 fixes in a row beyond the radius, each further away than the last, the last at least
//         max(2 × radius, 50 m) out (4 × radius when the phone reports it isn't moving).
//     It re-enters the hold when reported speed < stationarySpeedMps on 2 fixes in a row (or, with no speed reported,
//     when the last 3 fixes sit within the radius of their centre).
// The original accuracy is kept on every output fix.
import 'dart:async';
import 'dart:math' as math;

import '../radio/radio_api.dart';
import 'fix_window.dart' show StaleFixGuard;

double _distM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class PositionFilterConfig {
  /// Fixes worse than this are dropped (while better ones are recent).
  final double maxAccuracyM;

  /// The parked-hold is only entered on a fix at least this accurate (a 90 m fix says nothing about being parked).
  final double holdMaxAccuracyM;

  /// Lowest weight a new fix gets while moving (the Kalman gain is never smaller): keeps the estimate following the car.
  final double minGain;

  /// After this long without an acceptable fix, poor fixes are used anyway.
  final Duration acceptPoorAfter;

  /// Accuracy assumed when the platform doesn't report one.
  final double defaultAccuracyM;

  /// Below this reported speed the car counts as stopped.
  final double stationarySpeedMps;

  /// At or above this reported speed (two fixes in a row) the car counts as moving.
  final double movingSpeedMps;

  /// At or above this reported speed (one fix) the car is clearly driving.
  final double fastSpeedMps;

  /// Smallest hold radius around the parked position.
  final double minAnchorRadiusM;

  /// Largest hold radius. A 300 m-accurate fix (cell towers, no GPS yet) must not make a 600 m "parked" bubble that
  /// freezes the dot and the ping distance for the next kilometre of driving.
  final double maxAnchorRadiusM;

  /// Fixes in a row beyond the radius (moving consistently away) needed to leave the hold without speed.
  final int exitFixes;

  /// Without a usable speed (parked iPhones usually report none), a drift must also reach this far before it
  /// counts as driving off.
  final double unknownSpeedExitM;

  const PositionFilterConfig({
    this.maxAccuracyM = 100,
    this.holdMaxAccuracyM = 50,
    this.minGain = 0.15,
    this.acceptPoorAfter = const Duration(seconds: 10),
    this.defaultAccuracyM = 10,
    this.stationarySpeedMps = 1.0,
    this.movingSpeedMps = 2.0,
    this.fastSpeedMps = 5.0,
    this.minAnchorRadiusM = 15,
    this.maxAnchorRadiusM = 40,
    this.exitFixes = 3,
    this.unknownSpeedExitM = 50,
  });
}

/// The filter itself: feed raw fixes in time order to [add]; it returns the cleaned fix, or null for a dropped one.
class PositionFilter {
  final PositionFilterConfig config;
  PositionFilter([this.config = const PositionFilterConfig()]);

  // Kalman state (position estimate and its variance, m²).
  double? _lat, _lon;
  double _var = 0;
  double _vN = 0, _vE = 0; // estimated velocity, m/s north / east
  DateTime? _at;
  GeoFix? _prevRaw;
  DateTime? _lastGoodAt; // last fix within maxAccuracyM

  // Stationary hold.
  bool _stationary = false;
  double? _aLat, _aLon;
  int _fastRun = 0;
  int _slowRun = 0;
  final List<double> _outside = []; // distances of the current run of fixes beyond the radius
  final List<GeoFix> _recent = []; // last few accepted raw fixes (for "no speed" stop detection)

  /// Fixes the no-speed stop test looks at.
  static const int _stopFixes = 8;

  GeoFix? _last;

  /// The last fix [add] returned.
  GeoFix? get last => _last;

  /// True while holding a parked position.
  bool get stationary => _stationary;

  void reset() {
    _lat = _lon = _at = _prevRaw = _lastGoodAt = _aLat = _aLon = _last = null;
    _var = 0;
    _vN = _vE = 0;
    _stationary = false;
    _fastRun = _slowRun = 0;
    _outside.clear();
    _recent.clear();
  }

  double _acc(GeoFix f) {
    final a = f.accuracyM;
    return (a == null || a.isNaN || a <= 0) ? config.defaultAccuracyM : a;
  }

  double _radius(double acc) => math.min(math.max(2 * acc, config.minAnchorRadiusM), config.maxAnchorRadiusM);

  GeoFix? add(GeoFix raw) {
    if (raw.lat.isNaN || raw.lon.isNaN) return null;
    final acc = _acc(raw);
    final speed = (raw.speedMps == null || raw.speedMps!.isNaN || raw.speedMps! < 0) ? null : raw.speedMps;

    // 1. Accuracy gate.
    if (acc > config.maxAccuracyM) {
      if (_lastGoodAt != null && raw.at.difference(_lastGoodAt!) < config.acceptPoorAfter) return null;
    } else {
      _lastGoodAt = raw.at;
    }

    // 2. Alpha-beta smoothing (predict with the velocity, then blend in the fix).
    if (_lat == null) {
      _lat = raw.lat;
      _lon = raw.lon;
      _var = acc * acc;
      _setVelocityFromReport(raw, speed);
    } else {
      var dt = raw.at.difference(_at!).inMicroseconds / 1e6;
      if (dt < 0) dt = 0;
      if (dt > 30) _vN = _vE = 0; // a long silence: the old velocity says nothing
      final cosLat = math.max(0.01, math.cos(_lat! * math.pi / 180));
      if (!_stationary) {
        _lat = _lat! + _vN * dt / 111320.0;
        _lon = _lon! + _vE * dt / (111320.0 * cosLat);
      }
      var q = speed ?? 0;
      if (speed == null && _prevRaw != null && dt > 0) {
        q = _distM(_prevRaw!.lat, _prevRaw!.lon, raw.lat, raw.lon) / dt;
      }
      q = math.max(q, 1.0);
      _var += (q * dt) * (q * dt);
      var k = _var / (_var + acc * acc);
      if (!_stationary) k = math.max(k, config.minGain);
      final rN = (raw.lat - _lat!) * 111320.0;
      final rE = (raw.lon - _lon!) * 111320.0 * cosLat;
      _lat = _lat! + k * (raw.lat - _lat!);
      _lon = _lon! + k * (raw.lon - _lon!);
      _var = (1 - k) * _var;
      if (!_stationary && dt >= 0.2) {
        final beta = k * k / (2 - k);
        _vN = (_vN + beta / dt * rN).clamp(-60.0, 60.0);
        _vE = (_vE + beta / dt * rE).clamp(-60.0, 60.0);
      }
      _setVelocityFromReport(raw, speed);
    }
    _at = raw.at;
    _prevRaw = raw;
    _recent.add(raw);
    if (_recent.length > _stopFixes) _recent.removeAt(0);

    final radius = _radius(acc);

    // 3. Stationary hold.
    if (_last == null) {
      // First fix: parked unless the phone says we're moving.
      if ((speed == null || speed < config.stationarySpeedMps) && acc <= config.holdMaxAccuracyM) _enterHold();
    } else if (_stationary) {
      final d = _distM(_aLat!, _aLon!, raw.lat, raw.lon);
      _fastRun = (speed != null && speed >= config.movingSpeedMps) ? _fastRun + 1 : 0;
      if (d > radius) {
        if (_outside.isNotEmpty && d <= _outside.last) _outside.clear();
        _outside.add(d);
      } else {
        _outside.clear();
      }
      final reportsStill = speed != null && speed < config.stationarySpeedMps;
      final farEnough = reportsStill ? d >= 4 * radius : d >= math.max(2 * radius, config.unknownSpeedExitM);
      final leave = (speed != null && speed >= config.fastSpeedMps) ||
          _fastRun >= 2 ||
          (_outside.length >= config.exitFixes && farEnough);
      if (leave) {
        _stationary = false;
        _outside.clear();
        _slowRun = 0;
        // Restart the smoother at the fix that proved we're moving, so there's no lag pulling back to the anchor.
        _lat = raw.lat;
        _lon = raw.lon;
        _var = acc * acc;
        _vN = _vE = 0;
        _setVelocityFromReport(raw, speed);
      }
    } else {
      if (speed != null) {
        _slowRun = speed < config.stationarySpeedMps ? _slowRun + 1 : 0;
        if (_slowRun >= 2 && acc <= config.holdMaxAccuracyM) _enterHold();
      } else if (_recent.length >= _stopFixes) {
        // No speed reported: parked only if the last fixes are scattered round one point AND not trending away. The old rule (3 fixes
        // within the radius) took a car doing 10 m/s for parked once the accuracy was poor (radius 40 m), freezing the dot and the ping
        // position at an anchor for 9 s at a time.
        final cLat = _recent.map((f) => f.lat).reduce((a, b) => a + b) / _recent.length;
        final cLon = _recent.map((f) => f.lon).reduce((a, b) => a + b) / _recent.length;
        final half = _recent.length ~/ 2;
        double mean(Iterable<GeoFix> fs, double Function(GeoFix) v) => fs.map(v).reduce((a, b) => a + b) / fs.length;
        final first = _recent.take(half), last = _recent.skip(_recent.length - half);
        final trend = _distM(mean(first, (f) => f.lat), mean(first, (f) => f.lon), mean(last, (f) => f.lat), mean(last, (f) => f.lon));
        final spanOk = _recent.last.at.difference(_recent.first.at) >= const Duration(seconds: 7);
        if (acc <= config.holdMaxAccuracyM &&
            spanOk &&
            trend <= radius / 3 &&
            _recent.every((f) => _distM(cLat, cLon, f.lat, f.lon) <= radius)) {
          _enterHold();
        }
      }
    }

    // Altitude and the accuracies pass through unchanged (drive context, stream 7); course only while moving.
    final out = _stationary
        ? GeoFix(
            lat: _aLat!,
            lon: _aLon!,
            at: raw.at,
            accuracyM: raw.accuracyM,
            speedMps: 0,
            altitudeM: raw.altitudeM,
            altitudeAccuracyM: raw.altitudeAccuracyM,
            speedAccuracyMps: raw.speedAccuracyMps,
          )
        : GeoFix(
            lat: _lat!,
            lon: _lon!,
            at: raw.at,
            accuracyM: raw.accuracyM,
            speedMps: speed,
            altitudeM: raw.altitudeM,
            altitudeAccuracyM: raw.altitudeAccuracyM,
            courseDeg: raw.courseDeg,
            courseAccuracyDeg: raw.courseAccuracyDeg,
            speedAccuracyMps: raw.speedAccuracyMps,
          );
    _last = out;
    return out;
  }

  /// A reported speed (and course, when there is one) beats the estimated velocity; a reported near-zero speed zeroes it.
  void _setVelocityFromReport(GeoFix raw, double? speed) {
    if (speed == null) return;
    if (speed < config.stationarySpeedMps) {
      _vN = _vE = 0;
      return;
    }
    final c = raw.courseDeg;
    if (c == null || c.isNaN || c < 0 || c >= 360) return;
    final r = c * math.pi / 180;
    _vN = speed * math.cos(r);
    _vE = speed * math.sin(r);
  }

  void _enterHold() {
    _stationary = true;
    _aLat = _lat;
    _aLon = _lon;
    _fastRun = 0;
    _slowRun = 0;
    _outside.clear();
  }
}

/// Wraps any [LocationSource] and hands out filtered fixes (see [PositionFilter]). One filter is shared by every
/// listener and by [current], so the map, the engine and the ping positions all agree.
class FilteredLocationSource implements LocationSource {
  final LocationSource inner;
  final PositionFilter filter;
  final DateTime Function() _clock;

  /// [current] returns the last filtered fix if it arrived within this long; otherwise it asks [inner].
  final Duration freshFor;

  late final StreamController<GeoFix> _out;
  StreamSubscription<GeoFix>? _sub;
  DateTime? _lastAt; // by our clock

  FilteredLocationSource(
    this.inner, {
    PositionFilterConfig config = const PositionFilterConfig(),
    DateTime Function()? clock,
    this.freshFor = const Duration(seconds: 3),
  })  : filter = PositionFilter(config),
        _clock = clock ?? DateTime.now {
    _out = StreamController<GeoFix>.broadcast(onListen: _listen, onCancel: _cancel);
  }

  void _listen() {
    _sub = inner.fixes.listen((raw) {
      final f = _feed(raw);
      if (f != null) _out.add(f);
    }, onError: _out.addError);
  }

  void _cancel() {
    final s = _sub;
    _sub = null;
    s?.cancel();
  }

  final StaleFixGuard _stale = StaleFixGuard();

  /// Cached positions refused on arrival (see [StaleFixGuard]).
  int staleDropped = 0;

  GeoFix? _feed(GeoFix raw) {
    // A cached position (iOS hands one over when a stream starts) must never seed the smoother or the parked-hold anchor: it sat 1.2 km
    // behind and held ping 1 there for three fixes.
    if (_stale.isStale(raw.at, _clock())) {
      staleDropped++;
      return null;
    }
    final f = filter.add(raw);
    if (f != null) _lastAt = _clock();
    return f;
  }

  @override
  Stream<GeoFix> get fixes => _out.stream;

  @override
  Future<GeoFix?> current() async {
    final last = filter.last;
    if (last != null && _lastAt != null && _clock().difference(_lastAt!) <= freshFor) return last;
    final raw = await inner.current();
    if (raw == null) return null;
    // Older than what the filter has already seen (e.g. a cached last-known position): don't rewind the filter.
    final seen = filter.last;
    if (seen != null && !raw.at.isAfter(seen.at)) return seen;
    return _feed(raw) ?? filter.last;
  }

  @override
  Future<bool> ensurePermission() => inner.ensurePermission();
}
