// Settings > Observer (release 0.38, observer-everywhere-mqtt-plan-2026-11-15.md section 3.3): the one place that says
// whether this phone is an observer, and (as the observer work lands) the master switch, the MQTT feeds and their status.
// The section keeps its search entries here ([observerSettingsEntries], spread into settings_index.dart) next to the rows
// they point at, so the observer work never edits the shared Settings files. [observerStatusLine] is also the subtitle of
// More > Observer.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../app.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

/// The searchable rows of this section, in display order. Each id is a SettingsAnchor in [observerSectionRows].
const List<SettingsEntry> observerSettingsEntries = [
  SettingsEntry('observer-status', 'observer', 'Observer status',
      'Whether this phone is sharing the public packets its radio hears right now, and what it is waiting for if not.',
      keywords: ['observer', 'status', 'sharing', 'listening', 'packets', 'radio connected', 'mqtt', 'feeds'], info: true),
];

const String observerHelp =
    'While your radio is connected and the app is open, this phone can act as an observer: it shares the public '
    'packets its radio hears (never private messages or private channels).';

/// One line on what the observer is doing now, in plain words (More > Observer and the status row).
String observerStatusLine(AppState s) {
  if (!s.settings.telemetryEnabled) {
    return 'Off. Turn on "Share with MeshSonar" under Privacy & data sharing to share again.';
  }
  if (s.observerSharing) {
    return s.connected
        ? 'On: sharing the public packets your radio hears while the app is open.'
        : 'On: starts when your radio is connected.';
  }
  if (s.connected && s.radioKind == RadioKind.simulator) return 'The simulator is connected: nothing is shared from it.';
  if (!s.keyApproved) return 'On: starts once this phone\'s driver key is approved.';
  return 'On: starts after you have seen what MeshSonar shares (the sheet shown on first launch).';
}

List<Widget> observerSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  return [
    SettingsAnchor(
      id: 'observer-status',
      child: InfoTile(
        key: const Key('observer-status'),
        icon: s.observerSharing && s.connected ? Icons.sensors : Icons.sensors_off,
        title: settingsEntry('observer-status').title,
        subtitle: observerStatusLine(s),
      ),
    ),
  ];
}
