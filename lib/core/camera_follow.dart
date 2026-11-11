// Follow-the-car logic for the live map camera. Pure Dart (no Flutter), so the rules are testable without a map.
//
// Andy, Nov 10 2026: the map stays where the person puts it. Pings, position updates, ping results, coverage redraws and panel
// changes never move or zoom a map the person moved; it just draws as it goes.
//
// States:
//   following  the camera moves itself, smoothly, every frame, from the same pose the puck is drawn with. The puck KEEPS ITS
//              PLACE on the screen (where it was when follow started, the middle of the visible area after Recenter); it is
//              only nudged back inside the visible area if something covers it (keepInView). The zoom is never changed.
//   paused     the person panned, zoomed, pinched or rotated the map. The camera is never moved by code again until the
//              Recenter button is tapped (no auto-resume: Andy's call, it reset the view every few seconds).
//
// Options (remembered, MapPrefs): heading-up (the map turns so the direction of travel is up; default north-up), zoom by speed
// (opt-in, default off: zooms out gently at highway speed; the zoom otherwise stays where the person put it).
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier;

class CameraFollow extends ChangeNotifier {
  CameraFollow();

  bool _following = true;
  bool get following => _following;

  int _pointers = 0;

  /// A finger is on the map.
  bool get gestureActive => _pointers > 0;

  void pointerDown() {
    _pointers++;
  }

  void pointerUp() {
    if (_pointers > 0) _pointers--;
  }

  /// The person moved the map with a gesture (pan, pinch, zoom, rotate): follow stops until [resume].
  void userMoved() {
    if (_following) {
      _following = false;
      notifyListeners();
    }
  }

  /// Back to following: only the Recenter button (or a host that never follows switching it on).
  void resume() {
    if (!_following) {
      _following = true;
      notifyListeners();
    }
  }

  /// Per frame: should the camera move itself now? Never while paused, never while a finger is on the map.
  bool get shouldDrive => _following && _pointers == 0;
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
/// overlays (left, top, right, bottom); [fromTop] is how far down the free area the puck goes (0.5, the default, is the middle).
({double dx, double dy}) followAnchor({required double width, required double height, double left = 0, double top = 0, double right = 0, double bottom = 0, double fromTop = 0.5}) {
  final freeW = math.max(0.0, width - left - right);
  final freeH = math.max(0.0, height - top - bottom);
  final ax = left + freeW / 2;
  final ay = top + freeH * fromTop;
  return (dx: ax - width / 2, dy: ay - height / 2);
}

/// Keeps a puck offset ([dx], [dy] from the widget centre, screen pixels) inside the visible part of the map: the free area
/// (the widget minus [left]/[top]/[right]/[bottom] overlays) shrunk by [margin] on each side (at most a quarter of the free
/// size). An offset already inside is returned unchanged, so a puck the person can see is never moved.
({double dx, double dy}) keepInView({required double dx, required double dy, required double width, required double height, double left = 0, double top = 0, double right = 0, double bottom = 0, double margin = 48}) {
  final freeW = math.max(0.0, width - left - right);
  final freeH = math.max(0.0, height - top - bottom);
  final mx = math.min(margin, freeW / 4), my = math.min(margin, freeH / 4);
  final x0 = left + mx - width / 2, x1 = width - right - mx - width / 2;
  final y0 = top + my - height / 2, y1 = height - bottom - my - height / 2;
  return (dx: x1 < x0 ? (x0 + x1) / 2 : dx.clamp(x0, x1).toDouble(), dy: y1 < y0 ? (y0 + y1) / 2 : dy.clamp(y0, y1).toDouble());
}

/// The map rotation (degrees, what flutter_map calls rotation) that puts [headingDeg] at the top of the screen.
double headingUpRotation(double headingDeg) => -headingDeg;
