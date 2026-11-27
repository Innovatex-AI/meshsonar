// Build 77 (redesign round 5 S1, S3, M1; round 3 rule 10): Settings > Messages > Message delivery (direct tries, flood
// tries, flood fallback, the pointer to the radio's own "Confirm delivery twice"), the chat rows that were More > Chat
// settings, and Storage & diagnostics > Message log (shown in the app's time, copied in UTC with secrets hidden).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/delivery_settings.dart';
import 'package:meshsonar/chat/message_log.dart';
import 'package:meshsonar/chat/quick_replies.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/diagnostics_section.dart';
import 'package:meshsonar/ui/settings/messages_section.dart';
import 'package:meshsonar/ui/settings/settings_kit.dart';

import '../chat/chat_kit.dart';
import '../fakes.dart';

Widget _rows(Widget child, Harness h) => AppScope(
      state: h.state,
      child: host(Scaffold(body: SettingsAnchors(keys: <String, GlobalKey>{}, highlighted: null, child: SingleChildScrollView(child: child)))),
    );

void main() {
  test('deliveryCaption says the plan in words', () {
    expect(deliveryCaption(DeliverySettings.defaults), '4 direct tries, then 4 by flood.');
    expect(deliveryCaption(const DeliverySettings(directTries: 1, floodTries: 2)), '1 direct try, then 2 by flood.');
    expect(deliveryCaption(const DeliverySettings(directTries: 2, floodFallback: false)), '2 direct tries, no flood.');
    expect(deliveryCaption(const DeliverySettings(directTries: 3, floodTries: 0)), '3 direct tries, no flood.');
  });

  group('Message delivery rows', () {
    testWidgets('defaults 4 / 4 / on; a choice is saved in the chat database and read by new messages', (tester) async {
      setSize(tester, h: 1200);
      final kit = ChatKit();
      addTearDown(kit.dispose);
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(_rows(DeliveryRows(controller: kit.controller), h));
      Set<int> picked(String id) => tester.widget<SegmentedButton<int>>(find.byKey(Key('$id-selector'))).selected;
      expect(picked('delivery-direct'), {4});
      expect(picked('delivery-flood'), {4});
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('delivery-fallback'))).value, isTrue);
      expect(find.text('New messages: 4 direct tries, then 4 by flood. Up to 8 tries in all.'), findsOneWidget);
      // The ranges are the official app's: direct 1 to 4, flood 0 to 4.
      for (final n in [1, 2, 3, 4]) {
        expect(find.byKey(Key('delivery-direct-$n')), findsOneWidget);
      }
      expect(find.byKey(const Key('delivery-direct-0')), findsNothing);
      expect(find.byKey(const Key('delivery-flood-0')), findsOneWidget);

      await tester.tap(find.byKey(const Key('delivery-direct-2')));
      await tester.pumpAndSettle();
      expect(kit.controller.deliverySettings.directTries, 2);
      expect(DeliverySettingsStore(kit.store.db).load().directTries, 2, reason: 'kept in the chat database');
      await tester.tap(find.byKey(const Key('delivery-flood-1')));
      await tester.pumpAndSettle();
      expect(kit.controller.deliverySettings, const DeliverySettings(directTries: 2, floodTries: 1));
      expect(find.text('New messages: 2 direct tries, then 1 by flood. Up to 3 tries in all.'), findsOneWidget);

      // Flood fallback off: the flood tries are not used, and the row says why it is greyed.
      await tester.tap(find.byKey(const Key('delivery-fallback')));
      await tester.pumpAndSettle();
      expect(kit.controller.deliverySettings.floodFallback, isFalse);
      expect(kit.controller.deliverySettings.totalTries, 2);
      expect(tester.widget<SegmentedButton<int>>(find.byKey(const Key('delivery-flood-selector'))).onSelectionChanged, isNull);
      expect(find.text('Only used while Flood fallback is on. Turn it on first.'), findsOneWidget);
      expect(find.text('New messages: 2 direct tries, no flood. Up to 2 tries in all.'), findsOneWidget);
    });

    testWidgets('the radio\'s own "Confirm delivery twice" is one line pointing to Set up my radio', (tester) async {
      setSize(tester, h: 1200);
      final kit = ChatKit();
      addTearDown(kit.dispose);
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(_rows(DeliveryRows(controller: kit.controller), h));
      expect(find.descendant(of: find.byKey(const Key('delivery-confirm-twice')), matching: find.textContaining('Set up my radio')), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget, reason: 'only Flood fallback is a switch here; the radio setting is not copied');
    });

    testWidgets('before a radio has connected once: greyed, with the reason', (tester) async {
      setSize(tester, h: 1200);
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(_rows(const DeliveryRows(), h));
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('delivery-fallback'))).onChanged, isNull);
      expect(tester.widget<SegmentedButton<int>>(find.byKey(const Key('delivery-direct-selector'))).onSelectionChanged, isNull);
      expect(find.text(chatNotReadyReason), findsNWidgets(3));
    });
  });

  group('the chat rows (were More > Chat settings)', () {
    testWidgets('quick replies, Return sends and Load photos; no second haptics switch', (tester) async {
      setSize(tester, h: 1200);
      final kit = ChatKit();
      addTearDown(kit.dispose);
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(_rows(MessagesChatRows(controller: kit.controller), h));
      expect(find.byKey(const Key('page-delivery')), findsOneWidget);
      expect(find.text('4 direct tries, then 4 by flood.'), findsOneWidget);
      expect(find.textContaining('${defaultQuickReplies.length} saved'), findsOneWidget);
      expect(find.byKey(const Key('chat-haptics')), findsNothing, reason: 'Haptics lives in Map & display only');
      expect(loadReturnSends(kit.store), isFalse);
      await tester.tap(find.byKey(const Key('chat-return-sends')));
      await tester.pumpAndSettle();
      expect(loadReturnSends(kit.store), isTrue);
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('chat-photos-autoload'))).onChanged, isNull,
          reason: 'no photo controller in this test: greyed with the reason');
      // The order of S1: delivery, Quick replies, Return sends, Load photos.
      final ys = [for (final k in ['page-delivery', 'chat-quick-replies', 'chat-return-sends', 'chat-photos-autoload']) tester.getTopLeft(find.byKey(Key(k))).dy];
      expect(ys, [...ys]..sort());
    });
  });

  group('Message log', () {
    testWidgets('lines in the app\'s time; Copy gives UTC with a header and secrets hidden', (tester) async {
      setSize(tester, h: 1200);
      final kit = ChatKit();
      addTearDown(kit.dispose);
      kit.service.log.addChat('try 1 of 8 direct', messageId: 'abcdef123456');
      kit.service.log.addChat('note token=supersecret123456789');
      final h = Harness();
      await h.state.init();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(AppScope(state: h.state, child: host(MessageLogScreen(controller: kit.controller))));
      expect(find.byKey(const Key('message-log-count')), findsOneWidget);
      final at = MessageLog.lineTime(kit.clockMs);
      expect(find.textContaining('$at  = msg abcdef12 try 1 of 8 direct'), findsOneWidget, reason: 'the app\'s own time on screen');
      await tester.tap(find.byKey(const Key('message-log-copy-button')));
      await tester.pump();
      expect(copied, isNotNull);
      expect(copied, contains('MeshSonar message log'));
      expect(copied, contains('Times in UTC'));
      expect(copied, contains(MessageLog.utcStamp(kit.clockMs)));
      expect(copied, contains('Delivery settings: 4 direct tries, 4 flood tries, flood fallback on'));
      expect(copied, isNot(contains('supersecret123456789')));
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });

    testWidgets('no chat yet, or nothing logged: says so, nothing to copy', (tester) async {
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(AppScope(state: h.state, child: host(const MessageLogScreen())));
      expect(find.byKey(const Key('message-log-empty')), findsOneWidget);
      expect(find.textContaining('Connect your radio once'), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(const Key('message-log-copy'))).onPressed, isNull);
      final kit = ChatKit();
      addTearDown(kit.dispose);
      await tester.pumpWidget(AppScope(state: h.state, child: host(MessageLogScreen(controller: kit.controller))));
      expect(find.textContaining('Nothing logged yet'), findsOneWidget);
    });
  });
}
