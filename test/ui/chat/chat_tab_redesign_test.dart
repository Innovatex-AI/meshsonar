// The redesigned Chat tab (WP2): shell, Chats list, Network shell.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/chat/chats_list_view.dart' show ChatsSkeleton;
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;
import 'package:meshsonar/ui/shell/chat_tab.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;
import 'chat_kit.dart';
import '../../support/semantics_audit.dart';

const Size phone = Size(393, 852);
const Size se = Size(375, 667);
const Size ipad = Size(1024, 768);
const Size ipadPortrait = Size(744, 1133);

void main() {
  late ChatKit kit;
  late Harness h;
  ChatTabProviderImpl? provider;

  setUp(() {
    kit = ChatKit();
    h = Harness();
    RedesignedChatTabState.resetSession();
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

  Future<void> pumpTab(WidgetTester tester, {Size size = phone, double scale = 1.0, Brightness brightness = Brightness.light}) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await h.state.init();
    await tester.pumpWidget(AppScope(
      state: h.state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: meshSonarTheme(brightness).copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
        home: const Scaffold(body: ChatTab()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Ohio (channel, incoming), Bob (DM, own last message), Alice (DM, pinned, unread).
  Future<void> seed() async {
    final ch = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag);
    kit.bob();
    kit.clockMs += 1000;
    kit.incoming(ch, 'Dave', 'net starts at 8');
    kit.clockMs += 1000;
    kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'on my way');
  }

  group('shell', () {
    testWidgets('Chats is the default segment, the title, ✎ and the segments are there; one tap opens a conversation', (tester) async {
      await seed();
      await pumpTab(tester);
      expect(find.byKey(const Key('chat-segments')), findsOneWidget);
      expect(find.text('Chat'), findsWidgets);
      expect(find.byKey(const Key('chat-new')), findsOneWidget);
      final sz = tester.getSize(find.byKey(const Key('chat-new')));
      expect(sz.width, greaterThanOrEqualTo(44));
      expect(sz.height, greaterThanOrEqualTo(44));
      expect(find.text('Ohio'), findsOneWidget);
      expect(find.text('Bob'), findsOneWidget);
      await tester.tap(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget, reason: 'one tap from the list to the conversation');
    });

    testWidgets('segments switch, the choice is kept for the session, a cold launch is Chats again', (tester) async {
      await seed();
      await pumpTab(tester);
      await tester.tap(find.byKey(const Key('segment-network')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-empty')), findsOneWidget);
      // Rebuild the tab: the session remembers Network.
      await pumpTab(tester);
      expect(find.byKey(const Key('network-empty')), findsOneWidget);
      await tester.tap(find.byKey(const Key('segment-contacts')));
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget, reason: 'the Contacts segment is the real contacts list');
      RedesignedChatTabState.resetSession();
      await pumpTab(tester);
      expect(find.text('Ohio'), findsOneWidget);
    });

    testWidgets('the New button opens the New chat sheet; New message goes to Contacts', (tester) async {
      await seed();
      await pumpTab(tester);
      await tester.tap(find.byKey(const Key('chat-new')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-message')), findsOneWidget);
      expect(find.byKey(const Key('add-hashtag')), findsOneWidget);
      await tester.tap(find.byKey(const Key('new-message')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('contacts-list')), findsWidgets);
    });

    testWidgets('offline: the banner says so, with the one Connect action', (tester) async {
      await seed();
      await pumpTab(tester);
      expect(find.byKey(const Key('chat-status-banner')), findsOneWidget);
      expect(find.textContaining('Radio not connected'), findsOneWidget);
      expect(find.text('Connect'), findsOneWidget);
    });
  });

  // WP14: every width the app ships on at AX2 (2.0) and AX5 (3.1): no overflow, tap targets (iOS 44, Android 48), labelled targets.
  group('AX2 / AX5 matrix', () {
    for (final (name, size) in [('393', phone), ('375', se), ('744', ipadPortrait), ('1024', ipad)]) {
      for (final scale in [2.0, 3.1]) {
        testWidgets('Chats list at $name wide, text ${scale}x', (tester) async {
          await seed();
          final sem = tester.ensureSemantics();
          await pumpTab(tester, size: size, scale: scale);
          final ex = tester.takeException();
          expect(ex, isNull, reason: ex is FlutterError ? ex.diagnostics.map((n) => n.toStringDeep()).join('\n') : '$ex');
          expectHeader(tester);
          sem.dispose();
          await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        });
      }
    }
  });

  group('layouts', () {
    for (final (name, size, scale) in [('iPhone 17 Pro', phone, 1.0), ('iPhone SE', se, 1.0), ('SE AX3', se, 2.35), ('17 Pro AX3', phone, 2.35)]) {
      testWidgets('Chats list at $name: no overflow, targets 44 pt', (tester) async {
        await seed();
        await pumpTab(tester, size: size, scale: scale);
        final ex = tester.takeException();
        expect(ex, isNull, reason: ex is FlutterError ? ex.diagnostics.map((n) => n.toStringDeep()).join('\n') : '$ex');
        // The header (title, segments, banner, search, tip) is tall at AX3: scroll to the first row.
        await tester.scrollUntilVisible(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')), 200, scrollable: find.byType(Scrollable).first);
        expect(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')), findsOneWidget);
        final seg = tester.getSize(find.byKey(const Key('chat-segments')));
        expect(seg.height, greaterThanOrEqualTo(32));
        expect(tester.getSize(find.byKey(const Key('chat-new'))).height, greaterThanOrEqualTo(44));
        final row = tester.getSize(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')));
        expect(row.height, greaterThanOrEqualTo(72));
        expect(row.width, size.width);
        // Dark too.
        await pumpTab(tester, size: size, scale: scale, brightness: Brightness.dark);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('iPad 1024x768: sidebar plus detail placeholder; a tap shows the conversation in the pane and highlights the row', (tester) async {
      await seed();
      await pumpTab(tester, size: ipad);
      expect(find.byKey(const Key('chat-pane-empty')), findsOneWidget);
      expect(find.text('Select a conversation'), findsOneWidget);
      final sidebar = tester.getSize(find.byKey(const Key('chat-scroll')));
      expect(sidebar.width, 380);
      await tester.tap(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-pane-empty')), findsNothing);
      expect(find.byType(ConversationScreen), findsOneWidget);
      final tile = tester.widget<Semantics>(find.descendant(of: find.byKey(Key('conv-${ConvKey.dm(bobKey)}')), matching: find.byType(Semantics)).first);
      expect(tile.properties.selected, isTrue);
    });
  });

  group('rows', () {
    testWidgets('own last message shows its delivery glyph and word to screen readers; unread pill; channel sender prefix', (tester) async {
      await seed();
      kit.clockMs += 1000;
      final ch = kit.store.channels.list(radioA).first;
      kit.incoming(ch, 'Dave', 'second one');
      await pumpTab(tester);
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp(r'^Bob.*Waiting to send.*on my way')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Ohio, 2 unread.*Dave: second one')), findsOneWidget);
      expect(find.byKey(const Key('unread-pill')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a draft shows the Draft: prefix', (tester) async {
      await seed();
      kit.service.saveDraft(ConvKey.dm(bobKey), 'are you still at the');
      await pumpTab(tester);
      expect(find.textContaining('Draft: ', findRichText: true), findsOneWidget);
      expect(find.textContaining('are you still at the', findRichText: true), findsOneWidget);
    });

    testWidgets('pinned and muted rows show their marks', (tester) async {
      await seed();
      kit.service.setPinned(radioA, ConvKey.dm(bobKey), true);
      kit.service.setNotifyMode(radioA, 'c:1', NotifyMode.muted);
      await pumpTab(tester);
      final bob = find.byKey(Key('conv-${ConvKey.dm(bobKey)}'));
      expect(find.descendant(of: bob, matching: find.byIcon(CupertinoIcons.pin_fill)), findsOneWidget);
      final ohio = find.byKey(const Key('conv-c:1'));
      expect(find.descendant(of: ohio, matching: find.byIcon(CupertinoIcons.bell_slash)), findsOneWidget);
    });

    testWidgets('System group is last', (tester) async {
      await seed();
      await kit.store.channels.save(const Channel(radioId: radioA, slot: 7, name: '#wardriving', kind: ChannelKind.system), secret: null);
      await pumpTab(tester);
      expect(find.text('SYSTEM'), findsOneWidget);
      final sys = tester.getTopLeft(find.text('#wardriving')).dy;
      final bob = tester.getTopLeft(find.text('Bob')).dy;
      expect(sys, greaterThan(bob));
    });
  });

  group('swipe and menus', () {
    testWidgets('swiping right reveals Pin and tapping it pins', (tester) async {
      await seed();
      await pumpTab(tester);
      final key = ConvKey.dm(bobKey);
      await tester.drag(find.byKey(Key('conv-$key')), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('swipe-pin-$key')), findsOneWidget);
      await tester.tap(find.byKey(Key('swipe-pin-$key')));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(key)!.pinned, isTrue);
    });

    testWidgets('swiping left reveals Mute and Delete; Mute asks how long, then mutes', (tester) async {
      await seed();
      await pumpTab(tester);
      final key = ConvKey.dm(bobKey);
      await tester.drag(find.byKey(Key('conv-$key')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('swipe-mute-$key')), findsOneWidget);
      expect(find.byKey(Key('swipe-delete-$key')), findsOneWidget);
      await tester.tap(find.byKey(Key('swipe-mute-$key')));
      await tester.pumpAndSettle();
      expect(find.text('For 8 hours'), findsOneWidget);
      await tester.tap(find.text('For 8 hours'));
      await tester.pumpAndSettle();
      final s = kit.service.conversation(key)!;
      expect(s.isMutedAt(kit.clockMs), isTrue);
      expect(s.mutedUntilMs, kit.clockMs + const Duration(hours: 8).inMilliseconds);
    });

    testWidgets('Delete of a DM clears the history with an Undo that puts it back', (tester) async {
      await seed();
      await pumpTab(tester);
      final key = ConvKey.dm(bobKey);
      await tester.drag(find.byKey(Key('conv-$key')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-delete-$key')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(kit.service.conversation(key)!.lastTsMs, isNull, reason: 'history cleared');
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(kit.service.conversation(key)!.lastPreview, 'on my way');
      expect(kit.service.page(key).messages.length, 1);
    });

    testWidgets('Delete of a channel asks first; Cancel does nothing', (tester) async {
      await seed();
      await pumpTab(tester);
      await tester.drag(find.byKey(const Key('conv-c:1')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('swipe-delete-c:1')));
      await tester.pumpAndSettle();
      expect(find.text('Delete channel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(kit.store.channels.list(radioA).length, 1);
    });

    testWidgets('long-press opens the context menu with the last messages as the preview', (tester) async {
      await seed();
      await pumpTab(tester);
      final key = ConvKey.dm(bobKey);
      final g = await tester.startGesture(tester.getCenter(find.byKey(Key('conv-$key'))));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.byKey(Key('menu-pin-$key')), findsOneWidget);
      expect(find.byKey(Key('menu-delete-$key')), findsOneWidget);
      expect(find.byKey(Key('menu-open-$key')), findsOneWidget);
      expect(find.byKey(const Key('chat-preview')), findsWidgets);
      await tester.tap(find.byKey(Key('menu-pin-$key')));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(key)!.pinned, isTrue);
    });

    testWidgets('screen readers get Pin, Mute and Delete as custom actions', (tester) async {
      await seed();
      await pumpTab(tester);
      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')));
      final labels = node.getSemanticsData().customSemanticsActionIds!.map((id) => CustomSemanticsAction.getAction(id)!.label).toSet();
      expect(labels, containsAll(['Pin', 'Mute', 'Delete']));
      handle.dispose();
    });
  });

  group('search', () {
    testWidgets('typing filters the conversations and lists matching messages; no match offers message search', (tester) async {
      await seed();
      await pumpTab(tester);
      await tester.enterText(find.byKey(const Key('chat-search-field')), 'Ohio');
      await tester.pump();
      expect(find.byKey(const Key('conv-c:1')), findsOneWidget);
      expect(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')), findsNothing);
      await tester.enterText(find.byKey(const Key('chat-search-field')), 'zzzqq');
      await tester.pump();
      expect(find.byKey(const Key('chats-no-results')), findsOneWidget);
      expect(find.text('Search messages instead'), findsOneWidget);
    });

    testWidgets('a message result opens its conversation', (tester) async {
      await seed();
      await pumpTab(tester);
      await tester.enterText(find.byKey(const Key('chat-search-field')), 'starts');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chats-message-hits')), findsOneWidget);
      await tester.tap(find.descendant(of: find.byKey(const Key('chats-message-hits')), matching: find.textContaining('net starts at 8')));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets('no radio ever: the hero with Connect radio', (tester) async {
      kit.dispose();
      kit = ChatKit(knownRadio: false);
      provider?.dispose();
      provider = ChatTabProviderImpl(kit.controller);
      ChatTabHost.provider.value = provider;
      await pumpTab(tester);
      expect(find.byKey(const Key('chats-empty-no-radio')), findsOneWidget);
      expect(find.text('Connect a radio to start chatting'), findsOneWidget);
      expect(find.text('Connect radio'), findsOneWidget);
    });

    testWidgets('radio known, nothing yet, offline: No conversations yet with a way to add a channel', (tester) async {
      await pumpTab(tester);
      expect(find.byKey(const Key('chats-empty')), findsOneWidget);
      expect(find.text('No conversations yet'), findsOneWidget);
      expect(find.text('New chat'), findsOneWidget);
    });

    testWidgets('connected, nothing yet: Join Public channel and Announce myself', (tester) async {
      await kit.connect();
      await pumpTab(tester);
      expect(find.text('Join Public channel'), findsOneWidget);
      expect(find.text('Announce myself'), findsOneWidget);
    });

    testWidgets('syncing placeholder is distinct from empty and reads aloud', (tester) async {
      await pumpTab(tester);
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: ChatsSkeletonHost())));
      expect(find.byKey(const Key('chats-skeleton')), findsOneWidget);
      expect(find.textContaining('Reading channels from your radio'), findsOneWidget);
    });
  });

  group('Network', () {
    testWidgets('lists repeaters, rooms and sensors, five per section with Show all', (tester) async {
      for (var i = 0; i < 7; i++) {
        kit.store.contacts.upsert(Contact(
            radioId: radioA, publicKey: 'c${i}c0000000000000000000000000000000000000000000000000000000000000'.substring(0, 64), type: ContactType.repeater, name: 'Ridge $i', lastHeardMs: kit.clockMs - i * 60000));
      }
      kit.store.contacts.upsert(Contact(radioId: radioA, publicKey: 'd0d0000000000000000000000000000000000000000000000000000000000001', type: ContactType.sensor, name: 'Garage temp'));
      kit.store.contacts.upsert(Contact(radioId: radioA, publicKey: 'e0e0000000000000000000000000000000000000000000000000000000000001', type: ContactType.room, name: 'North room'));
      await pumpTab(tester);
      await tester.tap(find.byKey(const Key('segment-network')));
      await tester.pumpAndSettle();
      expect(find.text('REPEATERS'), findsOneWidget);
      expect(find.byKey(const Key('network-radio-card')), findsOneWidget);
      expect(find.text('Ridge 0'), findsOneWidget);
      expect(find.text('Ridge 4'), findsOneWidget);
      expect(find.text('Ridge 5'), findsNothing);
      expect(find.text('Show all 7'), findsOneWidget);
      expect(find.byKey(const Key('network-showall-repeater')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('network-showall-repeater')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('network-showall-repeater')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Ridge 6'), 200, scrollable: find.byType(Scrollable).first);
      expect(find.text('Ridge 6'), findsOneWidget);
      expect(find.text('Show fewer'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('SENSORS'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('Garage temp'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('ROOMS'), -300, scrollable: find.byType(Scrollable).first);
      expect(find.text('North room'), findsOneWidget);
    });
  });
}

/// Test host for the skeleton (the state needs a syncing ContactManager, which only a live radio produces).
class ChatsSkeletonHost extends StatelessWidget {
  const ChatsSkeletonHost({super.key});
  @override
  Widget build(BuildContext context) => const ChatsSkeleton();
}
