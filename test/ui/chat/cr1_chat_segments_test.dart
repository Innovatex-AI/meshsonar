// CR1 (chat + radio round): Chat is Chats | Contacts | Channels | Network. The Chats inbox keeps people, channels and rooms in
// labelled sections; Channels lists every channel, Public first, by recent activity or by name.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/chat/chats_list_view.dart' show resetChannelSort;
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;
import 'package:meshsonar/ui/shell/chat_tab.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;
import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  late Harness h;
  ChatTabProviderImpl? provider;

  setUp(() {
    kit = ChatKit();
    h = Harness();
    RedesignedChatTabState.resetSession();
    resetChannelSort();
    appTipStore = MemoryTipStore();
    ChatWiring.controller.value = kit.controller;
    provider = ChatTabProviderImpl(kit.controller);
    ChatTabHost.provider.value = provider;
  });
  tearDown(() {
    ChatTabHost.provider.value = null;
    ChatWiring.controller.value = null;
    provider?.dispose();
    kit.dispose();
    dismissAppToast();
  });

  Future<void> pumpTab(WidgetTester tester, {Size size = const Size(393, 852)}) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await h.state.init();
    await tester.pumpWidget(AppScope(
      state: h.state,
      child: MaterialApp(
        theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
        home: const Scaffold(body: ChatTab()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  double y(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  /// Public (old), #zebra (newest channel message), #alpha (no messages), Bob (DM), a room.
  Future<void> seed() async {
    final pub = await kit.channel(0, 'Public', kind: ChannelKind.public);
    await kit.channel(2, '#alpha', kind: ChannelKind.hashtag);
    final zebra = await kit.channel(3, '#zebra', kind: ChannelKind.hashtag);
    kit.bob();
    kit.clockMs += 1000;
    kit.incoming(pub, 'Ann', 'morning all');
    kit.clockMs += 1000;
    kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'on my way');
    kit.clockMs += 1000;
    kit.incoming(zebra, 'Dave', 'net at 8');
  }

  testWidgets('four segments; Cmd-1..4 switch; labels stay on one line on an SE', (tester) async {
    await seed();
    await pumpTab(tester, size: const Size(375, 667));
    for (final k in ['segment-chats', 'segment-contacts', 'segment-channels', 'segment-network']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
    // One line: every segment label is as tall as a single 13 pt line inside its 44 pt target.
    for (final label in ['Chats', 'Contacts', 'Channels', 'Network']) {
      expect(tester.getSize(find.text(label)).height, lessThan(20), reason: label);
    }
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('channels-sort')), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit4);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('channels-sort')), findsNothing);
  });

  testWidgets('the Chats inbox keeps direct messages and channels in their own labelled sections', (tester) async {
    await seed();
    await pumpTab(tester);
    expect(find.byKey(const Key('section-direct')), findsOneWidget);
    expect(find.byKey(const Key('section-channels')), findsOneWidget);
    expect(find.byKey(const Key('section-rooms')), findsNothing, reason: 'no rooms, no empty Rooms header');
    final dm = find.byKey(Key('conv-${ConvKey.dm(bobKey)}'));
    expect(dm, findsOneWidget);
    // Bob's DM is older than #zebra's last message, yet it sits in Direct messages above the Channels header.
    expect(y(tester, dm), lessThan(y(tester, find.byKey(const Key('section-channels')))));
    expect(y(tester, find.text('#zebra')), greaterThan(y(tester, find.byKey(const Key('section-channels')))));
  });

  testWidgets('Channels: every channel (also one with no messages), Public first, then recent; A–Z sorts by name', (tester) async {
    await seed();
    await pumpTab(tester);
    await tester.tap(find.byKey(const Key('segment-channels')));
    await tester.pumpAndSettle();
    expect(find.text('3 channels'), findsOneWidget);
    expect(find.text('Bob'), findsNothing, reason: 'people are not channels');
    final pub = y(tester, find.text('Public')), zebra = y(tester, find.text('#zebra')), alpha = y(tester, find.text('#alpha'));
    expect(pub, lessThan(zebra), reason: 'Public is always first, even when it is not the newest');
    expect(zebra, lessThan(alpha), reason: 'Recent: #zebra had the latest message, #alpha none');
    await tester.tap(find.byKey(const Key('channels-sort-name')));
    await tester.pumpAndSettle();
    expect(y(tester, find.text('Public')), lessThan(y(tester, find.text('#alpha'))));
    expect(y(tester, find.text('#alpha')), lessThan(y(tester, find.text('#zebra'))));
    // The sort is kept for the session.
    await tester.tap(find.byKey(const Key('segment-chats')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('segment-channels')));
    await tester.pumpAndSettle();
    expect(y(tester, find.text('#alpha')), lessThan(y(tester, find.text('#zebra'))));
  });

  testWidgets('Channels search matches names only; no match says so', (tester) async {
    await seed();
    await pumpTab(tester);
    await tester.tap(find.byKey(const Key('segment-channels')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('chat-search-field')), 'zeb');
    await tester.pumpAndSettle();
    expect(find.text('#zebra'), findsOneWidget);
    expect(find.text('#alpha'), findsNothing);
    expect(find.byKey(const Key('channels-sort')), findsNothing, reason: 'no sort control while searching');
    await tester.enterText(find.byKey(const Key('chat-search-field')), 'qqq');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('channels-no-results')), findsOneWidget);
  });

  testWidgets('Channels with only a DM: "No channels yet" with a way to join one', (tester) async {
    kit.bob();
    kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'hi');
    await pumpTab(tester);
    await tester.tap(find.byKey(const Key('segment-channels')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('channels-empty')), findsOneWidget);
  });
}
