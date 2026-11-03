// WP3: the New chat sheet and its channel forms, the quick switcher, mark unread, mute durations, the context-menu fallback
// and the screen-reader actions. Runs through the real Chat tab (the New button / Cmd-N open the sheet).
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/chat/chat_list_actions.dart';
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/chat/channel_flows.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/qr_widgets.dart';
import 'package:meshsonar/ui/contacts/add_contact_screen.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;
import 'package:meshsonar/ui/shell/chat_tab.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;
import 'chat_kit.dart';

const Size phone = Size(393, 1700); // tall: the sheet opens at half height and its list builds lazily
const Size ipad = Size(1024, 768);

void main() {
  late ChatKit kit;
  late Harness h;
  late ChatTabProviderImpl provider;

  setUp(() {
    kit = ChatKit();
    h = Harness();
    AppFlags.chatRedesign = true;
    RedesignedChatTabState.resetSession();
    appTipStore = MemoryTipStore();
    ChatWiring.controller.value = kit.controller;
    provider = ChatTabProviderImpl(kit.controller);
    ChatTabHost.provider.value = provider;
  });
  tearDown(() {
    ChatUiHooks.scanQr = defaultQrScan;
    ChatListActions.useContextMenu = true;
    ChatTabHost.provider.value = null;
    ChatWiring.controller.value = null;
    AppFlags.chatRedesign = false;
    provider.dispose();
    kit.dispose();
    dismissAppToast();
  });

  Future<void> pumpTab(WidgetTester tester, {Size size = phone}) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await h.state.init();
    await tester.pumpWidget(AppScope(
      state: h.state,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
        home: const Scaffold(body: ChatTab()),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('chat-new')));
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
  }

  group('sheet', () {
    testWidgets('the New button opens it; every entry is there; Cancel closes it', (tester) async {
      await pumpTab(tester);
      await openSheet(tester);
      for (final k in ['new-to', 'new-message', 'add-hashtag', 'add-public', 'add-create', 'add-scan', 'add-paste', 'new-contact']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.byKey(const Key('new-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-to')), findsNothing);
    });

    testWidgets('Cmd-N opens it', (tester) async {
      await pumpTab(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-to')), findsOneWidget);
    });

    testWidgets('add a channel is two taps from the New button; the old list-foot button is gone', (tester) async {
      await pumpTab(tester);
      expect(find.byKey(const Key('add-channel')), findsNothing);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-hashtag')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('form-name')), findsOneWidget);
      await tester.tap(find.byKey(const Key('new-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-hashtag')), findsOneWidget, reason: 'Back returns to the start page');
    });

    testWidgets('recent people and favourites sit in a strip; tapping one opens the conversation', (tester) async {
      kit.bob();
      kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'hi');
      await pumpTab(tester);
      await openSheet(tester);
      expect(find.byKey(const Key('new-recents')), findsOneWidget);
      await tester.tap(find.byKey(Key('new-recent-${bobKey.substring(0, 12)}')));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
    });

    testWidgets('typing in To: filters people by name or key and offers Add a contact when nobody matches', (tester) async {
      kit.bob();
      await pumpTab(tester);
      await openSheet(tester);
      await tester.enterText(find.byKey(const Key('new-to')), 'bo');
      await tester.pumpAndSettle();
      expect(find.byKey(Key('new-person-${bobKey.substring(0, 12)}')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('new-to')), 'b0b0');
      await tester.pumpAndSettle();
      expect(find.byKey(Key('new-person-${bobKey.substring(0, 12)}')), findsOneWidget, reason: 'key prefix');
      await tester.enterText(find.byKey(const Key('new-to')), 'zzzq');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-no-people')), findsOneWidget);
      expect(find.byKey(const Key('new-contact-search')), findsOneWidget);
    });

    testWidgets('a pasted link in To: is offered as a shortcut into the paste form', (tester) async {
      await pumpTab(tester);
      await openSheet(tester);
      final link = MeshLinks.encodeChannel(name: 'Club', secret: List.filled(16, 4));
      await tester.enterText(find.byKey(const Key('new-to')), link);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('new-use-link')));
      await tester.pumpAndSettle();
      expect(tester.widget<CupertinoTextField>(find.byKey(const Key('form-link'))).controller!.text, link);
    });

    testWidgets('Add a contact closes the sheet and opens the add screen', (tester) async {
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('new-contact')));
      await tester.pumpAndSettle();
      expect(find.byType(AddContactScreen), findsOneWidget);
    });
  });

  group('channel flows', () {
    testWidgets('Join Public writes the radio slot and toasts with Open', (tester) async {
      final s = await kit.connect();
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-public')));
      await tester.pumpAndSettle();
      expect(s.slots[0].name, 'Public');
      expect(find.text('Joined Public'), findsOneWidget);
      expect(find.byKey(const Key('new-to')), findsNothing, reason: 'sheet closed');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      await settle(tester);
    });

    testWidgets('Join Public without a radio says so inside the sheet', (tester) async {
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-public')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('new-error')), findsOneWidget);
      expect(find.textContaining('Connect your radio'), findsOneWidget);
    });

    testWidgets('# channel: live key preview, bad name explained, good name joins with the lower-case key', (tester) async {
      final s = await kit.connect();
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-hashtag')));
      await tester.pumpAndSettle();
      expect(find.text('Type a name to see its key.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('form-name')), 'HamRadio');
      await tester.pump();
      final key = hashtagSecret16('#hamradio').take(4).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(tester.widget<Text>(find.byKey(const Key('hashtag-preview'))).data, '#hamradio  ->  key $key…');
      await tester.enterText(find.byKey(const Key('form-name')), 'two words');
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('hashtag-preview'))).data, contains('letters, numbers and dashes'));
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('form-error')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('form-name')), 'HamRadio');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(s.slots.firstWhere((x) => !x.isEmpty).name, '#hamradio');
      expect(s.slots.firstWhere((x) => !x.isEmpty).secret, hashtagSecret16('#hamradio'));
      expect(find.text('Joined #hamradio'), findsOneWidget);
      await settle(tester);
    });

    testWidgets('radio full: plain-language message in the form, nothing saved', (tester) async {
      await kit.connect(session: FakeRadioSession(n: 2)..put(0, 'a', List.filled(16, 1))..put(1, 'b', List.filled(16, 2)));
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-hashtag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-name')), 'newone');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('no free channel slot'), findsOneWidget);
    });

    testWidgets('paste: garbage link explained, real link joins; name + secret works', (tester) async {
      final s = await kit.connect();
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-paste')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-link')), 'https://example.com');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('not a MeshCore link'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('form-link')), MeshLinks.encodeChannel(name: 'Club', secret: List.filled(16, 4)));
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(s.slots.any((x) => x.name == 'Club'), isTrue);
      await settle(tester);

      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-paste')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('form-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-name')), 'Crew');
      await tester.enterText(find.byKey(const Key('form-secret')), 'xyz');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('32 letters and numbers'), findsWidgets);
      await tester.enterText(find.byKey(const Key('form-secret')), '0f' * 16);
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(s.slots.any((x) => x.name == 'Crew'), isTrue);
      await settle(tester);
    });

    testWidgets('paste from clipboard fills the link field', (tester) async {
      final link = MeshLinks.encodeChannel(name: 'Clip', secret: List.filled(16, 6));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': link};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-paste')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('form-clipboard')));
      await tester.pumpAndSettle();
      expect(tester.widget<CupertinoTextField>(find.byKey(const Key('form-link'))).controller!.text, link);
    });

    testWidgets('scan: the injected scanner result asks before joining; Not now joins nothing, Join does', (tester) async {
      final s = await kit.connect();
      final link = MeshLinks.encodeChannel(name: 'Scanned', secret: List.filled(16, 8), regionScope: 'ohio');
      ChatUiHooks.scanQr = (_) async => link;
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('join-link-dialog')), findsOneWidget);
      expect(find.textContaining('"ohio"'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(s.slots.every((x) => x.isEmpty), isTrue);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('join-link-confirm')));
      await tester.pumpAndSettle();
      expect(s.slots.any((x) => x.name == 'Scanned'), isTrue);
      expect(kit.store.channels.list(radioA).single.regionScope, 'ohio');
      await settle(tester);
    });

    testWidgets('scan cancelled does nothing', (tester) async {
      final s = await kit.connect();
      ChatUiHooks.scanQr = (_) async => null;
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('join-link-dialog')), findsNothing);
      expect(s.slots.every((x) => x.isEmpty), isTrue);
    });

    testWidgets('create private: success page shows the QR, link and secret; the link joins a second phone; Done toasts', (tester) async {
      final s = await kit.connect();
      await pumpTab(tester);
      await openSheet(tester);
      await tester.tap(find.byKey(const Key('add-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-name')), 'Trail crew');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('channel-created')), findsOneWidget);
      expect(find.byKey(const Key('share-qr')), findsOneWidget);
      final link = tester.widget<SelectableText>(find.byKey(const Key('share-link'))).data!;
      final parsed = MeshLinks.parse(link) as ChannelLink;
      expect(parsed.name, 'Trail crew');
      expect(parsed.secret, s.slots.firstWhere((x) => x.name == 'Trail crew').secret);
      await tester.tap(find.byKey(const Key('show-secret')));
      await tester.pumpAndSettle();
      expect(tester.widget<SelectableText>(find.byKey(const Key('secret-hex'))).data, hasLength(32));

      final kit2 = ChatKit();
      final s2 = await kit2.connect();
      await kit2.controller.admin.joinFromLink(radioA, link);
      expect(s2.slots[0].secret, parsed.secret);
      kit2.dispose();

      await tester.tap(find.byKey(const Key('created-done')));
      await tester.pumpAndSettle();
      expect(find.text('Joined Trail crew'), findsOneWidget);
      await settle(tester);
    });
  });

  group('mark unread', () {
    Future<String> seedDm() async {
      kit.bob();
      kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'hello');
      return ConvKey.dm(bobKey);
    }

    testWidgets('swipe right reveals Mark unread; the row shows one unread, the tab badge counts it; opening clears it', (tester) async {
      final key = await seedDm();
      await pumpTab(tester);
      await tester.drag(find.byKey(Key('conv-$key')), const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('Mark unread'), findsOneWidget);
      await tester.tap(find.byKey(Key('swipe-unread-$key')));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(key)!.markedUnread, isTrue);
      expect(kit.controller.unreadMessages, 1);
      expect(find.byKey(const Key('unread-pill')), findsOneWidget);
      await tester.tap(find.byKey(Key('conv-$key')));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(key)!.markedUnread, isFalse);
      expect(kit.controller.unreadMessages, 0);
    });

    testWidgets('the context menu toggles it back to Mark read', (tester) async {
      final key = await seedDm();
      kit.service.markUnread(radioA, key);
      await pumpTab(tester);
      final g = await tester.startGesture(tester.getCenter(find.byKey(Key('conv-$key'))));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('Mark read'), findsOneWidget);
      await tester.tap(find.byKey(Key('menu-unread-$key')));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(key)!.markedUnread, isFalse);
    });
  });

  group('mute durations', () {
    for (final (label, hours) in [('For 1 hour', 1), ('For 24 hours', 24)]) {
      testWidgets('$label mutes until then', (tester) async {
        kit.bob();
        kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'hello');
        final key = ConvKey.dm(bobKey);
        await pumpTab(tester);
        await tester.drag(find.byKey(Key('conv-$key')), const Offset(-300, 0));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('swipe-mute-$key')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        final s = kit.service.conversation(key)!;
        expect(s.mutedUntilMs, kit.clockMs + Duration(hours: hours).inMilliseconds);
        expect(s.isMutedAt(kit.clockMs), isTrue);
        expect(s.isMutedAt(kit.clockMs + Duration(hours: hours).inMilliseconds + 1), isFalse, reason: 'expires by itself');
      });
    }

    testWidgets('Until I unmute is open-ended, Mentions only sets that mode, a muted row unmutes in one tap', (tester) async {
      final ch = await kit.channel(1, 'Ohio');
      kit.incoming(ch, 'Dave', 'hi');
      final key = ch.convKey;
      final actions = ChatListActions(kit.controller);
      await pumpTab(tester);
      Future<void> pick(String text) async {
        final row = kit.controller.conversationRows().firstWhere((r) => r.key == key);
        final ctx = tester.element(find.byKey(Key('conv-$key')));
        final f = actions.mute(ctx, row);
        await tester.pumpAndSettle();
        if (text.isNotEmpty) await tester.tap(find.text(text));
        await tester.pumpAndSettle();
        await f;
      }

      await pick('Until I unmute');
      var s = kit.service.conversation(key)!;
      expect(s.notifyMode, NotifyMode.muted);
      expect(s.mutedUntilMs, isNull);
      expect(s.isMutedAt(kit.clockMs + 999999999), isTrue);
      final row = kit.controller.conversationRows().firstWhere((r) => r.key == key);
      await actions.mute(tester.element(find.byKey(Key('conv-$key'))), row);
      await tester.pumpAndSettle();
      expect(kit.service.conversation(key)!.notifyMode, NotifyMode.all, reason: 'a muted conversation unmutes at once');
      await pick('Mentions only');
      s = kit.service.conversation(key)!;
      expect(s.notifyMode, NotifyMode.mentionsOnly);
    });
  });

  group('menus and screen readers', () {
    testWidgets('fallback: with the context menu off, long-press opens an action sheet with the same entries; Pin works', (tester) async {
      ChatListActions.useContextMenu = false;
      kit.bob();
      kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'hello');
      final key = ConvKey.dm(bobKey);
      await pumpTab(tester);
      await tester.longPress(find.byKey(Key('conv-$key')));
      await tester.pumpAndSettle();
      for (final id in ['open', 'pin', 'mute', 'markUnread', 'info', 'route', 'copyKey', 'delete']) {
        expect(find.byKey(Key('sheet-$id-$key')), findsOneWidget, reason: id);
      }
      await tester.tap(find.byKey(Key('sheet-pin-$key')));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(key)!.pinned, isTrue);
    });

    testWidgets('menu entries by kind: channels get Channel info, no Route; system rows only Open', (tester) async {
      final ch = await kit.channel(1, 'Ohio');
      kit.incoming(ch, 'Dave', 'hi');
      final a = ChatListActions(kit.controller);
      final rows = kit.controller.conversationRows();
      final ids = a.menuEntries(rows.firstWhere((r) => r.isChannel)).map((e) => e.id).toList();
      expect(ids, containsAll([ChatMenuId.info, ChatMenuId.markUnread, ChatMenuId.delete]));
      expect(ids, isNot(contains(ChatMenuId.route)));
      final groups = a.menuEntries(rows.firstWhere((r) => r.isChannel)).map((e) => e.group).toList();
      expect(groups, orderedEquals([...groups]..sort()), reason: 'groups stay in order');
    });

    testWidgets('screen readers get Pin, Mute, Mark unread, Contact info and Delete', (tester) async {
      kit.bob();
      kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'hello');
      await pumpTab(tester);
      final handle = tester.ensureSemantics();
      final node = tester.getSemantics(find.byKey(Key('conv-${ConvKey.dm(bobKey)}')));
      final labels = node.getSemanticsData().customSemanticsActionIds!.map((id) => CustomSemanticsAction.getAction(id)!.label).toSet();
      expect(labels, containsAll(['Pin', 'Mute', 'Mark unread', 'Contact info', 'Delete']));
      handle.dispose();
    });
  });

  group('quick switcher', () {
    Future<void> cmdK(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
    }

    testWidgets('iPad: Cmd-K filters conversations and Return opens the first', (tester) async {
      final ch = await kit.channel(1, 'Ohio');
      kit.incoming(ch, 'Dave', 'hi');
      kit.bob();
      kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'hello');
      await pumpTab(tester, size: ipad);
      await cmdK(tester);
      expect(find.byKey(const Key('switcher-field')), findsOneWidget);
      expect(find.byKey(const Key('switcher-c:1')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('switcher-field')), 'bo');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('switcher-c:1')), findsNothing);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(find.byKey(const Key('switcher-field')), findsNothing);
    });

    testWidgets('phone width: Cmd-K does nothing', (tester) async {
      await pumpTab(tester);
      await cmdK(tester);
      expect(find.byKey(const Key('switcher-field')), findsNothing);
    });
  });
}
