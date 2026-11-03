// Driving auto-collapse (Drive plan 5.3, R09) as a pure state machine with an injected clock.
//   Motion = fix speed >= 2.2 m/s (5 mph) for 3 s; cleared after 10 s below 0.5 m/s.
//   On motion Medium collapses to Dock after 15 s without any touch on the panel (every touch resets the timer).
//   Passenger on = never collapses until the drive ends (default off, [reset] at drive end).
import 'panel_physics.dart';

const double kMotionSpeedMps = 2.2;
const double kStillSpeedMps = 0.5;
const Duration kMotionHold = Duration(seconds: 3);
const Duration kStillHold = Duration(seconds: 10);
const Duration kCollapseAfter = Duration(seconds: 15);

class PanelAutoCollapse {
  bool _moving = false;
  DateTime? _fastSince, _slowSince;
  DateTime? _lastTouch;

  /// Passenger switch: no auto-collapse until the drive ends.
  bool passenger = false;

  bool get moving => _moving;

  /// Feed every GPS fix (speed null = unknown, treated as unchanged).
  void onFix(double? speedMps, DateTime now) {
    if (speedMps == null) return;
    if (speedMps >= kMotionSpeedMps) {
      _slowSince = null;
      _fastSince ??= now;
      if (!_moving && now.difference(_fastSince!) >= kMotionHold) _moving = true;
    } else {
      _fastSince = null;
      if (speedMps < kStillSpeedMps) {
        _slowSince ??= now;
        if (_moving && now.difference(_slowSince!) >= kStillHold) _moving = false;
      } else {
        _slowSince = null;
      }
    }
  }

  /// A touch on the panel, or the panel just opened.
  void touch(DateTime now) => _lastTouch = now;

  /// True when Medium should drop to Dock right now.
  bool shouldCollapse(DateTime now, PanelDetent detent) {
    if (detent != PanelDetent.medium || !_moving || passenger) return false;
    final t = _lastTouch;
    return t != null && now.difference(t) >= kCollapseAfter;
  }

  /// Drive ended: motion forgotten, Passenger back to off.
  void reset() {
    _moving = false;
    _fastSince = _slowSince = _lastTouch = null;
    passenger = false;
  }
}

/// Ping debounce: ignored while a ping is in flight and for 2 s after the last accepted tap (airtime protection).
class PingDebounce {
  static const Duration quiet = Duration(seconds: 2);
  DateTime? _last;

  /// True (and starts the quiet period) when a tap at [now] may send a ping.
  bool accept(DateTime now, {required bool inFlight}) {
    if (inFlight) return false;
    final l = _last;
    if (l != null && now.difference(l) < quiet) return false;
    _last = now;
    return true;
  }
}
