// APP-2 (build 62): one affordance and one wording for the radio link on the Dock, the collapsed pill, the mini drive bar, the map
// capsule and the (legacy) app-bar chip. The mapping table is in docs/FEATURES.md "Radio link: one look on every surface".
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/drive/radio_link_status.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/shell/mini_drive_bar.dart';

import '../fakes.dart';

Future<void> _pumpDrive(WidgetTester tester, Harness h) async {
  AppFlags.driveRedesign = true;
  addTearDown(() => AppFlags.driveRedesign = false);
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
        expect(const RadioLinkStatus(RadioLink.simulator).color(c), c.warning);
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
    testWidgets('not connected: Dock title, Dock button, capsule and chip', (tester) async {
      final h = Harness();
      await h.state.init();
      await _pumpDrive(tester, h);
      expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Not connected');
      expect(find.descendant(of: find.byKey(const Key('start-stop')), matching: find.text('Connect radio')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('start-stop')), matching: find.byIcon(Icons.bluetooth_disabled_rounded)), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, 'No radio');
      // The legacy app-bar chip: same words and glyph.
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: ConnectionChip(state: h.state, onPressed: () {}))),
      ));
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.byIcon(Icons.bluetooth_disabled_rounded), findsOneWidget);
    });

    testWidgets('connecting: spinner and the same word on the Dock, the capsule, the chip and the collapsed pill', (tester) async {
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
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: ConnectionChip(state: h.state, onPressed: () {}))),
      ));
      expect(find.text('Connecting…'), findsOneWidget);
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
}
