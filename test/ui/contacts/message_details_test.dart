import 'dart:async';

import 'package:flutter/material.dart' hide Route;
import 'package:meshsonar/chat/events.dart';
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
    testWidgetsT(name, (tester) async {
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
          {bool out = true, MessageState state = MessageState.acked, ConvKind kind = ConvKind.dm, String? convKey, int? ackMs, int? ack, FailReason? fail, int repeats = 0, double? snr, int? pathLen, Route? route, String text = 'hello there', String? hashes}) =>
      ChatMessage(
          id: id, radioId: radioA, convKind: kind, convKey: convKey ?? conv, direction: out ? Direction.outgoing : Direction.incoming, senderName: out ? 'Me' : 'Ann KE8ANN',
          tsSender: 1760000000, tsLocalMs: 1760000000000, text: text, state: state, dedupeKey: id, ackMs: ackMs, expectedAck: ack, failReason: fail,
          repeatsHeard: repeats, snr: snr, pathLen: pathLen, route: route, pathHashes: hashes);

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
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('in1', out: false, state: MessageState.received, snr: 7.5, pathLen: 2));
    await open(tester, 'in1');
    expect(find.text('From Ann KE8ANN'), findsOneWidget);
    expect(find.text('Via 2 repeaters'), findsOneWidget);
    expect(find.text('Strong · SNR 7.5 dB'), findsOneWidget, reason: 'plain word first (D6); the numbers live here');
    expect(find.byKey(const Key('details-Their clock')), findsOneWidget);
    expect(find.text('11 bytes'), findsOneWidget);
    expect(find.byKey(const Key('details-failure')), findsNothing);
    expect(find.byKey(const Key('details-retry')), findsNothing);
  });

  tw('incoming direct and weak', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('in2', out: false, state: MessageState.received, snr: -5, pathLen: null));
    await open(tester, 'in2');
    expect(find.text('Direct'), findsOneWidget);
    expect(find.text('Fair · SNR -5.0 dB'), findsOneWidget);
  });

  tw('outgoing acked: status, route, every try, which one was acknowledged', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('out1', ackMs: 2400, ack: 22, route: Route.direct));
    rig.store.outbox.addAttempt(const DeliveryAttempt(messageId: 'out1', attempt: 1, sentAtMs: 1760000000000, route: Route.flood, expectedAck: 11));
    rig.store.outbox.addAttempt(const DeliveryAttempt(messageId: 'out1', attempt: 2, sentAtMs: 1760000005000, route: Route.direct, expectedAck: 22));
    await open(tester, 'out1');
    expect(find.text('To Node 1'), findsOneWidget);
    expect(find.textContaining('Delivered'), findsWidgets);
    expect(find.text('2.4 s'), findsOneWidget);
    expect(find.text('Saved route'), findsOneWidget);
    // Each try with the route as the radio reported it and its outcome (build 77).
    expect(find.textContaining('Try 1 · flood'), findsOneWidget);
    expect(find.textContaining('Try 2 · direct'), findsOneWidget);
    expect(find.textContaining('confirmed after 2.4 s'), findsOneWidget);
    expect(find.textContaining('Try 1 · flood').evaluate().single.widget.toString().contains('confirmed'), isFalse);
    expect(find.textContaining('no confirmation'), findsOneWidget, reason: 'the first try got no confirmation');
    expect(find.textContaining('searched'), findsNothing, reason: 'build 76 wording');
  });

  tw('outgoing failed after three tries: the explanation, Retry restarts it, Copy text', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    final m = rig.chat.send(radioId: radioA, convKey: conv, text: 'ping?');
    for (var i = 1; i <= 3; i++) {
      rig.store.outbox.addAttempt(DeliveryAttempt(messageId: m.id, attempt: i, sentAtMs: 1760000000000 + i * 1000, route: Route.flood, expectedAck: i));
    }
    rig.store.messages.update(m.id, state: MessageState.failed, attempt: 3, failReason: FailReason.noAck);
    rig.store.outbox.remove(m.id);
    await open(tester, m.id);
    expect(find.text('Not delivered'), findsWidgets);
    expect(find.textContaining('No confirmation came back after 3 tries'), findsOneWidget);
    expect(find.textContaining('all to everyone nearby'), findsOneWidget);
    expect(find.textContaining('may not have you as a contact'), findsOneWidget);
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

  tw('failed after the direct tries and the flood fallback: says how they went, never guesses a route change', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('f2', state: MessageState.failed, fail: FailReason.noAck));
    for (var i = 1; i <= 5; i++) {
      rig.store.outbox.addAttempt(DeliveryAttempt(messageId: 'f2', attempt: i, sentAtMs: 1760000000000 + i, route: i < 5 ? Route.direct : Route.flood));
    }
    await open(tester, 'f2');
    expect(find.textContaining('4 along the route your radio had, then 1 to everyone nearby'), findsOneWidget);
    expect(find.textContaining('may have changed'), findsNothing, reason: 'build 76 guessed this');
  });

  tw('a message still being tried: TRIES n of m from the engine, Cancel stops it', (tester) async {
    setScreen(tester, h: 2400);
    rig.sink.hasRoute = true;
    await rig.withContacts(1);
    final m = rig.chat.send(radioId: radioA, convKey: conv, text: 'on my way');
    await rig.chat.pump();
    final p = rig.chat.deliveryProgress(m.id);
    expect(p.active, isTrue);
    await open(tester, m.id);
    expect(find.text('TRIES (1 of ${p.tryCount})'), findsOneWidget);
    expect(find.textContaining('Try 1 · direct'), findsOneWidget);
    expect(find.textContaining('waiting for confirmation'), findsOneWidget);
    await tester.tap(find.byKey(const Key('details-cancel')));
    await tester.pumpAndSettle();
    expect(rig.store.messages.get(m.id)!.state, MessageState.failed);
    expect(rig.store.messages.get(m.id)!.failReason, FailReason.cancelled);
  });

  tw('a failed message: Message log lists what the phone and radio said, and Export shares it as a file', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    final m = rig.chat.send(radioId: radioA, convKey: conv, text: 'secret words');
    await rig.chat.pump();
    rig.chat.cancel(m.id);
    final shared = <(String, String)>[];
    final was = shareMessageLog;
    shareMessageLog = (name, text) async => shared.add((name, text));
    addTearDown(() => shareMessageLog = was);
    await open(tester, m.id);
    await tester.ensureVisible(find.byKey(const Key('details-log')));
    await tester.tap(find.byKey(const Key('details-log')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-log-screen')), findsOneWidget);
    expect(find.byKey(const Key('message-log-line-0')), findsOneWidget);
    await tester.tap(find.byKey(const Key('message-log-export')));
    await tester.pumpAndSettle();
    expect(shared.single.$1, MessageLogScreen.fileNameFor(m.id));
    expect(shared.single.$2, isNotEmpty);
    expect(shared.single.$2.contains('secret words'), isFalse, reason: 'the log never holds message text');
  });

  tw('a hop two known repeaters share: "Work out the likely route" (round 2 N-U3)', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    for (final (k, n) in [('a1${'ee' * 31}', 'Ridge'), ('a1${'ff' * 31}', 'Hill')]) {
      rig.store.contacts.upsert(Contact(radioId: radioA, publicKey: k, type: ContactType.repeater, name: n, onRadio: true));
    }
    rig.store.messages.insert(msg('in3', out: false, state: MessageState.received, snr: 3, pathLen: 1, hashes: 'a1'));
    await open(tester, 'in3');
    expect(find.textContaining('2 possible'), findsWidgets);
    expect(find.byKey(const Key('details-likely-route')), findsOneWidget);
    await tester.tap(find.byKey(const Key('details-likely-route')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Open the Network tab, then Tools'), findsOneWidget, reason: 'no app shell in this test: it says where to find it');
  });

  tw('other failure reasons use their own sentence', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('f3', state: MessageState.failed, fail: FailReason.contactListFull));
    await open(tester, 'f3');
    expect(find.textContaining('contact list is full'), findsOneWidget);
  });

  tw('channel message: repeats heard', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('c1', kind: ConvKind.channel, convKey: 'c:1', state: MessageState.heard, repeats: 3, route: Route.flood));
    await open(tester, 'c1');
    expect(find.text('Sent by you'), findsOneWidget);
    expect(find.text('3 repeaters'), findsOneWidget);
    expect(find.byKey(const Key('details-retry')), findsNothing);
  });

  tw('closing the sheet cancels its event subscription (fix 7.2)', (tester) async {
    setScreen(tester, h: 2400);
    await rig.withContacts(1);
    rig.store.messages.insert(msg('leak', out: false, state: MessageState.received));
    var listeners = 0;
    late StreamController<ChatEvent> ctl;
    ctl = StreamController<ChatEvent>.broadcast(onListen: () => listeners++, onCancel: () => listeners--);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MessageDetails(chat: rig.chat, messageId: 'leak', events: ctl.stream))));
    expect(listeners, 1);
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(listeners, 0, reason: 'dispose cancels the subscription');
    await ctl.close();
  });

  tw('a message that no longer exists says so', (tester) async {
    setScreen(tester, h: 2400);
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
      final handle = tester.ensureSemantics();
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  }
}
