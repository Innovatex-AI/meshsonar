import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/radio/tools/rx_log.dart';
import 'package:meshsonar/ui/tools/rx_log_screen.dart';

import '../../support/tools_ui_rig.dart';

/// The simulated radio's timers are real ones: put packets on the air inside runAsync.
Future<void> inject(WidgetTester tester, void Function() body) async {
  await tester.runAsync(() async {
    body();
    await Future<void>.delayed(const Duration(milliseconds: 500));
  });
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

void main() {
  testWidgets('no radio: the plain-language gate', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.disconnected;
    await pumpTool(tester, const RxLogScreen(), host);
    expect(find.text('No radio connected'), findsOneWidget);
    expect(find.byKey(const Key('rxlog-privacy')), findsNothing);
    await end(tester);
  });

  testWidgets('empty: the privacy card is there with the ring size, and the empty words are honest', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const RxLogScreen(), host, device: Device.ipad);
    expect(find.byKey(const Key('rxlog-privacy')), findsOneWidget);
    expect(find.textContaining('headers only'), findsOneWidget);
    expect(find.textContaining('never read or stored'), findsOneWidget);
    expect(find.textContaining('nothing is decrypted'), findsOneWidget);
    expect(find.textContaining('last ${rig.tools.rxLog.capacity} packets'), findsOneWidget);
    expect(find.textContaining('Your own radio\u2019s sends and replies appear here too'), findsOneWidget);
    await end(tester);
  });

  testWidgets('packets on the air show up with route, hops, path, signal; counts and filters work', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const RxLogScreen(), host, device: Device.ipad);
    await inject(tester, () {
      rig.radio.injectAdvertHeard('Hill Top', lat: 40.13, lon: -82.93, pathHashes: [0xaa, 0xbb], scope: '#cmh', snrDb: 5.5);
      rig.radio.injectChatter('Ann', 'hello', slot: 0);
    });
    expect(find.text('2 heard, 2 kept'), findsOneWidget);
    expect(find.textContaining('Advert from Hill Top (repeater)'), findsOneWidget);
    expect(find.textContaining('Scoped flood, 2 hops, 1-byte hashes'), findsOneWidget);
    expect(find.text('Path aa > bb'), findsOneWidget);
    expect(find.text('in scope: #cmh'), findsOneWidget);
    expect(find.textContaining('+5.5 dB'), findsOneWidget);
    expect(find.text('Channel message 1'), findsOneWidget);

    await tester.tap(find.byKey(Key('rxlog-type-${PayloadType.advert}')));
    await tester.pump();
    expect(find.text('Filter on: 1 shown of 2 kept'), findsOneWidget);
    expect(find.textContaining('Advert from Hill Top'), findsOneWidget);
    expect(find.textContaining('Channel message on another channel'), findsNothing);
    await tester.tap(find.byKey(const Key('rxlog-filter-clear')));
    await tester.pump();
    expect(find.textContaining('Filter on'), findsNothing);
    await end(tester);
  });

  testWidgets('known channel is named only for a channel you joined; another one says so; no message text anywhere', (tester) async {
    final (rig, host) = await connectedRig(tester);
    host.channels = [KnownChannel('Public', Uint8List.fromList(publicChannelSecret))];
    await pumpTool(tester, const RxLogScreen(), host, device: Device.ipad);
    await tester.pump();
    await inject(tester, () {
      rig.radio.injectChatter('Ann', 'secret words here', slot: 0);
      rig.radio.injectChatter('Bob', 'other words there', slot: 1);
    });
    expect(find.textContaining('known channel: Public'), findsOneWidget);
    expect(find.textContaining('Channel message on another channel'), findsOneWidget);
    expect(find.textContaining('secret words'), findsNothing);
    expect(find.textContaining('other words'), findsNothing);
    expect(find.textContaining('Ann'), findsNothing);

    await tester.tap(find.byKey(const Key('rxlog-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rxlog-filter-known')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('Filter on: 1 shown of 2 kept'), findsOneWidget);
    expect(find.textContaining('known channel: Public'), findsOneWidget);
    await end(tester);
  });

  testWidgets('pause stops the list and counts what it missed; resume lists again; clear empties', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const RxLogScreen(), host, device: Device.ipad);
    await inject(tester, () => rig.radio.injectChatter('Ann', 'one'));
    await tester.tap(find.byKey(const Key('rxlog-pause')));
    await tester.pump();
    expect(find.text('Resume'), findsOneWidget);
    await inject(tester, () => rig.radio.injectChatter('Ann', 'two'));
    expect(find.text('Paused: 1 packet not listed. They are still counted.'), findsOneWidget);
    expect(find.text('2 heard, 1 kept'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rxlog-pause')));
    await tester.pump();
    await inject(tester, () => rig.radio.injectChatter('Ann', 'three'));
    expect(find.text('3 heard, 2 kept'), findsOneWidget);
    await tester.tap(find.byKey(const Key('rxlog-clear')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('rxlog-empty')), findsOneWidget);
    expect(find.text('0 heard, 0 kept'), findsOneWidget);
    await end(tester);
  });

  testWidgets('copy as CSV: headers only, to the clipboard, and it says how many rows', (tester) async {
    String? clip;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const RxLogScreen(), host, device: Device.ipad);
    await inject(tester, () {
      rig.radio.injectChatter('Ann', 'secret words here');
      rig.radio.injectAdvertHeard('Hill Top', lat: 40.13, lon: -82.93);
    });
    await tester.tap(find.byKey(const Key('rxlog-export')));
    await tester.pump();
    expect(find.text('Copied 2 rows (headers only, no message text)'), findsOneWidget);
    expect(clip, startsWith('time_utc,route,payload_type'));
    expect(clip, contains('Channel message'));
    expect(clip, contains('Hill Top'));
    expect(clip!.contains('secret words'), isFalse);
    expect(clip!.contains('40.13'), isFalse, reason: 'positions are not exported');
    await end(tester);
  });

  testWidgets('detail sheet: header fields, transport codes, advert facts; never message text', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const RxLogScreen(), host, device: Device.ipad);
    await inject(tester, () => rig.radio.injectAdvertHeard('Hill Top', lat: 40.13, lon: -82.93, pathHashes: [0xaa], scope: '#cmh'));
    await tester.tap(find.textContaining('Advert from Hill Top').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rxlog-detail')), findsOneWidget);
    expect(find.textContaining('Transport codes:'), findsOneWidget);
    expect(find.text('Region scope:'), findsOneWidget);
    expect(find.text('in scope: #cmh'), findsWidgets);
    expect(find.text('Advert name:'), findsOneWidget);
    expect(find.text('40.13000, -82.93000'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await inject(tester, () => rig.radio.injectChatter('Ann', 'secret words here', slot: 1));
    await tester.tap(find.textContaining('Channel message on another channel').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('Channel hash byte:'), findsOneWidget);
    expect(find.text('Message text is never shown here.'), findsOneWidget);
    expect(find.textContaining('secret words'), findsNothing);
    await end(tester);
  });

  testWidgets('rows read their facts to a screen reader', (tester) async {
    final sem = tester.ensureSemantics();
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const RxLogScreen(), host, device: Device.ipad);
    await inject(tester, () => rig.radio.injectAdvertHeard('Hill Top', pathHashes: [0xaa], snrDb: 2));
    expect(find.bySemanticsLabel(RegExp(r'Advert from Hill Top \(repeater\)\..*1 hop.*Opens details\.$')), findsOneWidget);
    sem.dispose();
    await end(tester);
  });

  testWidgets('every look: no overflow, tap targets 48', (tester) async {
    final (rig, host) = await connectedRig(tester);
    host.channels = [KnownChannel('A rather long channel name', Uint8List.fromList(publicChannelSecret))];
    await pumpTool(tester, const RxLogScreen(), host);
    await inject(tester, () {
      rig.radio.injectAdvertHeard('A very long repeater name that keeps going and going', lat: 40.1, lon: -82.9, pathHashes: [1, 2, 3], scope: '#cmh');
      rig.radio.injectChatter('Ann', 'hi', slot: 0);
    });
    await forEachLook(tester, () => const RxLogScreen(), () => host, (t) async {
      await t.pump(const Duration(milliseconds: 300));
      expectTapTargets(t);
    });
    await end(tester);
  });
}
