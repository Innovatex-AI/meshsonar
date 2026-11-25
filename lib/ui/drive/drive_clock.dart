// The 1 s clocks of the drive UI (elapsed time, next-ping countdown, dock hero, ping circle, mini bar) run only
// while they are worth drawing: a drive is running, the widget's tab is the visible one (the shell gives hidden tabs a
// disabled TickerMode) and the app is in front. They stop otherwise and restart on return (build 70, battery plan A5).
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../core/power_profile.dart';

/// Whether the app is in front (lifecycle resumed or inactive). Installed once by the first listener; true until told otherwise.
abstract final class UiForeground {
  static final ValueNotifier<bool> notifier = ValueNotifier<bool>(true);
  static _Observer? _observer;

  static bool get value => notifier.value;

  /// Starts following the app lifecycle (idempotent).
  static void ensureObserving() {
    if (_observer != null) return;
    final o = _Observer();
    _observer = o;
    WidgetsBinding.instance.addObserver(o);
    final st = WidgetsBinding.instance.lifecycleState;
    if (st != null) o.didChangeAppLifecycleState(st);
  }

  /// Tests only: back to "in front" and no observer.
  @visibleForTesting
  static void debugReset() {
    final o = _observer;
    if (o != null) WidgetsBinding.instance.removeObserver(o);
    _observer = null;
    notifier.value = true;
  }
}

class _Observer with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    UiForeground.notifier.value = state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;
  }
}

/// A once-a-second rebuild that exists only while [wantClock] says so AND the widget is visible AND the app is in front.
/// Call [wantClock] from build (it reads TickerMode, so a tab switch rebuilds and re-evaluates it).
mixin DriveClock<T extends StatefulWidget> on State<T> {
  Timer? _clock;
  bool _want = false;

  /// True while the 1 s timer exists (tests).
  bool get clockRunning => _clock != null;

  /// Called every second while running; rebuilds by default.
  void onClockTick() => setState(() {});

  @override
  void initState() {
    super.initState();
    UiForeground.ensureObserving();
    UiForeground.notifier.addListener(_foregroundChanged);
  }

  void _foregroundChanged() {
    if (!mounted) return;
    if (UiForeground.value) {
      setState(() {}); // back in front: build re-evaluates (and catches up the shown time)
    } else {
      _set(false);
    }
  }

  /// [on]: the widget has something live to count (a drive is running). Visibility and the foreground are added here.
  void wantClock(bool on) {
    _want = on;
    _set(_want && TickerMode.valuesOf(context).enabled && UiForeground.value);
  }

  void _set(bool run) {
    if (run && _clock == null) {
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        PowerCounters.inc(PowerCounters.timerWake);
        onClockTick();
      });
    } else if (!run && _clock != null) {
      _clock!.cancel();
      _clock = null;
    }
  }

  @override
  void dispose() {
    _clock?.cancel();
    _clock = null;
    UiForeground.notifier.removeListener(_foregroundChanged);
    super.dispose();
  }
}
