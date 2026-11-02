import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast;
import 'package:meshsonar/ui/radio/device_settings_screen.dart';

import '../../support/device_radio_fake.dart';
import '../../support/tools_rig.dart';
import '../../support/tools_ui_rig.dart';

class Rig {
  final DeviceRadioFake radio;
  final RadioTools tools;
  final FakeToolsHost host;
  Uint8List? shared;
  String? pasteValue;
  Rig(this.radio, this.tools, this.host);
}

Rig rig() {
  final radio = DeviceRadioFake();
  final tools = RadioTools(radio, testArbiter());
  final host = FakeToolsHost()..toolsValue = tools;
  return Rig(radio, tools, host);
}

Future<void> open(WidgetTester tester, Rig r, {Device device = Device.iphone}) async {
  addTearDown(dismissAppToast);
  await pumpTool(
    tester,
    DeviceSettingsScreen(
      shareFile: (b, n) async => r.shared = b,
      pasteText: () async => r.pasteValue,
      copyText: (_) async {},
    ),
    r.host,
    device: device,
  );
  tester.view.physicalSize = const Size(390 * 3, 3200 * 3); // tall: a ListView builds only what is near the screen
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> done(WidgetTester t) async {
  dismissAppToast();
  await t.pumpWidget(const SizedBox());
}

void main() {
  testWidgets('shows every row group for a current radio and no hidden list entries except ignored nodes', (tester) async {
    final r = rig();
    await open(tester, r);
    for (final k in ['row-name', 'row-battery', 'row-firmware', 'row-ask', 'row-autoadd', 'row-hops', 'row-contact-count', 'row-location', 'row-telemetry', 'row-hash', 'row-acks', 'row-setup', 'row-tools', 'row-console', 'row-pin', 'row-export', 'row-import', 'row-reboot', 'row-reset']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    expect(find.byKey(const Key('device-hidden')), findsOneWidget);
    expect(find.textContaining('Ignored nodes'), findsOneWidget);
    expect(find.textContaining('3.92 V'), findsWidgets);
  });

  testWidgets('an old radio hides path hash and console, and says why', (tester) async {
    final r = rig();
    r.radio
      ..fwCode = 9
      ..fwVersion = 'v1.17.1';
    await open(tester, r);
    expect(find.byKey(const Key('row-hash')), findsNothing);
    expect(find.byKey(const Key('row-console')), findsNothing);
    expect(find.textContaining('Needs firmware 1.18'), findsOneWidget);
    expect(find.textContaining('path hash sizes'), findsWidgets);
  });

  testWidgets('a switch writes, reads back and offers Undo', (tester) async {
    final r = rig();
    await open(tester, r);
    await tester.tap(find.byKey(const Key('row-acks-switch')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));
    expect(r.radio.multiAcks, 1);
    expect(find.text('Undo'), findsOneWidget);
    await done(tester);
  });

  testWidgets('factory reset: button stays off until RESET is typed, and the sheet lists what is lost', (tester) async {
    final r = rig();
    await open(tester, r);
    await tester.tap(find.byKey(const Key('row-reset')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-headline')), findsOneWidget);
    expect(find.textContaining('identity key'), findsWidgets);
    expect(find.textContaining('contacts stored'), findsOneWidget);
    FilledButton btn() => tester.widget<FilledButton>(find.byKey(const Key('reset-confirm')));
    expect(btn().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('reset-typed')), 'reset');
    await tester.pump();
    expect(btn().onPressed, isNull, reason: 'case matters');
    await tester.enterText(find.byKey(const Key('reset-typed')), 'RESET');
    await tester.pump();
    expect(btn().onPressed, isNotNull);
    expect(r.radio.reset, isFalse);
    await tester.tap(find.byKey(const Key('reset-confirm')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(r.radio.reset, isTrue);
    await done(tester);
  });

  testWidgets('PIN sheet validates and only then writes', (tester) async {
    final r = rig();
    await open(tester, r);
    await tester.tap(find.byKey(const Key('row-pin')));
    await tester.pumpAndSettle();
    FilledButton btn() => tester.widget<FilledButton>(find.byKey(const Key('pin-save')));
    expect(btn().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('pin-a')), '482913');
    await tester.enterText(find.byKey(const Key('pin-b')), '482914');
    await tester.pump();
    expect(find.byKey(const Key('pin-problem')), findsOneWidget);
    expect(btn().onPressed, isNull);
    await tester.enterText(find.byKey(const Key('pin-b')), '482913');
    await tester.pump();
    expect(btn().onPressed, isNotNull);
    await tester.tap(find.byKey(const Key('pin-save')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(r.radio.blePin, 482913);
    await done(tester);
  });

  testWidgets('console runs a line and refuses a blocked one', (tester) async {
    final r = rig();
    await open(tester, r);
    await tester.tap(find.byKey(const Key('row-console')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('console-input')), 'ver');
    await tester.tap(find.byKey(const Key('console-send')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('> ok'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('console-input')), 'get prv.key');
    await tester.tap(find.byKey(const Key('console-send')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.textContaining('never shown'), findsOneWidget);
    expect(r.radio.cliLog, ['ver']);
  });

  testWidgets('backup sheet checks the passphrase before anything is read', (tester) async {
    final r = rig();
    r.radio.contactList = [];
    await open(tester, r);
    await tester.tap(find.byKey(const Key('row-export')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('backup-pass-a')), 'short');
    await tester.enterText(find.byKey(const Key('backup-pass-b')), 'short');
    await tester.pump();
    expect(find.byKey(const Key('backup-problem')), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('backup-create'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('backup-pass-a')), 'correct horse battery');
    await tester.enterText(find.byKey(const Key('backup-pass-b')), 'correct horse battery');
    await tester.pump();
    expect(find.byKey(const Key('backup-problem')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const Key('backup-create'))).onPressed, isNotNull);
    expect(r.radio.sent.where((s) => s.frame[0] == Cmd.exportPrivateKey), isEmpty, reason: 'nothing read before the button');
  });
}
