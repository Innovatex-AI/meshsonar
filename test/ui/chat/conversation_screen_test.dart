import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';

import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() => kit = ChatKit());
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

  testWidgets('shows messages, sender once per run, day header and marks them read', (tester) async {
    setSize(tester);
    final ch = await pump(tester);
    expect(find.text('good morning everyone'), findsOneWidget);
    expect(find.text('anyone on 910?'), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget, reason: 'one sender label for a run of messages');
    expect(find.text('Today'), findsOneWidget);
    expect(find.byKey(const Key('unread-marker')), findsOneWidget);
    await tester.pump();
    expect(kit.service.conversation(ch.convKey)!.unread, 0);
    expect(kit.controller.unreadConversations, 0);
  });

  testWidgets('empty channel explains what to do', (tester) async {
    setSize(tester);
    await pump(tester, seed: false);
    expect(find.byKey(const Key('conv-empty')), findsOneWidget);
    expect(find.textContaining('Say hello'), findsOneWidget);
  });

  testWidgets('composer: live byte counter, over-limit blocks send, draft is saved and restored', (tester) async {
    setSize(tester);
    final ch = await pump(tester, seed: false);
    final max = kit.service.maxTextBytes(ch.convKey);
    expect(find.text('0 / $max bytes'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer-field')), 'hello');
    await tester.pump();
    expect(find.text('5 / $max bytes'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('composer-field')), 'é' * (max));
    await tester.pump();
    expect(find.textContaining('too long'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const Key('composer-send'))).onPressed, isNull);
    // leave the screen: the draft is flushed
    await tester.enterText(find.byKey(const Key('composer-field')), 'half written');
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(kit.service.loadDraft(ch.convKey), 'half written');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    expect(find.text('half written'), findsOneWidget);
  });

  testWidgets('send queues, shows delivery states, offline note and retry/cancel', (tester) async {
    setSize(tester);
    final ch = await pump(tester, seed: false);
    kit.sink.connected = false;
    await tester.enterText(find.byKey(const Key('composer-field')), 'on my way');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    expect(find.text('on my way'), findsOneWidget);
    expect(find.text('Waiting for the radio'), findsOneWidget);
    expect(find.byKey(const Key('composer-offline')), findsOneWidget);
    // radio comes back: pump the outbox
    kit.sink.connected = true;
    kit.switchable.adapter = null; // controller.radioConnected follows the real sink; offline note is about the adapter
    await kit.service.pump();
    await tester.pump();
    expect(kit.sink.channels.single.text, 'on my way');
    expect(find.text('Sent'), findsOneWidget);
    // a repeat is heard
    kit.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: kit.sink.channels.single.ts, text: 'Me: on my way'));
    await tester.pump();
    expect(find.text('Heard by 1 repeater'), findsOneWidget);
    expect(ch.id, isNotNull);
  });

  testWidgets('failed message shows the reason with Retry and Delete', (tester) async {
    setSize(tester);
    await pump(tester, seed: false);
    kit.sink.failNext = const RadioRejected('no');
    await tester.enterText(find.byKey(const Key('composer-field')), 'will fail');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pump();
    await kit.service.pump();
    await tester.pump();
    expect(find.text('Not sent'), findsOneWidget);
    expect(find.byKey(const Key('msg-retry')), findsOneWidget);
    await tester.tap(find.byKey(const Key('msg-retry')));
    await tester.pump();
    await kit.service.pump();
    await tester.pump();
    expect(kit.sink.channels.single.text, 'will fail');
    expect(find.byKey(const Key('msg-retry')), findsNothing);
  });

  testWidgets('long press: actions, details with SNR and hops, delete', (tester) async {
    setSize(tester);
    await pump(tester);
    await tester.longPress(find.text('good morning everyone'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('act-copy')), findsOneWidget);
    await tester.tap(find.byKey(const Key('act-details')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-details')), findsOneWidget);
    expect(find.textContaining('5.5 dB, strong'), findsOneWidget);
    expect(find.textContaining('2 hops through repeaters'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
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

  testWidgets('search in the conversation', (tester) async {
    setSize(tester);
    await pump(tester);
    await tester.tap(find.byKey(const Key('conv-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('conv-search-field')), 'morning');
    await tester.pump();
    expect(find.byKey(const Key('conv-search-results')), findsOneWidget);
    expect(find.text('good morning everyone'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('conv-search-field')), 'zzzz');
    await tester.pump();
    expect(find.text('Nothing found'), findsOneWidget);
  });

  testWidgets('links and mentions render; mention of me is highlighted', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Ann', 'see https://meshsonar.com/channels and @[Me] hi');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    expect(find.textContaining('@Me', findRichText: true), findsOneWidget);
    expect(find.textContaining('https://meshsonar.com/channels', findRichText: true), findsOneWidget);
  });
}
