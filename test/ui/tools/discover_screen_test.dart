import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/companion_link.dart' show ControlPacket;
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/ui/tools/discover_screen.dart';

import '../../support/tools_rig.dart';
import '../../support/tools_ui_rig.dart';

/// The simulated radio runs on real timers, the screen and the tool's listening window on the test clock: let the command
/// leave on a pump, let real time pass for the radio, then move the test clock past the 15 s listening window.
Future<void> advance(WidgetTester tester, double seconds) async {
  for (var i = 0; i < (seconds * 10).round(); i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Futures that finished in the real zone (a cancelled stream subscription) need one real turn before the test clock sees them.
Future<void> settleTail(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  await advance(tester, 1);
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pump();
  await tester.tap(find.byKey(Key(key)));
}

Future<void> simScan(WidgetTester tester) async {
  await tapKey(tester, 'discover-scan');
  await advance(tester, 0.3);
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
  await advance(tester, 16);
  await settleTail(tester);
}

RadioContact contact(String key, String name, {int type = AdvType.repeater, double? lat, double? lon}) =>
    RadioContact(publicKeyHex: key, type: type, outPath: Uint8List(0), name: name, lat: lat, lon: lon);

Uint8List payload(int type, double theirSnr, int tag, List<int> key) =>
    Uint8List.fromList([0x90 | type, (theirSnr * 4).round() & 0xff, tag & 255, (tag >> 8) & 255, (tag >> 16) & 255, (tag >> 24) & 255, ...key]);

class Scripted {
  final FakeToolsRadio radio = FakeToolsRadio();
  late final RadioTools tools = RadioTools(radio, testArbiter());
  int tag = 0;

  /// [answers] gets the tag the scan used and returns the control packets to "hear".
  List<ControlPacket> Function(int tag) answers = (t) => const [];

  Scripted({List<RadioContact> contacts = const []}) {
    radio.contactList = contacts;
    radio.onSend = (f) {
      tag = ByteData.sublistView(f).getUint32(3, Endian.little);
      return const OkFrame();
    };
  }

  Future<void> scan(WidgetTester tester) async {
    await tapKey(tester, 'discover-scan');
    await advance(tester, 0.3);
    for (final p in answers(tag)) {
      radio.control(p);
    }
    await advance(tester, 17);
    await settleTail(tester);
  }
}

ControlPacket heard(double snr, int rssi, Uint8List p) => ControlPacket(DateTime.now(), snr, rssi, 0, p);

List<int> fullKey(int first, int fill) => [first, ...List.filled(31, fill)];

void main() {
  testWidgets('no radio: the gate', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.handedOver;
    await pumpTool(tester, const DiscoverScreen(), host);
    expect(find.text('Radio handed to another app'), findsOneWidget);
    expect(find.byKey(const Key('discover-scan')), findsNothing);
  });

  testWidgets('before the first scan: what it does, the limit, 4 of 4 left, idle line', (tester) async {
    final s = Scripted();
    final host = FakeToolsHost()..toolsValue = s.tools;
    await pumpTool(tester, const DiscoverScreen(), host);
    expect(find.textContaining('only radios in direct range hear'), findsOneWidget);
    expect(find.textContaining('4 scans every 2 minutes'), findsOneWidget);
    expect(find.text('Scans left: 4 of 4'), findsOneWidget);
    expect(find.byKey(const Key('discover-idle')), findsOneWidget);
    expect(find.byKey(const Key('airtime-note')), findsOneWidget);
    // at least one type stays selected
    for (final t in [AdvType.repeater, AdvType.room]) {
      await tester.tap(find.byKey(Key('discover-type-$t')));
      await tester.pump();
    }
    await tester.tap(find.byKey(Key('discover-type-${AdvType.sensor}')));
    await tester.pump();
    expect(tester.widget<FilterChip>(find.byKey(Key('discover-type-${AdvType.sensor}'))).selected, isTrue);
  });

  testWidgets('scan on the simulated radio: sends the control frame, lists the nearest repeater with both directions', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const DiscoverScreen(), host);
    await advance(tester, 0.3);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await advance(tester, 0.5);
    // only repeaters
    await tester.tap(find.byKey(Key('discover-type-${AdvType.room}')));
    await tester.tap(find.byKey(Key('discover-type-${AdvType.sensor}')));
    await tester.pump();
    await simScan(tester);
    final f = rig.radio.sentFrames.where((f) => f[0] == Cmd.sendControlData).single;
    expect(f[2], 0x04, reason: 'repeaters only');
    expect(find.byKey(const Key('discover-result-0')), findsOneWidget);
    expect(find.textContaining('They hear you at'), findsWidgets);
    expect(find.textContaining('You hear them at'), findsWidgets);
    expect(find.textContaining('dBm'), findsWidgets);
    expect(find.byKey(const Key('discover-result-0-added')), findsOneWidget, reason: 'the simulated repeaters are contacts already');
    expect(find.text('In your contacts'), findsWidgets);
    expect(find.byKey(const Key('tool-map')), findsOneWidget);
    expect(find.text('Scans left: 3 of 4'), findsOneWidget);
    final sem = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp(r'Repeater\. They hear you at .*You hear them at .* In your contacts\.')), findsWidgets);
    sem.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('results sorted by the weaker direction; a prefix-only answer cannot be added, a full one can', (tester) async {
    final known = contact('ab${'11' * 31}', 'Ridge', lat: 40.2, lon: -82.9);
    final s = Scripted(contacts: [known]);
    final host = FakeToolsHost()..toolsValue = s.tools;
    s.answers = (t) => [
          heard(-4.25, -125, payload(2, -5.25, t, fullKey(0xdf, 1))), // weak both ways
          heard(-1.0, -110, payload(2, 3.0, t, [0xab, ...List.filled(7, 0x22)])), // 8-byte prefix, better
          heard(6.0, -90, payload(2, 5.5, t, known.publicKeyHex.isEmpty ? [] : Uint8List.fromList([for (var i = 0; i < 32; i++) int.parse(known.publicKeyHex.substring(i * 2, i * 2 + 2), radix: 16)]))),
        ];
    await pumpTool(tester, const DiscoverScreen(), host);
    await advance(tester, 0.3);
    await s.scan(tester);
    // order: Ridge (known, 5.5/6.0), then the prefix-only (3.0/-1.0), then the weak full key
    expect(find.descendant(of: find.byKey(const Key('discover-result-0')), matching: find.text('Ridge')), findsOneWidget);
    expect(find.byKey(const Key('discover-result-0-added')), findsOneWidget);
    expect(find.textContaining('(start only)'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('discover-result-1-add'))).onPressed, isNull);
    expect(find.byKey(const Key('discover-result-1-why')), findsOneWidget);
    expect(find.textContaining('cannot be added'), findsOneWidget);
    // the weak full-key node: add it
    final add = find.byKey(const Key('discover-result-2-add'));
    expect(tester.widget<OutlinedButton>(add).onPressed, isNotNull);
    await tapKey(tester, 'discover-result-2-add');
    await advance(tester, 0.5);
    expect(s.radio.added.single.publicKeyHex, 'df${'01' * 31}');
    expect(s.radio.added.single.type, AdvType.repeater);
    expect(find.byKey(const Key('discover-add-note')), findsOneWidget);
    expect(find.byKey(const Key('discover-result-2-added')), findsOneWidget);
    expect(find.byKey(const Key('discover-result-2-add')), findsNothing);
    await advance(tester, 5); // let the snack bar go
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nothing answers: a calm explanation; scans left drops', (tester) async {
    final s = Scripted();
    final host = FakeToolsHost()..toolsValue = s.tools;
    await pumpTool(tester, const DiscoverScreen(), host);
    await advance(tester, 0.3);
    await s.scan(tester);
    expect(find.byKey(const Key('discover-empty')), findsOneWidget);
    expect(find.textContaining('Nothing answered'), findsWidgets);
    expect(find.text('Scans left: 3 of 4'), findsOneWidget);
  });

  testWidgets('four scans, then the button counts the wait in words and is disabled; not an error', (tester) async {
    final s = Scripted();
    final host = FakeToolsHost()..toolsValue = s.tools;
    await pumpTool(tester, const DiscoverScreen(), host);
    await advance(tester, 0.3);
    for (var i = 0; i < 4; i++) {
      await s.scan(tester);
    }
    expect(find.text('Scans left: 0 of 4'), findsOneWidget);
    expect(find.textContaining('Wait '), findsOneWidget);
    expect(tester.widget<FilledButton>(find.descendant(of: find.byKey(const Key('discover-scan')), matching: find.byType(FilledButton))).onPressed, isNull);
    expect(find.byKey(const Key('discover-problem')), findsNothing);
    expect(s.radio.sent.where((f) => f.frame[0] == Cmd.sendControlData).length, 4);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old firmware: the refusal is a problem note in plain words', (tester) async {
    final s = Scripted();
    s.radio.onSend = (f) => const ErrFrame(ErrCode.unsupportedCmd);
    final host = FakeToolsHost()..toolsValue = s.tools;
    await pumpTool(tester, const DiscoverScreen(), host);
    await advance(tester, 0.3);
    await tapKey(tester, 'discover-scan');
    await advance(tester, 1);
    expect(find.byKey(const Key('discover-problem')), findsOneWidget);
    expect(find.textContaining('needs version 8'), findsOneWidget);
  });

  testWidgets('every look: no overflow, tap targets 48 px, rows readable', (tester) async {
    final known = contact('ab${'11' * 31}', 'A Repeater With A Rather Long Name On A Hill', lat: 40.2, lon: -82.9);
    for (final look in <({Device d, double scale, Brightness b})>[
      (d: Device.iphone, scale: 1.0, b: Brightness.light),
      (d: Device.iphone, scale: 2.5, b: Brightness.dark),
      (d: Device.iphoneSmall, scale: 2.5, b: Brightness.light),
      (d: Device.ipad, scale: 1.0, b: Brightness.dark),
    ]) {
      final s = Scripted(contacts: [known]);
      s.answers = (t) => [
            heard(-4.25, -125, payload(2, -5.25, t, fullKey(0xdf, 1))),
            heard(-1.0, -110, payload(3, 3.0, t, [0xab, ...List.filled(7, 0x22)])),
            heard(6.0, -90, payload(2, 5.5, t, Uint8List.fromList([for (var i = 0; i < 32; i++) int.parse(known.publicKeyHex.substring(i * 2, i * 2 + 2), radix: 16)]))),
          ];
      final host = FakeToolsHost()..toolsValue = s.tools;
      await pumpTool(tester, const DiscoverScreen(), host, device: look.d, textScale: look.scale, brightness: look.b);
      await advance(tester, 0.3);
      await s.scan(tester);
      expect(find.byKey(const Key('discover-result-2')), findsOneWidget);
      expectTapTargets(tester);
      expect(tester.takeException(), isNull, reason: 'overflow at ${look.d.name} x${look.scale} ${look.b.name}');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
