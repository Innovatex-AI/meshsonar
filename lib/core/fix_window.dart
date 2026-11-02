// The GPS fix POLICY for pings, in one pure-Dart place (no Flutter, no platform, no clock of its own: the caller passes a monotonic
// reading so a jumping wall clock or a busy UI isolate can never reorder or age fixes wrongly).
//
// Why a window (Nov 1 2026, Andy's drives): the engine used to ask the platform for "the" position at the moment a ping was due and wait
// up to 4 s for it, refusing anything over 50 m. Fixes sat at 35-46 m, so any excursion past 50 m, or one slow `current()` call, delayed
// or dropped the ping. Now the engine keeps the last [span] of fixes the stream delivered and picks the best one AT the due time, without
// waiting for anyone.
//
// The rules, each pinned by test/core/fix_window_test.dart:
//  1. Candidates are fixes that arrived within [span] (8 s) and are no worse than [pingAccuracyGateM].
//  2. The winner has the smallest EFFECTIVE ERROR: its accuracy plus how far the car has gone since (speed x age). A 35 m fix 4 s old at
//     13 m/s (87 m) loses to a fresh 52 m one; with the car parked age costs nothing. Ties go to the fresher fix.
//  3. The FIRST ping of a drive needs a fix at least as good as [firstPingAccuracyM] (a stale or coarse first fix put ping 1 1.2 km
//     from ping 2 on Nov 1). After [firstPingRelaxAfter] of waiting it takes anything inside the gate: a late first ping beats none.
//  4. A fix whose own timestamp is older than [staleFixAge] when it ARRIVES is a cached position (iOS hands one over at stream start):
//     never admitted ([StaleFixGuard]; a phone clock that is simply wrong shows a STEADY age and is not mistaken for it).
//  5. Speed and course the OS did not report are derived from the window (distance over >= 3 s between the two fixes, and only when the
//     movement clearly exceeds the fixes' own error), otherwise left null. Nothing is invented: no estimate, no dead reckoning.
import 'dart:math' as math;

import '../radio/radio_api.dart';

/// The worst accuracy (metres) a ping may be sent from. Coverage cells are about 25 m H3 res-11 hexagons, so a 60-100 m fix can land
/// a cell or three away; that is still better coverage data than a missing ping (a gap on the map reads as "no signal here"). Above this
/// the fix is a Wi-Fi/cell-tower guess and the ping would be placed on the wrong street.
const double pingAccuracyGateM = 100;

/// Pings from a fix worse than this are flagged `low_acc` in the trace; `gps_accuracy_m` carries the number to the server as always.
const double pingAccuracyFlagM = 50;

/// The first ping of a drive needs at least this accuracy ...
const double firstPingAccuracyM = 50;

/// ... until it has waited this long, then the normal gate applies.
const Duration firstPingRelaxAfter = Duration(seconds: 20);

/// How far back the window looks.
const Duration fixWindowSpan = Duration(seconds: 8);

/// A fix whose timestamp is older than this when it arrives is a cached position.
const Duration staleFixAge = Duration(seconds: 8);

/// Accuracy assumed for a fix that reports none.
const double unknownAccuracyM = 25;

/// Tells a cached position from a phone whose clock is wrong. A fix is stale when its timestamp is older than [staleFixAge] on arrival
/// AND that age is not just the same offset the previous fix had (a steady offset is a wrong phone clock; the engine's clock-skew check
/// reports that to the driver). Feed every raw fix, in order, to [isStale].
class StaleFixGuard {
  Duration? _prevAge;
  DateTime? _prevAt;

  bool isStale(DateTime fixAt, DateTime now) {
    final age = now.difference(fixAt);
    final prev = _prevAge, prevAt = _prevAt;
    _prevAge = age;
    _prevAt = fixAt;
    if (age <= staleFixAge) return false;
    // A wrong phone clock gives a steady age on fixes whose own times keep ADVANCING. The same cached fix handed over twice (stream, then
    // `current()`) has the same time again and is still stale.
    if (prev != null && prevAt != null && fixAt.isAfter(prevAt) && (age - prev).abs() < staleFixAge) return false;
    return true;
  }

  void reset() {
    _prevAge = null;
    _prevAt = null;
  }
}

double _rad(double d) => d * math.pi / 180;

double _distM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = _rad(lat2 - lat1), dLon = _rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double _bearing(double lat1, double lon1, double lat2, double lon2) {
  final dLon = _rad(lon2 - lon1);
  final y = math.sin(dLon) * math.cos(_rad(lat2));
  final x = math.cos(_rad(lat1)) * math.sin(_rad(lat2)) - math.sin(_rad(lat1)) * math.cos(_rad(lat2)) * math.cos(dLon);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Where a fix's speed came from.
enum SpeedSource { os, derived, none }

class WindowFix {
  final GeoFix fix;

  /// Monotonic reading when it arrived.
  final Duration arrived;
  final SpeedSource speedSource;
  const WindowFix(this.fix, this.arrived, this.speedSource);
}

/// The fix chosen for a ping and why.
class FixPick {
  final GeoFix fix;

  /// How long ago it arrived (monotonic).
  final Duration age;

  /// Which fixes were weighed.
  final int candidates;

  /// Fixes in the window the gate refused.
  final int refusedPoor;

  /// True when a fix other than the newest won (a better, older one).
  final bool notNewest;
  final SpeedSource speedSource;

  /// True for the drive's first ping, picked under the stricter first-ping rule.
  final bool first;
  const FixPick({
    required this.fix,
    required this.age,
    required this.candidates,
    required this.refusedPoor,
    required this.notNewest,
    required this.speedSource,
    this.first = false,
  });

  double? get accuracyM => fix.accuracyM;
  bool get lowAccuracy => (fix.accuracyM ?? 0) > pingAccuracyFlagM;
}

class FixWindow {
  final Duration span;
  final int maxFixes;
  FixWindow({this.span = fixWindowSpan, this.maxFixes = 32});

  final List<WindowFix> _fixes = [];

  /// Fixes refused on arrival as cached/stale.
  int staleRefused = 0;

  /// The newest admitted fix (enriched), with its arrival.
  WindowFix? get newest => _fixes.isEmpty ? null : _fixes.last;

  /// Fixes currently held (tests).
  List<WindowFix> get fixes => List.unmodifiable(_fixes);

  void clear() {
    _fixes.clear();
    staleRefused = 0;
  }

  /// Admits [raw], which arrived at monotonic [now]. [stale] = a [StaleFixGuard] called it a cached position. Returns the fix with
  /// speed/course filled in where they could be derived, or null if it was refused (stale, or not a position).
  GeoFix? add(GeoFix raw, Duration now, {bool stale = false}) {
    if (raw.lat.isNaN || raw.lon.isNaN) return null;
    if (stale) {
      staleRefused++;
      return null;
    }
    _trim(now);
    final enriched = _enrich(raw, now);
    _fixes.add(WindowFix(enriched.$1, now, enriched.$2));
    while (_fixes.length > maxFixes) {
      _fixes.removeAt(0);
    }
    return enriched.$1;
  }

  void _trim(Duration now) {
    // Keep a little more than the span so a derivation baseline exists; picking applies the real span.
    _fixes.removeWhere((w) => now - w.arrived > span + const Duration(seconds: 4));
  }

  (GeoFix, SpeedSource) _enrich(GeoFix raw, Duration now) {
    final os = raw.speedMps;
    final osOk = os != null && !os.isNaN && os >= 0 && os <= 150;
    // Baseline: the oldest fix that arrived at least 3 s ago.
    WindowFix? base;
    for (final w in _fixes) {
      if (now - w.arrived >= const Duration(seconds: 3)) {
        base = w;
        break;
      }
    }
    double? derived, course;
    if (base != null) {
      final dt = raw.at.difference(base.fix.at).inMilliseconds / 1000.0;
      if (dt >= 2.5 && dt <= 15) {
        final d = _distM(base.fix.lat, base.fix.lon, raw.lat, raw.lon);
        final a1 = base.fix.accuracyM ?? unknownAccuracyM, a2 = raw.accuracyM ?? unknownAccuracyM;
        // The movement must clearly exceed what the two fixes' own error could produce while parked.
        final noise = math.max(10.0, 0.5 * math.sqrt(a1 * a1 + a2 * a2));
        if (d > noise) {
          derived = d / dt;
          if (derived > 150) derived = null;
          if (derived != null && derived >= 1.5) course = _bearing(base.fix.lat, base.fix.lon, raw.lat, raw.lon);
        }
      }
    }
    final speed = osOk ? os : derived;
    final hasCourse = raw.courseDeg != null && raw.courseDeg! >= 0 && raw.courseDeg! < 360;
    final fix = GeoFix(
      lat: raw.lat,
      lon: raw.lon,
      at: raw.at,
      accuracyM: raw.accuracyM,
      speedMps: speed,
      altitudeM: raw.altitudeM,
      altitudeAccuracyM: raw.altitudeAccuracyM,
      courseDeg: hasCourse ? raw.courseDeg : course,
      courseAccuracyDeg: raw.courseAccuracyDeg,
      speedAccuracyMps: raw.speedAccuracyMps,
    );
    return (fix, osOk ? SpeedSource.os : (derived != null ? SpeedSource.derived : SpeedSource.none));
  }

  /// The fix to ping from at monotonic [now], or null when nothing in the window qualifies. [first] = this is the drive's first ping;
  /// [waited] = how long it has been waiting for a usable fix (relaxes the first-ping rule after [firstPingRelaxAfter]).
  FixPick? pick(Duration now, {bool first = false, Duration waited = Duration.zero}) {
    final strict = first && waited < firstPingRelaxAfter;
    WindowFix? best;
    double bestErr = double.infinity;
    var candidates = 0, refused = 0;
    // A fix with no speed of its own is not a parked car: it takes the newest speed the window knows, so an old speedless fix (the
    // first ones of a drive have none until a 3 s baseline exists) cannot beat fresher ones on a zero age penalty.
    double? lastSpeed;
    for (var i = _fixes.length - 1; i >= 0; i--) {
      final v = _fixes[i].fix.speedMps;
      if (v != null) {
        lastSpeed = v;
        break;
      }
    }
    for (final w in _fixes) {
      final age = now - w.arrived;
      if (age > span || age.isNegative) continue;
      final acc = w.fix.accuracyM;
      if (acc != null && acc > pingAccuracyGateM) {
        refused++;
        continue;
      }
      if (strict && (acc == null || acc > firstPingAccuracyM)) {
        refused++;
        continue;
      }
      candidates++;
      final err = (acc ?? unknownAccuracyM) + (w.fix.speedMps ?? lastSpeed ?? 0) * age.inMilliseconds / 1000.0;
      if (best == null || err < bestErr || (err == bestErr && w.arrived > best.arrived)) {
        best = w;
        bestErr = err;
      }
    }
    if (best == null) return null;
    return FixPick(
      fix: best.fix,
      age: now - best.arrived,
      candidates: candidates,
      refusedPoor: refused,
      notNewest: !identical(best, _fixes.last),
      speedSource: best.speedSource,
      first: first,
    );
  }
}
