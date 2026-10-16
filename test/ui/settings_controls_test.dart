// Settings: sliders (auto-ping, distance, heard hold, upload period), antenna type, upload toggles.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  await tester.tap(find.text('Settings'));
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

  testWidgets('antenna: internal by default, external keeps gain and height', (tester) async {
    final h = await openSettings(tester,
        settings: const Settings(antenna: Antenna(type: 'internal', gainDbi: 3, heightM: 1.5)));
    await show(tester, 'antenna-type');
    final seg = tester.widget<SegmentedButton<String>>(find.byKey(const Key('antenna-type')));
    expect(seg.selected, {'internal'});
    await tester.tap(find.byKey(const Key('settings-antenna-external')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.antenna.type, 'external');
    expect(h.settings.saved.antenna.gainDbi, 3);
    expect(h.settings.saved.antenna.heightM, 1.5);
    expect(find.text('3 dBi'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-antenna-internal')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.antenna.type, 'internal');
  });

  testWidgets('upload toggles: during-drive needs end-of-drive; the period slider follows', (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'sync-every-slider');
    expect(tester.widget<Slider>(find.byKey(const Key('sync-every-slider'))).onChanged, isNotNull);
    expect(valueText(tester, 'sync-every'), 'Every 5 min');

    await tester.tap(find.byKey(const Key('sync-during-drive')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.syncDuringDrive, isFalse);
    expect(tester.widget<Slider>(find.byKey(const Key('sync-every-slider'))).onChanged, isNull);

    await tester.tap(find.byKey(const Key('sync-during-drive')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.syncDuringDrive, isTrue);

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
}
