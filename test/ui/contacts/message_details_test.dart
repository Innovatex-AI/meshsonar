import 'package:flutter/material.dart' hide Route;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/outbox_repository.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/contacts/message_details.dart';

import '../../chat/contact_support.dart';
import '../../chat/support.dart';
import 'contacts_ui_support.dart';

void main() {
  late ContactsRig rig;
  final clip = <String>[];

  void tw(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      rig = ContactsRig();
      clip.clear();
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip.add((call.arguments as Map)['text'] as String);
        return null;
      });
      await body(tester);
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      rig.dispose();
    });
  }

  final conv = ConvKey.dm(keyN(1).substring(0, 12));

  ChatMessage msg(String id,
          {bool out = true, MessageState state = MessageState.acked, ConvKind kind = ConvKind.dm, String? convKey, int? ackMs, int? ack, FailReason? fail, int repeats = 0, double? snr, int? pathLen, Route? route, String text = 'hello there'}) =>
      ChatMessage(
          id: id, radioId: radioA, convKind: kind, convKey: convKey ?? conv, direction: out ? Direction.outgoing : Direction.incoming, senderName: out ? 'Me' : 'Ann KE8ANN',
          tsSender: 1760000000, tsLocalMs: 1760000000000, text: text, state: state, dedupeKey: id, ackMs: ackMs, expectedAck: ack, failReason: fail,
          repeatsHeard: repeats, snr: snr, pathLen: pathLen, route: route);

  Future<void> open(WidgetTester tester, String id, {Brightness b = Brightness.light}) async {
    await tester.pumpWidget(MaterialApp(
      key: UniqueKey(),
      theme: ThemeData(brightness: b, useMaterial3: true),
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(key: const Key('go'), onPressed: () => showMessageDetails(ctx, chat: rig.chat, messageId: id), child: const Text('go')),
        ),
      ),
    ));
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
  }

  tw('incoming DM: who, their clock, hops, signal in words, size', (tester) async {
    setScreen(tester);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('in1', out: false, state: MessageState.received, snr: 7.5, pathLen: 2));
    await open(tester, 'in1');
    expect(find.text('From Ann KE8ANN'), findsOneWidget);
    expect(find.byKey(const Key('details-Came')), findsOneWidget);
    expect(find.text('2 hops through repeaters'), findsOneWidget);
    expect(find.text('7.5 dB, strong'), findsOneWidget);
    expect(find.byKey(const Key('details-Their clock said')), findsOneWidget);
    expect(find.text('11 bytes'), findsOneWidget);
    expect(find.byKey(const Key('details-failure')), findsNothing);
    expect(find.byKey(const Key('details-retry')), findsNothing);
  });

  tw('incoming direct and weak', (tester) async {
    setScreen(tester);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('in2', out: false, state: MessageState.received, snr: -5, pathLen: null));
    await open(tester, 'in2');
    expect(find.text('Direct, no repeater in between'), findsOneWidget);
    expect(find.text('-5.0 dB, weak'), findsOneWidget);
  });

  tw('outgoing acked: status, route, every try, which one was acknowledged', (tester) async {
    setScreen(tester);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('out1', ackMs: 2400, ack: 22, route: Route.direct));
    rig.store.outbox.addAttempt(const DeliveryAttempt(messageId: 'out1', attempt: 1, sentAtMs: 1760000000000, route: Route.flood, expectedAck: 11));
    rig.store.outbox.addAttempt(const DeliveryAttempt(messageId: 'out1', attempt: 2, sentAtMs: 1760000005000, route: Route.direct, expectedAck: 22));
    await open(tester, 'out1');
    expect(find.text('To Node 1'), findsOneWidget);
    expect(find.text('Delivered in 2.4 s'), findsOneWidget);
    expect(find.text('Sent along a saved route'), findsOneWidget);
    expect(find.textContaining('Try 1, flooded'), findsOneWidget);
    expect(find.textContaining('Try 2, direct'), findsOneWidget);
    expect(find.textContaining('acknowledged after 2.4 s'), findsOneWidget);
    expect(find.byKey(const Key('details-try-1')).evaluate().isNotEmpty, isTrue);
    expect(find.textContaining('Try 1, flooded').evaluate().single.widget.toString().contains('acknowledged'), isFalse);
  });

  tw('outgoing failed after three tries: the explanation, Retry restarts it, Copy text', (tester) async {
    setScreen(tester);
    await rig.withContacts(1);
    final m = rig.chat.send(radioId: radioA, convKey: conv, text: 'ping?');
    for (var i = 1; i <= 3; i++) {
      rig.store.outbox.addAttempt(DeliveryAttempt(messageId: m.id, attempt: i, sentAtMs: 1760000000000 + i * 1000, route: Route.flood, expectedAck: i));
    }
    rig.store.messages.update(m.id, state: MessageState.failed, attempt: 3, failReason: FailReason.noAck);
    rig.store.outbox.remove(m.id);
    await open(tester, m.id);
    expect(find.text('Not delivered'), findsOneWidget);
    expect(find.textContaining('No acknowledgement after 3 tries'), findsOneWidget);
    expect(find.textContaining('flooded through the mesh'), findsOneWidget);
    await tester.tap(find.byKey(const Key('details-copy')));
    await tester.pump();
    expect(clip.single, 'ping?');
    await tester.tap(find.byKey(const Key('details-retry')));
    await tester.pumpAndSettle();
    final after = rig.store.messages.get(m.id)!;
    expect(after.state, MessageState.queued);
    expect(after.failReason, isNull);
    expect(find.byKey(const Key('message-details')), findsNothing, reason: 'the sheet closes after Try again');
  });

  tw('failed after a saved route: says the path may have changed', (tester) async {
    setScreen(tester);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('f2', state: MessageState.failed, fail: FailReason.noAck));
    for (var i = 1; i <= 5; i++) {
      rig.store.outbox.addAttempt(DeliveryAttempt(messageId: 'f2', attempt: i, sentAtMs: 1760000000000 + i, route: i < 5 ? Route.direct : Route.flood));
    }
    await open(tester, 'f2');
    expect(find.textContaining('4 along the saved route'), findsOneWidget);
    expect(find.textContaining('repeater path to them may have changed'), findsOneWidget);
  });

  tw('other failure reasons use their own sentence', (tester) async {
    setScreen(tester);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('f3', state: MessageState.failed, fail: FailReason.contactListFull));
    await open(tester, 'f3');
    expect(find.textContaining('contact list is full'), findsOneWidget);
  });

  tw('channel message: repeats heard', (tester) async {
    setScreen(tester);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('c1', kind: ConvKind.channel, convKey: 'c:1', state: MessageState.heard, repeats: 3, route: Route.flood));
    await open(tester, 'c1');
    expect(find.text('Sent by you'), findsOneWidget);
    expect(find.text('Heard by 3 repeaters'), findsOneWidget);
    expect(find.byKey(const Key('details-retry')), findsNothing);
  });

  tw('a message that no longer exists says so', (tester) async {
    setScreen(tester);
    await open(tester, 'nope');
    expect(find.byKey(const Key('details-gone')), findsOneWidget);
  });

  for (final cfg in <String, ({double w, double h, double s, Brightness b})>{
    'phone': (w: 390, h: 844, s: 1.0, b: Brightness.light),
    'ipad dialog': (w: 834, h: 1194, s: 1.0, b: Brightness.light),
    'text 2.5': (w: 390, h: 844, s: 2.5, b: Brightness.light),
    'dark': (w: 390, h: 844, s: 1.0, b: Brightness.dark),
  }.entries) {
    tw('failed DM layout, ${cfg.key}: no overflow, accessible', (tester) async {
      setScreen(tester, w: cfg.value.w, h: cfg.value.h, scale: cfg.value.s);
      await rig.withContacts(1);
      rig.store.messages.insert(msg('lay', state: MessageState.failed, fail: FailReason.noAck, text: 'a long message ' * 8));
      for (var i = 1; i <= 3; i++) {
        rig.store.outbox.addAttempt(DeliveryAttempt(messageId: 'lay', attempt: i, sentAtMs: 1760000000000 + i, route: Route.flood));
      }
      await open(tester, 'lay', b: cfg.value.b);
      expect(tester.takeException(), isNull);
      if (cfg.key.contains('ipad')) expect(find.byType(Dialog), findsOneWidget);
      await expectAccessible(tester);
    });
  }
}
