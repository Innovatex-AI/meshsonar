// APP-2 (build 62): one affordance and one wording for the radio link on the Dock, the collapsed pill, the mini drive bar, the map
// capsule and the (legacy) app-bar chip. The mapping table is in docs/FEATURES.md "Radio link: one look on every surface".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/alerts/saved_radios_store.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/radio/radio_api.dart' show RadioDevice;
import 'package:meshsonar/ui/alerts/alerts_status_strip.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/drive/radio_link_status.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/shell/mini_drive_bar.dart';

import '../fakes.dart';

Future<void> _pumpDrive(WidgetTester tester, Harness h) async {
  tester.view.physicalSize = const Size(402, 874);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: const MediaQuery(
        data: MediaQueryData(size: Size(402, 874), padding: EdgeInsets.only(top: 47, bottom: 106), viewPadding: EdgeInsets.only(top: 47, bottom: 34)),
        child: DriveScreen(),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('the mapping table', () {
    const table = <RadioLink, (IconData?, String, String)>{
      RadioLink.notConnected: (Icons.bluetooth_disabled_rounded, 'Connect radio', 'Not connected'),
      RadioLink.connecting: (null, 'Connecting…', 'Connecting…'),
      RadioLink.reconnecting: (null, 'Reconnecting…', 'Reconnecting…'),
      RadioLink.connected: (Icons.bluetooth_connected_rounded, 'Start drive', 'Connected'),
      RadioLink.simulator: (Icons.science_rounded, 'Start drive', 'Simulator'),
    };
    for (final e in table.entries) {
      test('${e.key.name}: icon, action label, status label', () {
        final s = RadioLinkStatus(e.key);
        expect(s.icon, e.value.$1);
        expect(s.label, e.value.$2);
        expect(s.statusLabel, e.value.$3);
        expect(s.working, e.value.$1 == null);
      });
    }

    test('colours: muted when idle, warning while working or simulated, ok when connected', () {
      for (final b in Brightness.values) {
        final c = AppColors.fromTheme(meshSonarTheme(b));
        expect(const RadioLinkStatus(RadioLink.notConnected).color(c), c.textMuted);
        expect(const RadioLinkStatus(RadioLink.connecting).color(c), c.warning);
        expect(const RadioLinkStatus(RadioLink.reconnecting).color(c), c.warning);
        expect(const RadioLinkStatus(RadioLink.simulator).color(c), c.ok);
        expect(const RadioLinkStatus(RadioLink.connected).color(c), c.ok);
      }
    });

    test('the four action words are exactly the ones Andy named', () {
      expect([RadioLinkStatus.connectLabel, RadioLinkStatus.connectingLabel, RadioLinkStatus.reconnectingLabel, RadioLinkStatus.startLabel], ['Connect radio', 'Connecting…', 'Reconnecting…', 'Start drive']);
    });
  });

  group('state to link', () {
    test('not connected, connecting, connected, and the automatic reconnect after launch', () async {
      final h = Harness();
      await h.state.init();
      expect(RadioLinkStatus.of(h.state, launchReconnecting: false).link, RadioLink.notConnected);
      expect(RadioLinkStatus.of(h.state, launchReconnecting: true).link, RadioLink.reconnecting, reason: 'AppState does not know about the launch loop');
      h.bt.connectGate = Completer<void>();
      unawaited(h.state.connect(h.bt.devices.first, RadioKind.bluetooth));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(RadioLinkStatus.of(h.state, launchReconnecting: false).link, RadioLink.connecting);
      expect(RadioLinkStatus.of(h.state, launchReconnecting: true).link, RadioLink.reconnecting, reason: 'the launch loop connects through AppState.connect');
      h.bt.connectGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(RadioLinkStatus.of(h.state, launchReconnecting: false).link, RadioLink.connected);
    });
  });

  group('every surface reads the helper', () {
    testWidgets('not connected: Dock title, Dock button and capsule', (tester) async {
      final h = Harness();
      await h.state.init();
      await _pumpDrive(tester, h);
      expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Not connected');
      expect(find.descendant(of: find.byKey(const Key('start-stop')), matching: find.text('Connect radio')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('start-stop')), matching: find.byIcon(Icons.bluetooth_disabled_rounded)), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, 'No radio');
    });

    testWidgets('connecting: spinner and the same word on the Dock, the capsule and the collapsed pill', (tester) async {
      final h = Harness();
      h.bt.connectGate = Completer<void>();
      await h.state.init();
      await _pumpDrive(tester, h);
      unawaited(h.state.connect(h.bt.devices.first, RadioKind.bluetooth));
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Connecting…');
      expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, 'Connecting…');
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      await tester.fling(find.byKey(const Key('drive-panel-grabber')), const Offset(0, 300), 1500);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.text('Connecting…')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.byType(CircularProgressIndicator)), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.byIcon(Icons.bluetooth_searching_rounded)), findsNothing, reason: 'no lone Bluetooth glyph');
      h.bt.connectGate!.complete();
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('collapsed pill: not connected says Connect radio with the shared glyph; connected says Start drive', (tester) async {
      final h = Harness();
      await h.state.init();
      await _pumpDrive(tester, h);
      await tester.fling(find.byKey(const Key('drive-panel-grabber')), const Offset(0, 300), 1500);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.text('Connect radio')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.byIcon(Icons.bluetooth_disabled_rounded)), findsOneWidget);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.text('Start drive')), findsOneWidget);
    });

    testWidgets('mini drive bar while driving with the radio gone: the same words', (tester) async {
      final h = Harness();
      await h.state.init();
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await h.state.disconnect(quiet: true);
      final sum = miniBarSummary(h.state);
      expect(sum.problem, isTrue);
      expect(sum.waiting, anyOf('Not connected', 'Reconnecting…', 'Radio problem'));
      expect(sum.waiting, isNot(anyOf('Waiting for radio', 'Radio reconnecting')), reason: 'the old words are gone');
      if (h.state.driving) await h.state.stopDrive();
      await tester.pump(const Duration(seconds: 25));
    });
  });

  // Build 71, rule 7 of the map panel rules: connection wording and icon come from ONE helper on every surface. This is the
  // one test that walks the link states and reads the Dock, the collapsed pill, the map capsule, the alerts strip and the
  // mini drive bar against RadioLinkStatus.of(state).
  group('one wording across the connection surfaces (build 71)', () {
    tearDown(() => AlertsHost.runtime.value?.reconnect = null);

    Future<void> pumpAll(WidgetTester tester, Harness h) async {
      tester.view.physicalSize = const Size(402, 874);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.dark),
          home: const MediaQuery(
            data: MediaQueryData(size: Size(402, 874), padding: EdgeInsets.only(top: 47, bottom: 106), viewPadding: EdgeInsets.only(top: 47, bottom: 34)),
            child: Stack(children: [
              Positioned.fill(child: DriveScreen()),
              Positioned(left: 0, right: 0, top: 200, child: AlertsStatusStrip()),
            ]),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
    }

    Finder inside(String key, Finder what) => find.descendant(of: find.byKey(Key(key)), matching: what);

    /// Icon or spinner of [link] inside the surface keyed [key].
    void expectLeading(String key, RadioLinkStatus link) {
      final icon = link.icon;
      expect(icon == null ? inside(key, find.byType(CircularProgressIndicator)) : inside(key, find.byIcon(icon)), findsWidgets, reason: '$key shows the helper\'s glyph for ${link.link.name}');
    }

    Future<void> expectSurfaces(WidgetTester tester, Harness h, RadioLink want) async {
      final link = RadioLinkStatus.of(h.state);
      expect(link.link, want);
      // 1. Dock: the title is the helper's status words, the affordance its action label and glyph.
      expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, link.statusLabel);
      if (!link.working) {
        expect(inside('start-stop', find.text(link.label)), findsOneWidget);
        expectLeading('start-stop', link);
      } else {
        expectLeading('drive-panel', link);
      }
      // 2. Map capsule: the compact form of the same status words.
      expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, link.link == RadioLink.notConnected ? 'No radio' : (link.connected ? 'Radio' : link.statusLabel));
      // 3. Alerts strip (only while the automatic reconnect has something to say): the helper's words and spinner first.
      if (find.byKey(const Key('reconnect-strip')).evaluate().isNotEmpty) {
        expect(inside('reconnect-strip', find.textContaining(link.statusLabel)), findsOneWidget);
        expectLeading('reconnect-strip', link);
      }
      // 4. Collapsed pill: the same action label and glyph as the Dock.
      await tester.fling(find.byKey(const Key('drive-panel-grabber')), const Offset(0, 300), 1500);
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      expect(inside('pill-start', find.text(link.label)), findsOneWidget);
      expectLeading('pill-start', link);
      await tester.tap(find.byKey(const Key('pill-nub')));
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
    }

    testWidgets('Dock, pill, capsule and alerts strip say what RadioLinkStatus says, in every link state', (tester) async {
      // Not connected.
      final h = Harness();
      h.bt.connectGate = Completer<void>();
      await h.state.init();
      final gate = Completer<void>();
      final lr = LaunchReconnect(
        store: SavedRadiosStore(initial: const [SavedRadio(id: 'uuid-1', name: 'Radio One')]),
        connect: (RadioDevice d) async => false,
        isConnected: () => false,
        mode: () => AutoConnectMode.always,
        wait: (d) => gate.future,
      );
      AlertsHost.runtime.value!.reconnect = lr; // idle until run()
      await pumpAll(tester, h);
      await expectSurfaces(tester, h, RadioLink.notConnected);

      // Reconnecting (the automatic reconnect after launch): the strip joins in.
      unawaited(lr.run());
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const Key('reconnect-strip')), findsOneWidget);
      await expectSurfaces(tester, h, RadioLink.reconnecting);
      lr.cancel();
      gate.complete();
      await tester.pump(const Duration(milliseconds: 100));
      AlertsHost.runtime.value!.reconnect = null;

      // Connecting (the person's own attempt).
      unawaited(h.state.connect(h.bt.devices.first, RadioKind.bluetooth));
      await tester.pump(const Duration(milliseconds: 50));
      await expectSurfaces(tester, h, RadioLink.connecting);

      // Connected.
      h.bt.connectGate!.complete();
      await tester.pump(const Duration(milliseconds: 300));
      final link = RadioLinkStatus.of(h.state);
      expect(link.link, RadioLink.connected);
      expect(inside('start-stop', find.text(link.label)), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, 'Radio');
    });

    testWidgets('mini drive bar: the radio words are the helper\'s', (tester) async {
      final h = Harness();
      await h.state.init();
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await h.state.disconnect(quiet: true);
      final words = miniBarSummary(h.state).waiting;
      final helper = {for (final l in RadioLink.values) RadioLinkStatus(l).statusLabel};
      expect(words == 'Radio problem' || helper.contains(words), isTrue, reason: '"$words" is the helper\'s status wording (or the engine error line)');
      if (h.state.driving) await h.state.stopDrive();
      await tester.pump(const Duration(seconds: 25));
    });
  });
}
