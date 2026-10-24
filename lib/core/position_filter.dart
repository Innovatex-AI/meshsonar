// Cleans up raw GPS fixes before the app uses them: no wandering dot while parked, no fake "movement" that would
// trigger distance-based pings, and little lag while driving. Pure Dart.
//
// What it does, per fix:
//  1. Rejects fixes whose reported accuracy is poor (> maxAccuracyM) — unless nothing better has arrived for a while,
//     so a phone that only gets poor fixes still has a position.
//  2. Smooths with a simple accuracy-weighted Kalman filter (position only; uncertainty grows with speed × time, so a
//     moving car follows the raw fixes closely and never overshoots a turn: each estimate is a blend of the previous
//     estimate and the new fix).
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

  /// Fixes in a row beyond the radius (moving consistently away) needed to leave the hold without speed.
  final int exitFixes;

  /// Without a usable speed (parked iPhones usually report none), a drift must also reach this far before it
  /// counts as driving off.
  final double unknownSpeedExitM;

  const PositionFilterConfig({
    this.maxAccuracyM = 50,
    this.acceptPoorAfter = const Duration(seconds: 10),
    this.defaultAccuracyM = 10,
    this.stationarySpeedMps = 1.0,
    this.movingSpeedMps = 2.0,
    this.fastSpeedMps = 5.0,
    this.minAnchorRadiusM = 15,
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

  GeoFix? _last;

  /// The last fix [add] returned.
  GeoFix? get last => _last;

  /// True while holding a parked position.
  bool get stationary => _stationary;

  void reset() {
    _lat = _lon = _at = _prevRaw = _lastGoodAt = _aLat = _aLon = _last = null;
    _var = 0;
    _stationary = false;
    _fastRun = _slowRun = 0;
    _outside.clear();
    _recent.clear();
  }

  double _acc(GeoFix f) {
    final a = f.accuracyM;
    return (a == null || a.isNaN || a <= 0) ? config.defaultAccuracyM : a;
  }

  double _radius(double acc) => math.max(2 * acc, config.minAnchorRadiusM);

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

    // 2. Kalman smoothing.
    if (_lat == null) {
      _lat = raw.lat;
      _lon = raw.lon;
      _var = acc * acc;
    } else {
      var dt = raw.at.difference(_at!).inMicroseconds / 1e6;
      if (dt < 0) dt = 0;
      var q = speed ?? 0;
      if (speed == null && _prevRaw != null && dt > 0) {
        q = _distM(_prevRaw!.lat, _prevRaw!.lon, raw.lat, raw.lon) / dt;
      }
      q = math.max(q, 1.0);
      _var += (q * dt) * (q * dt);
      final k = _var / (_var + acc * acc);
      _lat = _lat! + k * (raw.lat - _lat!);
      _lon = _lon! + k * (raw.lon - _lon!);
      _var = (1 - k) * _var;
    }
    _at = raw.at;
    _prevRaw = raw;
    _recent.add(raw);
    if (_recent.length > 3) _recent.removeAt(0);

    final radius = _radius(acc);

    // 3. Stationary hold.
    if (_last == null) {
      // First fix: parked unless the phone says we're moving.
      if (speed == null || speed < config.stationarySpeedMps) _enterHold();
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
      }
    } else {
      if (speed != null) {
        _slowRun = speed < config.stationarySpeedMps ? _slowRun + 1 : 0;
        if (_slowRun >= 2) _enterHold();
      } else if (_recent.length >= 3) {
        final cLat = _recent.map((f) => f.lat).reduce((a, b) => a + b) / _recent.length;
        final cLon = _recent.map((f) => f.lon).reduce((a, b) => a + b) / _recent.length;
        if (_recent.every((f) => _distM(cLat, cLon, f.lat, f.lon) <= radius)) _enterHold();
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

  GeoFix? _feed(GeoFix raw) {
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
