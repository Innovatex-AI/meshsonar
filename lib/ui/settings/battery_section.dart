// Settings > Battery (build 70, meshsonar-infra docs/planning/battery-efficiency-plan-2026-11-16.md §3): "What's running
// now" at the top, the battery mode (Max data / Balanced / Saver, "Custom" once a knob was changed), the Low Power Mode
// follow switch, then every knob. Everything reads and writes the one app-wide profile (lib/core/power_profile.dart):
// a mode applies its preset, a knob calls PowerProfile.set(chosen.tweak(...)). The components obey PowerProfile.current
// themselves; this file only sets and shows it.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/drive_report_battery.dart' show batteryModeLabel;
import '../../core/observer_engine.dart' show ObserverFeedState;
import '../../core/power_profile.dart';
import '../app.dart';
import '../design/app_surfaces.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String batteryHelp = 'Each power setting on its own. Changing one makes the mode Custom.';

const List<String> _kw = ['battery', 'power', 'energy', 'drain', 'saver'];

/// The Settings entries of this section, spread into settings_index.dart in display order.
const List<SettingsEntry> batterySettingsEntries = [
  SettingsEntry('battery-running', 'wardriving', 'What\'s running now',
      'A live list of what is using power at this moment, each with the setting that changes it.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'running', 'now', 'live', 'what uses', 'gps', 'compass', 'mqtt', 'meshtrack', 'screen on']),
  SettingsEntry('battery-mode', 'wardriving', 'Battery mode',
      'Max data, Balanced or Saver: sets every setting below at once. Changing one of them shows Custom.',
      was: 'Battery', keywords: [..._kw, 'mode', 'max data', 'balanced', 'custom', 'preset', 'battery life', 'low power']),
  SettingsEntry('battery-low-power', 'wardriving', 'Use Saver when iPhone Low Power Mode is on',
      'While Low Power Mode is on, MeshSonar uses Saver; your own choice comes back when it is off.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'low power', 'low power mode', 'iphone', 'ios', 'follow', 'automatic']),
  SettingsEntry('battery-screen-on', 'wardriving', 'Keep screen on during a drive',
      'Never lets the phone lock normally; the map and the drive keep running.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'screen on', 'screen', 'wakelock', 'awake', 'lock', 'display', 'sleep']),
  SettingsEntry('battery-map-fps', 'wardriving', 'Map smoothness',
      'How many times a second the map and your position dot are redrawn while they move.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'fps', 'frames', 'hz', 'smooth', 'refresh rate', '120', 'promotion', 'animation']),
  SettingsEntry('battery-gps', 'wardriving', 'Drive GPS precision',
      'How hard the GPS works during a drive. Every ping still asks for a fresh position.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'gps', 'location', 'accuracy', 'precision', 'track', 'navigation']),
  SettingsEntry('battery-gps-pause', 'wardriving', 'Pause GPS when parked',
      'After this long without moving, the GPS drops to low accuracy until the phone moves off again.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'gps', 'parked', 'stopped', 'idle', 'pause', 'still']),
  SettingsEntry('battery-end-drive', 'wardriving', 'End a drive left open',
      'Ends and saves a drive that was left running while parked or with no radio. Nothing is deleted.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'auto stop', 'forgot', 'left open', 'end drive', 'stop drive', 'parked', 'no radio', 'timeout']),
  SettingsEntry('battery-compass', 'wardriving', 'Compass on the map',
      'Turns the map and the position dot with the phone\'s compass. Off uses the GPS direction of travel.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'compass', 'heading', 'magnetometer', 'direction', 'rotate', 'sensor']),
  SettingsEntry('battery-radio-checks', 'wardriving', 'Check radio for messages',
      'A backup check for new messages. The radio\'s own alert still delivers a message right away.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'radio', 'messages', 'poll', 'check', 'bluetooth', 'ble', 'sync', 'push']),
  SettingsEntry('battery-observer-uploads', 'wardriving', 'Observer uploads when locked',
      'How often heard packets upload while the phone is locked. Nothing is lost; they wait in a queue.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'observer', 'upload', 'telemetry', 'packets', 'locked', 'background', 'queue']),
  SettingsEntry('battery-drive-upload', 'wardriving', 'Drive data upload',
      'Off waits until the drive ends to upload its pings, so the phone radio stays quiet while you drive.',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'upload', 'sync', 'during', 'while driving', 'cellular', 'data']),
  SettingsEntry('battery-stats', 'wardriving', 'Radio and phone stats',
      'How often the drive report records radio and phone readings (battery, temperature, pressure).',
      page: 'battery', was: 'Battery', keywords: [..._kw, 'stats', 'telemetry', 'samples', 'radio battery', 'report', 'interval']),
];

// ---------------------------------------------------------------- the knobs: one description each

/// One choice of a knob: the value, its label and a short hint.
class PowerChoice<T> {
  final T value;
  final String label;
  final String? hint;
  const PowerChoice(this.value, this.label, [this.hint]);
}

/// A knob with a fixed set of choices: how to read it, how to change it, and its words.
class PowerKnob<T> {
  final String id;
  final IconData icon;
  final List<PowerChoice<T>> choices;
  final T Function(PowerSettings s) read;
  final PowerSettings Function(PowerSettings s, T v) write;

  /// A sheet title when one row holds two knobs ("End a drive left open" has parked and no radio).
  final String? subTitle;

  /// Words for a value outside [choices] (an older saved profile); default `'$v'`.
  final String Function(T v)? other;
  const PowerKnob(this.id, this.icon, this.choices, this.read, this.write, {this.subTitle, this.other});

  String get title => subTitle ?? settingsEntry(id).title;

  /// The label of [s]'s value; a value outside the choices (an older saved profile) still reads in plain words.
  String labelOf(PowerSettings s) {
    final v = read(s);
    for (final c in choices) {
      if (c.value == v) return c.label;
    }
    return other?.call(v) ?? '$v';
  }
}

String _secs(int s) => s == 0 ? 'Never' : (s % 60 == 0 ? '${s ~/ 60} min' : '$s s');
String _mins(int m) => m == 0 ? 'Never' : '$m min';

final screenOnKnob = PowerKnob<ScreenOnMode>(
  'battery-screen-on',
  Icons.light_mode_outlined,
  const [
    PowerChoice(ScreenOnMode.always, 'Always', 'The screen stays on for the whole drive, on any tab.'),
    PowerChoice(ScreenOnMode.driveTabOnly, 'Drive tab only', 'On while the Drive tab is open; other tabs lock as usual.'),
    PowerChoice(ScreenOnMode.never, 'Never', 'The phone locks normally. The drive keeps running.'),
  ],
  (s) => s.screenOn,
  (s, v) => s.copyWith(screenOn: v),
);

final mapFpsKnob = PowerKnob<int>(
  'battery-map-fps',
  Icons.animation_outlined,
  const [
    PowerChoice(120, '120 Hz', 'Smoothest on a ProMotion screen.'),
    PowerChoice(60, '60 Hz', 'Smooth, about half the drawing.'),
    PowerChoice(30, '30 Hz', 'Steady, least drawing.'),
  ],
  (s) => s.mapFps,
  (s, v) => s.copyWith(mapFps: v),
  other: (v) => '$v Hz',
);

final gpsKnob = PowerKnob<GpsPrecision>(
  'battery-gps',
  Icons.gps_fixed,
  const [
    PowerChoice(GpsPrecision.best, 'Best', 'Navigation accuracy, every movement.'),
    PowerChoice(GpsPrecision.high, 'High', 'Best accuracy, a new fix after every short move.'),
    PowerChoice(GpsPrecision.standard, 'Standard (less precise drive track)', 'Street-level accuracy, fewer fixes.'),
  ],
  (s) => s.gps,
  (s, v) => s.copyWith(gps: v),
);

final gpsPauseKnob = PowerKnob<int>(
  'battery-gps-pause',
  Icons.local_parking,
  const [
    PowerChoice(0, 'Never'),
    PowerChoice(1, 'After 1 min still'),
    PowerChoice(3, 'After 3 min still'),
    PowerChoice(5, 'After 5 min still'),
  ],
  (s) => s.pauseGpsParkedMin,
  (s, v) => s.copyWith(pauseGpsParkedMin: v),
  other: _mins,
);

final endParkedKnob = PowerKnob<int>(
  'battery-end-drive',
  Icons.local_parking,
  const [PowerChoice(0, 'Never'), PowerChoice(15, 'After 15 min'), PowerChoice(30, 'After 30 min'), PowerChoice(60, 'After 60 min')],
  (s) => s.endDriveParkedMin,
  (s, v) => s.copyWith(endDriveParkedMin: v),
  other: _mins,
  subTitle: 'Parked',
);

final endNoRadioKnob = PowerKnob<int>(
  'battery-end-drive',
  Icons.bluetooth_disabled,
  const [PowerChoice(0, 'Never'), PowerChoice(5, 'After 5 min'), PowerChoice(15, 'After 15 min'), PowerChoice(30, 'After 30 min')],
  (s) => s.endDriveNoRadioMin,
  (s, v) => s.copyWith(endDriveNoRadioMin: v),
  other: _mins,
  subTitle: 'No radio',
);

final compassKnob = PowerKnob<CompassMode>(
  'battery-compass',
  Icons.explore_outlined,
  const [
    PowerChoice(CompassMode.always, 'Always', 'On for the whole drive.'),
    PowerChoice(CompassMode.auto, 'Auto', 'Only on the Drive tab, when slow or stopped.'),
    PowerChoice(CompassMode.off, 'Off', 'The position dot follows the GPS direction of travel.'),
  ],
  (s) => s.compass,
  (s, v) => s.copyWith(compass: v),
);

final radioFrontKnob = PowerKnob<int>(
  'battery-radio-checks',
  Icons.phone_iphone,
  const [PowerChoice(5, 'Every 5 s'), PowerChoice(30, 'Every 30 s'), PowerChoice(120, 'Every 2 min')],
  (s) => s.radioPollFrontS,
  (s, v) => s.copyWith(radioPollFrontS: v),
  other: _secs,
  subTitle: 'App open',
);

final radioBackKnob = PowerKnob<int>(
  'battery-radio-checks',
  Icons.lock_outline,
  const [
    PowerChoice(5, 'Every 5 s'),
    PowerChoice(120, 'Every 2 min'),
    PowerChoice(0, 'Radio alert only', 'No backup check; the radio\'s own alert still arrives right away.'),
  ],
  (s) => s.radioPollBackS,
  (s, v) => s.copyWith(radioPollBackS: v),
  other: _secs,
  subTitle: 'Phone locked',
);

final observerUploadKnob = PowerKnob<int>(
  'battery-observer-uploads',
  Icons.cloud_upload_outlined,
  const [PowerChoice(60, 'Every 60 s'), PowerChoice(300, 'Every 5 min'), PowerChoice(900, 'Every 15 min')],
  (s) => s.observerUploadBackS,
  (s, v) => s.copyWith(observerUploadBackS: v),
  other: _secs,
);

final statsKnob = PowerKnob<int>(
  'battery-stats',
  Icons.query_stats,
  const [PowerChoice(60, 'Every 60 s'), PowerChoice(300, 'Every 5 min')],
  (s) => s.statsEveryS,
  (s, v) => s.copyWith(statsEveryS: v),
  other: _secs,
);

String knobLabel<T>(PowerKnob<T> k, PowerSettings s) => k.labelOf(s);

/// Applies one knob change: the mode becomes Custom (unless the value did not change).
Future<void> setKnob<T>(PowerKnob<T> k, T v) async {
  final now = PowerProfile.chosen;
  if (k.read(now) == v) return;
  await PowerProfile.set(now.tweak((s) => k.write(s, v)));
}

/// Applies a mode's preset (keeps the Low Power Mode switch as it is).
Future<void> setBatteryMode(BatteryMode m) =>
    PowerProfile.set(PowerSettings.preset(m, followLowPower: PowerProfile.chosen.followLowPower));

/// The choices of [k] in a sheet, the current one marked; picking one applies it.
Future<void> pickKnob<T>(BuildContext context, PowerKnob<T> k) async {
  final cur = k.read(PowerProfile.chosen);
  final v = await showAppSheet<PowerChoice<T>>(
    context,
    detents: const [0.6],
    builder: (ctx, controller) => AppSheetScaffold(
      key: Key('${k.id}${k.subTitle == null ? '' : '-${k.subTitle!.toLowerCase().replaceAll(' ', '-')}'}-sheet'),
      controller: controller,
      title: k.subTitle == null ? k.title : '${settingsEntry(k.id).title}: ${k.subTitle}',
      padding: EdgeInsets.zero,
      secondaryAction: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      children: [
        for (final c in k.choices)
          Semantics(
            inMutuallyExclusiveGroup: true,
            checked: c.value == cur,
            child: ListTile(
              key: Key('${k.id}-option-${c.value is Enum ? (c.value as Enum).name : c.value}'),
              leading: Icon(c.value == cur ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(c.label),
              subtitle: c.hint == null ? null : Text(c.hint!),
              selected: c.value == cur,
              onTap: () => Navigator.pop(ctx, c),
            ),
          ),
      ],
    ),
  );
  if (v != null) await setKnob<T>(k, v.value);
}

// ---------------------------------------------------------------- listening

/// Rebuilds [builder] whenever the power profile changes (a mode, a knob, Low Power Mode).
class PowerProfileBuilder extends StatefulWidget {
  final WidgetBuilder builder;
  const PowerProfileBuilder({super.key, required this.builder});
  @override
  State<PowerProfileBuilder> createState() => _PowerProfileBuilderState();
}

class _PowerProfileBuilderState extends State<PowerProfileBuilder> {
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    PowerProfile.addListener(_changed);
  }

  @override
  void dispose() {
    PowerProfile.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

// ---------------------------------------------------------------- the section

/// Driving > Battery details: what is running now, the Low Power Mode switch and every knob. The mode picker itself is on
/// the first level of Driving (BatteryModePicker).
List<Widget> batterySectionRows(BuildContext context) => [
      SettingsAnchor(
        id: 'battery-running',
        child: ListTile(
          key: const Key('battery-running'),
          leading: const Icon(Icons.bolt),
          title: Text(settingsEntry('battery-running').title),
          subtitle: const Text('What is using power at this moment.'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const WhatsRunningScreen())),
        ),
      ),
      SettingsAnchor(
        id: 'battery-low-power',
        child: PowerProfileBuilder(
          builder: (context) => SwitchListTile(
            key: const Key('battery-low-power'),
            secondary: const Icon(Icons.battery_saver_outlined),
            title: Text(settingsEntry('battery-low-power').title),
            subtitle: const Text('Your own choice comes back when it is off.'),
            value: PowerProfile.chosen.followLowPower,
            onChanged: (v) => unawaited(PowerProfile.set(PowerProfile.chosen.copyWith(followLowPower: v))),
          ),
        ),
      ),
      SettingsAnchor(id: 'battery-screen-on', child: KnobTile(knob: screenOnKnob)),
      SettingsAnchor(id: 'battery-map-fps', child: KnobTile(knob: mapFpsKnob)),
      SettingsAnchor(id: 'battery-gps', child: KnobTile(knob: gpsKnob)),
      SettingsAnchor(id: 'battery-gps-pause', child: KnobTile(knob: gpsPauseKnob)),
      SettingsAnchor(id: 'battery-end-drive', child: _KnobPair(id: 'battery-end-drive', icon: Icons.timer_off_outlined, a: endParkedKnob, b: endNoRadioKnob)),
      SettingsAnchor(id: 'battery-compass', child: KnobTile(knob: compassKnob)),
      SettingsAnchor(id: 'battery-radio-checks', child: _KnobPair(id: 'battery-radio-checks', icon: Icons.mark_chat_unread_outlined, a: radioFrontKnob, b: radioBackKnob)),
      SettingsAnchor(id: 'battery-observer-uploads', child: KnobTile(knob: observerUploadKnob)),
      SettingsAnchor(
        id: 'battery-drive-upload',
        child: _KnobSwitch(
          id: 'battery-drive-upload',
          icon: Icons.cloud_sync_outlined,
          label: 'Upload during a drive',
          read: (s) => s.uploadDuringDrive,
          write: (s, v) => s.copyWith(uploadDuringDrive: v),
          extra: 'Uploads (Driving > Uploads) must also be on.',
        ),
      ),
      SettingsAnchor(id: 'battery-stats', child: KnobTile(knob: statsKnob)),
    ];

/// Max data / Balanced / Saver, with "Custom" when a knob was changed and a line while Low Power Mode overrides.
class BatteryModePicker extends StatelessWidget {
  const BatteryModePicker({super.key});

  static const _hints = {
    BatteryMode.maxData: 'Everything as often as it can: screen on, best GPS, 120 Hz map.',
    BatteryMode.balanced: 'Full coverage data, less waste. The default.',
    BatteryMode.saver: 'For a long day: the phone locks, standard GPS, uploads when the drive ends.',
    BatteryMode.custom: 'You changed a setting in Battery details. Pick a mode to set them all again.',
  };

  @override
  Widget build(BuildContext context) => PowerProfileBuilder(builder: (context) {
        final t = Theme.of(context);
        final chosen = PowerProfile.chosen;
        final cur = chosen.mode;
        // One row: the three modes side by side, and what the picked one does under them. Custom selects none.
        return ListTile(
          key: const Key('battery-mode'),
          leading: const Icon(Icons.battery_charging_full),
          title: Text(settingsEntry('battery-mode').title),
          subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6),
              child: SegmentedButton<BatteryMode>(
                key: const Key('battery-mode-selector'),
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                segments: [
                  for (final m in const [BatteryMode.maxData, BatteryMode.balanced, BatteryMode.saver])
                    ButtonSegment(value: m, label: Text(batteryModeLabel(m), key: Key('battery-mode-${m.name}'), textAlign: TextAlign.center)),
                ],
                selected: {if (cur != BatteryMode.custom) cur},
                onSelectionChanged: (v) {
                  if (v.isNotEmpty) unawaited(setBatteryMode(v.first));
                },
              ),
            ),
            Text('Now: ${batteryModeLabel(cur)}. ${_hints[cur] ?? ''}',
                key: Key(cur == BatteryMode.custom ? 'battery-mode-custom' : 'battery-mode-now')),
            if (PowerProfile.lowPowerOverride)
              Padding(
                key: const Key('battery-low-power-active'),
                padding: const EdgeInsets.only(top: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(Icons.battery_alert, size: 18, color: t.colorScheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('iPhone Low Power Mode is on, so MeshSonar is using Saver for now.', style: t.textTheme.bodySmall),
                  ),
                ]),
              ),
          ]),
        );
      });
}

/// One knob as a row: title, the current choice and what it does; tap to choose.
class KnobTile<T> extends StatelessWidget {
  final PowerKnob<T> knob;
  const KnobTile({super.key, required this.knob});

  @override
  Widget build(BuildContext context) => PowerProfileBuilder(builder: (context) {
        final e = settingsEntry(knob.id);
        return ListTile(
          key: Key(knob.id),
          leading: Icon(knob.icon),
          title: Text(e.title),
          subtitle: Text('${knobLabel(knob, PowerProfile.chosen)}. ${e.summary}', key: Key('${knob.id}-value')),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(pickKnob<T>(context, knob)),
        );
      });
}

/// A row with two knobs (parked / no radio, app open / locked).
class _KnobPair extends StatelessWidget {
  final String id;
  final IconData icon;
  final PowerKnob<int> a, b;
  const _KnobPair({required this.id, required this.icon, required this.a, required this.b});

  @override
  Widget build(BuildContext context) => PowerProfileBuilder(builder: (context) {
        final e = settingsEntry(id);
        final s = PowerProfile.chosen;
        Widget sub(PowerKnob<int> k) => ListTile(
              key: Key('$id-${k.subTitle!.toLowerCase().replaceAll(' ', '-')}'),
              contentPadding: const EdgeInsets.only(left: 72, right: 16),
              dense: true,
              title: Text(k.subTitle!),
              subtitle: Text(knobLabel(k, s)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => unawaited(pickKnob<int>(context, k)),
            );
        return Column(key: Key(id), crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(leading: Icon(icon), title: Text(e.title), subtitle: Text(e.summary)),
          sub(a),
          sub(b),
        ]);
      });
}

/// An on/off knob.
class _KnobSwitch extends StatelessWidget {
  final String id;
  final IconData icon;
  final String? label;
  final String? extra;
  final bool Function(PowerSettings s) read;
  final PowerSettings Function(PowerSettings s, bool v) write;
  const _KnobSwitch({required this.id, required this.icon, required this.read, required this.write, this.label, this.extra});

  @override
  Widget build(BuildContext context) => PowerProfileBuilder(builder: (context) {
        final e = settingsEntry(id);
        return SwitchListTile(
          key: Key(id),
          secondary: Icon(icon),
          title: Text(label == null ? e.title : '${e.title}: $label'),
          subtitle: Text([e.summary, ?extra].join(' ')),
          value: read(PowerProfile.chosen),
          onChanged: (v) => unawaited(PowerProfile.set(PowerProfile.chosen.tweak((s) => write(s, v)))),
        );
      });
}

// ---------------------------------------------------------------- What's running now

/// One line of "What's running now".
class RunningItem {
  final String id;
  final IconData icon;
  final String title;
  final String status;

  /// Opens the setting that changes it; null for lines that only inform.
  final void Function(BuildContext context)? open;

  /// Using power at this moment (the screen lists these first).
  final bool active;
  const RunningItem(this.id, this.icon, this.title, this.status, {this.open, this.active = true});
}

/// What is using power now, in plain words, from the profile the components obey ([PowerProfile.current]) and what
/// the app is doing (driving, radio connected, MQTT feeds, MeshTrack sharing).
List<RunningItem> whatsRunning(AppState s, PowerSettings p) {
  final driving = s.driving;
  final radio = s.connected;
  void Function(BuildContext) pick<T>(PowerKnob<T> k) => (c) => unawaited(pickKnob<T>(c, k));
  final gps = switch (p.gps) {
    GpsPrecision.best => 'Best (navigation)',
    GpsPrecision.high => 'High',
    GpsPrecision.standard => 'Standard (less precise drive track)',
  };
  final screen = switch (p.screenOn) {
    ScreenOnMode.always => 'Yes, for the whole drive',
    ScreenOnMode.driveTabOnly => 'Yes, while the Drive tab is open',
    ScreenOnMode.never => 'No, the phone locks normally',
  };
  final compass = switch (p.compass) {
    CompassMode.always => 'Always on during a drive',
    CompassMode.auto => 'Auto: Drive tab, slow or stopped only',
    CompassMode.off => 'Off: the dot follows the GPS direction',
  };
  final feeds = s.observerEngine.statuses
      .where((f) => f.state == ObserverFeedState.connected || f.state == ObserverFeedState.connecting)
      .length;
  final mt = s.meshTrack;
  final sharing = mt?.state.sharingNames ?? const <String>[];
  return [
    RunningItem('running-drive', Icons.directions_car_outlined, 'Drive',
        driving ? 'Running${p.uploadDuringDrive ? '' : ', uploads at the end'}' : 'Not running',
        active: driving),
    RunningItem('running-gps', Icons.gps_fixed, 'GPS',
        driving
            ? '$gps${p.pauseGpsParkedMin == 0 ? '' : ', low accuracy after ${p.pauseGpsParkedMin} min parked'}'
            : 'Idle: no drive running',
        open: pick(gpsKnob), active: driving),
    RunningItem('running-screen', Icons.light_mode_outlined, 'Screen kept on', driving ? screen : 'No: no drive running',
        open: pick(screenOnKnob), active: driving && p.screenOn != ScreenOnMode.never),
    RunningItem('running-compass', Icons.explore_outlined, 'Compass', driving ? compass : 'Off: no drive running',
        open: pick(compassKnob), active: driving && p.compass != CompassMode.off),
    RunningItem('running-map', Icons.animation_outlined, 'Map drawing', 'Up to ${p.mapFps} times a second while it moves',
        open: pick(mapFpsKnob)),
    RunningItem(
        'running-radio-checks',
        Icons.mark_chat_unread_outlined,
        'Radio checks',
        radio
            ? '${_secs(p.radioPollFrontS).replaceAll('Never', 'Off')} with the app open, '
                '${p.radioPollBackS == 0 ? 'radio alert only' : _secs(p.radioPollBackS)} when locked'
            : 'Off: no radio connected',
        open: pick(radioFrontKnob), active: radio),
    RunningItem(
        'running-observer',
        Icons.cloud_upload_outlined,
        'Observer uploads',
        radio
            ? 'Every ${_secs(p.observerUploadBackS)} when locked${s.telemetryQueued > 0 ? ', ${s.telemetryQueued} waiting' : ''}'
            : 'Off: no radio connected',
        open: pick(observerUploadKnob), active: radio),
    RunningItem('running-mqtt', Icons.hub_outlined, 'MQTT feeds',
        feeds == 0 ? 'None open' : '$feeds open', active: feeds > 0),
    if (mt != null)
      RunningItem('running-meshtrack', Icons.people_alt_outlined, 'MeshTrack sharing',
          sharing.isEmpty ? 'Not sharing' : 'Sharing with ${sharing.join(', ')}', active: sharing.isNotEmpty),
  ];
}

class WhatsRunningScreen extends StatelessWidget {
  const WhatsRunningScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(settingsEntry('battery-running').title)),
      body: SafeArea(
        child: PowerProfileBuilder(builder: (context) {
          final t = Theme.of(context);
          final p = PowerProfile.current;
          final items = whatsRunning(s, p);
          final on = [for (final i in items) if (i.active) i];
          final off = [for (final i in items) if (!i.active) i];
          Widget head(String text, Key key) => Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Semantics(header: true, child: Text(text, key: key, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary))),
              );
          Widget line(RunningItem i) => ListTile(
                key: Key(i.id),
                minTileHeight: 56,
                leading: Icon(i.icon, color: i.active ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
                title: Text(i.title),
                subtitle: Text(i.status, key: Key('${i.id}-status')),
                trailing: i.open == null ? null : const Icon(Icons.chevron_right),
                onTap: i.open == null ? null : () => i.open!(context),
              );
          return ListView(key: const Key('whats-running'), padding: const EdgeInsets.only(bottom: 24), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                  'Mode: ${batteryModeLabel(p.mode)}'
                  '${PowerProfile.lowPowerOverride ? ' (iPhone Low Power Mode is on)' : ''}. '
                  'Tap a line with an arrow to change it.',
                  key: const Key('whats-running-mode'),
                  style: t.textTheme.bodyMedium),
            ),
            head('Using power now (${on.length})', const Key('whats-running-on')),
            for (final i in on) line(i),
            if (off.isNotEmpty) head('Not running', const Key('whats-running-off')),
            for (final i in off) line(i),
          ]);
        }),
      ),
    );
  }
}
