// Follow-the-car logic for the live map camera. Pure Dart (no Flutter), so the rules are testable without a map.
//
// The camera keeps the puck at a fixed place on the screen (lower third while driving, so more road ahead is visible) and
// moves with it EVERY FRAME, continuously, from the same pose the puck is drawn with: no stepped animations per GPS fix, so
// there is nothing to lag or fight.
//
// States:
//   following  the camera drives itself (default on a drive).
//   paused     the person moved the map. The camera stops driving at once (never fights a finger) and a re-centre button
//              shows. It resumes when the button is tapped, or on its own after [autoResume] with no finger on the map.
//
// Options (remembered, MapPrefs): heading-up (the map turns so the direction of travel is up; default north-up), zoom by speed
// (zooms out gently at highway speed; default off, the zoom stays where the person put it), auto-resume (default 10 s).
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier;

class CameraFollow extends ChangeNotifier {
  CameraFollow({this.autoResume = const Duration(seconds: 10)});

  /// How long after the last touch a paused camera re-centres by itself; null = only the button does.
  Duration? autoResume;

  bool _following = true;
  bool get following => _following;

  int _pointers = 0;
  DateTime? _idleSince;

  /// A finger is on the map.
  bool get gestureActive => _pointers > 0;

  void pointerDown() {
    _pointers++;
  }

  void pointerUp(DateTime now) {
    if (_pointers > 0) _pointers--;
    if (_pointers == 0) _idleSince = now;
  }

  /// The person moved the map with a gesture (pan, pinch, rotate): follow pauses.
  void userMoved(DateTime now) {
    _idleSince = now;
    if (_following) {
      _following = false;
      notifyListeners();
    }
  }

  /// Back to following (the re-centre button, a new drive, a first fix).
  void resume() {
    _idleSince = null;
    if (!_following) {
      _following = true;
      notifyListeners();
    }
  }

  /// Per frame: should the camera move itself now? Applies the auto-resume rule.
  bool shouldDrive(DateTime now) {
    if (!_following) {
      final a = autoResume;
      if (a != null && _pointers == 0 && _idleSince != null && now.difference(_idleSince!) >= a) {
        resume();
      }
    }
    return _following && _pointers == 0;
  }

  /// Seconds left before a paused camera re-centres by itself (null when not paused, no timer, or a finger is down).
  Duration? resumeIn(DateTime now) {
    final a = autoResume;
    if (_following || a == null || _pointers > 0 || _idleSince == null) return null;
    final left = a - now.difference(_idleSince!);
    return left.isNegative ? Duration.zero : left;
  }
}

/// How many zoom levels to zoom OUT at [speedMps] when zoom-by-speed is on: nothing below ~13 mph, easing to
/// [maxLevels] at ~65 mph (a smoothstep, so there is no kink).
double speedZoomOffset(double speedMps, {double maxLevels = 1.3}) {
  const lo = 6.0, hi = 29.0;
  final x = ((speedMps - lo) / (hi - lo)).clamp(0.0, 1.0);
  return -maxLevels * x * x * (3 - 2 * x);
}

/// First-order ease of [current] toward [target] over [dtS] with time constant [tau].
double easeToward(double current, double target, double dtS, double tau) {
  if (dtS <= 0) return current;
  return current + (target - current) * (1 - math.exp(-dtS / tau));
}

/// Where on the map widget the puck sits, as an offset from the widget's centre. [padding] is the part of the widget covered by
/// overlays (left, top, right, bottom); [fromTop] is how far down the free area the puck goes (0.5 centre, 0.66 lower third).
({double dx, double dy}) followAnchor({required double width, required double height, double left = 0, double top = 0, double right = 0, double bottom = 0, double fromTop = 0.66}) {
  final freeW = math.max(0.0, width - left - right);
  final freeH = math.max(0.0, height - top - bottom);
  final ax = left + freeW / 2;
  final ay = top + freeH * fromTop;
  return (dx: ax - width / 2, dy: ay - height / 2);
}

/// The map rotation (degrees, what flutter_map calls rotation) that puts [headingDeg] at the top of the screen.
double headingUpRotation(double headingDeg) => -headingDeg;
