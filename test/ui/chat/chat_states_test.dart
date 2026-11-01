// Contacts list, Chat-in-Drive sheet, banners, passenger lock in the composer, and every main screen at phone / iPad
// sizes, text scale 2.5 and dark mode (no overflow, 48 dp targets, labelled targets).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/channel_detail_screen.dart';
import 'package:meshsonar/ui/chat/channels_view.dart';
import 'package:meshsonar/ui/chat/chat_banner_host.dart';
import 'package:meshsonar/ui/chat/chat_drive_sheet.dart';
import 'package:meshsonar/ui/chat/contacts_view.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';

import 'chat_kit.dart';

/// The chat streams were made outside the test's fake-async zone: let the real event loop deliver, then build.
Future<void> flush(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
  await tester.pump();
}

void main() {
  late ChatKit kit;
  setUp(() => kit = ChatKit());
  tearDown(() => kit.dispose());

  group('Contacts', () {
    testWidgets('real contacts with last message, search, tap opens the DM; repeaters are not chat partners', (tester) async {
      setSize(tester);
      kit.bob();
      kit.store.contacts.upsert(Contact(radioId: radioA, publicKey: 'c' * 64, type: ContactType.repeater, name: 'Hilltop'));
      kit.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: 5, text: 'you there?', snr: 4));
      await tester.pumpWidget(host(Scaffold(body: ContactsView(controller: kit.controller))));
      await tester.pump();
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('you there?'), findsOneWidget);
      expect(find.text('Hilltop'), findsNothing);
      await tester.enterText(find.byKey(const Key('contacts-search')), 'zzz');
      await tester.pump();
      expect(find.text('No match'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('contacts-search')), 'bo');
      await tester.pump();
      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(find.text('you there?'), findsOneWidget);
    });

    testWidgets('no contacts: explains where they come from', (tester) async {
      setSize(tester);
      await tester.pumpWidget(host(Scaffold(body: ContactsView(controller: kit.controller))));
      await tester.pump();
      expect(find.byKey(const Key('contacts-empty')), findsOneWidget);
    });
  });

  group('Passenger lock in the composer', () {
    testWidgets('moving: composer replaced by the lock with I am a passenger; tapping it brings the composer back', (tester) async {
      setSize(tester);
      final ch = await kit.channel(1, 'Ohio');
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pump();
      final now = DateTime.fromMillisecondsSinceEpoch(kit.clockMs);
      kit.controller.updateDrive(driving: true, sessionId: 'd1', speedMps: 12, fixAt: now);
      await tester.pump();
      expect(find.byKey(const Key('composer-locked')), findsOneWidget);
      expect(find.byKey(const Key('composer-field')), findsNothing);
      // incoming messages still arrive while locked
      kit.incoming(ch, 'Ann', 'ping from the road');
      await flush(tester);
      expect(find.text('ping from the road'), findsOneWidget);
      await tester.tap(find.byKey(const Key('passenger-button')));
      await tester.pump();
      expect(find.byKey(const Key('composer-field')), findsOneWidget);
      // slow down / stop the drive: composer stays
      kit.controller.updateDrive(driving: false);
      await tester.pump();
      expect(find.byKey(const Key('composer-field')), findsOneWidget);
    });
  });

  group('Chat-in-Drive sheet', () {
    Future<void> pumpSheet(WidgetTester tester) async {
      await tester.pumpWidget(host(Builder(builder: (c) => Scaffold(body: Center(child: FilledButton(key: const Key('open'), onPressed: () => showChatDriveSheet(c, kit.controller), child: const Text('open')))))));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
    }

    testWidgets('lists unread conversations first; opens one with a composer; locked while moving', (tester) async {
      setSize(tester);
      final a = await kit.channel(1, 'Ohio');
      final b = await kit.channel(2, 'Quiet');
      kit.incoming(a, 'Ann', 'convoy at the exit');
      kit.service.markRead(b.convKey);
      await pumpSheet(tester);
      expect(find.text('Unread messages'), findsOneWidget);
      expect(find.byKey(Key('drive-chat-row-${a.convKey}')), findsOneWidget);
      expect(find.byKey(Key('drive-chat-row-${b.convKey}')), findsNothing);
      await tester.tap(find.byKey(Key('drive-chat-row-${a.convKey}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-chat-conversation')), findsOneWidget);
      expect(find.byKey(const Key('composer-field')), findsOneWidget);
      kit.controller.updateDrive(driving: true, sessionId: 'd1', speedMps: 20, fixAt: DateTime.fromMillisecondsSinceEpoch(kit.clockMs));
      await tester.pump();
      expect(find.byKey(const Key('composer-locked')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-chat-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('drive-chat-locked')), findsOneWidget);
    });

    testWidgets('nothing yet: says so', (tester) async {
      setSize(tester);
      await pumpSheet(tester);
      expect(find.text('No messages yet'), findsOneWidget);
    });
  });

  group('Banners', () {
    testWidgets('an incoming message shows a banner that opens the conversation; muted and the open conversation do not', (tester) async {
      setSize(tester);
      final ch = await kit.channel(1, 'Ohio');
      final quiet = await kit.channel(2, 'Quiet');
      kit.service.setNotifyMode(radioA, quiet.convKey, NotifyMode.muted);
      final holder = ValueNotifier<ChatController?>(kit.controller);
      await tester.pumpWidget(host(ChatBannerHost(controllerListenable: holder, visibleFor: const Duration(seconds: 2), child: const Scaffold(body: Center(child: Text('shell'))))));
      kit.incoming(quiet, 'Q', 'muted chatter');
      await flush(tester);
      expect(find.byKey(const Key('chat-banner')), findsNothing);
      kit.incoming(ch, 'Ann', 'hello from Ann');
      await flush(tester);
      expect(find.byKey(const Key('chat-banner')), findsOneWidget);
      expect(find.text('Ann in Ohio'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-banner')));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      kit.incoming(ch, 'Ann', 'while looking');
      await flush(tester);
      expect(find.byKey(const Key('chat-banner')), findsNothing);
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('Layouts: phone, iPad, text scale 2.5, dark', () {
    final configs = <String, (double, double, double, Brightness)>{
      'iPhone light': (390, 844, 1.0, Brightness.light),
      'iPhone 2.5x dark': (390, 844, 2.5, Brightness.dark),
      'iPad light': (820, 1180, 1.0, Brightness.light),
      'iPad landscape 1.5x dark': (1180, 820, 1.5, Brightness.dark),
    };

    Future<void> seed() async {
      await kit.connect();
      final ch = await kit.channel(1, 'Ohio');
      final h = await kit.channel(2, '#hamradio', kind: ChannelKind.hashtag);
      kit.bob();
      kit.incoming(ch, 'Ann with a rather long display name', 'A long message that has to wrap over several lines because people write paragraphs on a mesh network too, with https://meshsonar.com/channels in it and an @[Me] mention');
      kit.incoming(h, 'Bo', 'short');
      kit.service.setPinned(radioA, h.convKey, true);
      await kit.store.channels.save(Channel(radioId: radioA, slot: 0, name: '#wardriving', kind: ChannelKind.system), secret: Uint8List0.value);
      kit.service.recordOwnPing(radioA, 0);
      kit.sink.failNext = const RadioRejected('x');
      kit.service.send(radioId: radioA, convKey: ch.convKey, text: 'this one fails');
      await kit.service.pump();
    }

    for (final e in configs.entries) {
      final (w, h, scale, b) = e.value;
      testWidgets('${e.key}: channels list', (tester) async {
        setSize(tester, w: w, h: h, scale: scale);
        await seed();
        await tester.pumpWidget(host(Scaffold(body: ChannelsView(controller: kit.controller)), brightness: b));
        await tester.pump();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      });
      testWidgets('${e.key}: conversation with a failed message and long text', (tester) async {
        setSize(tester, w: w, h: h, scale: scale);
        await seed();
        final ch = kit.store.channels.bySlot(radioA, 1)!;
        await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey), brightness: b));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('Not sent'), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(textContrastGuideline));
      });
      testWidgets('${e.key}: composer locked while moving', (tester) async {
        setSize(tester, w: w, h: h, scale: scale);
        await seed();
        final ch = kit.store.channels.bySlot(radioA, 1)!;
        kit.controller.updateDrive(driving: true, sessionId: 'd', speedMps: 15, fixAt: DateTime.fromMillisecondsSinceEpoch(kit.clockMs));
        await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey), brightness: b));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('composer-locked')), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      });
      testWidgets('${e.key}: channel info', (tester) async {
        setSize(tester, w: w, h: h, scale: scale);
        await seed();
        final ch = kit.store.channels.bySlot(radioA, 1)!;
        await tester.pumpWidget(host(ChannelDetailScreen(controller: kit.controller, channelId: ch.id!), brightness: b));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      });
    }
  });
}

class Uint8List0 {
  static final value = Uint8List.fromList(List.filled(16, 3));
}
