import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/ui/tools/adverts_screen.dart';

import '../../support/tools_ui_rig.dart';

String shortKeyOf(String name) => toHex(sha256(utf8.encode('meshsonar-sim-advert:$name'))).substring(0, 8);

Future<void> scrollTo(WidgetTester tester, Finder f) async {
  if (f.evaluate().isNotEmpty && tester.any(f.hitTestable())) return;
  await tester.scrollUntilVisible(f, 200, scrollable: find.descendant(of: find.byKey(const Key('adverts-list')), matching: find.byType(Scrollable)).first);
}

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
  testWidgets('no radio: the plain-language gate, nothing else', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.disconnected;
    await pumpTool(tester, const AdvertsScreen(), host);
    expect(find.text('Radio not connected'), findsOneWidget);
    expect(find.byKey(const Key('adverts-send-local')), findsNothing);
    await end(tester);
  });

  testWidgets('empty: honest words, airtime note, the hint-not-proof line is not shown without adverts', (tester) async {
    final (_, host) = await connectedRig(tester);
    await pumpTool(tester, const AdvertsScreen(), host, device: Device.ipad);
    expect(find.byKey(const Key('adverts-empty')), findsOneWidget);
    expect(find.textContaining('Nothing heard yet. On a quiet mesh this can take minutes'), findsOneWidget);
    expect(find.byKey(const Key('airtime-note')), findsOneWidget);
    expect(find.textContaining('uses about'), findsOneWidget);
    expect(find.byKey(const Key('adverts-send-local')), findsOneWidget);
    await end(tester);
  });

  testWidgets('send local advert: the frame reaches the radio, a calm note shows, the button counts down', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const AdvertsScreen(), host, device: Device.ipad);
    await tester.tap(find.byKey(const Key('adverts-send-local')));
    await settleReal(tester);
    expect(rig.radio.sentAdverts, [false]);
    expect(find.byKey(const Key('adverts-result')), findsOneWidget);
    expect(find.textContaining('Local advert sent'), findsOneWidget);
    expect(find.textContaining('Wait'), findsOneWidget);
    await end(tester);
  });

  testWidgets('whole-mesh advert asks first; cancel sends nothing; confirm sends and the 5 minute cooldown applies', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const AdvertsScreen(), host, device: Device.ipad);
    await tester.tap(find.byKey(const Key('adverts-send-flood')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adverts-flood-confirm')), findsOneWidget);
    expect(find.textContaining('repeater that hears it will send it on'), findsOneWidget);
    expect(find.textContaining('usually enough'), findsOneWidget);
    await tester.tap(find.byKey(const Key('adverts-flood-cancel')));
    await tester.pumpAndSettle();
    expect(rig.radio.sentAdverts, isEmpty);
    await tester.tap(find.byKey(const Key('adverts-send-flood')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('adverts-flood-go')));
    await settleReal(tester);
    expect(rig.radio.sentAdverts, [true]);
    expect(find.textContaining('Advert sent to the whole mesh'), findsOneWidget);
    expect(find.text('Wait 5 min'), findsOneWidget);
    await end(tester);
  });

  testWidgets('heard adverts: scope chips, path, position and distance, clock skew, details, scope sheet, clear', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const AdvertsScreen(), host, device: Device.ipad);
    final nowSecs = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await inject(tester, () {
      rig.radio.injectAdvertHeard('Hill Top', lat: 40.13, lon: -82.93, pathHashes: [0xaa, 0xbb], scope: '#cmh', snrDb: 5.5);
      rig.radio.injectAdvertHeard('Plain Node', pathHashes: const [], snrDb: -3, timestamp: nowSecs + 600);
    });

    expect(find.textContaining('2 nodes heard since'), findsOneWidget);
    expect(find.text('A heard advert is a hint, not proof of who sent it.'), findsOneWidget);
    final hill = shortKeyOf('Hill Top'), plain = shortKeyOf('Plain Node');
    await scrollTo(tester, find.byKey(Key('adverts-row-$hill')));
    expect(find.descendant(of: find.byKey(Key('adverts-scope-$hill')), matching: find.text('Region scope check: in scope: #cmh')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('adverts-scope-$plain')), matching: find.text('Region scope check: unscoped')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('adverts-row-$hill')), matching: find.textContaining('via aa > bb')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('adverts-row-$plain')), matching: find.text('Direct')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('adverts-row-$hill')), matching: find.textContaining('from you')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('adverts-row-$hill')), matching: find.textContaining('40.1300, -82.9300')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('adverts-row-$plain')), matching: find.text('Its clock is 10 min off from yours')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('adverts-row-$hill')), matching: find.textContaining('Its clock')), findsNothing);
    expect(find.descendant(of: find.byKey(Key('adverts-row-$hill')), matching: find.textContaining('+5.5 dB, strong')), findsOneWidget);

    await tester.tap(find.byKey(Key('adverts-scope-$hill')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adverts-scope-sheet')), findsOneWidget);
    expect(find.textContaining('cannot be turned back into a name'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(of: find.byKey(Key('adverts-row-$hill')), matching: find.byType(InkWell)).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('adverts-detail')), findsOneWidget);
    expect(find.textContaining(hill), findsWidgets);
    expect(find.textContaining('Scoped flood'), findsWidgets);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const Key('adverts-clear')), -200, scrollable: find.descendant(of: find.byKey(const Key('adverts-list')), matching: find.byType(Scrollable)).first);
    await tester.tap(find.byKey(const Key('adverts-clear')));
    await settleReal(tester, real: const Duration(milliseconds: 50));
    expect(find.byKey(const Key('adverts-empty')), findsOneWidget);
    await end(tester);
  });

  testWidgets('rows read their facts to a screen reader', (tester) async {
    final sem = tester.ensureSemantics();
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const AdvertsScreen(), host, device: Device.ipad);
    await inject(tester, () => rig.radio.injectAdvertHeard('Hill Top', lat: 40.13, lon: -82.93, pathHashes: [0xaa], snrDb: 2));
    await scrollTo(tester, find.byKey(Key('adverts-row-${shortKeyOf('Hill Top')}')));
    expect(find.bySemanticsLabel(RegExp(r'^Hill Top\. Repeater.*via aa.*Opens details\.$')), findsOneWidget);
    sem.dispose();
    await end(tester);
  });

  testWidgets('every look: no overflow, tap targets 48', (tester) async {
    final (rig, host) = await connectedRig(tester);
    await pumpTool(tester, const AdvertsScreen(), host);
    await inject(tester, () {
      rig.radio.injectAdvertHeard('A very long repeater name that keeps going and going', lat: 40.1, lon: -82.9, pathHashes: [1, 2, 3], scope: '#cmh');
      rig.radio.injectAdvertHeard('B', pathHashes: const []);
    });
    await forEachLook(tester, () => const AdvertsScreen(), () => host, (t) async {
      await t.pump(const Duration(milliseconds: 300));
      expectTapTargets(t);
    });
    await end(tester);
  });
}
