// WP4: a 5,000-message conversation stays cheap (one delivery change rebuilds one bubble), and VoiceOver gets what the
// plan promises (bubble sentence, custom actions, link nodes, announcements).
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_bubble.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';

import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() {
    kit = ChatKit();
    MessageMenu.useContextMenu = false;
  });
  tearDown(() => kit.dispose());

  ChatMessage m(Channel ch, String id, int i, {bool out = false, MessageState? state, String? text}) => ChatMessage(
        id: id,
        radioId: radioA,
        convKind: ConvKind.channel,
        convKey: ch.convKey,
        direction: out ? Direction.outgoing : Direction.incoming,
        senderName: out ? 'Me' : 'Ann',
        tsSender: 1000 + i,
        tsLocalMs: kit.clockMs + i * 1000,
        text: text ?? 'message $i',
        state: state ?? (out ? MessageState.sent : MessageState.received),
        dedupeKey: id,
        read: true,
      );

  testWidgets('5,000 messages: only the page is built, scrolling pages in, a delivery change rebuilds one bubble', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    for (var i = 0; i < 5000; i++) {
      kit.store.messages.insert(m(ch, 'm$i', i));
    }
    final last = m(ch, 'mine', 5001, out: true, state: MessageState.sent, text: 'on my way');
    kit.store.messages.insert(last);
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    await tester.pump();
    expect(find.byType(MessageBubble).evaluate().length, lessThan(40), reason: 'lazy list: only the visible rows exist');
    expect(find.descendant(of: find.byKey(const Key('conv-list')), matching: find.byType(RepaintBoundary)), findsWidgets);

    // a delivery change on one message
    MessageBubble.debugBuilds = 0;
    kit.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: last.tsSender, text: 'Me: on my way', pathHashes: 'a1', hops: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Heard by 1 repeater'), findsOneWidget);
    expect(MessageBubble.debugBuilds, lessThanOrEqualTo(2), reason: 'only the changed bubble (and at most its neighbour) rebuilds, not the list');

    // opening the info strip on one bubble also leaves the others alone
    MessageBubble.debugBuilds = 0;
    await tester.tap(find.text('message 4999'));
    await tester.pump();
    expect(MessageBubble.debugBuilds, lessThanOrEqualTo(2));

    // scrolling back loads older pages without exceptions
    for (var i = 0; i < 12; i++) {
      await tester.drag(find.byKey(const Key('conv-list')), const Offset(0, 600));
      await tester.pump();
    }
    expect(tester.takeException(), isNull);
    expect(find.byType(MessageBubble).evaluate().length, lessThan(60));
  });

  testWidgets('VoiceOver: bubble sentence, custom actions, link nodes', (tester) async {
    setSize(tester);
    final handle = tester.ensureSemantics();
    final ch = await kit.channel(1, 'Ohio');
    kit.store.messages.insert(m(ch, 'a', 0, text: 'see https://meshsonar.com/x'));
    kit.store.messages.insert(m(ch, 'b', 1, out: true, state: MessageState.heard, text: 'on my way'));
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();

    final incoming = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Ann, see https')));
    final data = incoming.getSemanticsData();
    final labels = [for (final id in data.customSemanticsActionIds ?? <int>[]) CustomSemanticsAction.getAction(id)!.label];
    expect(labels, containsAll(['Copy', 'Details', 'Delete']));
    expect(data.hasAction(SemanticsAction.tap), isTrue, reason: 'double tap opens the info strip');
    expect(find.bySemanticsLabel(RegExp(r'^Link, https://meshsonar.com/x')), findsOneWidget);

    final mine = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^You, on my way')));
    expect(mine.label, contains('Heard by'));
    handle.dispose();
  });

  testWidgets('VoiceOver: Delivered and Failed are announced, a new incoming message is read out', (tester) async {
    setSize(tester);
    final said = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (msg) async {
      if (msg is Map && msg['type'] == 'announce') said.add((msg['data'] as Map)['message'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null));
    final ch = await kit.channel(1, 'Ohio');
    kit.store.messages.insert(m(ch, 'out', 0, out: true, state: MessageState.sent, text: 'hello'));
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    kit.incoming(ch, 'Ann', 'ping', ts: 5000);
    await tester.pump();
    expect(said, contains('Ann: ping'));
    kit.sink.failNext = const RadioRejected('no');
    kit.controller.send(ch.convKey, 'will fail');
    await kit.service.pump();
    await tester.pump();
    expect(said, contains('Not delivered'));
  });
}
