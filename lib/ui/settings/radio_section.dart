// Settings > Radio: the link to the Radio tab's read-only details and each radio's antenna setup. Nothing here writes RF
// settings to a radio. The pinging controls (channel, discovery, interval, distance, listen window) are Wardriving.
import 'package:flutter/material.dart';

import '../../core/antenna_profile.dart';
import '../antenna_sheet.dart';
import '../app.dart';
import '../radio/radio_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String radioHelp = 'What your radio reports, and how each radio\'s antenna is set up. Nothing here writes to the radio. '
    'The channel, ping interval and distance are under Wardriving.';

List<Widget> radioSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  return [
    SettingsAnchor(
      id: 'radio-tab',
      child: ListTile(
        key: const Key('radio-tab-link'),
        leading: const Icon(Icons.settings_input_antenna),
        title: Text(settingsEntry('radio-tab').title),
        subtitle: Text(s.connected
            ? 'Firmware, frequency and the region preset compared field by field. Read-only.'
            : 'No radio connected. More > Radio connects one and then shows what it reports.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RadioScreen())),
      ),
    ),
    SettingsAnchor(
      id: 'antenna',
      child: Column(key: const Key('antenna-group'), children: [
        if (st.antennaProfiles.isEmpty)
          ListTile(
            key: const Key('antenna-none'),
            leading: const Icon(Icons.info_outline),
            title: const Text('No radios set up yet'),
            subtitle: const Text('Connect a radio and MeshSonar asks how its antenna is set up. Tap to open the Radio '
                'tab.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RadioScreen())),
          ),
        for (final e in st.antennaProfiles.entries) AntennaProfileTile(radioKey: e.key, profile: e.value),
      ]),
    ),
  ];
}

/// One saved radio in Settings → Radio: tap to edit, or forget it (it is asked again on its next connect).
class AntennaProfileTile extends StatelessWidget {
  final String radioKey;
  final AntennaProfile profile;
  const AntennaProfileTile({super.key, required this.radioKey, required this.profile});

  Future<void> _forget(BuildContext context, String name) async {
    final s = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Forget the antenna of $name?'),
        content: const Text('Its drives keep what they recorded. The next time this radio connects, MeshSonar asks '
            'about its antenna again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            key: const Key('antenna-forget-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok == true) await s.forgetAntennaProfile(radioKey);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final name = s.radioName(radioKey) ?? 'Radio ${radioKey.length > 8 ? radioKey.substring(0, 8) : radioKey}';
    // The radio in use keeps its antenna until the drive ends (the drive has already recorded it).
    final locked = s.driving && s.selfInfo?.publicKey.toLowerCase() == radioKey;
    return ListTile(
      key: ValueKey('antenna-profile-$radioKey'),
      leading: Icon(locked ? Icons.lock_outline : Icons.settings_input_antenna),
      title: Text(name),
      subtitle: locked
          ? SettingsWhyNot('${profile.summaryIn(s.units)}\nLocked while this radio is on a drive: stop the drive to change it.')
          : Text('${profile.summaryIn(s.units)}\nTap to change; forget it to be asked again on the next connect.'),
      trailing: IconButton(
        key: ValueKey('antenna-forget-$radioKey'),
        tooltip: 'Forget this radio\'s antenna',
        icon: const Icon(Icons.delete_outline),
        onPressed: locked ? null : () => _forget(context, name),
      ),
      onTap: locked ? null : () => showAntennaSheet(context, radioKey: radioKey),
    );
  }
}

