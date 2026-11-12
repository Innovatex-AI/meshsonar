// APP-1 (build 62): a cold start with no radio, a connect attempt and an automatic reconnect all leave the Drive panel at the Dock
// detent, bottom-anchored, collapsible, with the map interactive. Nothing about the radio may move the panel by itself, and a
// panel left at Medium in an earlier run must not reopen in the middle of the screen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/alerts/saved_radios_store.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/connect_screen.dart';
import 'package:meshsonar/ui/drive/panel/panel_physics.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';
import 'package:meshsonar/radio/radio_api.dart' show RadioDevice;

import '../fakes.dart';

const _size = Size(402, 874);
const _dockTop = 680.0, _immersiveTop = 752.0;

Future<Harness> _pump(WidgetTester tester, {Harness? harness, String? savedDetent}) async {
  AppFlags.driveRedesign = true;
  addTearDown(() => AppFlags.driveRedesign = false);
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = harness ?? Harness();
  await h.state.init();
  if (savedDetent != null) await uiPrefsFor(h.state).setDrivePanelDetent(savedDetent);
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: MediaQuery(
        data: const MediaQueryData(size: _size, padding: EdgeInsets.only(top: 47, bottom: 106), viewPadding: EdgeInsets.only(top: 47, bottom: 34)),
        child: const DriveScreen(),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}

double _panelTop(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('drive-panel'))).dy;

/// The map is usable: a drag on it does not throw, no dialog or connect screen covers it, and the panel stays where it is.
Future<void> _expectMapUsableAndPanelAtDock(WidgetTester tester) async {
  expect(_panelTop(tester), closeTo(_dockTop, 1), reason: 'bottom-anchored at the Dock detent, not centred');
  expect(find.byType(ConnectScreen), findsNothing);
  expect(find.byType(ModalBarrier).evaluate().where((e) => (e.widget as ModalBarrier).color != null && (e.widget as ModalBarrier).color != Colors.transparent), isEmpty);
  expect(find.byKey(const Key('drive-panel-medium')), findsNothing, reason: 'Medium content is not built at the Dock');
  await tester.dragFrom(const Offset(200, 300), const Offset(-60, 40));
  await tester.pump(const Duration(milliseconds: 300));
  expect(tester.takeException(), isNull);
  expect(_panelTop(tester), closeTo(_dockTop, 1), reason: 'a map gesture never moves the panel');
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

void main() {
  tearDown(() => AlertsHost.runtime.value?.reconnect = null);

  testWidgets('cold start with no radio: Dock, "Not connected" + Connect radio, map usable', (tester) async {
    await _pump(tester);
    expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Not connected');
    expect(find.text('Connect radio'), findsOneWidget);
    await _expectMapUsableAndPanelAtDock(tester);
  });

  testWidgets('a panel left at Medium in an earlier run reopens at the Dock, not in the middle', (tester) async {
    await _pump(tester, savedDetent: PanelDetent.medium.name);
    await _expectMapUsableAndPanelAtDock(tester);
  });

  testWidgets('a manual connect attempt shows Connecting… in the Dock and never changes the detent', (tester) async {
    final h = Harness();
    h.bt.connectGate = Completer<void>();
    await _pump(tester, harness: h);
    unawaited(h.state.connect(h.bt.devices.first, RadioKind.bluetooth));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.state.connecting, isTrue);
    expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Connecting…');
    await _settle(tester);
    await _expectMapUsableAndPanelAtDock(tester);
    h.bt.connectGate!.complete();
    await tester.pump(const Duration(milliseconds: 300));
    await _settle(tester);
    expect(h.state.connected, isTrue);
    expect(_panelTop(tester), closeTo(_dockTop, 1), reason: 'a successful connect does not move it either');
  });

  testWidgets('the automatic reconnect after launch shows Reconnecting… in the Dock, Cancel works, the panel stays at the Dock', (tester) async {
    final gate = Completer<void>();
    final store = SavedRadiosStore(initial: const [SavedRadio(id: 'uuid-1', name: 'Radio One')]);
    final lr = LaunchReconnect(
      store: store,
      connect: (RadioDevice d) async => false,
      isConnected: () => false,
      mode: () => AutoConnectMode.always,
      wait: (d) => gate.future,
    );
    AlertsHost.runtime.value!.reconnect = lr;
    final h = await _pump(tester);
    unawaited(lr.run());
    await tester.pump(const Duration(milliseconds: 50));
    expect(lr.active, isTrue);
    expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Reconnecting…');
    expect(find.text('Looking for Radio One'), findsOneWidget);
    await _settle(tester);
    await _expectMapUsableAndPanelAtDock(tester);
    // Collapsible: the person can drag it down to the hidden pill, and back.
    await tester.fling(find.byKey(const Key('drive-panel-grabber')), const Offset(0, 300), 1500);
    await _settle(tester);
    expect(find.byKey(const Key('immersive-pill')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.text('Reconnecting…')), findsOneWidget, reason: 'the collapsed pill says the same words');
    await tester.tap(find.byKey(const Key('pill-nub')));
    await _settle(tester);
    expect(_panelTop(tester), closeTo(_dockTop, 1));
    await tester.tap(find.byKey(const Key('connect-cancel')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(lr.active, isFalse);
    expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Not connected');
    expect(h.state.connected, isFalse);
    gate.complete();
    await tester.pump(const Duration(milliseconds: 100));
    expect(_panelTop(tester), lessThan(_immersiveTop));
  });

  testWidgets('the panel can be dragged to Medium and back by the person, and only then', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('drive-panel-grabber')));
    await _settle(tester);
    expect(_panelTop(tester), lessThan(_dockTop - 100), reason: 'the person asked for Medium');
    await tester.tap(find.byKey(const Key('drive-panel-grabber')));
    await _settle(tester);
    expect(_panelTop(tester), closeTo(_dockTop, 1));
  });
}
