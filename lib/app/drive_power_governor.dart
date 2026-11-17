// The drive's power decisions, once a second (build 70, battery plan §3): which GPS settings the stream runs with, and whether a
// drive left open should end. Pure Dart and clock-free (the caller passes a monotonic time), so tests drive it with a fake clock.
//
//  * Parked: no fix further than [moveM] (25 m) from the anchor for `pauseGpsParkedMin` minutes drops the GPS to the parked
//    settings; a fix [resumeM] (50 m) or more from the anchor restores the chosen precision. No fix yet = never parked (a car in a
//    tunnel is not parked).
//  * No radio: while no radio is connected the GPS is capped at High (no pings are possible, A10).
//  * End a drive left open: `endDriveParkedMin` parked or `endDriveNoRadioMin` with no radio (0 = never) ends the drive once.
import 'dart:math' as math;

import '../core/drive_gps_tuning.dart';
import '../core/power_profile.dart';
import '../radio/radio_api.dart' show GeoFix;

/// Why a drive was ended automatically.
enum DriveAutoEndReason { parked, noRadio }

class DriveAutoEnd {
  final DriveAutoEndReason reason;
  final int minutes;
  const DriveAutoEnd(this.reason, this.minutes);

  /// The notification text, e.g. "Drive ended: parked 30 min".
  String get message => switch (reason) {
        DriveAutoEndReason.parked => 'Drive ended: parked $minutes min',
        DriveAutoEndReason.noRadio => 'Drive ended: no radio for $minutes min',
      };

  @override
  bool operator ==(Object other) => other is DriveAutoEnd && other.reason == reason && other.minutes == minutes;
  @override
  int get hashCode => Object.hash(reason, minutes);
  @override
  String toString() => message;
}

class DrivePowerDecision {
  final DriveGpsMode mode;
  final bool parked;

  /// Set once, on the tick the drive should end.
  final DriveAutoEnd? end;
  const DrivePowerDecision(this.mode, {this.parked = false, this.end});
}

class DrivePowerGovernor {
  final PowerSettings Function() settings;

  /// Movement that resets the parked clock while the GPS runs normally.
  final double moveM;

  /// Movement that ends the parked state (the GPS is coarse then).
  final double resumeM;

  DrivePowerGovernor({PowerSettings Function()? settings, this.moveM = 25, this.resumeM = 50})
      : settings = settings ?? (() => PowerProfile.current);

  double? _aLat, _aLon;
  Duration _lastMoved = Duration.zero;
  Duration? _noRadioSince;
  bool _parked = false;
  bool _ended = false;

  bool get parked => _parked;

  /// The drive (re)started at [now].
  void start(Duration now) {
    _aLat = null;
    _aLon = null;
    _lastMoved = now;
    _noRadioSince = null;
    _parked = false;
    _ended = false;
  }

  /// Every drive fix.
  void onFix(GeoFix f, Duration now) {
    final lat = _aLat, lon = _aLon;
    if (lat == null || lon == null) {
      _aLat = f.lat;
      _aLon = f.lon;
      _lastMoved = now;
      return;
    }
    final d = _distanceM(lat, lon, f.lat, f.lon);
    if (d >= (_parked ? resumeM : moveM)) {
      _aLat = f.lat;
      _aLon = f.lon;
      _lastMoved = now;
      _parked = false;
    }
  }

  DrivePowerDecision tick(Duration now, {required bool radioConnected}) {
    final s = settings();
    final parkedFor = _aLat == null ? Duration.zero : now - _lastMoved;
    _parked = s.pauseGpsParkedMin > 0 && parkedFor >= Duration(minutes: s.pauseGpsParkedMin);
    if (radioConnected) {
      _noRadioSince = null;
    } else {
      _noRadioSince ??= now;
    }
    DriveAutoEnd? end;
    if (!_ended) {
      final noRadioFor = _noRadioSince == null ? Duration.zero : now - _noRadioSince!;
      if (s.endDriveParkedMin > 0 && _aLat != null && parkedFor >= Duration(minutes: s.endDriveParkedMin)) {
        end = DriveAutoEnd(DriveAutoEndReason.parked, s.endDriveParkedMin);
      } else if (s.endDriveNoRadioMin > 0 && noRadioFor >= Duration(minutes: s.endDriveNoRadioMin)) {
        end = DriveAutoEnd(DriveAutoEndReason.noRadio, s.endDriveNoRadioMin);
      }
      if (end != null) _ended = true;
    }
    return DrivePowerDecision(
      effectiveDriveGpsMode(chosen: s.gps, radioConnected: radioConnected, parked: _parked),
      parked: _parked,
      end: end,
    );
  }

  static double _distanceM(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
    final dp = (lat2 - lat1) * math.pi / 180, dl = (lon2 - lon1) * math.pi / 180;
    final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
    return 2 * r * math.asin(math.min(1, math.sqrt(a)));
  }
}
