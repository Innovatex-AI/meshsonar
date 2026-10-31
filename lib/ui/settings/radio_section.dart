// Settings > Radio: the link to the Radio tab's read-only details, the channel pings go out on, listen-only discovery,
// the auto-ping cadence, and each radio's antenna setup. Nothing here writes RF settings to a radio.
import 'package:flutter/material.dart';

import '../../core/antenna_profile.dart';
import '../antenna_sheet.dart';
import '../app.dart';
import '../radio/radio_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String radioHelp = 'An auto-ping goes out when BOTH are met: the time has passed and you\'ve moved the distance. '
    'Ping now works any time. Changes apply straight away, even mid-drive.';

const String _discoveryReason = 'Off in discovery mode: nothing is transmitted. Turn Discovery (listen-only) off to '
    'use it.';

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
      id: 'channel',
      child: ListTile(
        key: const Key('channel'),
        leading: const Icon(Icons.tag),
        title: const Text('Channel'),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(st.channel),
          const Text('The channel pings are sent on. Use the one your mesh community wardrives on.'),
        ]),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final v = await editSettingText(context,
              title: 'Channel',
              initial: st.channel,
              hint: '#wardriving',
              help: 'The channel pings are sent on. Use the one your mesh community wardrives on.',
              validate: (v) => v.trim().isEmpty ? 'Enter a channel name' : null);
          if (v != null) {
            var c = v.trim();
            if (!c.startsWith('#')) c = '#$c';
            await s.updateSettings(st.copyWith(channel: c));
          }
        },
      ),
    ),
    SettingsAnchor(
      id: 'discovery-mode',
      child: SwitchListTile(
        key: const Key('discovery-mode'),
        secondary: Icon(s.driving ? Icons.lock_outline : Icons.hearing_outlined),
        title: const Text('Discovery (listen-only)'),
        subtitle: s.driving
            ? const SettingsWhyNot('Locked while driving: stop the drive to change it.')
            : const Text('The next drive transmits nothing at all — not even the privacy-hardened ping — and only '
                'records what it overhears from other mesh traffic.'),
        value: st.discoveryMode,
        onChanged: s.driving ? null : (v) => s.updateSettings(st.copyWith(discoveryMode: v)),
      ),
    ),
    SettingsAnchor(
      id: 'interval',
      child: SliderTile(
        key: const Key('interval'),
        sliderKey: const Key('interval-slider'),
        icon: Icons.timer_outlined,
        title: 'Auto-ping',
        stops: intervalStops,
        value: st.intervalSec,
        label: (v) => 'Every $v s',
        caption: 'How often an automatic ping may go out while driving.',
        disabledReason: _discoveryReason,
        minLabel: '10 s',
        maxLabel: '2 min',
        enabled: !st.discoveryMode,
        onChanged: (v) => s.updateSettings(s.settings.copyWith(intervalSec: v)),
      ),
    ),
    SettingsAnchor(
      id: 'min-distance',
      child: SliderTile(
        key: const Key('min-distance'),
        sliderKey: const Key('min-distance-slider'),
        icon: Icons.straighten,
        title: 'Minimum distance',
        stops: s.units.minDistanceStops(distanceStops),
        value: st.minDistanceM,
        label: s.units.sliderDistance,
        caption: 'Skips auto-pings while you\'re stopped at lights.',
        disabledReason: _discoveryReason,
        minLabel: s.units.sliderDistance(s.units.minDistanceStops(distanceStops).first),
        maxLabel: s.units.sliderDistance(s.units.minDistanceStops(distanceStops).last),
        enabled: !st.discoveryMode,
        onChanged: (v) => s.updateSettings(s.settings.copyWith(minDistanceM: v)),
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

