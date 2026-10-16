// Screen wake lock and haptics behind a tiny interface, so widget tests can swap in a fake and never touch platform
// channels. The Drive screen reads it from [DeviceFeedbackScope] (falls back to the real one).
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

abstract class DeviceFeedback {
  /// Keep the screen on (true) or let it sleep (false).
  Future<void> keepAwake(bool on);

  /// A subtle tick when a ping finishes: [heard] gets a light tap, "heard nothing" a medium one.
  Future<void> pingResult({required bool heard});
}

class PlatformDeviceFeedback implements DeviceFeedback {
  const PlatformDeviceFeedback();

  @override
  Future<void> keepAwake(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (_) {
      // Unsupported platform or plugin missing: the app works, the screen may just dim.
    }
  }

  @override
  Future<void> pingResult({required bool heard}) async {
    try {
      await (heard ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact());
    } catch (_) {}
  }
}

/// Provides a [DeviceFeedback] to the widget tree (tests insert a fake).
class DeviceFeedbackScope extends InheritedWidget {
  final DeviceFeedback feedback;
  const DeviceFeedbackScope({super.key, required this.feedback, required super.child});

  /// Used when no scope is in the tree. Tests may replace it (and restore it in tearDown).
  /// Under `flutter test` this is a no-op, so widget tests never reach platform channels.
  static DeviceFeedback fallback = _inFlutterTest() ? const NoDeviceFeedback() : const PlatformDeviceFeedback();

  static DeviceFeedback of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<DeviceFeedbackScope>()?.feedback ?? fallback;

  @override
  bool updateShouldNotify(DeviceFeedbackScope old) => !identical(old.feedback, feedback);
}

/// Does nothing (tests, unsupported platforms).
class NoDeviceFeedback implements DeviceFeedback {
  const NoDeviceFeedback();
  @override
  Future<void> keepAwake(bool on) async {}
  @override
  Future<void> pingResult({required bool heard}) async {}
}

bool _inFlutterTest() {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}
