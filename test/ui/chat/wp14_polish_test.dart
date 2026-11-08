// Chat WP14: the known gaps closed in the polish pass. Route health card, ping options, real RadioCaps, airtime, More > Chat,
// one-time tips, copy and the accessibility switches.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/outbox_repository.dart' show DeliveryAttempt;
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/models.dart' as models show Route;
import 'package:meshsonar/chat/quick_replies.dart';
import 'package:meshsonar/chat/route_health.dart';
import 'package:meshsonar/chat/tip_store.dart';
import 'package:meshsonar/core/plan/airtime_calc.dart';
import 'package:meshsonar/radio/caps.dart';
import 'package:meshsonar/radio/rx_facts.dart';
import 'package:meshsonar/ui/chat/chat_settings_screen.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_bubble.dart';
import 'package:meshsonar/ui/contacts/profile_tiles.dart';
import 'package:meshsonar/ui/contacts/profile_widgets.dart';
import 'package:meshsonar/ui/design/app_widgets.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/theme.dart';

import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() => kit = ChatKit());
  tearDown(() => kit.dispose());

  /// [n] outgoing DMs to Bob, newest last. Each failed one made [directTries] tries over the saved route.
  void failedDms(int n, {int directTries = 2, MessageState last = MessageState.failed}) {
    for (var i = 0; i < n; i++) {
      final id = 'f$i';
      final state = i == n - 1 ? last : MessageState.failed;
      kit.store.messages.insert(ChatMessage(
        id: id,
        radioId: radioA,
        convKind: ConvKind.dm,
        convKey: ConvKey.dm(bobKey),
        direction: Direction.outgoing,
        tsSender: 1000 + i,
        tsLocalMs: kit.clockMs + i * 1000,
        text: 'try $i',
        state: state,
        failReason: state == MessageState.failed ? FailReason.noAck : null,
        dedupeKey: 'dk$i',
        read: true,
      ));
      for (var t = 1; t <= directTries; t++) {
        kit.store.outbox.addAttempt(DeliveryAttempt(messageId: id, attempt: t, sentAtMs: kit.clockMs, route: models.Route.direct));
      }
    }
  }

  Contact bobWithRoute({PathMode mode = PathMode.auto, int? learned}) {
    final c = Contact(
      radioId: radioA,
      publicKey: bobKey,
      type: ContactType.companion,
      name: 'Bob',
      outPath: Uint8List.fromList([1, 2]),
      outPathLen: 2,
      pathMode: mode,
      pathLearnedMs: learned,
    );
    kit.store.contacts.upsert(c);
    return c;
  }

  group('route health', () {
    test('three failed messages over a saved route: broken', () {
      final c = bobWithRoute();
      failedDms(3);
      expect(routeLooksBroken(kit.store, c), isTrue);
    });

    test('two failures are not enough; a delivered message in the window clears it', () {
      final c = bobWithRoute();
      failedDms(2);
      expect(routeLooksBroken(kit.store, c), isFalse);
      kit.store.messages.insert(ChatMessage(
          id: 'ok', radioId: radioA, convKind: ConvKind.dm, convKey: ConvKey.dm(bobKey), direction: Direction.outgoing, tsSender: 9, tsLocalMs: kit.clockMs + 99000, text: 'ok', state: MessageState.acked, dedupeKey: 'dkok', read: true));
      failedDms(0);
      expect(routeLooksBroken(kit.store, c), isFalse);
    });

    test('searches that never used the route (flood only) do not blame it', () {
      final c = bobWithRoute();
      failedDms(3, directTries: 0);
      expect(routeLooksBroken(kit.store, c), isFalse);
    });

    test('no saved route, or Always search: nothing to blame', () {
      failedDms(3);
      expect(routeLooksBroken(kit.store, Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'Bob')), isFalse);
      expect(routeLooksBroken(kit.store, bobWithRoute(mode: PathMode.flood)), isFalse);
    });

    test('a route learned after the failures is a new route', () {
      failedDms(3);
      expect(routeLooksBroken(kit.store, bobWithRoute(learned: kit.clockMs + 60000)), isFalse);
    });

    testWidgets('the conversation shows the card with both actions; Reset route confirms and clears the card', (tester) async {
      setSize(tester);
      bobWithRoute();
      failedDms(3);
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ConvKey.dm(bobKey))));
      await tester.pump();
      expect(find.byKey(const Key('route-broken-card')), findsOneWidget);
      expect(find.text('This route may be broken.'), findsOneWidget);
      expect(find.byKey(const Key('broken-find')), findsOneWidget);
      expect(find.byKey(const Key('broken-reset')), findsOneWidget);
      await tester.tap(find.byKey(const Key('broken-reset')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('broken-reset-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('route-broken-card')), findsNothing);
      expect(kit.store.contacts.get(radioA, bobKey)!.hasPath, isFalse);
    });
  });

  group('Ping tile options', () {
    testWidgets('a repeater tile offers options on long press and as a VoiceOver action; a person does not', (tester) async {
      final handle = tester.ensureSemantics();
      final seen = <ProfileTileId>[];
      Widget grid(ContactType type) => host(Scaffold(
            body: ProfileTileGrid(
              tiles: profileTiles(Contact(radioId: radioA, publicKey: bobKey, type: type, name: 'X'),
                  connected: true, caps: RadioCaps.baseline, canMessage: true, canAdmin: true),
              onTap: (_) {},
              onOptions: (t) => seen.add(t.id),
            ),
          ));
      await tester.pumpWidget(grid(ContactType.repeater));
      await tester.longPress(find.byKey(const Key('tile-ping')));
      await tester.pump();
      expect(seen, [ProfileTileId.ping]);
      final data = tester.getSemantics(find.byKey(const Key('tile-ping'))).getSemanticsData();
      expect(data.customSemanticsActionIds, isNotEmpty);
      expect(CustomSemanticsAction.getAction(data.customSemanticsActionIds!.first)!.label, 'More ping options');

      seen.clear();
      await tester.pumpWidget(grid(ContactType.companion));
      await tester.longPress(find.byKey(const Key('tile-ping')));
      await tester.pump();
      expect(seen, isEmpty, reason: 'a person is pinged by route search; there is nothing to choose');
      handle.dispose();
    });
  });

  group('airtime of a received message', () {
    test('the logged packet length is kept', () {
      // header 0x14 (flood, GRP_TXT), path_len 0, 20 payload bytes
      final raw = Uint8List.fromList([0x14, 0, ...List.filled(20, 7)]);
      final f = parseRxPacket(raw, snrDb: 5, rssiDbm: -90)!;
      expect(f.rawLength, 22);
    });

    test('time on air for that length at SF7 / 62.5 kHz / 4/5 is a plausible tens of ms', () {
      final ms = timeOnAir(22, const AirRadio(sf: 7, bwKHz: 62.5, cr: 5)).totalMs;
      expect(ms, inInclusiveRange(80, 200));
    });
  });

  group('More > Chat', () {
    testWidgets('Return sends is stored, Quick replies shows the count, Haptics switch is there', (tester) async {
      setSize(tester);
      await tester.pumpWidget(host(ChatSettingsScreen(controller: kit.controller)));
      await tester.pump();
      expect(find.text('Quick replies'), findsOneWidget);
      expect(find.text('${defaultQuickReplies.length}'), findsOneWidget);
      expect(loadReturnSends(kit.store), isFalse);
      await tester.tap(find.byKey(const Key('chat-return-sends')));
      await tester.pump();
      expect(loadReturnSends(kit.store), isTrue);
      await tester.tap(find.byKey(const Key('chat-quick-replies')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('quick-add-field')), findsOneWidget);
    });

    testWidgets('with Return sends on, a plain Return sends the message and Shift-Return does not', (tester) async {
      setSize(tester);
      kit.bob();
      final conv = ConvKey.dm(bobKey);
      await kit.connect();
      saveReturnSends(kit.store, true);
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: conv)));
      await tester.pump();
      tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('composer-field')), matching: find.byType(EditableText))).focusNode.requestFocus();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('composer-field')), 'hello');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      bool sent() => kit.store.messages.page(conv).messages.any((m) => m.isOutgoing && m.text == 'hello');
      expect(sent(), isFalse, reason: 'Shift-Return is a new line');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent(), isTrue);
    });

    testWidgets('with Return sends off (the default), a plain Return does not send', (tester) async {
      setSize(tester);
      kit.bob();
      final conv = ConvKey.dm(bobKey);
      await kit.connect();
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: conv)));
      await tester.pump();
      tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('composer-field')), matching: find.byType(EditableText))).focusNode.requestFocus();
      await tester.pump();
      await tester.enterText(find.byKey(const Key('composer-field')), 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(kit.store.messages.page(conv).messages.where((m) => m.isOutgoing), isEmpty);
    });
  });

  group('one-time tips', () {
    test('the seen flag lives in the chat settings and survives a new store object', () {
      final a = ChatDbTipStore(kit.store);
      expect(a.seen('conv-details-tip'), isFalse);
      a.markSeen('conv-details-tip');
      expect(ChatDbTipStore(kit.store).seen('conv-details-tip'), isTrue);
      expect(kit.store.db.setting('tip.conv-details-tip'), '1');
    });

    testWidgets('the conversation tip shows once and a dismiss is remembered', (tester) async {
      setSize(tester);
      appTipStore = ChatDbTipStore(kit.store);
      addTearDown(() => appTipStore = MemoryTipStore());
      final ch = await kit.channel(1, 'Ohio');
      kit.incoming(ch, 'Ann', 'hi');
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pump();
      expect(find.text('See how a message travelled'), findsOneWidget);
      await tester.tap(find.byKey(const Key('tip-dismiss')));
      await tester.pump();
      expect(find.text('See how a message travelled'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pump();
      expect(find.text('See how a message travelled'), findsNothing);
    });
  });

  group('accessibility switches', () {
    testWidgets('Increase Contrast puts a hairline edge on every bubble', (tester) async {
      setSize(tester);
      final ch = await kit.channel(1, 'Ohio');
      kit.incoming(ch, 'Ann', 'hello there');
      Future<BoxDecoration> deco(bool hc) async {
        await tester.pumpWidget(MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(highContrast: hc), child: w!),
          home: Scaffold(body: ConversationScreen(controller: kit.controller, convKey: ch.convKey)),
        ));
        await tester.pump();
        final box = tester.widget<Container>(find.descendant(of: find.byType(MessageBubble), matching: find.byWidgetPredicate((w) => w is Container && w.key is Key && (w.key as Key).toString().contains('bubble-'))).first);
        return box.decoration! as BoxDecoration;
      }

      expect((await deco(false)).border, isNull);
      expect((await deco(true)).border, isNotNull);
    });

    testWidgets('Increase Contrast and a missing Reduce Transparency answer both make the bars opaque', (tester) async {
      late BuildContext ctx;
      Future<bool> opaque({required bool hc}) async {
        await tester.pumpWidget(MaterialApp(
          builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(highContrast: hc), child: w!),
          home: Builder(builder: (c) {
            ctx = c;
            return const SizedBox();
          }),
        ));
        return Blur.opaque(ctx);
      }

      expect(await opaque(hc: true), isTrue);
    });
  });
}
