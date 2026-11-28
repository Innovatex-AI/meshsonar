// Chat WP7: the Route screen (find / test / reset, Advanced). Build 77: no route modes, no Undo of a reset and no
// "Choose repeaters yourself" (the radio alone holds the route, as in the official app).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/misc_repositories.dart' show PathHistoryEntry;
import 'package:meshsonar/chat/models.dart' hide fromHex;
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/ui/contacts/path_manager_screen.dart';
import 'package:meshsonar/ui/design/hop_chain.dart';
import 'package:meshsonar/ui/theme.dart';
import 'package:meshsonar/ui/tools/ping_result_sheet.dart' show showPingOptions;

import '../../chat/contact_support.dart';
import '../../chat/support.dart';
import '../../support/tools_rig.dart';
import 'contacts_ui_support.dart' hide testWidgetsT;
import 'contacts_ui_support.dart' as support show testWidgetsT;
import '../../support/semantics_audit.dart';

String hashKey(String first) => first + 'ee' * (32 - first.length ~/ 2);

Contact repeater(String first, String name, {double? lat, double? lon}) => Contact(
    radioId: radioA, publicKey: hashKey(first), type: ContactType.repeater, name: name, lat: lat, lon: lon, onRadio: true, lastHeardMs: 1759999000000);

void testWidgetsBase(String name, Future<void> Function(WidgetTester) body) => support.testWidgetsT(name, body);

void main() {
  late ContactsRig rig;
  late FakeToolsRadio fake;
  late RadioTools tools;

  // The rig and the scripted radio own streams, so they are built INSIDE the test body (the fake-async zone), not in setUp:
  // events of a stream made outside it would only be delivered after the test.
  void testWidgetsT(String name, Future<void> Function(WidgetTester) body) => testWidgetsBase(name, (tester) async {
        rig = ContactsRig();
        fake = FakeToolsRadio();
        tools = RadioTools(fake, testArbiter());
        addTearDown(rig.dispose);
        await body(tester);
      });

  Contact c(String k) => rig.store.contacts.get(radioA, k)!;

  Future<void> pumpRoute(WidgetTester tester, String key, {Brightness b = Brightness.light}) async {
    setScreen(tester);
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(b),
      home: PathManagerScreen(manager: rig.chat.contacts, publicKey: key, changes: rig.controller, tools: tools),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> withRoute() async {
    rig.port.radioAdd(radioContact(1, name: 'Maya', path: true));
    rig.chat.contacts.attach(rig.port);
    await rig.chat.contacts.syncNow();
  }

  group('the screen', () {
    testWidgetsT('no "Choose repeaters yourself": Advanced shows the hash size, never a route editor', (tester) async {
      await withRoute();
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('route-advanced')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adv-choose')), findsNothing);
      expect(find.byKey(const Key('adv-hash')), findsOneWidget);
    });

    testWidgetsT('route card and the one sentence; no route modes (build 77)', (tester) async {
      await withRoute();
      await pumpRoute(tester, keyN(1));
      expect(find.text('Route to Maya'), findsOneWidget);
      expect(find.byKey(const Key('route-chain')), findsOneWidget);
      expect(find.byKey(const Key('route-caption')), findsOneWidget);
      for (final gone in ['Automatic', 'Keep this route', 'Always search']) {
        expect(find.text(gone), findsNothing, reason: gone);
      }
      for (final k in ['mode-auto', 'mode-fixed', 'mode-flood']) {
        expect(find.byKey(Key(k)), findsNothing, reason: k);
      }
      expect(find.textContaining('Your radio picks the route'), findsOneWidget);
    });

    testWidgetsT('Reset route: the route is gone at once and the toast says what happens next; there is no Undo', (tester) async {
      await withRoute();
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('route-reset')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(c(keyN(1)).hasPath, isFalse);
      expect(rig.port.resets, [keyN(1)]);
      expect(find.text('Route cleared. The next message goes to everyone nearby and your radio learns a new route.'), findsOneWidget);
      expect(find.text('No route yet'), findsOneWidget);
      expect(find.text('Undo'), findsNothing, reason: 'the app never writes a route back to the radio');
    });

    testWidgetsT('Reset route is inert with no route', (tester) async {
      rig.port.radioAdd(radioContact(1, name: 'Maya'));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpRoute(tester, keyN(1));
      expect(find.text('No route saved'), findsOneWidget);
      await tester.tap(find.byKey(const Key('route-reset')));
      await tester.pumpAndSettle();
      expect(rig.port.resets, isEmpty);
    });

    testWidgetsT('Find a route now: result card with the route; nothing to save, it goes into the history', (tester) async {
      await withRoute();
      fake.onSend = (f) {
        expect(f[0], 52);
        Timer(const Duration(milliseconds: 50), () => fake.push(encodePathDiscoveryPush(fromHex(keyN(1)), 2, [0xa1, 0xb2], 1, [0xb2])));
        return const SentFrame(flood: true, tag: 1, estTimeoutMs: 500);
      };
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('route-find')));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const Key('found-card')), findsOneWidget);
      expect(find.textContaining('Found a route'), findsOneWidget);
      expect(c(keyN(1)).lastPingOk, isTrue);
      expect(find.byKey(const Key('found-note')), findsOneWidget);
      expect(find.byKey(const Key('found-use')), findsNothing, reason: 'no route is pinned or written by the app');
      expect(rig.store.pathHistory.list(keyN(1)).first.kind, 'discovered');
      expect(rig.port.uploads, isEmpty);
    });

    testWidgetsT('Find a route now with no reply says so in words', (tester) async {
      await withRoute();
      fake.onSend = (f) => const SentFrame(flood: true, tag: 1, estTimeoutMs: 100);
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('route-find')));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 50));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Not heard. Out of range, route out of date, or the radio is busy.'), findsOneWidget);
      expect(c(keyN(1)).lastPingOk, isFalse);
      expect(rig.store.pingResults.list(keyN(1)).first.failReason, 'noReply');
    });

    testWidgetsT('radio away: Test this route says so; Find explains', (tester) async {
      await withRoute();
      rig.chat.contacts.detach();
      await pumpRoute(tester, keyN(1));
      expect(find.text('Radio not connected'), findsNWidgets(2), reason: 'Find and Test both say why');
      await tester.tap(find.byKey(const Key('route-find')));
      await tester.pumpAndSettle();
      expect(find.text('Connect your radio to look for a route.'), findsOneWidget);
    });

    testWidgetsT('Advanced lists recent deliveries and route history', (tester) async {
      await withRoute();
      rig.chat.contacts.recordPing(keyN(1), kind: 'discovery', ok: true);
      rig.store.pathHistory.add(PathHistoryEntry(contactKey: keyN(1), tsMs: 1759999000000, kind: 'learned', hops: const ['01']));
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('route-advanced')));
      await tester.pumpAndSettle();
      expect(find.text('Nothing delivered yet'), findsOneWidget);
      expect(find.textContaining('Learned'), findsOneWidget);
      expect(find.text('1 byte'), findsOneWidget);
    });

    // WP14: AX2 and AX5 at 393 / 375 / 744 / 1024 wide: no overflow, iOS tap targets, labelled targets.
    for (final (w, h) in [(393.0, 852.0), (375.0, 667.0), (744.0, 1133.0), (1024.0, 768.0)]) {
      for (final scale in [2.0, 3.1]) {
        testWidgetsT('Route screen at ${w.toInt()} wide, text ${scale}x', (tester) async {
          await withRoute();
          final sem = tester.ensureSemantics();
          setScreen(tester, w: w, h: h, scale: scale);
          await tester.pumpWidget(MaterialApp(
            theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
            home: PathManagerScreen(manager: rig.chat.contacts, publicKey: keyN(1), changes: rig.controller, tools: tools),
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expectHeader(tester);
          sem.dispose();
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        });
      }
    }

    testWidgetsT('dark and AX text lay out without overflow', (tester) async {
      await withRoute();
      setScreen(tester, scale: 2.0);
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: PathManagerScreen(manager: rig.chat.contacts, publicKey: keyN(1), changes: rig.controller, tools: tools),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(HopChain), findsOneWidget);
    });
  });

  group('Ping options (long press on the Ping tile)', () {
    testWidgetsT('the sheet offers Ping, Direct only and the 2 and 3 byte ID sizes; a choice runs the ping sheet', (tester) async {
      rig.store.contacts.upsert(repeater('a1', 'Ridge'));
      setScreen(tester);
      final ridge = c(hashKey('a1'));
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: Builder(builder: (ctx) => Scaffold(body: TextButton(key: const Key('open'), onPressed: () => showPingOptions(ctx, contact: ridge, manager: rig.chat.contacts, tools: tools), child: const Text('x')))),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('ping-options')), findsOneWidget);
      expect(find.text('Direct only'), findsOneWidget);
      expect(find.text('Direct only, 2-byte IDs'), findsOneWidget);
      expect(find.text('Direct only, 3-byte IDs'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ping-opt-direct-2')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Ping Ridge'), findsWidgets);
    });
  });

}
