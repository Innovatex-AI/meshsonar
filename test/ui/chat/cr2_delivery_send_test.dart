// CR2 (chat + radio round): "No repeater heard it" with Resend for a channel message nobody relayed, the clock that wakes a
// quiet conversation when a status changes by time alone, and long-press Send to search for a new route on a direct message.
import 'package:flutter/material.dart' hide Route;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/migrations.dart';
import 'package:meshsonar/chat/delivery_state.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/chat/message_menu.dart';
import 'package:meshsonar/ui/theme.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../chat/support.dart' as svc;
import 'chat_kit.dart';

ChatMessage chan({required MessageState state, int repeats = 0, int localMs = 0}) => ChatMessage(
    id: 'c1',
    radioId: radioA,
    convKind: ConvKind.channel,
    convKey: 'c:1',
    direction: Direction.outgoing,
    tsSender: 1,
    tsLocalMs: localMs,
    text: 'hi',
    state: state,
    repeatsHeard: repeats,
    dedupeKey: 'k');

void main() {
  group('delivery state', () {
    test('a sent channel message nobody relayed: Sent, then after 30 s "No repeater heard it" with Resend', () {
      final m = chan(state: MessageState.sent);
      expect(deliveryUi(m, radioConnected: true, nowMs: 29999).word, 'Sent');
      final late = deliveryUi(m, radioConnected: true, nowMs: 30000);
      expect(late.word, 'No repeater heard it');
      expect(late.canResend, isTrue);
      expect(late.alwaysVisible, isTrue, reason: 'shown on any bubble, not just the last of a run');
      expect(deliveryUi(chan(state: MessageState.heard, repeats: 1), radioConnected: true, nowMs: 99999).canResend, isFalse);
    });

    test('nextDeliveryChangeMs: when a status changes by the clock alone', () {
      expect(nextDeliveryChangeMs(chan(state: MessageState.sent, localMs: 1000)), 31000);
      expect(nextDeliveryChangeMs(chan(state: MessageState.heard, repeats: 2, localMs: 1000)), isNull);
    });
  });

  test('migration v5 adds outbox.force_flood', () {
    final db = sqlite3.openInMemory();
    migrateDatabase(db, chatMigrations);
    expect(db.select('PRAGMA table_info(outbox)').map((r) => r['name']), contains('force_flood'));
    db.close();
  });

  group('service', () {
    test('Resend sends a channel message again; refused once a repeater relayed it', () async {
      final h = svc.Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      final m = h.service.send(radioId: svc.radioA, convKey: ch.convKey, text: 'anyone?');
      await h.service.pump();
      expect(h.sink.channels, hasLength(1));
      expect(h.service.resendChannel(m.id), isTrue);
      expect(h.store.messages.get(m.id)!.state, MessageState.queued);
      await h.service.pump();
      expect(h.sink.channels, hasLength(2));
      final ts = h.store.messages.get(m.id)!.tsSender;
      h.service.handleInbound(InboundRepeatHeard(radioId: svc.radioA, channelSlot: 1, timestamp: ts, text: 'Me: anyone?', pathHashes: 'a1', hops: 1));
      expect(h.service.resendChannel(m.id), isFalse);
    });

    test('Send and search: every try of that one message searches, even with a saved route', () async {
      final h = svc.Harness();
      h.bob(path: true);
      h.service.send(radioId: svc.radioA, convKey: h.bobConv, text: 'normal');
      await h.service.pump();
      h.service.send(radioId: svc.radioA, convKey: h.bobConv, text: 'search', forceFlood: true);
      await h.service.pump();
      expect(h.sink.directs.map((d) => (d.text, d.forceFlood)), [('normal', false), ('search', true)]);
    });
  });

  group('widgets', () {
    late ChatKit kit;
    setUp(() {
      kit = ChatKit();
      MessageMenu.useContextMenu = false;
    });
    tearDown(() => kit.dispose());

    Widget host(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS), home: child);

    testWidgets('a quiet conversation turns Sent into "No repeater heard it" by itself; Resend sends it again', (tester) async {
      setSize(tester);
      final ch = await kit.channel(1, 'Ohio');
      kit.sink.connected = true;
      final m = kit.service.send(radioId: radioA, convKey: ch.convKey, text: 'on my way');
      await kit.service.pump();
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pump();
      expect(find.byKey(Key('resend-${m.id}')), findsNothing);
      // 31 s later, with no event at all: the screen's own wake-up redraws it.
      kit.clockMs += 31000;
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(find.textContaining('No repeater heard it'), findsOneWidget);
      await tester.tap(find.byKey(Key('resend-${m.id}')));
      await kit.service.pump();
      await tester.pump();
      expect(kit.sink.channels, hasLength(2));
    });

    testWidgets('long-press Send on a direct message offers Send or Send and search; a channel has no such choice', (tester) async {
      setSize(tester);
      kit.bob();
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ConvKey.dm(bobKey))));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'where are you');
      await tester.pump();
      await tester.longPress(find.byKey(const Key('composer-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('send-route-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('send-flood')));
      await tester.pumpAndSettle();
      await kit.service.pump();
      expect(kit.sink.directs.single.forceFlood, isTrue);

      final ch = await kit.channel(1, 'Ohio');
      await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
      await tester.pump();
      await tester.enterText(find.byType(EditableText), 'hello');
      await tester.pump();
      await tester.longPress(find.byKey(const Key('composer-send')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('send-route-sheet')), findsNothing);
    });
  });
}
