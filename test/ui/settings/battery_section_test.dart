// Settings > Battery (build 70, battery-efficiency-plan-2026-11-16.md §3): the section renders with every knob, a mode
// applies its preset, a knob change makes the mode Custom, Low Power Mode shows the override line, search finds it,
// What's running now lists what uses power, and Diagnostics shows the power counters with per-hour rates.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/ui/settings/battery_section.dart';
import 'package:meshsonar/ui/settings/diagnostics_section.dart' show powerCounterLines;
import 'package:meshsonar/ui/settings/settings_index.dart';

import '../fakes.dart';
import '../settings_test_kit.dart';
import '../toast_test_kit.dart';

Future<Harness> _open(WidgetTester tester) async {
  useTallScreen(tester);
  final h = Harness()..approveKey();
  await h.pumpApp(tester);
  await openSettingsTab(tester);
  return h;
}

void main() {
  setUp(() {
    PowerProfile.debugReset();
    PowerCounters.debugReset();
  });
  tearDown(PowerProfile.debugReset);

  testWidgetsT('the Battery section shows the mode (Balanced by default) and every knob', (tester) async {
    await _open(tester);
    await showSetting(tester, 'battery-mode');
    expect(find.byKey(const Key('section-battery')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('battery-mode-now'))).data, startsWith('Now: Balanced.'));
    expect(find.byKey(const Key('battery-mode-custom')), findsNothing);
    for (final id in [
      'battery-running',
      'battery-low-power',
      'battery-screen-on',
      'battery-map-fps',
      'battery-gps',
      'battery-gps-pause',
      'battery-end-drive',
      'battery-compass',
      'battery-radio-checks',
      'battery-observer-uploads',
      'battery-drive-upload',
      'battery-stats',
      'battery-simple-basemap',
    ]) {
      await showSetting(tester, id);
      expect(find.descendant(of: find.byKey(const Key('section-battery')), matching: find.byKey(Key(id))), findsOneWidget,
          reason: id);
    }
    expect(tester.widget<Text>(find.byKey(const Key('battery-gps-value'))).data, startsWith('High.'));
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('battery-low-power'))).value, isTrue);
  });

  testWidgetsT('picking a mode applies its whole preset', (tester) async {
    await _open(tester);
    await showSetting(tester, 'battery-mode-saver');
    await tester.tap(find.byKey(const Key('battery-mode-saver')));
    await tester.pumpAndSettle();
    expect(PowerProfile.chosen.mode, BatteryMode.saver);
    expect(PowerProfile.chosen.toJson(), PowerSettings.saver.toJson());
    expect(tester.widget<Text>(find.byKey(const Key('battery-mode-now'))).data, startsWith('Now: Saver.'));
    await showSetting(tester, 'battery-gps');
    expect(tester.widget<Text>(find.byKey(const Key('battery-gps-value'))).data, startsWith('Standard (less precise drive track).'));

    await showSetting(tester, 'battery-mode-maxData');
    await tester.tap(find.byKey(const Key('battery-mode-maxData')));
    await tester.pumpAndSettle();
    expect(PowerProfile.chosen.toJson(), PowerSettings.maxData.toJson());
  });

  testWidgetsT('changing one knob makes the mode Custom and keeps the rest', (tester) async {
    await _open(tester);
    await showSetting(tester, 'battery-compass');
    await tester.tap(find.byKey(const Key('battery-compass')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('battery-compass-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('battery-compass-option-off')));
    await tester.pumpAndSettle();
    expect(PowerProfile.chosen.mode, BatteryMode.custom);
    expect(PowerProfile.chosen.compass, CompassMode.off);
    expect(PowerProfile.chosen.gps, PowerSettings.balanced.gps);
    await showSetting(tester, 'battery-mode');
    expect(tester.widget<Text>(find.byKey(const Key('battery-mode-now'))).data, startsWith('Now: Custom.'));
    expect(find.byKey(const Key('battery-mode-custom')), findsOneWidget);

    // A two-knob row: the locked radio check.
    await showSetting(tester, 'battery-radio-checks-phone-locked');
    await tester.tap(find.byKey(const Key('battery-radio-checks-phone-locked')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('battery-radio-checks-option-0')));
    await tester.pumpAndSettle();
    expect(PowerProfile.chosen.radioPollBackS, 0);

    // A switch knob.
    await showSetting(tester, 'battery-simple-basemap');
    await tester.tap(find.byKey(const Key('battery-simple-basemap')));
    await tester.pumpAndSettle();
    expect(PowerProfile.chosen.simpleBasemap, isTrue);

    // Picking a mode again resets every knob.
    await showSetting(tester, 'battery-mode-balanced');
    await tester.tap(find.byKey(const Key('battery-mode-balanced')));
    await tester.pumpAndSettle();
    expect(PowerProfile.chosen.toJson(), PowerSettings.balanced.toJson());
    expect(find.byKey(const Key('battery-mode-custom')), findsNothing);
  });

  testWidgetsT('Low Power Mode shows the override line; the switch turns following off (mode unchanged)', (tester) async {
    await _open(tester);
    await showSetting(tester, 'battery-mode');
    expect(find.byKey(const Key('battery-low-power-active')), findsNothing);
    PowerProfile.setLowPowerMode(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('battery-low-power-active')), findsOneWidget);
    expect(find.textContaining('Low Power Mode is on, so MeshSonar is using Saver'), findsOneWidget);
    expect(PowerProfile.current.mode, BatteryMode.saver);

    await showSetting(tester, 'battery-low-power');
    await tester.tap(find.byKey(const Key('battery-low-power')));
    await tester.pumpAndSettle();
    expect(PowerProfile.chosen.followLowPower, isFalse);
    expect(PowerProfile.chosen.mode, BatteryMode.balanced);
    expect(PowerProfile.lowPowerOverride, isFalse);
    await showSetting(tester, 'battery-mode');
    expect(find.byKey(const Key('battery-low-power-active')), findsNothing);
  });

  testWidgetsT('What\'s running now lists what uses power and follows the profile', (tester) async {
    await _open(tester);
    await showSetting(tester, 'battery-running');
    await tester.tap(find.byKey(const Key('battery-running')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('whats-running')), findsOneWidget);
    String status(String id) => tester.widget<Text>(find.byKey(Key('$id-status'))).data!;
    expect(status('running-drive'), 'Not running');
    expect(status('running-gps'), 'Idle: no drive running');
    expect(status('running-radio-checks'), 'Off: no radio connected');
    expect(status('running-mqtt'), 'None open');
    expect(status('running-map'), 'Up to 60 times a second while it moves');
    expect(tester.widget<Text>(find.byKey(const Key('whats-running-mode'))).data, startsWith('Mode: Balanced.'));

    PowerProfile.setLowPowerMode(true);
    await tester.pumpAndSettle();
    expect(status('running-map'), 'Up to 30 times a second while it moves');
    expect(tester.widget<Text>(find.byKey(const Key('whats-running-mode'))).data, contains('Low Power Mode is on'));

    // A line opens its setting.
    await tester.tap(find.byKey(const Key('running-map')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('battery-map-fps-sheet')), findsOneWidget);
  });

  test('search finds the Battery rows', () {
    for (final q in ['battery', 'power', 'screen on', 'gps', 'compass', 'low power']) {
      expect(searchSettings(q).any((e) => e.section == 'battery'), isTrue, reason: q);
    }
    expect(searchSettings('low power').first.id, 'battery-low-power');
  });

  test('every knob reads its preset value in words', () {
    for (final s in [PowerSettings.maxData, PowerSettings.balanced, PowerSettings.saver]) {
      for (final k in <PowerKnob<Object?>>[
        screenOnKnob, mapFpsKnob, gpsKnob, gpsPauseKnob, endParkedKnob, endNoRadioKnob, compassKnob, radioFrontKnob,
        radioBackKnob, observerUploadKnob, statsKnob,
      ]) {
        expect(k.choices.any((c) => c.value == k.read(s)), isTrue, reason: '${k.id} ${k.subTitle} in ${s.mode}');
      }
    }
    expect(knobLabel(gpsPauseKnob, PowerSettings.balanced.copyWith(pauseGpsParkedMin: 7)), '7 min');
    expect(knobLabel(observerUploadKnob, PowerSettings.balanced.copyWith(observerUploadBackS: 45)), '45 s');
  });

  test('power counters: totals and per-hour rates', () {
    final since = DateTime.utc(2026, 11, 17, 10);
    final now = since.add(const Duration(hours: 2));
    final lines = Map.fromEntries([
      for (final (a, b) in powerCounterLines({PowerCounters.bleCommand: 720, PowerCounters.gpsHighSeconds: 3600, 'other_key': 3}, since, now))
        MapEntry(a, b),
    ]);
    expect(lines['Radio commands'], '720 (360/h)');
    expect(lines['GPS, high accuracy'], '60.0 min (30.0 min/h)');
    expect(lines['Compass'], '0.0 min (0.0 min/h)');
    expect(lines['other_key'], '3 (1.5/h)');
    // Under a minute: no rate.
    expect(powerCounterLines({PowerCounters.bleCommand: 5}, since, since.add(const Duration(seconds: 30))).firstWhere((l) => l.$1 == 'Radio commands').$2, '5');
  });

  testWidgetsT('Diagnostics shows the power counters card', (tester) async {
    PowerCounters.inc(PowerCounters.bleCommand, 12);
    await _open(tester);
    await showSetting(tester, 'diagnostics-power-counters');
    expect(find.byKey(const Key('power-counter-Radio commands')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('power-counter-Radio commands'))).data, startsWith('12'));
  });
}
