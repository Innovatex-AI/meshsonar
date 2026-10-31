// Settings: sliders (auto-ping, distance, heard hold, upload period), antenna type, upload toggles, discovery mode.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/settings_screen.dart';

import 'fakes.dart';

Finder get settingsScroll =>
    find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;

Future<Harness> openSettings(WidgetTester tester, {Settings? settings}) async {
  useTallScreen(tester);
  final h = Harness();
  if (settings != null) h.settings.saved = settings;
  await h.pumpApp(tester);
  await openSettingsTab(tester);
  await tester.pumpAndSettle();
  return h;
}

/// Scrolls [key] into view and to the top of the list (clear of the bottom navigation bar).
Future<void> show(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(find.byKey(Key(key)), 100, scrollable: settingsScroll);
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> slideTo(WidgetTester tester, String key, int index) async {
  await show(tester, key);
  final sl = tester.widget<Slider>(find.byKey(Key(key)));
  sl.onChanged!(index.toDouble());
  sl.onChangeEnd!(index.toDouble());
  await tester.pumpAndSettle();
}

String valueText(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key('$key-value'))).data!;

void main() {
  test('slider stops cover the allowed ranges exactly', () {
    expect(intervalStops.first, Settings.minIntervalSec);
    expect(intervalStops.last, Settings.maxIntervalSec);
    for (var i = 1; i < intervalStops.length; i++) {
      expect(intervalStops[i] - intervalStops[i - 1], 5);
    }
    expect(distanceStops.first, Settings.minDistance);
    expect(distanceStops.last, Settings.maxDistance);
    expect(syncEveryStops.first, 1);
    expect(syncEveryStops.last, 30);
    expect(holdStops, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
    expect(nearestStop(distanceStops, 110), distanceStops.indexOf(100));
    expect(nearestStop(distanceStops, 9999), distanceStops.length - 1);
    expect(nearestStop(intervalStops, 0), 0);
  });

  test('stored values outside the ranges are clamped on load', () {
    final s = Settings.fromJson({'interval_sec': 0, 'min_distance_m': 5000, 'sync_every_min': 99, 'antenna': {'type': 'mag-mount'}});
    expect(s.intervalSec, 10);
    expect(s.minDistanceM, 500);
    expect(s.syncEveryMin, 30);
    expect(s.antenna.type, 'internal');
  });

  testWidgets('defaults read "Every 30 s" and "100 m"; no "manual" wording', (tester) async {
    await openSettings(tester);
    await show(tester, 'interval');
    expect(valueText(tester, 'interval'), 'Every 30 s');
    await show(tester, 'min-distance');
    expect(valueText(tester, 'min-distance'), '100 m');
    expect(find.textContaining('BOTH'), findsOneWidget);
    expect(find.textContaining('Ping now works any time'), findsOneWidget);
    expect(find.textContaining('manual'), findsNothing);
    expect(find.textContaining('0 = '), findsNothing);
  });

  testWidgets('sliders save their stop and the label follows', (tester) async {
    final h = await openSettings(tester);
    await slideTo(tester, 'interval-slider', 0);
    expect(h.settings.saved.intervalSec, 10);
    await slideTo(tester, 'interval-slider', intervalStops.length - 1);
    expect(h.settings.saved.intervalSec, 120);
    expect(valueText(tester, 'interval'), 'Every 120 s');
    await slideTo(tester, 'min-distance-slider', 0);
    expect(h.settings.saved.minDistanceM, 15);
    await slideTo(tester, 'min-distance-slider', distanceStops.length - 1);
    expect(h.settings.saved.minDistanceM, 500);
    await slideTo(tester, 'heard-hold-slider', 6);
    expect(h.settings.saved.heardHoldPings, 7);
    expect(valueText(tester, 'heard-hold'), '7 pings');
    await slideTo(tester, 'sync-every-slider', 14);
    expect(h.settings.saved.syncEveryMin, 15);
    expect(valueText(tester, 'sync-every'), 'Every 15 min');
    expect(h.state.settings.syncEveryMin, 15);
  });

  testWidgets('a real drag on the interval slider saves once, at the end', (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'interval-slider');
    final saves = h.settings.saveCount;
    await tester.drag(find.byKey(const Key('interval-slider')), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(h.settings.saveCount, saves + 1);
    expect(h.settings.saved.intervalSec, greaterThan(30));
    expect(intervalStops, contains(h.settings.saved.intervalSec));
  });

  testWidgets('an odd stored distance shows the nearest stop', (tester) async {
    await openSettings(tester, settings: const Settings(minDistanceM: 110));
    await show(tester, 'min-distance');
    expect(valueText(tester, 'min-distance'), '100 m');
  });

  // 0.4.0 (spec m1-app-0.4.0 §4): the global antenna type toggle is gone; each radio has its own row.
  testWidgets('antenna: no global type toggle; each saved radio shows its mount, gain and height', (tester) async {
    await openSettings(tester,
        settings: const Settings().copyWith(antennaProfiles: {
          'abcdef0123': AntennaProfile(
              mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8, updatedAt: DateTime.utc(2026, 10, 16)),
          'ffee000111': AntennaProfile(
              mount: AntennaMount.fixedMast, gainDbi: null, heightM: 9, updatedAt: DateTime.utc(2026, 10, 16)),
        }));
    expect(find.byKey(const Key('antenna-type')), findsNothing);
    expect(find.byKey(const Key('settings-antenna-external')), findsNothing);
    for (final (key, mount, gain, height) in [
      ('abcdef0123', 'Roof mag-mount', '5.8 dBi', '1.8 m'),
      ('ffee000111', 'Fixed mast', null, '9 m'),
    ]) {
      await show(tester, 'antenna-profile-$key');
      final row = find.byKey(ValueKey('antenna-profile-$key'));
      expect(find.descendant(of: row, matching: find.textContaining(mount)), findsWidgets, reason: key);
      if (gain != null) expect(find.descendant(of: row, matching: find.textContaining(gain)), findsWidgets, reason: key);
      expect(find.descendant(of: row, matching: find.textContaining(height)), findsWidgets, reason: key);
      expect(find.descendant(of: row, matching: find.textContaining('dBi')), gain == null ? findsNothing : findsWidgets,
          reason: '"Don\'t know" gain shows no dBi value');
    }
  });

  testWidgets('upload toggles: during-drive needs end-of-drive; the period slider follows', (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'sync-every-slider');
    expect(tester.widget<Slider>(find.byKey(const Key('sync-every-slider'))).onChanged, isNotNull);
    expect(valueText(tester, 'sync-every'), 'Every 5 min');

    // Each control is brought into view before it is tapped (the list ends with the "saved on this phone" footer).
    await show(tester, 'sync-during-drive');
    await tester.tap(find.byKey(const Key('sync-during-drive')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.syncDuringDrive, isFalse);
    expect(tester.widget<Slider>(find.byKey(const Key('sync-every-slider'))).onChanged, isNull);

    await show(tester, 'sync-during-drive');
    await tester.tap(find.byKey(const Key('sync-during-drive')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.syncDuringDrive, isTrue);

    await show(tester, 'auto-sync');
    await tester.tap(find.byKey(const Key('auto-sync')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.autoSync, isFalse);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('sync-during-drive'))).onChanged, isNull);
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('sync-during-drive'))).value, isFalse);
    expect(tester.widget<Slider>(find.byKey(const Key('sync-every-slider'))).onChanged, isNull);
  });

  testWidgets('last upload line shows time / failure', (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'last-upload');
    expect(find.textContaining('No uploads yet'), findsOneWidget);
    h.approveKey();
    await h.state.init();
    h.store.seed(DriveSession(id: 's1', startedAt: DateTime.utc(2026, 10, 16, 17)), [silentPing('x')]);
    await h.state.syncSession('s1');
    await tester.pumpAndSettle();
    expect(find.textContaining('Last upload'), findsOneWidget);
    expect(find.textContaining('OK'), findsOneWidget);
    h.sync.failWith = 'SocketException: network is unreachable';
    h.store.seed(DriveSession(id: 's2', startedAt: DateTime.utc(2026, 10, 16, 17)), [silentPing('y')]);
    await h.state.syncSession('s2');
    await tester.pumpAndSettle();
    expect(find.textContaining('Last upload failed'), findsOneWidget);
  });

  testWidgets('discovery mode: greys the interval/distance sliders, persists, and locks the switch while driving',
      (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'discovery-mode');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('discovery-mode'))).value, isFalse);
    expect(tester.widget<Slider>(find.byKey(const Key('interval-slider'))).onChanged, isNotNull);
    expect(tester.widget<Slider>(find.byKey(const Key('min-distance-slider'))).onChanged, isNotNull);

    await tester.tap(find.byKey(const Key('discovery-mode')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.discoveryMode, isTrue);
    await show(tester, 'interval-slider');
    expect(tester.widget<Slider>(find.byKey(const Key('interval-slider'))).onChanged, isNull);
    await show(tester, 'min-distance-slider');
    expect(tester.widget<Slider>(find.byKey(const Key('min-distance-slider'))).onChanged, isNull);

    // Turned back off (not driving yet), then a drive starts: the switch locks, disabled rather than hidden.
    await show(tester, 'discovery-mode');
    await tester.tap(find.byKey(const Key('discovery-mode')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.discoveryMode, isFalse);

    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pumpAndSettle();
    await show(tester, 'discovery-mode');
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('discovery-mode'))).onChanged, isNull,
        reason: 'privacy-critical toggle: disabled, not hidden, while a drive is active');
    await h.state.stopDrive();
  });

  testWidgets('discovery mode on at Start drive: the engine is told listenOnly, not the usual auto-ping config',
      (tester) async {
    final h = Harness()..settings.saved = const Settings().copyWith(discoveryMode: true);
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pumpAndSettle();
    expect(h.engines.single.config!.listenOnly, isTrue);
    await h.state.stopDrive();
  });
}
