// The real shell with the real chat provider: Chat tab (Contacts | Channels), unread badge, Chat-in-Drive button on the Drive tab.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';

import '../fakes.dart' show Harness;
import 'chat_kit.dart';

Future<void> tapTab(WidgetTester tester, String label) async {
  await tester.tap(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text(label)));
  await tester.pumpAndSettle();
}

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

  testWidgets('Chat tab: segments are real, Channels lists channels, the badge counts unread conversations, search opens', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    kit.bob();
    final h = Harness();
    await h.pumpApp(tester);
    kit.incoming(ch, 'Ann', 'morning all');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
    expect(find.byKey(const Key('chat-badge')), findsOneWidget);
    await tapTab(tester, 'Chat');
    expect(find.byKey(const Key('chat-segments')), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget, reason: 'Contacts segment is a real list, not a placeholder');
    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();
    expect(find.text('Ohio'), findsOneWidget);
    expect(find.text('morning all'), findsWidgets, reason: 'the row and the in-app banner');
    await tester.pump(const Duration(seconds: 7)); // the banner has gone
    await tester.tap(find.byKey(const Key('chat-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('global-search-field')), 'morning');
    await tester.pump();
    expect(find.byKey(const Key('global-search-results')), findsOneWidget);
  });

  testWidgets('Drive tab has the Messages button; it opens the drive sheet with the unread conversation', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Ann', 'road closed ahead');
    final h = Harness()..approveKey();
    await h.pumpApp(tester);
    await tester.pump();
    expect(find.byKey(const Key('drive-chat')), findsOneWidget);
    await tester.tap(find.byKey(const Key('drive-chat')));
    await tester.pumpAndSettle();
    expect(find.byKey(Key('drive-chat-row-${ch.convKey}')), findsOneWidget);
    expect(find.text('road closed ahead'), findsOneWidget);
  });

  testWidgets('iPad landscape: two columns, a tapped conversation opens in the right pane', (tester) async {
    setSize(tester, w: 1194, h: 834);
    final ch = await kit.channel(1, 'Ohio');
    kit.incoming(ch, 'Ann', 'morning all');
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.descendant(of: find.byKey(const Key('shell-rail')), matching: find.text('Chat')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-pane-empty')), findsOneWidget);
    await tester.tap(find.text('Channels'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ohio'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chat-pane-empty')), findsNothing);
    expect(find.byKey(const Key('composer-field')), findsOneWidget, reason: 'the conversation is in the pane');
    expect(find.byKey(const Key('chat-segments')), findsOneWidget, reason: 'the list is still on screen beside it');
    await tester.pump(const Duration(seconds: 7));
  });
}
