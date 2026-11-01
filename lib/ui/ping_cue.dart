// What the phone does when a ping finishes (Settings > Wardriving > "Ping feedback"): a haptic tap and/or a short sound,
// different for "heard" and "heard nothing", so you can drive without looking. Haptics are on by default (they always were);
// sound is OFF by default (a car radio, a passenger and a phone that suddenly beeps are the person's call to make).
//
// The sound is the platform's own system sound (SystemSound.click for heard, SystemSound.alert for heard nothing): no audio
// file, no new plugin, no new permission. On a platform without one it is silently nothing. [PingCue.player] is the seam widget
// tests replace.
import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../core/api.dart' show Settings;
import 'device_feedback.dart';

/// Plays the sound for a ping result.
abstract class PingSoundPlayer {
  Future<void> play({required bool heard});
}

class SystemPingSoundPlayer implements PingSoundPlayer {
  const SystemPingSoundPlayer();
  @override
  Future<void> play({required bool heard}) async {
    try {
      await SystemSound.play(heard ? SystemSoundType.click : SystemSoundType.alert);
    } catch (_) {
      // No system sound on this platform: the haptic (if on) is still the signal.
    }
  }
}

class NoPingSound implements PingSoundPlayer {
  const NoPingSound();
  @override
  Future<void> play({required bool heard}) async {}
}

abstract final class PingCue {
  /// Tests swap this; under `flutter test` the default makes no platform call.
  static PingSoundPlayer player = _inFlutterTest() ? const NoPingSound() : const SystemPingSoundPlayer();

  /// Fires the cues [settings] asks for, for one finished ping: the haptic through [feedback], the sound through [player].
  static Future<void> ping(Settings settings, DeviceFeedback? feedback, {required bool heard}) async {
    if (settings.pingHaptics) await feedback?.pingResult(heard: heard);
    if (settings.pingSound) await player.play(heard: heard);
  }
}

bool _inFlutterTest() {
  try {
    return Platform.environment.containsKey('FLUTTER_TEST');
  } catch (_) {
    return false;
  }
}
