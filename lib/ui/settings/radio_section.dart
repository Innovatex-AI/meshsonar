// Settings > Radio: the link to the Radio tab's read-only details, Auto-connect (Always / At launch only / Off), the saved
// radios list, and each radio's antenna setup. Nothing here writes RF settings to a radio. The pinging controls (channel, discovery, interval, distance, listen window) are Wardriving.
import 'package:flutter/material.dart';

import '../design/app_surfaces.dart';
import '../../alerts/alert_prefs.dart';
import '../../alerts/alerts_runtime.dart';
import '../../core/antenna_profile.dart';
import '../antenna_sheet.dart';
import '../app.dart';
import '../radio/radio_screen.dart';
import '../saved_radios_screen.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

/// Under the Auto-connect choices: mid-drive reconnect is not governed by the setting.
const String autoConnectFooter = 'While driving, a dropped radio is always reconnected.';

const String radioHelp = 'What your radio reports, when MeshSonar connects by itself, your saved radios, and how each radio\'s '
    'antenna is set up. Nothing here writes to the radio. '
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
    const SettingsAnchor(id: 'auto-connect', child: AutoConnectTile()),
    const SettingsAnchor(id: 'saved-radios', child: SavedRadiosRow()),
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

/// Settings > Radio > Auto-connect: Always (default), At launch only, Off, with the mid-drive footer.
class AutoConnectTile extends StatelessWidget {
  const AutoConnectTile({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AlertsRuntime?>(
      valueListenable: AlertsHost.runtime,
      builder: (context, rt, _) {
        if (rt == null) {
          return ListTile(
            key: const Key('auto-connect'),
            leading: const Icon(Icons.bluetooth_searching),
            title: Text(settingsEntry('auto-connect').title),
            subtitle: const SettingsWhyNot('Not available in this build: connect from More > Radio.'),
          );
        }
        return ListenableBuilder(
          listenable: rt.prefs,
          builder: (context, _) {
            final t = Theme.of(context);
            final cur = rt.prefs.autoConnect;
            return Column(
              key: const Key('auto-connect'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ListTile(
                  leading: const Icon(Icons.bluetooth_searching),
                  title: Text(settingsEntry('auto-connect').title),
                  subtitle: Text(settingsEntry('auto-connect').summary),
                ),
                for (final m in AutoConnectMode.values)
                  Semantics(
                    inMutuallyExclusiveGroup: true,
                    checked: m == cur,
                    child: ListTile(
                      key: Key('auto-connect-${m.id}'),
                      minTileHeight: 56,
                      leading: Icon(
                        m == cur ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                        color: m == cur ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant,
                      ),
                      title: Text(m.label),
                      subtitle: Text(m.summary),
                      selected: m == cur,
                      onTap: m == cur ? null : () => rt.setAutoConnect(m),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.m),
                  child: Text(autoConnectFooter,
                      key: const Key('auto-connect-footer'),
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Settings > Radio > Saved radios: opens the list (the same one the connect screen shows).
class SavedRadiosRow extends StatelessWidget {
  const SavedRadiosRow({super.key});

  @override
  Widget build(BuildContext context) {
    final store = AlertsHost.runtime.value?.savedRadios;
    final e = settingsEntry('saved-radios');
    if (store == null) {
      return ListTile(
        key: const Key('saved-radios'),
        leading: const Icon(Icons.bluetooth),
        title: Text(e.title),
        subtitle: const SettingsWhyNot('Not available in this build: connect from More > Radio.'),
      );
    }
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final n = store.radios.length;
        final star = store.starred;
        return ListTile(
          key: const Key('saved-radios'),
          leading: const Icon(Icons.bluetooth),
          title: Text(e.title),
          subtitle: Text(n == 0
              ? 'None yet. Every radio you connect to is saved here.'
              : '$n ${n == 1 ? 'radio' : 'radios'}${star != null ? '. Auto-connect: ${star.displayName}' : ''}. '
                  'Connect, nickname, star or forget.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => openSavedRadios(context),
        );
      },
    );
  }
}

/// One saved radio in Settings → Radio: tap to edit, or forget it (it is asked again on its next connect).
class AntennaProfileTile extends StatelessWidget {
  final String radioKey;
  final AntennaProfile profile;
  const AntennaProfileTile({super.key, required this.radioKey, required this.profile});

  Future<void> _forget(BuildContext context, String name) async {
    final s = AppScope.read(context);
    final ok = await showAppAlert(
      context,
      title: 'Forget the antenna of $name?',
      message: 'Its drives keep what they recorded. The next time this radio connects, MeshSonar asks '
          'about its antenna again.',
      confirmLabel: 'Forget',
      destructive: true,
      confirmKey: const Key('antenna-forget-confirm'),
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

