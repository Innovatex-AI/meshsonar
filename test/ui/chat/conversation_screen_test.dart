import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';

import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() {
    kit = ChatKit();
    MessageMenu.useContextMenu = false;
  });
  tearDown(() => kit.dispose());

  Future<Channel> pump(WidgetTester tester, {bool seed = true}) async {
    final ch = await kit.channel(1, 'Ohio');
    if (seed) {
      kit.incoming(ch, 'Ann', 'good morning everyone');
      kit.incoming(ch, 'Ann', 'anyone on 910?', ts: kit.clockMs ~/ 1000 + 1);
    }
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    return ch;
  }

  testWidgets('shows messages grouped: one sender label per run, time separator, unread marker, marked read', (tester) async {
    setSize(tester);
    final ch = await pump(tester);
    expect(find.text('good morning everyone'), findsOneWidget);
    expect(find.text('anyone on 910?'), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget, reason: 'one sender label for a run of messages');
    expect(find.byKey(const Key('time-separator')), findsOneWidget);
    expect(find.textContaining('Today'), findsOneWidget);
    expect(find.byKey(const Key('unread-marker')), findsOneWidget);
    // one time line, under the LAST bubble of the run only
    expect(find.byKey(const Key('time-m1')), findsOneWidget);
    expect(find.byKey(const Key('time-m0')), findsNothing);
    await tester.pump();
    expect(kit.service.conversation(ch.convKey)!.unread, 0);
    expect(kit.controller.unreadMessages, 0);
  });

  testWidgets('title block is one 44 pt target with route-kind subtitle; the old (i) is gone', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag, region: 'Ohio');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    expect(find.text('Hashtag channel · Ohio'), findsOneWidget);
    final size = tester.getSize(find.byKey(const Key('conv-title')));
    expect(size.height, greaterThanOrEqualTo(44));
    expect(find.byKey(const Key('conv-channel-info')), findsNothing);
    await tester.tap(find.byKey(const Key('conv-title')));
    await tester.pumpAndSettle();
    expect(find.text('Ohio'), findsWidgets);
  });

  testWidgets('DM subtitle says Direct / Via N repeaters / No route yet', (tester) async {
    setSize(tester);
    kit.bob();
    final key = ConvKey.dm(bobKey.substring(0, 12));
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: key, title: 'Bob')));
    await tester.pump();
    expect(find.byKey(const Key('dm-route-text')), findsOneWidget);
    expect(find.text('No route yet'), findsOneWidget);
  });

  testWidgets('empty channel explains what to do', (tester) async {
    setSize(tester);
    await pump(tester, seed: false);
    expect(find.byKey(const Key('conv-empty')), findsOneWidget);
    expect(find.textContaining('Say hello'), findsOneWidget);
  });

  testWidgets('composer: ring shows at 60%, the number sits inside at 20 left, hard stop at 0, draft is saved and restored', (tester) async {
    setSize(tester);
    final ch = await pump(tester, seed: false);
    final max = kit.service.maxTextBytes(ch.convKey);
    expect(find.byKey(const Key('composer-left')), findsNothing);
    await tester.enterText(find.byKey(const Key('composer-field')), 'hello');
    await tester.pump();
    expect(find.byKey(const Key('composer-left')), findsNothing, reason: 'quiet below 60%');
    await tester.enterText(find.byKey(const Key('composer-field')), 'é' * ((max - 16) ~/ 2));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('composer-send')), matching: find.text('16')), findsOneWidget);
    // typing or pasting past the packet is cut at a character boundary: 0 left, never over
    await tester.enterText(find.byKey(const Key('composer-field')), '😀' * 60);
    await tester.pump();
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('composer-send')), matching: find.text('0')), findsOneWidget);
    expect(find.byKey(const Key('composer-trimmed')), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const Key('composer-trimmed')), findsNothing);
    // leave the screen: the draft is flushed
    await tester.enterText(find.byKey(const Key('composer-field')), 'half written');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(kit.service.loadDraft(ch.convKey), 'half written');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    expect(find.text('half written'), findsOneWidget);
  });

  testWidgets('quick replies strip inserts text without sending; @ shows recent senders', (tester) async {
    setSize(tester);
    await pump(tester);
    expect(find.byKey(const Key('quick-strip')), findsNothing);
    await tester.tap(find.byKey(const Key('composer-quick')));
    await tester.pump();
    expect(find.byKey(const Key('quick-On my way')), findsOneWidget);
    await tester.tap(find.byKey(const Key('quick-On my way')));
    await tester.pump();
    expect(find.text('On my way'), findsWidgets);
    expect(kit.sink.channels, isEmpty);
    await tester.tap(find.byKey(const Key('composer-quick')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('composer-field')), 'hi @A');
    await tester.pump();
    expect(find.byKey(const Key('mention-Ann')), findsOneWidget);
    await tester.tap(find.byKey(const Key('mention-Ann')));
    await tester.pump();
    expect(find.text('hi @[Ann] '), findsOneWidget);
  });

  testWidgets('send queues, shows glyph + word states, offline hint', (tester) async {
    setSize(tester);
    final ch = await pump(tester, seed: false);
    kit.sink.connected = false;
    await tester.enterText(find.byKey(const Key('composer-field')), 'on my way');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    expect(find.text('on my way'), findsOneWidget);
    expect(find.textContaining('Waiting'), findsOneWidget);
    expect(find.byKey(const Key('composer-offline')), findsOneWidget);
    kit.sink.connected = true;
    kit.switchable.adapter = null;
    await kit.service.pump();
    await tester.pump();
    expect(kit.sink.channels.single.text, 'on my way');
    expect(find.textContaining('Sent'), findsOneWidget);
    kit.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: kit.sink.channels.single.ts, text: 'Me: on my way', pathHashes: 'a1', hops: 1));
    await tester.pump();
    expect(find.textContaining('Heard by 1 repeater'), findsOneWidget);
    expect(ch.id, isNotNull);
  });

  testWidgets('failed: red glyph opens Try Again / Details / Delete; one tap more retries', (tester) async {
    setSize(tester);
    await pump(tester, seed: false);
    kit.sink.failNext = const RadioRejected('no');
    await tester.enterText(find.byKey(const Key('composer-field')), 'will fail');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    await kit.service.pump();
    await tester.pump();
    expect(find.textContaining('Not delivered'), findsOneWidget);
    final glyph = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('failed-glyph-'));
    expect(tester.getSize(glyph).height, greaterThanOrEqualTo(44));
    await tester.tap(glyph);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('failed-details')), findsOneWidget);
    expect(find.byKey(const Key('failed-delete')), findsOneWidget);
    await tester.tap(find.byKey(const Key('failed-retry')));
    await tester.pumpAndSettle();
    await kit.service.pump();
    await tester.pump();
    expect(kit.sink.channels.single.text, 'will fail');
    expect(find.textContaining('Not delivered'), findsNothing);
  });

  testWidgets('two or more failed show Retry all; it retries both', (tester) async {
    setSize(tester);
    final ch = await pump(tester, seed: false);
    for (var i = 0; i < 2; i++) {
      kit.sink.failNext = const RadioRejected('no');
      kit.controller.send(ch.convKey, 'msg $i');
      await kit.service.pump();
      kit.clockMs += 600000;
    }
    await tester.pump();
    expect(find.byKey(const Key('retry-all-banner')), findsOneWidget);
    expect(find.text('2 not delivered'), findsOneWidget);
    await tester.tap(find.byKey(const Key('retry-all')));
    await tester.pump();
    await kit.service.pump();
    await tester.pump();
    expect(find.byKey(const Key('retry-all-banner')), findsNothing);
  });

  testWidgets('tap a bubble: info strip with route and signal, stays (no timer) until tapped again', (tester) async {
    setSize(tester);
    await pump(tester);
    expect(find.byKey(const Key('info-strip')), findsNothing);
    await tester.tap(find.text('good morning everyone'));
    await tester.pump();
    expect(find.byKey(const Key('info-strip')), findsOneWidget);
    expect(find.textContaining('SNR 5.5 dB'), findsOneWidget);
    expect(find.textContaining('Via 2 repeaters'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
    expect(find.byKey(const Key('info-strip')), findsOneWidget, reason: 'no timer closes it');
    await tester.tap(find.text('good morning everyone'));
    await tester.pump();
    expect(find.byKey(const Key('info-strip')), findsNothing);
  });

  testWidgets('long press: actions sheet, details sheet, delete', (tester) async {
    setSize(tester);
    await pump(tester);
    await tester.longPress(find.text('good morning everyone'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('act-copy')), findsOneWidget);
    await tester.tap(find.byKey(const Key('act-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-details')), findsOneWidget);
    expect(find.textContaining('SNR 5.5 dB'), findsOneWidget);
    expect(find.text('Via 2 repeaters'), findsWidgets);
    await tester.tap(find.byKey(const Key('details-done')));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('good morning everyone'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('act-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-message')));
    await tester.pumpAndSettle();
    expect(find.text('good morning everyone'), findsNothing);
    expect(find.text('anyone on 910?'), findsOneWidget);
  });

  testWidgets('delete message: Keep leaves it', (tester) async {
    setSize(tester);
    await pump(tester);
    await tester.longPress(find.text('good morning everyone'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('act-delete')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-delete-message')), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.text('good morning everyone'), findsOneWidget);
  });

  testWidgets('ellipsis menu: search in conversation lands on the hit and flashes it', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    for (var i = 0; i < 90; i++) {
      kit.clockMs += 1000;
      kit.incoming(ch, 'Ann', i == 3 ? 'needle in the haystack' : 'filler $i', ts: kit.clockMs ~/ 1000);
    }
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    expect(find.text('needle in the haystack'), findsNothing, reason: 'older than the first page');
    await tester.tap(find.byKey(const Key('conv-menu-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('conv-search-field')), 'needle');
    await tester.pump();
    expect(find.byKey(const Key('conv-search-results')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('conv-search-field')), 'zzzz');
    await tester.pump();
    expect(find.textContaining('No matches for'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('conv-search-field')), 'needle');
    await tester.pump();
    await tester.tap(find.text('needle in the haystack'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('conv-search-results')), findsNothing);
    expect(find.text('needle in the haystack'), findsOneWidget, reason: 'scrolled to the hit');
    await tester.pump(const Duration(seconds: 3)); // the flash ends
  });

  testWidgets('open with anchorMessageId pages around the message (global search hit)', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    for (var i = 0; i < 120; i++) {
      kit.clockMs += 1000;
      kit.incoming(ch, 'Ann', i == 10 ? 'anchor text' : 'filler $i', ts: kit.clockMs ~/ 1000);
    }
    final anchor = kit.store.messages.page(ch.convKey, limit: 500).messages.firstWhere((m) => m.text == 'anchor text');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey, anchorMessageId: anchor.id)));
    await tester.pump();
    await tester.pump();
    expect(find.text('anchor text'), findsOneWidget);
    expect(find.byKey(const Key('conv-jump')), findsOneWidget, reason: 'newer messages exist: the capsule takes you back');
    await tester.tap(find.byKey(const Key('conv-jump')));
    await tester.pumpAndSettle();
    expect(find.text('filler 119'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('links and mentions render; mention of me is highlighted; links are their own focus nodes', (tester) async {
    setSize(tester);
    final handle = tester.ensureSemantics();
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Ann', 'see https://meshsonar.com/channels and @[Me] hi');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    expect(find.textContaining('@Me', findRichText: true), findsOneWidget);
    expect(find.textContaining('https://meshsonar.com/channels', findRichText: true), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Link, https://meshsonar.com/channels')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Ann, see https')), findsOneWidget);
    handle.dispose();
  });
}
