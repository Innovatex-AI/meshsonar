// CR4 (chat + radio round): hop names with ambiguity and the roster fallback, the route a sent DM actually used, the info card
// under a long-pressed bubble, the details sheet's repeats, and the path map.
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/hop_resolver.dart';
import 'package:meshsonar/chat/message_info.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_info_card.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/contacts/message_details.dart';
import 'package:meshsonar/ui/theme.dart';

import 'chat_kit.dart';

Contact rep(String key, String name, {double? lat, double? lon, ContactType type = ContactType.repeater}) =>
    Contact(radioId: radioA, publicKey: key.padRight(64, '0'), type: type, name: name, lat: lat, lon: lon);

ChatMessage msg({bool out = false, ConvKind kind = ConvKind.dm, String? sentPath, int? sentHashSize, int? pathLen, String? pathHashes, int repeats = 0, Route? route}) =>
    ChatMessage(
      id: 'x',
      radioId: radioA,
      convKind: kind,
      convKey: kind == ConvKind.channel ? 'c:1' : 'd:bob',
      direction: out ? Direction.outgoing : Direction.incoming,
      senderName: out ? null : 'Ann',
      tsSender: 1000,
      tsLocalMs: 1000000,
      text: 'hi',
      state: out ? MessageState.sent : MessageState.received,
      dedupeKey: 'k',
      sentPath: sentPath,
      sentHashSize: sentHashSize,
      pathLen: pathLen,
      pathHashes: pathHashes,
      repeatsHeard: repeats,
      route: route,
    );

void main() {
  group('HopResolver', () {
    test('radio contact first; roster fills the name and position the radio lacks; ambiguity and unknown are explicit', () {
      final r = HopResolver(
        contacts: [rep('a1', 'Ridge'), rep('b2aa', 'Hill'), rep('b2bb', 'Hollow'), rep('c3', 'Not a repeater', type: ContactType.companion)],
        roster: const [
          RosterNode(key: 'a1000000', name: 'Ridge (roster)', lat: 40.0, lon: -83.0),
          RosterNode(key: 'd4cc', name: 'Tower', lat: 39.9, lon: -82.9),
          RosterNode(key: 'e5aa', name: 'East A', lat: 1, lon: 1),
          RosterNode(key: 'e5bb', name: 'East B', lat: 2, lon: 2),
        ],
      );
      final ridge = r.resolve('A1');
      expect((ridge.name, ridge.source, ridge.ambiguous), ('Ridge', HopSource.radio, false));
      expect(r.resolve('b2').ambiguous, isTrue);
      expect(r.resolve('b2').candidates, ['Hill', 'Hollow']);
      expect(r.resolve('b2').label, '?b2');
      final tower = r.resolve('d4');
      expect((tower.name, tower.source, tower.lat), ('Tower', HopSource.roster, 39.9));
      expect(r.resolve('e5').description, '?e5 (2 possible: East A, East B)');
      expect(r.resolve('c3').known, isFalse, reason: 'only repeaters and rooms name a hop');
      expect(r.resolve('ff').description, '?ff (unknown repeater)');
    });
  });

  group('messageInfo', () {
    final res = HopResolver(contacts: [rep('01', 'One'), rep('02', 'Two'), rep('09', 'Nine')]);
    final bob = Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'Bob', outPath: Uint8List.fromList([9]), outPathLen: 1);

    test('a sent DM shows the route it used, not the contact route of today', () {
      final i = messageInfo(msg(out: true, sentPath: '0102', sentHashSize: 1, route: Route.direct), resolver: res, contact: bob, peer: 'Bob');
      expect(i.hops, ['One', 'Two']);
      expect(i.routeIsActual, isTrue);
      expect(i.chips, ['You', 'One', 'Two', 'Bob']);
    });

    test('a sent DM from before routes were recorded falls back to the saved route, marked as such', () {
      final i = messageInfo(msg(out: true, route: Route.direct), resolver: res, contact: bob, peer: 'Bob');
      expect(i.hops, ['Nine']);
      expect(i.routeIsActual, isFalse);
    });

    test('a sent channel message says how many repeaters heard it', () {
      expect(messageInfo(msg(out: true, kind: ConvKind.channel)).routeWord, 'Sent to everyone nearby');
      expect(messageInfo(msg(out: true, kind: ConvKind.channel, repeats: 2)).routeWord, 'Heard by 2 repeaters');
    });

    test('relayedBySummary: distinct, first heard first, capped', () {
      MessageRepeat r(String p) => MessageRepeat(messageId: 'x', heardMs: 0, pathHashes: p, hashSize: 1, hops: p.length ~/ 2);
      final v = repeatViews(msg(out: true, kind: ConvKind.channel), [r('01'), r('0102'), r('02'), r('09')], res);
      expect(relayedBySummary(v), 'One, Two +1');
    });
  });

  group('widgets', () {
    late ChatKit kit;
    setUp(() {
      kit = ChatKit();
      MessageMenu.useContextMenu = true;
      MessagePathMapScreen.mapBuilder = (context, placed, connect) =>
          Text('MAP ${placed.map((n) => n.label).join(',')} connect=$connect', key: const Key('fake-map'));
    });
    tearDown(() {
      kit.dispose();
      MessagePathMapScreen.mapBuilder = null;
    });

    /// The iOS context menu opens on a held press (as a finger does), not on the test's quick long-press.
    Future<void> holdOn(WidgetTester tester, Finder f) async {
      final g = await tester.startGesture(tester.getCenter(f));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await g.up();
      await tester.pumpAndSettle();
    }

    Widget iosHost(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS), home: child);

    Future<(Channel, ChatMessage)> sentWithRepeats(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      kit.store.contacts.upsert(rep('a1', 'Ridge', lat: 40.0, lon: -83.0));
      kit.store.contacts.upsert(rep('b2', 'Hill'));
      final ch = await kit.channel(1, 'Ohio');
      kit.sink.connected = true;
      final m = kit.service.send(radioId: radioA, convKey: ch.convKey, text: 'on my way');
      await kit.service.pump();
      final ts = kit.store.messages.get(m.id)!.tsSender;
      kit.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: ts, text: 'Me: on my way', pathHashes: 'a1', hops: 1, snr: 6.5, rssi: -92));
      kit.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: ts, text: 'Me: on my way', pathHashes: 'b2a1', hops: 2, snr: -3, rssi: -110));
      return (ch, kit.store.messages.get(m.id)!);
    }

    testWidgets('long-press a sent channel message: the card says who relayed it; Path on map shows the repeaters as points', (tester) async {
      final (ch, m) = await sentWithRepeats(tester);
      await tester.pumpWidget(iosHost(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pumpAndSettle();
      await holdOn(tester, find.byKey(Key('bubble-${m.id}')));
      expect(find.byKey(const Key('message-info-card')), findsOneWidget);
      expect(find.textContaining('Heard by 2 repeaters'), findsWidgets);
      expect(find.text('Relayed by Ridge, Hill'), findsOneWidget);
      expect(find.byKey(const Key('card-times')), findsOneWidget);
      await tester.tap(find.byKey(Key('menu-pathMap-${m.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('path-map-screen')), findsOneWidget);
      expect(find.text('MAP Ridge connect=false'), findsOneWidget, reason: 'only Ridge has a position; no line between separate repeats');
      expect(find.byKey(const Key('path-map-missing')), findsOneWidget, reason: 'Hill has no position and is listed under the map');
    });

    testWidgets('a received message with known hops: the card shows the chain sender › hops › you', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      kit.store.contacts.upsert(rep('a1', 'Ridge'));
      final ch = await kit.channel(1, 'Ohio');
      kit.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 1, timestamp: 500, text: 'Ann: hello', snr: 4.25, pathLen: 1, pathHashes: 'a1', hashSize: 1, rssi: -97));
      final m = kit.store.messages.page(ch.convKey).messages.single;
      await tester.pumpWidget(iosHost(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pumpAndSettle();
      await holdOn(tester, find.byKey(Key('bubble-${m.id}')));
      expect(find.byKey(const Key('hop-chain')), findsOneWidget);
      expect(find.textContaining('SNR 4.3 dB · RSSI -97 dBm'), findsOneWidget);
      expect(find.byKey(Key('menu-pathMap-${m.id}')), findsNothing, reason: 'Ridge has no known position');
      expect(find.byKey(Key('menu-details-${m.id}')), findsOneWidget);
    });

    testWidgets('details lists every repeat with who relayed it, the path, signal and delay', (tester) async {
      final (_, m) = await sentWithRepeats(tester);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageDetails(chat: kit.service, messageId: m.id))));
      await tester.pumpAndSettle();
      expect(find.text('REPEATS (2)'), findsOneWidget);
      expect(find.text('Relayed by Ridge'), findsOneWidget);
      expect(find.text('Relayed by Hill'), findsOneWidget);
      expect(find.textContaining('SNR 6.5 · RSSI -92'), findsOneWidget);
      expect(find.byKey(const Key('details-map')), findsOneWidget);
    });
  });
}
