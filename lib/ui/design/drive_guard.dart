// The drive guard: while a drive is active, prompts that the phone raised by itself (permission pre-prompt, link-join
// error, region preset, antenna prompt, telemetry) must not appear over the driving screen. They queue here and are shown,
// in order, the moment the drive ends. Prompts the person asked for (a tap) are never held: pass `userInitiated: true`.
import 'dart:async';

import 'package:flutter/foundation.dart';

class DriveGuard {
  DriveGuard._();
  static final DriveGuard instance = DriveGuard._();

  final ValueNotifier<bool> _driving = ValueNotifier(false);
  final List<_Held> _queue = [];

  ValueListenable<bool> get drivingListenable => _driving;
  bool get driving => _driving.value;
  int get queued => _queue.length;

  /// Called by the app shell whenever `AppState.driving` changes. Flushes the queue when a drive ends.
  void setDriving(bool value) {
    if (_driving.value == value) return;
    _driving.value = value;
    if (!value) _flush();
  }

  /// Runs [show] now when it is allowed, else holds it until the drive ends. The returned future completes with
  /// [show]'s result (or null if it was dropped because [stillValid] said no).
  Future<T?> run<T>(Future<T?> Function() show, {bool userInitiated = true, bool Function()? stillValid}) {
    if (userInitiated || !driving) return show();
    final held = _Held<T>(show, stillValid);
    _queue.add(held);
    return held.completer.future;
  }

  void _flush() {
    final pending = List<_Held>.of(_queue);
    _queue.clear();
    // One at a time, in order: the next prompt waits for the previous one to be dismissed.
    unawaited(() async {
      for (final h in pending) {
        await h.fire();
      }
    }());
  }

  @visibleForTesting
  void reset() {
    _queue.clear();
    _driving.value = false;
  }
}

class _Held<T> {
  final Future<T?> Function() show;
  final bool Function()? stillValid;
  final Completer<T?> completer = Completer<T?>();
  _Held(this.show, this.stillValid);

  Future<void> fire() async {
    if (stillValid != null && !stillValid!()) {
      completer.complete(null);
      return;
    }
    try {
      completer.complete(await show());
    } catch (e, st) {
      completer.completeError(e, st);
    }
  }
}
