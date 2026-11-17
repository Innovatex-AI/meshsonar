// iPhone Low Power Mode -> PowerProfile.setLowPowerMode (battery plan §3 "Low Power Mode follow"). Native side: the
// `meshsonar/power` method channel (current state) and `meshsonar/power/events` event channel (NSProcessInfoPowerStateDidChange)
// in ios/Runner/AppDelegate.swift. A no-op on every other platform and wherever the channel is missing (tests).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/power_profile.dart';

abstract final class LowPowerModeFollower {
  static const MethodChannel _method = MethodChannel('meshsonar/power');
  static const EventChannel _events = EventChannel('meshsonar/power/events');
  static StreamSubscription<dynamic>? _sub;

  /// Reads the current state and follows changes. Idempotent.
  static Future<void> start({@visibleForTesting bool? isIOS}) async {
    final ios = isIOS ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS);
    if (!ios || _sub != null) return;
    try {
      _sub = _events.receiveBroadcastStream().listen((v) {
        if (v is bool) PowerProfile.setLowPowerMode(v);
      }, onError: (Object _) {});
    } catch (_) {}
    try {
      final on = await _method.invokeMethod<bool>('isOn');
      if (on != null) PowerProfile.setLowPowerMode(on);
    } catch (_) {}
  }

  /// Tests only.
  @visibleForTesting
  static Future<void> debugStop() async {
    await _sub?.cancel();
    _sub = null;
  }
}
