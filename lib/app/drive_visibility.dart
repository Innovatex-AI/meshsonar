// Signals the battery-saving code reads to know whether the Drive map is worth feeding (build 70, battery plan A2):
//  * [DriveVisibility.visible]: the Drive tab is the selected tab AND the app is in front. Set from the shell's tab changes
//    (lib/ui/shell/home_shell.dart) and the app lifecycle (observed here).
//  * [DriveVisibility.slow]: the drive's GPS speed is under ~2 m/s or unknown (the puck has no usable course then). Set from the
//    drive's GpsMonitor on every fix that carries a speed.
// The compass (lib/platform/compass_sensors_plus.dart) runs in Auto mode only while both are true.
import 'package:flutter/widgets.dart';

abstract final class DriveVisibility {
  /// Drive tab selected and the app in front.
  static final ValueNotifier<bool> visible = ValueNotifier<bool>(true);

  /// GPS speed below [slowBelowMps] (or unknown).
  static final ValueNotifier<bool> slow = ValueNotifier<bool>(true);

  /// Under this the car counts as slow or stopped.
  static const double slowBelowMps = 2.0;

  static bool _driveTab = true;
  static bool _foreground = true;
  static _LifecycleObserver? _observer;

  static void _update() => visible.value = _driveTab && _foreground;

  /// The shell selected a tab.
  static void setDriveTab(bool onDrive) {
    _driveTab = onDrive;
    _update();
  }

  /// The app went to the background / came back.
  static void setForeground(bool front) {
    _foreground = front;
    _update();
  }

  /// A drive fix with [speedMps] (null = not measured; leaves the state as it is).
  static void noteSpeed(double? speedMps) {
    if (speedMps == null) return;
    slow.value = speedMps < slowBelowMps;
  }

  /// Starts following the app lifecycle (idempotent).
  static void ensureObserving() {
    if (_observer != null) return;
    try {
      final o = _LifecycleObserver();
      WidgetsBinding.instance.addObserver(o);
      _observer = o;
      final st = WidgetsBinding.instance.lifecycleState;
      if (st != null) o.didChangeAppLifecycleState(st);
    } catch (_) {}
  }

  /// Tests only.
  @visibleForTesting
  static void debugReset() {
    final o = _observer;
    if (o != null) WidgetsBinding.instance.removeObserver(o);
    _observer = null;
    _driveTab = true;
    _foreground = true;
    visible.value = true;
    slow.value = true;
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      DriveVisibility.setForeground(state == AppLifecycleState.resumed || state == AppLifecycleState.inactive);
}
