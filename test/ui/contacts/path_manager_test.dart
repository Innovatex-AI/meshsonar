// Chat WP7: the Route screen (modes, find / test / reset, Advanced) and the Choose-repeaters page with the set-path write flag.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/chat/db/misc_repositories.dart' show PathHistoryEntry;
import 'package:meshsonar/chat/models.dart' hide fromHex;
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/radio_tools.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/ui/contacts/path_manager_screen.dart';
import 'package:meshsonar/ui/contacts/route_picker_page.dart';
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

  Future<void> pumpRoute(WidgetTester tester, String key, {bool routeWrite = false, Brightness b = Brightness.light}) async {
    setScreen(tester);
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(b),
      home: PathManagerScreen(manager: rig.chat.contacts, publicKey: key, changes: rig.controller, tools: tools, routeWrite: routeWrite),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> withRoute() async {
    rig.port.radioAdd(radioContact(1, name: 'Maya', path: true));
    rig.chat.contacts.attach(rig.port);
    await rig.chat.contacts.syncNow();
  }

  group('the screen', () {
    testWidgetsT('shipped default: the set-path write is hidden', (tester) async {
      expect(AppFlags.routeWriteVerified, isFalse);
      await withRoute();
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('route-advanced')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('adv-choose')), findsNothing);
      expect(find.byKey(const Key('adv-hash')), findsOneWidget);
    });

    testWidgetsT('route card, three modes with their sentences, Automatic ticked', (tester) async {
      await withRoute();
      await pumpRoute(tester, keyN(1));
      expect(find.text('Route to Maya'), findsOneWidget);
      expect(find.byKey(const Key('route-chain')), findsOneWidget);
      expect(find.text('Automatic'), findsOneWidget);
      expect(find.text('Keep this route'), findsOneWidget);
      expect(find.text('Always search'), findsOneWidget);
      expect(find.text('Learns the best route; searches again if it breaks.'), findsOneWidget);
      expect(find.text('Always uses this route, even if it fails.'), findsOneWidget);
      expect(find.text('Sends to everyone nearby. Slower, uses more airtime.'), findsOneWidget);
      expect(find.byKey(const Key('route-caption')), findsOneWidget);
    });

    testWidgetsT('Keep this route is disabled with the reason when no route is known', (tester) async {
      rig.port.radioAdd(radioContact(1, name: 'Maya'));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      await pumpRoute(tester, keyN(1));
      expect(find.text('No route learned yet. Find a route first.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mode-fixed')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).pathMode, PathMode.auto);
    });

    testWidgetsT('choosing Keep this route pins the route; Always search and Automatic switch back', (tester) async {
      await withRoute();
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('mode-fixed')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(c(keyN(1)).pathMode, PathMode.fixed);
      expect(c(keyN(1)).pinnedPath, '01');
      await tester.tap(find.byKey(const Key('mode-flood')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(c(keyN(1)).pathMode, PathMode.flood);
      expect(c(keyN(1)).pinnedPath, isNull);
      await tester.tap(find.byKey(const Key('mode-auto')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).pathMode, PathMode.auto);
    });

    testWidgetsT('Reset route: action sheet first, then the route is gone and a toast says so', (tester) async {
      await withRoute();
      await pumpRoute(tester, keyN(1));
      await tester.tap(find.byKey(const Key('route-reset')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).hasPath, isTrue);
      await tester.tap(find.byKey(const Key('reset-route-confirm')));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(c(keyN(1)).hasPath, isFalse);
      expect(find.text('Route cleared. The next message searches again.'), findsOneWidget);
      expect(find.text('No route yet'), findsOneWidget);
    });

    testWidgetsT('Find a route now: result card with the route, Use this route to Automatic', (tester) async {
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
      await tester.ensureVisible(find.byKey(const Key('found-use')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('found-use')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('use-auto')));
      await tester.pumpAndSettle();
      expect(c(keyN(1)).pathMode, PathMode.auto);
      expect(rig.store.pathHistory.list(keyN(1)).first.kind, 'discovered');
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
      expect(find.text('Radio not connected'), findsOneWidget);
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
      rig.store.db.putSetting('ping_airtime_ack', '1');
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

  group('Choose repeaters yourself (write flag forced ON in this test only)', () {
    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('route-advanced')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('adv-choose')));
      await tester.pumpAndSettle();
    }

    Future<void> setup(WidgetTester tester) async {
      rig.port.radioAdd(radioContact(1, name: 'Maya'));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      rig.chat.contacts.routeWriteEnabled = () => true;
      rig.store.contacts.upsert(repeater('a1', 'Ridge', lat: 39.1, lon: -84.1));
      rig.store.contacts.upsert(repeater('a1ff', 'Hill'));
      rig.store.contacts.upsert(repeater('c3', 'Far'));
      await pumpRoute(tester, keyN(1), routeWrite: true);
    }

    testWidgetsT('the row is there, picks append, the cap line follows the hash size', (tester) async {
      await setup(tester);
      await openPicker(tester);
      expect(find.text('At most 63 repeaters with 1-byte hashes.'), findsOneWidget);
      await tester.tap(find.byKey(Key('pick-${hashKey('c3').substring(0, 8)}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chip-0')), findsOneWidget);
      expect(find.text('c3'), findsWidgets);
      await tester.tap(find.text('2 bytes'));
      await tester.pumpAndSettle();
      expect(find.text('At most 32 repeaters with 2-byte hashes.'), findsOneWidget);
      expect(find.byKey(const Key('chip-0')), findsOneWidget, reason: 'the chain still fits, so it is kept');
    });

    testWidgetsT('two repeaters sharing a1 show the warning; 2-byte hashes clear it', (tester) async {
      await setup(tester);
      await openPicker(tester);
      await tester.tap(find.byKey(Key('pick-${hashKey('a1').substring(0, 8)}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('share a1'), findsOneWidget);
      expect(find.text('2 repeaters share a1; the radio can\'t tell them apart.'), findsOneWidget);
      await tester.tap(find.text('2 bytes'));
      await tester.pumpAndSettle();
      expect(find.textContaining('share'), findsNothing);
    });

    testWidgetsT('typed hashes: errors in words, then the chain; Save without testing asks, then writes and keeps the route', (tester) async {
      await setup(tester);
      await openPicker(tester);
      await tester.enterText(find.byKey(const Key('picker-text')), 'zz');
      await tester.tap(find.byKey(const Key('picker-text-apply')));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a hash'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('picker-text')), 'c3,a1');
      await tester.tap(find.byKey(const Key('picker-text-apply')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chip-1')), findsOneWidget);
      await tester.tap(find.byKey(const Key('picker-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('picker-save-untested')), findsOneWidget);
      await tester.tap(find.byKey(const Key('picker-save-untested')));
      await tester.pumpAndSettle();
      expect(rig.port.table[keyN(1)]!.outPath, [0xc3, 0xa1]);
      expect(rig.port.table[keyN(1)]!.outPathLen, 2);
      expect(c(keyN(1)).pathMode, PathMode.fixed);
      expect(c(keyN(1)).pinnedPath, 'c3,a1');
    });

    testWidgetsT('Test route before Save: a chain that answers enables a plain Save', (tester) async {
      await setup(tester);
      fake.onSend = (f) {
        expect(f[0], 36);
        final tag = ByteData.sublistView(f).getUint32(1, Endian.little);
        Timer(const Duration(milliseconds: 50), () => fake.push(encodeTraceDataPush(tag, f.sublist(10), [6.0], 4.0, hashSize: 1)));
        return const SentFrame(flood: false, tag: 1, estTimeoutMs: 500);
      };
      await openPicker(tester);
      await tester.tap(find.byKey(Key('pick-${hashKey('c3').substring(0, 8)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picker-test')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Works'), findsOneWidget);
      await tester.tap(find.byKey(const Key('picker-save')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('picker-save-untested')), findsNothing);
      expect(rig.port.table[keyN(1)]!.outPath, [0xc3]);
    });

    testWidgetsT('write refused by the radio: the page stays, nothing is pinned', (tester) async {
      await setup(tester);
      rig.port.failUpload = StateError('x');
      await openPicker(tester);
      await tester.tap(find.byKey(Key('pick-${hashKey('c3').substring(0, 8)}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picker-save')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('picker-save-untested')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('picker-save')), findsOneWidget);
      expect(c(keyN(1)).pathMode, PathMode.auto);
    });
  });

  test('hop cap words', () => expect(hopCapText(3), 'At most 21 repeaters with 3-byte hashes.'));
}
