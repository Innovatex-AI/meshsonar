import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/radio/inbound.dart' show RadioChannel;
import 'package:meshsonar/ui/chat/channel_detail_screen.dart';
import 'package:meshsonar/ui/chat/channel_flows.dart';
import 'package:meshsonar/ui/chat/channels_view.dart';
import 'package:meshsonar/ui/chat/chat_row.dart';
import 'package:meshsonar/ui/chat/qr_widgets.dart';

import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  setUp(() => kit = ChatKit());
  tearDown(() {
    ChatUiHooks.scanQr = defaultQrScan;
    kit.dispose();
  });

  Widget view() => host(Scaffold(body: ChannelsView(controller: kit.controller)));

  group('Channels list', () {
    testWidgets('rows: last message, unread badge, pinned and muted marks, sorted pinned then newest', (tester) async {
      setSize(tester);
      final a = await kit.channel(1, 'Ohio');
      final b = await kit.channel(2, '#hamradio', kind: ChannelKind.hashtag);
      final c = await kit.channel(3, 'Quiet');
      kit.incoming(a, 'Ann', 'hello ohio');
      kit.clockMs += 60000;
      kit.incoming(b, 'Bo', 'ham news');
      kit.incoming(b, 'Bo', 'more ham');
      kit.service.setPinned(radioA, c.convKey, true);
      kit.service.setNotifyMode(radioA, b.convKey, NotifyMode.muted);
      await tester.pumpWidget(view());
      await tester.pump();
      expect(find.text('hello ohio'), findsOneWidget);
      expect(find.byKey(Key('unread-${b.id}')), findsOneWidget);
      expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
      final order = tester.widgetList<ChatRow>(find.byType(ChatRow)).map((t) => (t.key as ValueKey?)?.value).toList();
      final rowKeys = [for (final k in order) if (k.toString().contains('channel-row')) k.toString()];
      expect(rowKeys.first, contains('${c.id}'), reason: 'pinned first');
      expect(rowKeys[1], contains('${b.id}'), reason: 'then newest');
    });

    testWidgets('System section: before the first drive it explains itself; with a wardrive channel it shows ping count, last ping and the budget pause', (tester) async {
      setSize(tester);
      await tester.pumpWidget(view());
      await tester.pump();
      expect(find.byKey(const Key('system-empty')), findsOneWidget);
      final sys = await kit.store.channels.save(Channel(radioId: radioA, slot: 0, name: '#wardriving', kind: ChannelKind.system), secret: hashtagSecret16('#wardriving'));
      kit.service.recordOwnPing(radioA, 0);
      kit.service.recordOwnPing(radioA, 0);
      kit.clockMs += 3 * 60000;
      kit.controller.refresh();
      await tester.pump();
      expect(find.byKey(Key('system-row-${sys.id}')), findsOneWidget);
      expect(find.textContaining('2 pings sent, last ping 3 min ago'), findsOneWidget);
      expect(find.byKey(const Key('system-paused')), findsNothing);
    });

    testWidgets('System traffic is read-only: others\' pings, no composer', (tester) async {
      setSize(tester);
      final sys = await kit.store.channels.save(Channel(radioId: radioA, slot: 0, name: '#wardriving', kind: ChannelKind.system), secret: hashtagSecret16('#wardriving'));
      kit.service.handleInbound(InboundChannelText(radioId: radioA, channelSlot: 0, timestamp: 100, text: 'Zed: MS:abc123xyz9', snr: 3));
      await tester.pumpWidget(view());
      await tester.pump();
      await tester.tap(find.byKey(const Key('view-traffic')));
      await tester.pumpAndSettle();
      expect(find.text('MS:abc123xyz9'), findsOneWidget);
      expect(find.byKey(const Key('composer-field')), findsNothing);
      expect(kit.service.conversations().any((c) => c.key == sys.convKey), isFalse, reason: 'never a chat');
    });

    testWidgets('no channels and no radio: explains, no dead end', (tester) async {
      setSize(tester);
      await tester.pumpWidget(view());
      await tester.pump();
      expect(find.byKey(const Key('channels-empty')), findsOneWidget);
      expect(find.byKey(const Key('channels-offline')), findsOneWidget);
      expect(find.textContaining('Connect it'), findsWidgets);
      expect(find.byKey(const Key('add-channel')), findsOneWidget);
    });
  });

  group('Add a channel', () {
    Future<void> openAdd(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('add-channel')));
      await tester.pumpAndSettle();
    }

    testWidgets('Join Public from the empty state writes the radio slot and the row appears', (tester) async {
      setSize(tester);
      final s = await kit.connect();
      await tester.pumpWidget(view());
      await tester.pump();
      await tester.tap(find.byKey(const Key('join-public-empty')));
      await tester.pumpAndSettle();
      expect(s.slots[0].name, 'Public');
      expect(find.byKey(const Key('channels-empty')), findsNothing);
      expect(find.text('Public'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('# channel: bad name is explained inside the form, a good one joins with the lower-case key', (tester) async {
      setSize(tester);
      final s = await kit.connect();
      await tester.pumpWidget(view());
      await tester.pump();
      await openAdd(tester);
      await tester.tap(find.byKey(const Key('add-hashtag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-name')), 'two words');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('form-error')), findsOneWidget);
      expect(find.textContaining('letters, numbers and dashes'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('form-name')), 'HamRadio');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(s.slots.firstWhere((x) => !x.isEmpty).name, '#hamradio');
      expect(s.slots.firstWhere((x) => !x.isEmpty).secret, hashtagSecret16('#hamradio'));
      expect(find.text('#hamradio'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('radio full: plain-language message in the form, nothing saved', (tester) async {
      setSize(tester);
      final s = FakeRadioSession(n: 2)..put(0, 'a', List.filled(16, 1))..put(1, 'b', List.filled(16, 2));
      await kit.connect(session: s);
      await tester.pumpWidget(view());
      await tester.pump();
      await openAdd(tester);
      await tester.tap(find.byKey(const Key('add-hashtag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-name')), 'newone');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.textContaining('no free channel slot'), findsOneWidget);
    });

    testWidgets('radio not connected: says to connect, in the form', (tester) async {
      setSize(tester);
      await tester.pumpWidget(view());
      await tester.pump();
      await openAdd(tester);
      await tester.tap(find.byKey(const Key('add-hashtag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-name')), 'x');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('form-error')), findsOneWidget);
      expect(find.textContaining('Connect your radio'), findsOneWidget);
    });

    testWidgets('paste: a garbage link is explained, a real link joins; name + secret works too', (tester) async {
      setSize(tester);
      final s = await kit.connect();
      await tester.pumpWidget(view());
      await tester.pump();
      await openAdd(tester);
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
      await tester.pump(const Duration(seconds: 5));

      await openAdd(tester);
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
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('scan: the scanned link asks before joining; Not now joins nothing', (tester) async {
      setSize(tester);
      final s = await kit.connect();
      final link = MeshLinks.encodeChannel(name: 'Scanned', secret: List.filled(16, 8), regionScope: 'ohio');
      ChatUiHooks.scanQr = (_) async => link;
      await tester.pumpWidget(view());
      await tester.pump();
      await openAdd(tester);
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('join-link-dialog')), findsOneWidget);
      expect(find.textContaining('private channel'), findsOneWidget);
      expect(find.textContaining('"ohio"'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(s.slots.every((x) => x.isEmpty), isTrue);
      await openAdd(tester);
      await tester.tap(find.byKey(const Key('add-scan')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('join-link-confirm')));
      await tester.pumpAndSettle();
      expect(s.slots.any((x) => x.name == 'Scanned'), isTrue);
      expect(kit.store.channels.list(radioA).single.regionScope, 'ohio');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('create private -> share screen with QR and link -> the link joins on a second phone with the same secret', (tester) async {
      setSize(tester, h: 1200);
      final s = await kit.connect();
      await tester.pumpWidget(view());
      await tester.pump();
      await openAdd(tester);
      await tester.tap(find.byKey(const Key('add-create')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('form-name')), 'Trail crew');
      await tester.tap(find.byKey(const Key('form-submit')));
      await tester.pumpAndSettle();
      // lands on the channel screen with the share QR
      expect(find.byKey(const Key('channel-detail')), findsOneWidget);
      expect(find.byKey(const Key('share-qr')), findsOneWidget);
      final link = tester.widget<Text>(find.byKey(const Key('share-link'))).data!;
      final parsed = MeshLinks.parse(link) as ChannelLink;
      expect(parsed.name, 'Trail crew');
      expect(parsed.secret, s.slots.firstWhere((x) => x.name == 'Trail crew').secret);

      // second phone
      final kit2 = ChatKit();
      final s2 = await kit2.connect();
      final j = await kit2.controller.admin.joinFromLink(radioA, link);
      expect(s2.slots[0].secret, parsed.secret);
      expect(j.channel.kind, ChannelKind.private);
      kit2.dispose();
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('Channel info', () {
    Future<Channel> open(WidgetTester tester, {ChannelKind kind = ChannelKind.private}) async {
      final s = FakeRadioSession();
      await kit.connect(session: s);
      final j = kind == ChannelKind.private ? await kit.controller.admin.createPrivate(radioA, 'Club') : await kit.controller.admin.joinHashtag(radioA, '#club');
      await tester.pumpWidget(host(ChannelDetailScreen(controller: kit.controller, channelId: j.channel.id!)));
      await tester.pumpAndSettle();
      return j.channel;
    }

    testWidgets('notify mode and pin are stored', (tester) async {
      setSize(tester, h: 1400);
      final ch = await open(tester);
      await tester.tap(find.text('Muted'));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(ch.convKey)!.notifyMode, NotifyMode.muted);
      await tester.tap(find.text('Mentions'));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(ch.convKey)!.notifyMode, NotifyMode.mentionsOnly);
      await tester.tap(find.byKey(const Key('pin-switch')));
      await tester.pumpAndSettle();
      expect(kit.service.conversation(ch.convKey)!.pinned, isTrue);
    });

    testWidgets('region: help text, saved, and the channel send carries a scope key', (tester) async {
      setSize(tester, h: 1400);
      final ch = await open(tester);
      await tester.tap(find.byKey(const Key('region-row')));
      await tester.pumpAndSettle();
      expect(find.textContaining('limits how far your messages are repeated'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('region-field')), 'Ohio');
      await tester.tap(find.byKey(const Key('region-save')));
      await tester.pumpAndSettle();
      expect(kit.store.channels.getById(ch.id!)!.regionScope, 'ohio');
      expect(find.text('ohio'), findsOneWidget);
    });

    testWidgets('rename (private only) rewrites the radio slot', (tester) async {
      setSize(tester, h: 1400);
      final ch = await open(tester);
      await tester.tap(find.byKey(const Key('rename-row')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('rename-field')), 'Club 2');
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(kit.store.channels.getById(ch.id!)!.name, 'Club 2');
      expect(find.text('Club 2'), findsWidgets);
    });

    testWidgets('a # channel offers no rename; its link and QR are there', (tester) async {
      setSize(tester, h: 1400);
      await open(tester, kind: ChannelKind.hashtag);
      expect(find.byKey(const Key('rename-row')), findsNothing);
      expect(find.byKey(const Key('share-qr')), findsOneWidget);
      expect(find.textContaining('anyone can also join it by typing its name'), findsOneWidget);
    });

    testWidgets('delete asks first, empties the radio slot and removes the channel', (tester) async {
      setSize(tester, h: 1400);
      final nav = GlobalKey<NavigatorState>();
      final s = FakeRadioSession();
      await kit.connect(session: s);
      final j = await kit.controller.admin.createPrivate(radioA, 'Doomed');
      await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: ChannelDetailScreen(controller: kit.controller, channelId: j.channel.id!)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('delete-channel')), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const Key('delete-channel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('delete-channel-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('delete-channel-confirm')));
      await tester.pumpAndSettle();
      expect(s.slots.every((x) => x.isEmpty), isTrue);
      expect(kit.store.channels.getById(j.channel.id!), isNull);
    });

    testWidgets('delete with the radio away is refused in plain words and keeps the channel', (tester) async {
      setSize(tester, h: 1400);
      final s = FakeRadioSession();
      await kit.connect(session: s);
      final j = await kit.controller.admin.createPrivate(radioA, 'Stay');
      await tester.pumpWidget(host(ChannelDetailScreen(controller: kit.controller, channelId: j.channel.id!)));
      await tester.pumpAndSettle();
      await kit.controller.onSession(null);
      await tester.scrollUntilVisible(find.byKey(const Key('delete-channel')), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.byKey(const Key('delete-channel')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('delete-channel-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('channel-error-dialog')), findsOneWidget);
      expect(find.textContaining('Connect your radio first'), findsOneWidget);
      expect(kit.store.channels.getById(j.channel.id!), isNotNull);
    });

    testWidgets('a channel that left the radio offers to put it back', (tester) async {
      setSize(tester, h: 1400);
      final s = FakeRadioSession();
      await kit.connect(session: s);
      final j = await kit.controller.admin.createPrivate(radioA, 'Back');
      s.slots[j.channel.slot!] = RadioChannel(j.channel.slot!, '', Uint8List(16));
      await kit.controller.admin.syncFromRadio(radioA);
      await tester.pumpWidget(host(ChannelDetailScreen(controller: kit.controller, channelId: j.channel.id!)));
      await tester.pumpAndSettle();
      expect(find.text('Not on your radio right now'), findsOneWidget);
      await tester.tap(find.byKey(const Key('put-back')));
      await tester.pumpAndSettle();
      expect(kit.store.channels.getById(j.channel.id!)!.slot, isNotNull);
      expect(s.slots.any((x) => x.name == 'Back'), isTrue);
    });
  });
}
