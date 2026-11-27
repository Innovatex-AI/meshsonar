// Build 77, redesign round 3 (Chat) on the delivery engine: the behaviour each item changed, one test or more per item.
// C-U2 and D4 (MeshTrack) are in test/ui/meshtrack/round3_meshtrack_test.dart; C-U1 / A1 / A2 in
// test/alerts/alert_coordinator_round3_test.dart; message details (tries, log, Cancel, N-U3) in
// test/ui/contacts/message_details_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/hop_resolver.dart';
import 'package:meshsonar/core/time_format.dart' as tf;
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/ui/chat/chat_banner_host.dart';
import 'package:meshsonar/ui/chat/composer.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/hop_names.dart';
import 'package:meshsonar/ui/chat/message_format.dart';
import 'package:meshsonar/ui/chat/message_info_card.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast;
import 'package:meshsonar/ui/design/tokens.dart';

import '../../support/photo_fakes.dart' show privateUrlA, privateKeyA;
import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() {
    kit = ChatKit();
    MessageMenu.useContextMenu = false;
  });
  tearDown(() => kit.dispose());

  String dm() => ConvKey.dm(bobKey);

  group('direct-message thread on the delivery engine', () {
    testWidgets('a message still being tried says "try n of m" from the engine and has Cancel, which stops it', (tester) async {
      setSize(tester);
      kit.bob();
      final m = kit.service.send(radioId: radioA, convKey: dm(), text: 'on my way');
      await kit.service.pump();
      final p = kit.service.deliveryProgress(m.id);
      expect(p.active, isTrue);
      kit.clockMs += 25000; // the try count shows once the first try has been out a while
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: dm())));
      await tester.pump();
      expect(find.textContaining('try 1 of ${p.tryCount}'), findsOneWidget);
      expect(find.byKey(Key('cancel-${m.id}')), findsOneWidget);
      await tester.tap(find.byKey(Key('cancel-${m.id}')));
      await tester.pump();
      expect(kit.store.messages.get(m.id)!.state, MessageState.failed);
      expect(kit.store.messages.get(m.id)!.failReason, FailReason.cancelled);
      expect(find.byKey(Key('cancel-${m.id}')), findsNothing);
      dismissAppToast();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('the long-press menu of a message being tried offers Cancel sending instead of Delete', (tester) async {
      setSize(tester);
      kit.bob();
      final m = kit.service.send(radioId: radioA, convKey: dm(), text: 'still trying');
      await kit.service.pump();
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: dm())));
      await tester.pump();
      await tester.longPress(find.text('still trying'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('act-cancel')), findsOneWidget);
      expect(find.byKey(const Key('act-delete')), findsNothing);
      await tester.tap(find.byKey(const Key('act-cancel')));
      await tester.pumpAndSettle();
      expect(kit.store.messages.get(m.id)!.failReason, FailReason.cancelled);
      dismissAppToast();
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('rule 16: a person who never confirmed a message gets the "add you" note; it goes after their first confirmation', (tester) async {
      setSize(tester);
      kit.bob();
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: dm())));
      await tester.pump();
      expect(find.byKey(const Key('needs-add-you')), findsOneWidget);
      expect(find.text('$needsToAddYouText.'), findsOneWidget);
      kit.store.contacts.markConfirmed(radioA, bobKey, kit.clockMs);
      await tester.pumpWidget(host(ConversationScreen(key: UniqueKey(), controller: kit.controller, convKey: dm())));
      await tester.pump();
      expect(find.byKey(const Key('needs-add-you')), findsNothing);
    });

    testWidgets('no "Probably delivered" and no route-broken card exist any more', (tester) async {
      setSize(tester);
      kit.bob();
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: dm())));
      await tester.pump();
      expect(find.textContaining('Probably delivered'), findsNothing);
      expect(find.byKey(const Key('route-broken-card')), findsNothing);
    });
  });

  group('C-U4: a thread with unread messages opens at the first unread, with the true count', () {
    testWidgets('63 unread in a busy channel: "63 new messages" on screen, the oldest unread under it', (tester) async {
      setSize(tester);
      final ch = await kit.channel(1, 'Ohio');
      for (var i = 0; i < 20; i++) {
        kit.clockMs += 1000;
        kit.incoming(ch, 'Ann', 'read $i', ts: kit.clockMs ~/ 1000);
      }
      kit.service.markRead(ch.convKey);
      for (var i = 0; i < 63; i++) {
        kit.clockMs += 1000;
        kit.incoming(ch, 'Ann', i == 0 ? 'first unread' : 'unread $i', ts: kit.clockMs ~/ 1000);
      }
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(find.byKey(const Key('unread-marker')), findsOneWidget);
      expect(find.textContaining('63 new messages'), findsOneWidget, reason: 'build 76 capped this at the 40 loaded');
      expect(find.text('first unread'), findsOneWidget, reason: 'it opens AT the first unread, not at the bottom');
      expect(find.text('unread 62'), findsNothing);
    });
  });

  group('C-U6: Connect from inside a thread', () {
    testWidgets('radio not connected: the note has Connect; while reconnecting it says so with no button', (tester) async {
      setSize(tester);
      kit.bob();
      kit.sink.connected = false;
      var connects = 0;
      Widget composer({bool connecting = false}) => host(Scaffold(
          body: Align(
              alignment: Alignment.bottomCenter,
              child: Composer(key: UniqueKey(), controller: kit.controller, convKey: dm(), onConnect: (_) => connects++, connecting: connecting))));
      await tester.pumpWidget(composer());
      await tester.pump();
      expect(find.text('Radio not connected. Sends when it connects.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('composer-connect')));
      expect(connects, 1);
      await tester.pumpWidget(composer(connecting: true));
      await tester.pump();
      expect(find.text('Reconnecting to your radio…'), findsOneWidget);
      expect(find.byKey(const Key('composer-connect')), findsNothing);
    });
  });

  group('C-V3: one time style through lib/core/time_format.dart', () {
    tearDown(() {
      tf.use24HourClock = false;
      tf.activeTimeZone = tf.TimeZonePreference.phone;
    });

    testWidgets('bubble and list times follow the phone 12/24 h setting and the Local / UTC setting', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(host(Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      final at = DateTime.utc(2026, 11, 27, 18, 14).millisecondsSinceEpoch;
      tf.activeTimeZone = tf.TimeZonePreference.utc;
      expect(timeLabel(ctx, at), contains('6:14 PM'));
      expect(timeLabel(ctx, at), contains('UTC'));
      tf.use24HourClock = true;
      expect(timeLabel(ctx, at), contains('18:14'));
      expect(messageTimesLine(ChatMessage(
          id: 'x', radioId: radioA, convKind: ConvKind.dm, convKey: dm(), direction: Direction.outgoing, tsSender: 1, tsLocalMs: at, text: 'x', state: MessageState.sent, dedupeKey: 'x')),
          contains('18:14:00'));
    });
  });

  group('C-U8: a named repeater in a route opens its page', () {
    testWidgets('only a hop exactly one known node has is a button; the details chain calls back with it', (tester) async {
      final ridge = Contact(radioId: radioA, publicKey: 'a1${'ee' * 31}', type: ContactType.repeater, name: 'Ridge', onRadio: true);
      kit.store.contacts.upsert(ridge);
      kit.store.contacts.upsert(Contact(radioId: radioA, publicKey: 'b2${'ee' * 31}', type: ContactType.repeater, name: 'Hill', onRadio: true));
      kit.store.contacts.upsert(Contact(radioId: radioA, publicKey: 'b2${'ff' * 31}', type: ContactType.repeater, name: 'Hill 2', onRadio: true));
      final resolver = hopResolverFor(kit.store, radioA, const []);
      final nodes = resolver.resolveAll(const ['a1', 'b2', 'c3']);
      expect(hopTarget(kit.store, radioA, const [], nodes[0])!.contact!.publicKey, ridge.publicKey);
      expect(hopTarget(kit.store, radioA, const [], nodes[1]), isNull, reason: 'two repeaters share b2');
      expect(hopTarget(kit.store, radioA, const [], nodes[2]), isNull, reason: 'nobody known has c3');
      final opened = <HopNode>[];
      await tester.pumpWidget(host(Scaffold(
          body: HopChain(
              first: 'You',
              nodes: nodes,
              last: 'Bob',
              canOpen: (n) => hopTarget(kit.store, radioA, const [], n) != null,
              onHop: opened.add))));
      expect(find.byKey(const Key('hop-open-0')), findsOneWidget);
      expect(find.byKey(const Key('hop-open-1')), findsNothing);
      expect(find.byKey(const Key('hop-open-2')), findsNothing);
      expect(tester.getSize(find.byKey(const Key('hop-open-0'))).height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(const Key('hop-open-0')));
      expect(opened.single.label, 'Ridge');
    });
  });

  group('wording', () {
    testWidgets('long-press Send says direct or flood (official way), never "search for a new route"', (tester) async {
      setSize(tester);
      kit.bob();
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: dm())));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'x');
      await tester.pump();
      await tester.longPress(find.byKey(const Key('composer-send')));
      await tester.pumpAndSettle();
      expect(find.text('Send this message direct or by flood?'), findsOneWidget);
      expect(find.textContaining('search'), findsNothing);
      await tester.tap(find.byKey(const Key('send-normal')));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('C-V1: the hop chip border is the neutral repeater colour, never amber (build 77 colour language)', (tester) async {
    late AppColors c;
    final nodes = hopResolverFor(kit.store, radioA, const []).resolveAll(const ['c3']);
    await tester.pumpWidget(host(Builder(builder: (ctx) {
      c = AppColors.of(ctx);
      return Scaffold(body: HopChain(first: 'You', nodes: nodes, last: 'Bob'));
    })));
    final borders = [
      for (final d in tester.widgetList<Container>(find.descendant(of: find.byKey(const Key('hop-chain')), matching: find.byType(Container))))
        if (d.decoration is BoxDecoration && (d.decoration! as BoxDecoration).border != null) ((d.decoration! as BoxDecoration).border! as Border).top.color,
    ];
    expect(borders, contains(c.repeater));
    expect(borders, isNot(contains(c.beacon)));
  });

  testWidgets('A1 / A2: the in-app banner shows the preview (never a photo address or key) and skips position updates', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    final holder = ValueNotifier<ChatController?>(kit.controller);
    await tester.pumpWidget(host(ChatBannerHost(controllerListenable: holder, visibleFor: const Duration(seconds: 2), child: const Scaffold(body: Center(child: Text('shell'))))));
    kit.incoming(ch, 'Jo N8JO', 'MT1 @86GV429W+H34 s40 c46');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
    expect(find.byKey(const Key('chat-banner')), findsNothing, reason: 'a position update never raises a banner');
    kit.incoming(ch, 'Ann', 'trail $privateUrlA');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
    expect(find.byKey(const Key('chat-banner')), findsOneWidget);
    expect(find.text('Photo: trail'), findsOneWidget);
    expect(find.textContaining(privateKeyA), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });
}
