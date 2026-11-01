import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/ui/tools/telemetry_screen.dart';

import '../../support/tools_rig.dart';
import '../../support/tools_ui_rig.dart';

Future<void> leave(WidgetTester tester) async => tester.pumpWidget(const SizedBox());

/// Real radio work and fake-clock widget work take turns: pump, let real time pass, pump again.
Future<void> alternate(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
  }
  await tester.pump(const Duration(milliseconds: 300));
}

void tall(WidgetTester tester) => tester.view.physicalSize = const Size(390 * 3, 2600 * 3);

RadioContact contact(String key, String name, int type) =>
    RadioContact(publicKeyHex: key * 32, type: type, outPath: Uint8List(0), name: name);

void main() {
  test('temperature follows the unit', () {
    expect(formatTemperature(45.0, imperial: false), '45.0 °C');
    expect(formatTemperature(45.0, imperial: true), '113.0 °F');
    expect(formatTemperature(-10, imperial: true), '14.0 °F');
  });

  test('contacts that can answer come first, then chat contacts, by name', () {
    final out = telemetryContactOrder([contact('aa', 'Zed', AdvType.chat), contact('bb', 'Beta', AdvType.repeater), contact('cc', 'alpha', AdvType.room)]);
    expect(out.map((c) => c.name), ['alpha', 'Beta', 'Zed']);
  });

  testWidgets('no radio: the gate', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.disconnected;
    await pumpTool(tester, const TelemetryScreen(), host);
    expect(find.byKey(const Key('tool-unavailable')), findsOneWidget);
  });

  testWidgets('this radio: voltage and temperature, listed under Latest answers, and still there after leaving and coming back', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const TelemetryScreen(), host);
    tall(tester);
    expect(find.text('Read this radio'), findsOneWidget);
    await tester.tap(find.byKey(const Key('telemetry-read-self')));
    await alternate(tester);
    expect(find.byKey(const Key('telemetry-result')), findsOneWidget);
    expect(find.text('Battery voltage'), findsOneWidget);
    expect(find.text('Temperature'), findsOneWidget);
    expect(find.textContaining('°C'), findsWidgets);
    expect(find.byKey(const Key('telemetry-latest')), findsOneWidget);
    expect(rig.tools.telemetry.latest, contains('self'));
    await leave(tester);
    await pumpTool(tester, const TelemetryScreen(), host);
    tall(tester);
    expect(find.byKey(const Key('telemetry-latest')), findsOneWidget);
    expect(find.text('This radio'), findsWidgets);
    await leave(tester);
  });

  testWidgets('a contact: the nearest simulated repeater answers with battery, temperature and position; cooldown shows after', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const TelemetryScreen(), host);
    tall(tester);
    await tester.tap(find.text('A contact'));
    await alternate(tester, rounds: 4);
    final r = rig.nearest;
    final tile = find.byKey(Key('telemetry-contact-${r.keyHex.substring(0, 8)}'));
    expect(tile, findsOneWidget);
    expect(find.textContaining('Pick a contact first'), findsOneWidget);
    expect(find.byKey(const Key('airtime-note')), findsOneWidget);
    await tester.tap(tile);
    await tester.pump();
    await tester.tap(find.byKey(const Key('telemetry-ask')));
    await alternate(tester);
    expect(find.text('Answer from ${r.name}'), findsOneWidget);
    expect(find.text('Battery voltage'), findsOneWidget);
    expect(find.byKey(const Key('telemetry-position')), findsOneWidget);
    expect(find.textContaining('from you'), findsOneWidget);
    expect(find.byKey(const Key('tool-map')), findsOneWidget);
    expect(find.textContaining('Wait '), findsWidgets, reason: 'the cooldown is visible in the button');
    await leave(tester);
  });

  testWidgets('a contact the radio does not have: says add it first and points to Discover nearby', (tester) async {
    final fake = FakeToolsRadio()
      ..contactList = [contact('ab', 'Ghost', AdvType.repeater)]
      ..onSend = ((f) => const ErrFrame(ErrCode.notFound));
    final host = FakeToolsHost()..toolsValue = RadioTools(fake, testArbiter());
    await pumpTool(tester, const TelemetryScreen(), host);
    tall(tester);
    await tester.tap(find.text('A contact'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Ghost'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('telemetry-ask')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Not a contact yet'), findsOneWidget);
    expect(find.textContaining('Add it first'), findsOneWidget);
    expect(find.textContaining('Discover nearby'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('a contact that stays silent: a calm note, not an error', (tester) async {
    final fake = FakeToolsRadio()
      ..contactList = [contact('ab', 'Sleepy', AdvType.repeater)]
      ..onSend = ((f) => const SentFrame(flood: false, tag: 1, estTimeoutMs: 100));
    final tools = RadioTools(fake, testArbiter());
    final host = FakeToolsHost()..toolsValue = tools;
    await pumpTool(tester, const TelemetryScreen(), host);
    tall(tester);
    await tester.tap(find.text('A contact'));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.text('Sleepy'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('telemetry-ask')));
    await tester.pump();
    expect(find.byKey(const Key('telemetry-busy')), findsOneWidget);
    await tester.pump(const Duration(seconds: 6)); // the wait is on the fake clock; the scripted radio is instant
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('No answer'), findsOneWidget);
    expect(find.textContaining('out of range or asleep'), findsOneWidget);
    await leave(tester);
  });

  testWidgets('no contacts on the radio: the empty state', (tester) async {
    final host = FakeToolsHost()..toolsValue = RadioTools(FakeToolsRadio(), testArbiter());
    await pumpTool(tester, const TelemetryScreen(), host);
    await tester.tap(find.text('A contact'));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('telemetry-no-contacts')), findsOneWidget);
    await leave(tester);
  });

  testWidgets('every look: no overflow at 2.5x text, small phone, tablet, dark; targets >= 48; contact list semantics', (tester) async {
    final sem = tester.ensureSemantics();
    final (rig, host) = await connectedRig(tester);
    await tester.runAsync(() => rig.tools.telemetry.requestSelf());
    await forEachLook(tester, () => const TelemetryScreen(), () => host, (t) async {
      await t.drag(find.byKey(const Key('telemetry-list')), const Offset(0, 6000)); // state carries over between looks: back to the top
      await t.pump();
      await t.tap(find.text('A contact'));
      await alternate(t, rounds: 4);
      await t.scrollUntilVisible(find.byKey(const Key('telemetry-contacts')), 200, scrollable: find.descendant(of: find.byKey(const Key('telemetry-list')), matching: find.byType(Scrollable)).first);
      expect(find.byKey(const Key('telemetry-contacts')), findsOneWidget);
      expectTapTargets(t);
      expect(find.bySemanticsLabel(RegExp('Repeater')), findsWidgets, reason: 'each contact row reads its name and type');
    });
    await leave(tester);
    sem.dispose();
  });
}
