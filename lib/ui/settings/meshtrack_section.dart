// Settings > MeshTrack (plan section 7): Groups (opens the Group sheet; "Share on every drive" lives in each group's
// menu there), "Position friends see" (Exact / Approximate), Rate (Smart / Low traffic) and Answer "Where are you?"
// while sharing. The position choice is never called "precision": that word belongs to Settings > Observer.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../meshtrack/group_sheet.dart' show showGroupSheet;
import '../meshtrack/meshtrack_binding.dart';
import '../meshtrack/meshtrack_copy.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String meshTrackHelp = 'See friends on the map while you drive. Your position goes only to your group, never to MeshSonar\'s servers.';

/// The Settings entries of this section, spread into settings_index.dart in display order.
const List<SettingsEntry> meshTrackSettingsEntries = [
  SettingsEntry('meshtrack-groups', 'meshtrack', 'Groups',
      'Your MeshTrack groups: whose positions you see and who gets yours. Make, join, invite or leave a group.',
      keywords: ['meshtrack', 'track', 'tracking', 'friends', 'group', 'family', 'share', 'share location', 'location', 'position', 'where', 'invite', 'join', 'new group', 'qr', 'map', 'crew'],
      available: meshTrackAvailable),
  SettingsEntry('meshtrack-position', 'meshtrack', 'Position friends see',
      'Exact sends where you are to within a few steps. Approximate sends only the neighbourhood.',
      keywords: ['meshtrack', 'exact', 'approximate', 'rough', 'privacy', 'location', 'friends'], available: meshTrackAvailable),
  SettingsEntry('meshtrack-rate', 'meshtrack', 'Update rate',
      'Smart sends more often at speed and on turns and nothing while parked. Low traffic sends half as often.',
      keywords: ['meshtrack', 'rate', 'how often', 'interval', 'airtime', 'low traffic', 'smart'], available: meshTrackAvailable),
  SettingsEntry('meshtrack-answer', 'meshtrack', 'Answer "Where are you?"',
      'While you share with a group, a friend\'s "Where are you?" gets your position back.',
      keywords: ['meshtrack', 'request', 'where are you', 'answer', 'reply', 'ask'], available: meshTrackAvailable),
];

/// MeshTrack is in this build (AppFlags.meshTrack) and wired.
bool meshTrackAvailable(AppState s) => MeshTrackUi.forState(s) != null;

List<Widget> meshTrackSectionRows(BuildContext context) {
  final b = MeshTrackUi.of(context);
  if (b == null) return const [];
  return [_MeshTrackRows(binding: b)];
}

class _MeshTrackRows extends StatelessWidget {
  final MeshTrackBinding binding;
  const _MeshTrackRows({required this.binding});

  @override
  Widget build(BuildContext context) {
    final b = binding;
    return ListenableBuilder(
      listenable: Listenable.merge([b.ops, _ServiceListenable(b.service)]),
      builder: (context, _) {
        final t = Theme.of(context);
        final st = b.service.state;
        final n = st.groups.length;
        final sharing = st.sharingCount;
        final groupsSub = n == 0
            ? 'No groups yet. Make one or join a friend\'s.'
            : '$n ${n == 1 ? 'group' : 'groups'}${sharing > 0 ? ', sharing with $sharing' : ''}';
        Widget choice<T>(String keyBase, T value, T current, String label, String summary, Future<void> Function(T) set) => Semantics(
              inMutuallyExclusiveGroup: true,
              checked: value == current,
              child: ListTile(
                key: Key('$keyBase-${(value as Enum).name}'),
                minTileHeight: 56,
                leading: Icon(
                  value == current ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: value == current ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
                ),
                title: Text(label),
                subtitle: Text(summary),
                selected: value == current,
                onTap: value == current ? null : () => unawaited(set(value)),
              ),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SettingsAnchor(
            id: 'meshtrack-groups',
            child: ListTile(
              key: const Key('meshtrack-groups'),
              leading: const Icon(Icons.people_alt_outlined),
              title: Text(settingsEntry('meshtrack-groups').title),
              subtitle: Text(groupsSub),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unawaited(showGroupSheet(context)),
            ),
          ),
          const Divider(height: 1),
          SettingsAnchor(
            id: 'meshtrack-position',
            child: Column(key: const Key('meshtrack-position'), crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                leading: const Icon(Icons.my_location),
                title: Text(settingsEntry('meshtrack-position').title),
                subtitle: Text(settingsEntry('meshtrack-position').summary),
              ),
              for (final m in MtPositionMode.values)
                choice<MtPositionMode>('meshtrack-position', m, b.ops.positionMode, mtPositionModeLabel(m, b.units),
                    m == MtPositionMode.exact ? 'Friends can find your car in a parking lot.' : 'Friends see the area you are in, not the street.',
                    b.ops.setPositionMode),
            ]),
          ),
          const Divider(height: 1),
          SettingsAnchor(
            id: 'meshtrack-rate',
            child: Column(key: const Key('meshtrack-rate'), crossAxisAlignment: CrossAxisAlignment.start, children: [
              ListTile(
                leading: const Icon(Icons.speed),
                title: Text(settingsEntry('meshtrack-rate').title),
                subtitle: Text(settingsEntry('meshtrack-rate').summary),
              ),
              for (final r in MtRate.values)
                choice<MtRate>('meshtrack-rate', r, b.ops.rate, mtRateLabel(r),
                    r == MtRate.smart ? 'About every minute on the highway, every 5 min in slow traffic.' : 'Half as often: gentler on a busy mesh.',
                    b.ops.setRate),
            ]),
          ),
          const Divider(height: 1),
          SettingsAnchor(
            id: 'meshtrack-answer',
            child: SwitchListTile(
              key: const Key('meshtrack-answer'),
              secondary: const Icon(Icons.reply),
              title: Text(settingsEntry('meshtrack-answer').title),
              subtitle: const Text('Only while you share with that group, and never from inside a privacy zone.'),
              value: b.ops.answerRequests,
              onChanged: (v) => unawaited(b.ops.setAnswerRequests(v)),
            ),
          ),
        ]);
      },
    );
  }
}

/// MeshTrackService has the Listenable shape without implementing Listenable; this adapts it.
class _ServiceListenable extends Listenable {
  final MeshTrackService s;
  _ServiceListenable(this.s);
  @override
  void addListener(VoidCallback listener) => s.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => s.removeListener(listener);
}
