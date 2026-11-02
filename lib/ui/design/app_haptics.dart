// Haptics (chat plan 2.2): selection = segment change, toggle, picker; light = send tap, pin, swipe commit; soft =
// incoming message in the open conversation (rate limited to once per 3 s); success / warning / error go through the
// iOS notification generator (lib/platform/haptics_channel.dart), with a heavyImpact fallback elsewhere.
// The "Haptics" setting (Settings > Units & display, default on) switches all of it off through [enabled].
import 'package:flutter/services.dart';

import '../../platform/haptics_channel.dart';

abstract final class AppHaptics {
  /// Mirrors Settings.haptics; written by the app shell when the setting changes.
  static bool enabled = true;

  static DateTime? _lastSoft;
  static HapticsChannel channel = HapticsChannel();

  /// Test seam for the clock.
  static DateTime Function() now = DateTime.now;

  static Future<void> selection() async {
    if (enabled) await HapticFeedback.selectionClick();
  }

  static Future<void> light() async {
    if (enabled) await HapticFeedback.lightImpact();
  }

  /// Incoming message in the open conversation; at most one per 3 s.
  static Future<void> soft() async {
    if (!enabled) return;
    final t = now();
    final last = _lastSoft;
    if (last != null && t.difference(last) < const Duration(seconds: 3)) return;
    _lastSoft = t;
    await channel.impact('soft');
  }

  static Future<void> success() async {
    if (enabled) await channel.notify('success');
  }

  static Future<void> warning() async {
    if (enabled) await channel.notify('warning');
  }

  static Future<void> error() async {
    if (enabled) await channel.notify('error');
  }

  static void resetForTest() {
    enabled = true;
    _lastSoft = null;
    now = DateTime.now;
    channel = HapticsChannel();
  }
}
