// Settings > Wardriving > Ping feedback: haptic tap and sound when a ping finishes (lib/ui/ping_cue.dart). Sound is off by default.
import 'package:flutter/material.dart';

import '../app.dart';
import '../ping_cue.dart';
import 'settings_kit.dart';

/// The row group for the Wardriving page; one anchor so the search lands on it.
Widget pingFeedbackRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  return SettingsAnchor(
    id: 'ping-feedback',
    child: Column(
      key: const Key('ping-feedback'),
      children: [
        SwitchListTile(
          key: const Key('ping-haptics'),
          secondary: const Icon(Icons.vibration),
          title: const Text('Tap when a ping finishes'),
          subtitle: const Text('Light when heard, firmer when not.'),
          value: st.pingHaptics,
          onChanged: (v) => s.updateSettings(st.copyWith(pingHaptics: v)),
        ),
        SwitchListTile(
          key: const Key('ping-sound'),
          secondary: const Icon(Icons.volume_up_outlined),
          title: const Text('Sound when a ping finishes'),
          subtitle: const Text('A click when heard, another tone when not. Follows the ring/silent switch.'),
          value: st.pingSound,
          onChanged: (v) {
            s.updateSettings(st.copyWith(pingSound: v));
            if (v) PingCue.player.play(heard: true); // a preview, so the person hears what they turned on
          },
        ),
      ],
    ),
  );
}
