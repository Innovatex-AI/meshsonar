// Settings > Wardriving: everything that decides when and how a drive pings. Channel, discovery (listen-only), how often,
// how far apart, and how long each ping listens for echoes. The same three cadence sliders open from the Map tab
// ("Ping settings", lib/ui/drive/ping_settings_sheet.dart). Changes apply straight away, even mid-drive
// (AppState._applyPingCadence -> engine.updateConfig).
import 'package:flutter/material.dart';

import '../../core/api.dart' show Settings;
import '../app.dart';
import 'settings_kit.dart';

const String wardrivingHelp =
    'An auto-ping goes out when BOTH are met: the time has passed and you\'ve moved the distance. '
    'Ping now works any time. Changes apply straight away, even mid-drive.';

const String _discoveryReason =
    'Off in discovery mode: nothing is transmitted. Turn Discovery (listen-only) off to '
    'use it.';

/// The three cadence sliders. [prefix] keeps the keys of the Settings copy and the Map tab's quick sheet apart.
List<Widget> pingCadenceTiles(BuildContext context, {String prefix = ''}) {
  final s = AppScope.of(context);
  final st = s.settings;
  final units = s.units;
  return [
    SliderTile(
      key: Key('${prefix}interval'),
      sliderKey: Key('${prefix}interval-slider'),
      icon: Icons.timer_outlined,
      title: 'Auto-ping',
      stops: intervalStops,
      value: st.intervalSec,
      label: (v) => 'Every $v s',
      caption:
          'How often an automatic ping may go out while driving. Shorter maps more, but uses more airtime on the '
          'shared mesh.',
      disabledReason: _discoveryReason,
      minLabel: '10 s',
      maxLabel: '2 min',
      enabled: !st.discoveryMode,
      onChanged: (v) => s.updateSettings(s.settings.copyWith(intervalSec: v)),
    ),
    SliderTile(
      key: Key('${prefix}min-distance'),
      sliderKey: Key('${prefix}min-distance-slider'),
      icon: Icons.straighten,
      title: 'Minimum distance',
      stops: units.minDistanceStops(distanceStops),
      value: st.minDistanceM,
      label: units.sliderDistance,
      caption: 'Skips auto-pings while you\'re stopped at lights: the next one waits until you have moved this far.',
      disabledReason: _discoveryReason,
      minLabel: units.sliderDistance(units.minDistanceStops(distanceStops).first),
      maxLabel: units.sliderDistance(units.minDistanceStops(distanceStops).last),
      enabled: !st.discoveryMode,
      onChanged: (v) => s.updateSettings(s.settings.copyWith(minDistanceM: v)),
    ),
    SliderTile(
      key: Key('${prefix}listen-window'),
      sliderKey: Key('${prefix}listen-window-slider'),
      icon: Icons.hearing_outlined,
      title: 'Listen window',
      stops: listenStops,
      value: st.listenWindowSec,
      label: (v) => '$v s',
      caption:
          'How long each ping waits for repeaters to answer. Longer hears slower and more distant repeaters. It is '
          'also the shortest gap between two pings. Default 7 s.',
      disabledReason: _discoveryReason,
      minLabel: '${Settings.minListenSec} s',
      maxLabel: '${Settings.maxListenSec} s',
      enabled: !st.discoveryMode,
      onChanged: (v) => s.updateSettings(s.settings.copyWith(listenWindowSec: v)),
    ),
  ];
}

List<Widget> wardrivingSectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  final tiles = pingCadenceTiles(context);
  return [
    SettingsAnchor(
      id: 'channel',
      child: ListTile(
        key: const Key('channel'),
        leading: const Icon(Icons.tag),
        title: const Text('Channel'),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(st.channel),
            const Text('The channel pings are sent on. Use the one your mesh community wardrives on.'),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () async {
          final v = await editSettingText(
            context,
            title: 'Channel',
            initial: st.channel,
            hint: '#wardriving',
            help: 'The channel pings are sent on. Use the one your mesh community wardrives on.',
            validate: (v) => v.trim().isEmpty ? 'Enter a channel name' : null,
          );
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
            : const Text(
                'The next drive transmits nothing at all — not even the privacy-hardened ping — and only '
                'records what it overhears from other mesh traffic.',
              ),
        value: st.discoveryMode,
        onChanged: s.driving ? null : (v) => s.updateSettings(st.copyWith(discoveryMode: v)),
      ),
    ),
    SettingsAnchor(id: 'interval', child: tiles[0]),
    SettingsAnchor(id: 'min-distance', child: tiles[1]),
    SettingsAnchor(id: 'listen-window', child: tiles[2]),
  ];
}
