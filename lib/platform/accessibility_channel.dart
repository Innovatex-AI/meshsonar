// Reduce Transparency (spike S10: Flutter exposes no signal for it). A ~10-line iOS channel
// (ios/Runner/HapticsChannel.swift, `app.meshsonar/accessibility`) answers UIAccessibility.isReduceTransparencyEnabled.
// Blurred bars are opaque when it reports on, and also when it is absent (Android, desktop, tests, channel error).
import 'package:flutter/services.dart';

class AccessibilitySignals {
  static const MethodChannel _c = MethodChannel('app.meshsonar/accessibility');

  /// null until asked or when the platform cannot answer.
  static bool? reduceTransparency;

  static Future<bool?> refresh() async {
    try {
      reduceTransparency = await _c.invokeMethod<bool>('reduceTransparency');
    } on MissingPluginException {
      reduceTransparency = null;
    } on PlatformException {
      reduceTransparency = null;
    }
    return reduceTransparency;
  }
}
