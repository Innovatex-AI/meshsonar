// The tiny iOS haptics channel (ios/Runner/HapticsChannel.swift): notification feedback (success / warning / error) and
// soft impacts, which Flutter's HapticFeedback does not expose. Anywhere the channel is missing (Android, desktop,
// tests) the call falls back to HapticFeedback pairs.
import 'package:flutter/services.dart';

class HapticsChannel {
  static const MethodChannel _c = MethodChannel('app.meshsonar/haptics');

  /// [kind] is success, warning or error.
  Future<void> notify(String kind) async {
    try {
      await _c.invokeMethod<void>('notify', kind);
    } on MissingPluginException {
      await _fallback(kind);
    } on PlatformException {
      await _fallback(kind);
    }
  }

  /// [style] is soft, light or medium.
  Future<void> impact(String style) async {
    try {
      await _c.invokeMethod<void>('impact', style);
    } on MissingPluginException {
      await HapticFeedback.lightImpact();
    } on PlatformException {
      await HapticFeedback.lightImpact();
    }
  }

  static Future<void> _fallback(String kind) async {
    switch (kind) {
      case 'success':
        await HapticFeedback.lightImpact();
        await HapticFeedback.mediumImpact();
      case 'warning':
        await HapticFeedback.mediumImpact();
      default:
        await HapticFeedback.heavyImpact();
        await HapticFeedback.heavyImpact();
    }
  }
}
