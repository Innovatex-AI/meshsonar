// MeshTrack's smart sharing rate (meshtrack plan section 4): WHEN a position goes out, given the GPS fixes. It decides
// rate only; the no-send gates (sharing off, radio, privacy zones, GPS accuracy, airtime budget, ping listen window)
// live in MeshTrackService. Pure Dart, clock passed in on every call (no wall clock read here).
//
//   moving:  v >= 80 km/h every 60 s, v <= 10 km/h every 300 s, between 60 s x 80 / v (40 km/h -> 120 s)
//   turns:   at v >= 10 km/h send early when the course changed by more than 25 + 300 / v degrees since the last
//            send, at least 15 s after it
//   parked:  v < 3 km/h for 90 s -> one `s0` position, then nothing until moved more than 50 m from it
//   floor:   never two sends closer than max(20 s, 100 x airtime of one position) (under 1% of wall time)
//   low traffic doubles every interval; N sharing groups (max 3) multiply every interval and the floor by N
//
// Pure Dart: no Flutter imports (lib/core layering rule).
import 'dart:math' as math;

import '../../radio/airtime.dart' show groupTextPacketBytes, loraAirtimeMs;
import '../privacy_zones.dart' show distanceM;

/// A GPS fix as MeshTrack needs it (the app maps `GeoFix` onto this).
class MtFix {
  final double lat;
  final double lon;

  /// Horizontal accuracy, metres; null or <= 0 = unknown.
  final double? accuracyM;

  /// Speed over ground, m/s; null = not measured (derived from the last two fixes instead).
  final double? speedMps;

  /// Course over ground, degrees; null = not measured.
  final double? courseDeg;
  final DateTime at;
  const MtFix({required this.lat, required this.lon, required this.at, this.accuracyM, this.speedMps, this.courseDeg});
}

/// Smart (default) or Low traffic (every interval doubled).
enum MtRate { smart, lowTraffic }

/// Why a beacon fired.
enum MtBeaconWhy { first, interval, corner, parked, moved }

/// Same accuracy gate as pings (`maxPingAccuracyM`).
const double kMtMaxAccuracyM = 100;

/// Below this speed for [kMtParkAfter] the sender is parked.
const double kMtParkedKmh = 3;
const Duration kMtParkAfter = Duration(seconds: 90);

/// A parked sender sends again after moving this far.
const double kMtUnparkM = 50;

/// Minimum gap between a send and an early (corner) send.
const Duration kMtCornerMinGap = Duration(seconds: 15);

/// The floor never goes below this.
const Duration kMtFloorMin = Duration(seconds: 20);

/// Floor = this many airtimes of one position.
const int kMtFloorAirtimes = 100;

/// Time on air of one MeshTrack position (`<name>: MT1 @87G8Q2X5+7F2 s34 c270`, 26 body bytes) at the radio's preset;
/// SF7 / BW 62.5 / CR 5 (MeshCore US default) when the preset is not known. [nameBytes] defaults to 6 ("KE4BFI").
Duration meshTrackPositionAirtime({int? sf, double? bwKhz, int? cr, int nameBytes = 6, bool transportCodes = false}) {
  final okPreset = sf != null && bwKhz != null && sf >= 5 && sf <= 12 && bwKhz > 0;
  final bytes = groupTextPacketBytes(nameBytes + 2 + 26, transportCodes: transportCodes);
  final ms = loraAirtimeMs(
      payloadBytes: bytes, sf: okPreset ? sf : 7, bwKhz: okPreset ? bwKhz : 62.5, cr: (cr ?? 5).clamp(5, 8));
  return Duration(microseconds: (ms * 1000).round());
}

/// What [SmartBeacon.decide] says about one fix.
class MtBeaconDecision {
  final bool send;
  final MtBeaconWhy? why;

  /// Send it as the parked `s0` position.
  final bool parked;

  /// Speed used for this fix (reported, else derived), km/h; null when unknown.
  final double? speedKmh;

  /// Course used (reported, else derived), degrees; null when unknown.
  final double? courseDeg;
  const MtBeaconDecision(this.send, {this.why, this.parked = false, this.speedKmh, this.courseDeg});
  static const MtBeaconDecision no = MtBeaconDecision(false);
}

/// Saved state, so a send the airtime budget refused can be undone ([SmartBeacon.restore]).
class MtBeaconMark {
  final DateTime? lastSentAt;
  final double? lastSentCourse;
  final bool parked;
  final double? parkedLat, parkedLon;
  final bool lastWasParked;
  const MtBeaconMark(this.lastSentAt, this.lastSentCourse, this.parked, this.parkedLat, this.parkedLon, this.lastWasParked);
}

/// The rate decision. Feed every fix to [decide] once; call [markSent] when the position was handed to the radio.
class SmartBeacon {
  DateTime? _lastSentAt;
  double? _lastSentCourse;
  MtFix? _prev;
  DateTime? _slowSince;
  bool _parked = false;
  bool _lastWasParked = false;
  double? _parkedLat, _parkedLon;

  DateTime? get lastSentAt => _lastSentAt;

  /// True after the parked `s0` went out, until the sender moves more than 50 m.
  bool get parked => _parked;

  /// Interval between regular sends at [vKmh].
  static Duration interval(double vKmh, {int groups = 1, MtRate rate = MtRate.smart}) {
    final double s;
    if (vKmh >= 80) {
      s = 60;
    } else if (vKmh <= 10) {
      s = 300;
    } else {
      s = 60 * 80 / vKmh;
    }
    final mult = (rate == MtRate.lowTraffic ? 2 : 1) * groups.clamp(1, 3);
    return Duration(milliseconds: (s * 1000 * mult).round());
  }

  /// Smallest gap between two sends.
  static Duration floor(Duration positionAirtime, {int groups = 1}) {
    final a = positionAirtime * kMtFloorAirtimes;
    final f = a > kMtFloorMin ? a : kMtFloorMin;
    return f * groups.clamp(1, 3);
  }

  /// Course change that triggers an early send at [vKmh] (>= 10 km/h).
  static double cornerThresholdDeg(double vKmh) => 25 + 300 / vKmh;

  /// Forget everything (share start).
  void reset() {
    _lastSentAt = null;
    _lastSentCourse = null;
    _prev = null;
    _slowSince = null;
    _parked = false;
    _lastWasParked = false;
    _parkedLat = _parkedLon = null;
  }

  double? _speedKmh(MtFix f) {
    final s = f.speedMps;
    if (s != null && s.isFinite && s >= 0) return s * 3.6;
    final p = _prev;
    if (p == null) return null;
    final dt = f.at.difference(p.at).inMilliseconds / 1000.0;
    if (dt <= 0 || dt > 120) return null;
    return distanceM(p.lat, p.lon, f.lat, f.lon) / dt * 3.6;
  }

  double? _course(MtFix f) {
    final c = f.courseDeg;
    if (c != null && c.isFinite && c >= 0) return c % 360;
    final p = _prev;
    if (p == null || distanceM(p.lat, p.lon, f.lat, f.lon) < 10) return null;
    return bearingDeg(p.lat, p.lon, f.lat, f.lon);
  }

  /// Decides for one fix at [now]. Stateful (tracks the slow time and the previous fix): call once per fix.
  MtBeaconDecision decide(MtFix fix, {required DateTime now, int groups = 1, Duration? positionAirtime, MtRate rate = MtRate.smart}) {
    final v = _speedKmh(fix);
    final course = _course(fix);
    _prev = fix;
    final slow = v == null || v < kMtParkedKmh;
    if (slow) {
      _slowSince ??= now;
    } else {
      _slowSince = null;
    }
    final last = _lastSentAt;
    MtBeaconDecision yes(MtBeaconWhy why, {bool parked = false}) =>
        MtBeaconDecision(true, why: why, parked: parked, speedKmh: parked ? 0 : v, courseDeg: parked ? null : course);
    if (last == null) return yes(MtBeaconWhy.first);
    final since = now.difference(last);
    if (since < floor(positionAirtime ?? meshTrackPositionAirtime(), groups: groups)) return MtBeaconDecision.no;
    final vv = v ?? 0;
    if (_parked) {
      final moved = _parkedLat == null ? double.infinity : distanceM(_parkedLat!, _parkedLon!, fix.lat, fix.lon);
      if (moved <= kMtUnparkM) return MtBeaconDecision.no;
      // Moved away: no longer parked. Really moving -> send now; creeping (still under 3 km/h) -> the normal slow
      // rules below, with the 90 s parked timer started again.
      _parked = false;
      _parkedLat = _parkedLon = null;
      if (!slow) return yes(MtBeaconWhy.moved);
      _slowSince = now;
    }
    final slowSince = _slowSince;
    if (slowSince != null && now.difference(slowSince) >= kMtParkAfter) {
      // One s0 per stop; a second one (creeping, parking again) waits the slow interval like any other send.
      if (!_lastWasParked || since >= interval(vv, groups: groups, rate: rate)) return yes(MtBeaconWhy.parked, parked: true);
      return MtBeaconDecision.no;
    }
    if (since >= interval(vv, groups: groups, rate: rate)) return yes(MtBeaconWhy.interval);
    final lc = _lastSentCourse;
    if (vv >= 10 && course != null && lc != null && since >= kMtCornerMinGap) {
      if (angleDiffDeg(course, lc) > cornerThresholdDeg(vv)) return yes(MtBeaconWhy.corner);
    }
    return MtBeaconDecision.no;
  }

  /// Records a send of [d] for [fix] at [at]; returns the state before, for [restore].
  MtBeaconMark markSent(MtBeaconDecision d, MtFix fix, DateTime at) {
    final before = MtBeaconMark(_lastSentAt, _lastSentCourse, _parked, _parkedLat, _parkedLon, _lastWasParked);
    _lastSentAt = at;
    if (d.courseDeg != null) _lastSentCourse = d.courseDeg;
    _lastWasParked = d.parked;
    if (d.parked) {
      _parked = true;
      _parkedLat = fix.lat;
      _parkedLon = fix.lon;
    } else if ((d.speedKmh ?? 0) >= kMtParkedKmh) {
      _parked = false;
      _parkedLat = _parkedLon = null;
    }
    return before;
  }

  /// Puts back the state from before a send that did not go out (the next fix re-evaluates).
  void restore(MtBeaconMark m) {
    _lastSentAt = m.lastSentAt;
    _lastSentCourse = m.lastSentCourse;
    _lastWasParked = m.lastWasParked;
    _parked = m.parked;
    _parkedLat = m.parkedLat;
    _parkedLon = m.parkedLon;
  }
}

/// Smallest angle between two bearings, 0-180.
double angleDiffDeg(double a, double b) {
  final d = ((a - b) % 360 + 360) % 360;
  return d > 180 ? 360 - d : d;
}

/// Initial great-circle bearing from 1 to 2, degrees 0-360.
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final y = math.sin(rad(lon2 - lon1)) * math.cos(rad(lat2));
  final x = math.cos(rad(lat1)) * math.sin(rad(lat2)) - math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(rad(lon2 - lon1));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}
