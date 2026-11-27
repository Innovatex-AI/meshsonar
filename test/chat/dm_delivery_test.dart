// DM delivery state machine. First written for the Nov 8 2026 fix round (Andy's field report on 0.29.0+49: messages that
// were answered showed "Not delivered"); rewritten for build 77 (redesign round 3), where delivery follows the official
// MeshCore flow. Covers: late confirmations in every state, a retry (a new send) with confirmations of the old send, the
// confirmation/send race, the link dropping during the wait, the removal of "Probably delivered", and the wording.
// The tries themselves (4 direct, one reset, 4 flood; try numbers; waits) are in outbox_test.dart and, against the
// scripted lossy radio, in delivery_lossy_test.dart.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/conversation_row.dart';
import 'package:meshsonar/chat/db/outbox_repository.dart';
import 'package:meshsonar/chat/delivery_state.dart';
import 'package:meshsonar/chat/delivery_text.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/core/time_format.dart' as tf;

import 'support.dart';

/// A sink whose next send can be held open, so a confirmation can arrive while a try is being handed to the radio.
class HoldingSink extends FakeSink {
  Completer<void>? hold;
  @override
  Future<SendReceipt> sendDirect({
    required String radioId,
    required String contactPublicKey,
    required String text,
    required int timestamp,
    required int attempt,
    required bool forceFlood,
  }) async {
    final h = hold;
    if (h != null) await h.future;
    return super.sendDirect(radioId: radioId, contactPublicKey: contactPublicKey, text: text, timestamp: timestamp, attempt: attempt, forceFlood: forceFlood);
  }
}

void main() {
  late Harness h;
  setUp(() => h = Harness());

  ChatMessage sendDm(String text) => h.service.send(radioId: radioA, convKey: h.bobConv, text: text);
  ChatMessage get(String id) => h.store.messages.get(id)!;
  InboundDirectText fromBob(String text, {int ts = 1760000100}) =>
      InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: ts, text: text);

  Future<void> runFor(int ms, {int step = 1000}) async {
    for (var t = 0; t < ms; t += step) {
      await h.service.pump();
      h.clock.advance(step);
    }
    await h.service.pump();
  }

  group('waits', () {
    test('each try waits the radio\'s estimate x 1.2, the last one too, then Not delivered', () async {
      h.bob();
      h.sink.estTimeoutMs = 10000; // the radio's own estimate for a slow flood
      final m = sendDm('hi');
      await runFor(11000);
      expect(h.sink.directs.length, 1, reason: 'the wait is 12 s: no second try at 11 s');
      await runFor(2000);
      expect(h.sink.directs.length, 2);
      await runFor(6 * 12000 + 1000);
      expect(h.sink.directs.length, 8);
      expect(get(m.id).state, MessageState.sent, reason: 'the last try has its wait too');
      final wait = h.store.outbox.get(m.id)!.dueAtMs - h.store.outbox.attemptsFor(m.id).last.sentAtMs;
      expect(wait, 12000, reason: 'the same rule for the last try: no extra grace of our own');
      await runFor(13000);
      expect(get(m.id).state, MessageState.failed);
      expect(get(m.id).failReason, FailReason.noAck);
    });
  });

  group('late confirmations', () {
    test('a confirmation after Not delivered upgrades to Delivered, with the radio trip time', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(60000);
      expect(get(m.id).state, MessageState.failed);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1001, tripMs: 41234)); // try 2's code
      final a = get(m.id);
      expect(a.state, MessageState.acked);
      expect(a.ackMs, 41234);
      expect(a.expectedAck, 1001, reason: 'records which try got through');
      expect(a.failReason, isNull);
    });

    test('a late confirmation of the first send while the manual retry is still queued confirms it and sends nothing more', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(60000);
      expect(get(m.id).state, MessageState.failed);
      final sends = h.sink.directs.length;
      h.sink.connected = false; // Retry while the radio is away: it waits in the queue
      expect(h.service.retryFailed(m.id), isTrue);
      await h.service.pump();
      expect(get(m.id).state, MessageState.queued);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
      expect(get(m.id).state, MessageState.acked);
      h.sink.connected = true;
      await runFor(60000);
      expect(h.sink.directs.length, sends, reason: 'no duplicate after the confirmation');
    });

    test('after a retry the codes of the old send and of the new send both confirm', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(60000); // codes 1000..1007
      h.clock.advance(1000);
      expect(h.service.retryFailed(m.id), isTrue);
      await h.service.pump(); // the new send, try 1: code 1008
      expect(h.sink.directs.last.attempt, 0);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1007)); // first send, try 8
      expect(get(m.id).state, MessageState.acked);
      expect(h.store.outbox.count(), 0);
      expect(h.store.outbox.attemptsFor(m.id).where((t) => t.outcome == TryOutcome.confirmed).single.round, 0);
    });

    test('a confirmation arriving while the next try is being handed to the radio is not overwritten', () async {
      final sink = HoldingSink();
      h = Harness.withSink(sink);
      h.bob();
      final m = sendDm('hi');
      await h.service.pump(); // try 1, code 1000
      h.clock.advance(13000);
      sink.hold = Completer<void>();
      final pumping = h.service.pump(); // try 2 is now waiting on the radio
      await Future<void>.delayed(Duration.zero);
      expect(get(m.id).state, MessageState.sending);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
      sink.hold!.complete();
      await pumping;
      expect(get(m.id).state, MessageState.acked, reason: 'was overwritten with sent and left waiting forever');
      expect(h.store.outbox.count(), 0);
      final tries = h.store.outbox.attemptsFor(m.id);
      expect(tries.length, 2, reason: 'the try that went out is still logged');
      expect(tries.map((t) => t.outcome), [TryOutcome.confirmed, TryOutcome.noConfirmation]);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1001)); // the second try's confirmation: harmless
      expect(get(m.id).state, MessageState.acked);
    });

    test('a confirmation that arrives BEFORE the radio answered the send is matched (the code is computed on the phone)', () async {
      final sink = HoldingSink();
      h = Harness.withSink(sink);
      h.bob();
      final m = sendDm('hi');
      sink.hold = Completer<void>();
      final pumping = h.service.pump();
      await Future<void>.delayed(Duration.zero);
      final t = h.store.outbox.attemptsFor(m.id).single;
      expect(t.outcome, TryOutcome.sending);
      expect(t.expectedAck, isNotNull);
      h.service.handleInbound(InboundAck(radioId: radioA, ackCode: t.expectedAck!));
      expect(get(m.id).state, MessageState.acked);
      sink.hold!.complete();
      await pumping;
      expect(get(m.id).state, MessageState.acked);
      expect(h.store.outbox.attemptsFor(m.id).single.outcome, TryOutcome.confirmed);
    });
  });

  group('"Probably delivered (they replied)" is gone (decision D2)', () {
    test('a reply while we wait changes nothing: the message is still tried, and only a confirmation delivers it', () async {
      h.bob();
      final m = sendDm('you there?');
      await h.service.pump();
      h.clock.advance(2000);
      h.service.handleInbound(fromBob('yes'));
      expect(get(m.id).state, MessageState.sent);
      await runFor(6000);
      expect(h.sink.directs.length, 2, reason: 'the next try goes out as planned');
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
      expect(get(m.id).state, MessageState.acked);
    });

    test('a reply after Not delivered leaves it Not delivered', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(60000);
      h.service.handleInbound(fromBob('hello'));
      expect(get(m.id).state, MessageState.failed);
      expect(get(m.id).failReason, FailReason.noAck);
    });

    test('an old row that still says likelyDelivered reads as Not delivered everywhere', () {
      h.bob();
      final m = sendDm('hi');
      h.store.db.raw.execute("UPDATE messages SET state = 'likelyDelivered' WHERE id = ?", [m.id]);
      final ui = deliveryUi(get(m.id), radioConnected: true, nowMs: h.clock.ms);
      expect(ui.word, 'Not delivered');
      expect(ui.stage, DeliveryStage.failed);
      expect(deliveryLabel(get(m.id)), 'Not delivered');
      expect(deliveryFor(const LastMessageInfo(direction: Direction.outgoing, state: MessageState.likelyDelivered), isChannel: false), RowDelivery.failed);
    });
  });

  group('radio link drops during the wait', () {
    test('a wait that ends while disconnected is not counted: no confirmation can arrive while the phone is away', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(36000); // all eight tries are out (4.8 s each); the eighth is still waiting
      expect(h.sink.directs.length, 8);
      h.sink.connected = false;
      await runFor(120000);
      expect(get(m.id).state, MessageState.sent, reason: 'not Not delivered while the phone cannot hear the radio');
      h.sink.connected = true;
      h.service.notifyRadioReady();
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1007));
      expect(get(m.id).state, MessageState.acked);
    });

    test('back on the link with tries left: the next try goes out with the next try number', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(6000); // two tries
      expect(h.sink.directs.length, 2);
      h.sink.connected = false;
      await runFor(60000);
      expect(h.sink.directs.length, 2);
      h.sink.connected = true;
      h.service.notifyRadioReady();
      await runFor(11000);
      expect(h.sink.directs.map((d) => d.attempt).take(3), [0, 1, 2]);
      expect(h.sink.directs.map((d) => d.ts).toSet().length, 1);
      expect(get(m.id).state, isNot(MessageState.failed));
    });

    test('a confirmation after a reconnect for a try sent before it still matches (state is persisted)', () async {
      h.bob();
      final m = sendDm('hi');
      await h.service.pump();
      h.sink.connected = false;
      h.clock.advance(3000);
      h.sink.connected = true;
      h.service.notifyRadioReady();
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
      expect(get(m.id).state, MessageState.acked);
    });
  });

  group('wording', () {
    test('Sending, then Waiting for confirmation, never a bare Sent for a DM', () async {
      h.bob();
      final m = sendDm('hi');
      h.store.messages.update(m.id, state: MessageState.sending, attempt: 1);
      expect(deliveryUi(get(m.id), radioConnected: true, nowMs: h.clock.ms).word, 'Sending');
      h.store.messages.update(m.id, state: MessageState.queued, attempt: 0);
      await h.service.pump();
      final ui = deliveryUi(get(m.id), radioConnected: true, nowMs: h.clock.ms, maxAttempts: 8);
      expect(ui.word, 'Waiting for confirmation');
      expect(ui.stage, DeliveryStage.sent);
      expect(ui.pending, isTrue, reason: 'a message still retrying can be cancelled');
    });

    test('"try n of m" from the second try on, with the real numbers; no "wider search" guess on the last try', () async {
      h.bob(path: true);
      final m = sendDm('hi');
      await runFor(5000);
      var ui = deliveryUi(get(m.id), radioConnected: true, nowMs: h.clock.ms, maxAttempts: h.store.outbox.get(m.id)!.maxAttempts);
      expect(ui.word, 'Waiting for confirmation (try 2 of 8)');
      expect(deliveryLabel(get(m.id), maxAttempts: 8), 'Waiting for confirmation (try 2 of 8)');
      await runFor(30000);
      ui = deliveryUi(get(m.id), radioConnected: true, nowMs: h.clock.ms, maxAttempts: 8);
      expect(ui.word, 'Waiting for confirmation (try 8 of 8)');
      expect(ui.detail, isNot(contains('wider')));
    });

    test('message details: each try with the route the radio reported and its outcome', () async {
      h.bob(path: true);
      final m = sendDm('hi');
      await runFor(60000);
      final tries = h.service.deliveryTries(m.id);
      final lines = [for (var i = 0; i < tries.length; i++) describeAttempt(tries[i], i + 1, get(m.id), last: i == tries.length - 1, formatTime: (_) => 'T').text];
      expect(lines.first, 'Try 1 · direct · T · no confirmation');
      expect(lines[4], 'Try 5 · flood · after reset path · T · no confirmation');
      expect(lines.last, 'Try 8 · flood · T · no confirmation');
      expect(describeFailure(get(m.id), tries),
          startsWith('No confirmation came back after 8 tries: 4 direct along the route your radio had, then 4 by flood to everyone nearby.'));
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1005, tripMs: 2100));
      final after = h.service.deliveryTries(m.id);
      final hit = describeAttempt(after[5], 6, get(m.id), last: false, formatTime: (_) => 'T');
      expect(hit.text, 'Try 6 · flood · T · confirmed after 2.1 s');
      expect(hit.acked, isTrue);
    });

    test('a try whose reply was lost says so and claims no route', () async {
      h.bob();
      h.sink.failNext = const RadioNoAnswer();
      final m = sendDm('hi');
      await h.service.pump();
      final t = h.service.deliveryTries(m.id).single;
      expect(describeTryRoute(t), 'route not reported');
      expect(describeTryOutcome(t, get(m.id), last: true), 'the radio did not answer; it may have gone out');
    });

    test('a try\'s time goes through the one app time formatter: the phone\'s time by default, UTC and labelled when set', () {
      h.bob();
      final m = sendDm('hi');
      const a = DeliveryAttempt(messageId: 'x', attempt: 1, sentAtMs: 1762798445000, route: Route.direct, outcome: TryOutcome.waiting); // 2025-11-10 18:14:05 UTC
      addTearDown(() {
        tf.activeTimeZone = tf.TimeZonePreference.phone;
        tf.use24HourClock = false;
        tf.debugLocalClock = null;
      });
      tf.debugLocalClock = (utc) => (wall: utc.subtract(const Duration(hours: 5)), abbr: 'EST');
      expect(describeAttempt(a, 1, get(m.id), last: true).text, 'Try 1 · direct · 1:14:05 PM · waiting for confirmation');
      tf.use24HourClock = true;
      expect(describeAttempt(a, 1, get(m.id), last: true).text, 'Try 1 · direct · 13:14:05 · waiting for confirmation');
      tf.activeTimeZone = tf.TimeZonePreference.utc;
      expect(describeAttempt(a, 1, get(m.id), last: true).text, 'Try 1 · direct · 18:14:05 UTC · waiting for confirmation');
    });

    test('rows stored before build 77 (no outcome) still read sensibly', () {
      h.bob();
      final m = sendDm('hi');
      h.store.messages.update(m.id, state: MessageState.failed, failReason: FailReason.noAck, attempt: 1);
      const old = DeliveryAttempt(messageId: 'x', attempt: 1, sentAtMs: 0, route: Route.flood, expectedAck: 5);
      expect(describeAttempt(old, 1, get(m.id), last: true, formatTime: (_) => 'T').text, 'Try 1 · flood · T · no confirmation');
    });
  });
}
