// The ping settings (interval, minimum distance, listen window): in More > Settings > Wardriving and as a quick sheet on the
// Map tab; saved, and actually consumed by the engine (also mid-drive).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/settings/settings_index.dart';
import 'package:meshsonar/ui/settings/settings_kit.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/radio/radio_api.dart';

import 'drive_flow_test.dart' show drain, settle;
import 'fakes.dart';

Future<void> slide(WidgetTester tester, String key, int index) async {
  final sl = tester.widget<Slider>(find.byKey(Key(key)));
  sl.onChanged!(index.toDouble());
  sl.onChangeEnd!(index.toDouble());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  test('listen window is a persisted setting: default 10 s, written only when changed, clamped on load', () {
    expect(const Settings().listenWindowSec, 10);
    expect(const Settings().toJson().containsKey('listen_window_sec'), isFalse, reason: 'default file unchanged');
    final j = const Settings(listenWindowSec: 12).toJson();
    expect(j['listen_window_sec'], 12);
    expect(Settings.fromJson(j).listenWindowSec, 12);
    expect(Settings.fromJson({'listen_window_sec': 1}).listenWindowSec, Settings.minListenSec);
    expect(Settings.fromJson({'listen_window_sec': 999}).listenWindowSec, Settings.maxListenSec);
    expect(Settings.fromJson(const {}).listenWindowSec, 10);
    expect(listenStops.first, Settings.minListenSec);
    expect(listenStops.last, Settings.maxListenSec);
  });

  test('Wardriving is a Settings section holding channel, discovery, interval, distance, listen window', () {
    expect(settingsSections.map((s) => s.id), contains('wardriving'));
    for (final id in ['channel', 'send-pings', 'interval', 'min-distance', 'listen-window']) {
      expect(settingsEntries.where((e) => e.id == id).single.section, 'wardriving', reason: id);
    }
  });

  testWidgets('More > Wardriving settings opens Settings on the Wardriving section with all five controls', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tapShellTab(tester, 'More');
    await tester.scrollUntilVisible(find.byKey(const Key('more-wardriving')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('more-wardriving')), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-wardriving')));
    await tester.pumpAndSettle();
    for (final k in ['channel', 'send-pings', 'interval', 'min-distance', 'listen-window']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    await slide(tester, 'listen-window-slider', listenStops.indexOf(12));
    expect(h.settings.saved.listenWindowSec, 12, reason: 'saved to disk');
    expect(h.state.settings.listenWindowSec, 12);
  });

  testWidgets('Map tab chip opens the quick sheet; a change saves and reaches the running engine at once', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);
    final e = h.engines.single;
    expect(e.config!.intervalSec, 30);
    expect(e.config!.listenWindow, const Duration(seconds: 10));

    expect(find.byKey(const Key('ping-settings-chip')), findsOneWidget);
    expect(find.text('Ping 30 s / 100 m'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ping-settings-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ping-settings-sheet')), findsOneWidget);

    await slide(tester, 'quick-interval-slider', intervalStops.indexOf(60));
    await slide(tester, 'quick-min-distance-slider', distanceStops.indexOf(250));
    await slide(tester, 'quick-listen-window-slider', listenStops.indexOf(10));
    expect(h.settings.saved.intervalSec, 60);
    expect(h.settings.saved.minDistanceM, 250);
    expect(h.settings.saved.listenWindowSec, 10);
    // Consumed by the running engine, not dead UI.
    expect(e.config!.intervalSec, 60);
    expect(e.config!.minDistanceM, 250);
    expect(e.config!.listenWindow, const Duration(seconds: 10));

    // The chip says so, and the sheet's link goes to the full section.
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Ping 60 s / 250 m'), findsOneWidget);
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('a new drive starts with the saved listen window and cadence', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.settings.saved = const Settings(intervalSec: 45, minDistanceM: 75, listenWindowSec: 9);
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);
    final c = h.engines.single.config!;
    expect(c.intervalSec, 45);
    expect(c.minDistanceM, 75);
    expect(c.listenWindow, const Duration(seconds: 9));
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('GPS fixes move the dot every time but only tell the map model when the phone moved or 2 s passed', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);
    final model = DriveMapModel(h.state);
    addTearDown(model.dispose);
    await tester.pump();
    var notes = 0;
    model.addListener(() => notes++);

    var t = h.clockNow;
    for (var i = 0; i < 10; i++) {
      t = t.add(const Duration(milliseconds: 100));
      h.clockNow = t;
      // 1 m a step: a parked-ish crawl.
      h.location.fixController.add(GeoFix(lat: 40 + i / 111320.0, lon: -83, at: t, accuracyM: 5, speedMps: 1));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(model.puck.pose, isNotNull);
    expect(notes, lessThanOrEqualTo(2), reason: '10 fixes in 1 s: the map model hears about the first, not each');
    await h.state.stopDrive();
    await drain(tester);
  });
}
