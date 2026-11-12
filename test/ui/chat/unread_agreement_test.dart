// APP-3 (build 62): ONE unread rule, shown the same everywhere. The Chat tab badge, the Chats "Mark all as read" control (shown only
// when the count is above zero), the app-icon badge and the pills on the conversation rows all derive from
// ChatController.unreadMessages: unread incoming messages in non-muted, non-system conversations. docs/FEATURES.md "Unread count".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/conversation_row.dart' show unreadCountLabel;
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';

import '../fakes.dart' show Harness;
import 'chat_integration_helpers.dart';
import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() {
    kit = ChatKit();
    ChatWiring.controller.value = kit.controller;
    ChatTabHost.provider.value = ChatTabProviderImpl(kit.controller);
  });
  tearDown(() {
    ChatWiring.controller.value = null;
    ChatTabHost.provider.value = null;
    kit.dispose();
  });

  void dm(int n) {
    for (var i = 0; i < n; i++) {
      kit.clockMs += 1000;
      kit.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: kit.clockMs ~/ 1000, text: 'dm $i'));
    }
  }

  void channelMsgs(Channel ch, int n) {
    for (var i = 0; i < n; i++) {
      kit.clockMs += 1000;
      kit.incoming(ch, 'Ann', 'msg $i', ts: kit.clockMs ~/ 1000);
    }
  }

  /// The text of the tab badge, or null when it is not shown.
  String? tabBadge(WidgetTester tester) {
    final f = find.byKey(const Key('chat-badge'));
    if (f.evaluate().isEmpty) return null;
    return tester.widget<Text>(find.descendant(of: f, matching: find.byType(Text))).data;
  }

  /// Every unread pill on the Chats list, with whether it belongs to a muted row (grey pill).
  List<String> rowPills(WidgetTester tester) => [for (final w in tester.widgetList<Text>(find.descendant(of: find.byKey(const Key('unread-pill')), matching: find.byType(Text)))) w.data!];

  testWidgets('tab badge, Mark-all control, app-icon badge and the row pills agree (muted and system excluded)', (tester) async {
    setSize(tester);
    kit.bob();
    final ohio = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag);
    final family = await kit.channel(2, 'Family');
    final wardrive = await kit.channel(3, 'Wardrive', kind: ChannelKind.system);
    channelMsgs(ohio, 3); // counts
    channelMsgs(family, 2); // muted: does not count
    channelMsgs(wardrive, 4); // system: does not count
    dm(2); // counts
    kit.service.setNotifyMode(radioA, family.convKey, NotifyMode.muted);

    final h = Harness();
    await h.pumpApp(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();

    const expected = 5; // 3 in Ohio + 2 from Bob
    expect(kit.controller.unreadMessages, expected, reason: 'the one rule');
    expect(kit.service.unreadBadge(), expected, reason: 'the app-icon badge is the same number');
    expect(tabBadge(tester), '$expected');

    await tapTab(tester, 'Chat');
    await tester.pump(const Duration(seconds: 7)); // the in-app banner has gone
    expect(find.byKey(const Key('chat-mark-all-read')), findsOneWidget, reason: 'shown exactly when the count is above zero');
    final pills = rowPills(tester);
    // Rows: Ohio 3, Bob 2 (counted) and Family 2 (muted, a grey pill that is NOT in the badge). The system channel has no row here.
    expect(pills.toList()..sort(), ['2', '2', '3']);
    final counted = tester.widgetList<Container>(find.byKey(const Key('unread-pill')));
    expect(counted.length, 3);
    expect(pills.map(int.parse).reduce((a, b) => a + b) - 2, expected, reason: 'row pills minus the muted row equal the badge');

    // Clearing: Mark all as read clears the tab badge, the control and every non-muted pill together.
    await tester.tap(find.byKey(const Key('chat-mark-all-read')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(kit.controller.unreadMessages, 0);
    expect(tabBadge(tester), isNull);
    expect(find.byKey(const Key('chat-mark-all-read')), findsNothing);
  });

  testWidgets('every badge caps the same way: 99+', (tester) async {
    setSize(tester);
    kit.bob();
    final busy = await kit.channel(1, 'Busy', kind: ChannelKind.hashtag);
    channelMsgs(busy, 120);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
    expect(kit.controller.unreadMessages, 120);
    expect(unreadCountLabel(120), '99+');
    expect(tabBadge(tester), '99+');
    await tapTab(tester, 'Chat');
    await tester.pump(const Duration(seconds: 7));
    expect(rowPills(tester), ['99+']);
  });

  test('unreadCountLabel: the number up to 99, then 99+', () {
    expect([0, 1, 99].map(unreadCountLabel), ['0', '1', '99']);
    expect([100, 1000].map(unreadCountLabel), ['99+', '99+']);
  });

  testWidgets('a conversation marked unread counts one, in the badge and on its row', (tester) async {
    setSize(tester);
    kit.bob();
    final ohio = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag);
    channelMsgs(ohio, 1);
    kit.service.markRead(ohio.convKey);
    expect(kit.controller.unreadMessages, 0);
    kit.service.markUnread(radioA, ohio.convKey);
    kit.controller.refresh();
    expect(kit.controller.unreadMessages, 1);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.pump();
    expect(tabBadge(tester), '1');
    await tapTab(tester, 'Chat');
    await tester.pump(const Duration(seconds: 7));
    expect(rowPills(tester), ['1']);
  });
}
