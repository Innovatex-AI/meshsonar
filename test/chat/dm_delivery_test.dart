// DM delivery state machine (fix round, Nov 8 2026, Andy's field report on 0.29.0+49: messages 511 answered showed
// "Not delivered"). Covers: late acks in every state, retries that change the expected ack, the ack/send race,
// reply-implies-delivered, the link dropping during the ack wait, path-aware waits and the wording.
import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/conversation_row.dart';
import 'package:meshsonar/chat/delivery_state.dart';
import 'package:meshsonar/chat/delivery_text.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/radio_bridge.dart';

import 'support.dart';

/// A sink whose next send can be held open, so an ack can arrive while a try is being handed to the radio.
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

  group('path-aware waits', () {
    test('flood: at least 12 s per try, at least 30 s after the last try, then Not delivered', () async {
      h.bob();
      final m = sendDm('hi');
      await h.service.pump();
      final first = h.store.outbox.get(m.id)!.dueAtMs - h.clock.ms;
      expect(first, greaterThanOrEqualTo(12000));
      await runFor(40000);
      expect(h.sink.directs.length, 3, reason: 'three flood tries within 40 s');
      expect(get(m.id).state, MessageState.sent, reason: 'the last try still has its grace period');
      final grace = h.store.outbox.get(m.id)!.dueAtMs - h.store.outbox.attemptsFor(m.id).last.sentAtMs;
      expect(grace, greaterThanOrEqualTo(30000));
      await runFor(40000);
      expect(get(m.id).state, MessageState.failed);
      expect(get(m.id).failReason, FailReason.noAck);
    });

    test('policy: direct waits are shorter than flood waits, everything is capped', () {
      const p = RetryPolicy(jitterMs: 0);
      final direct = p.ackWaitMs(2000, Random());
      final flood = p.ackWaitMs(2000, Random(), flood: true);
      expect(direct, 6000); // 2000 * 1.5 + 1500 = 4500, floor 6000
      expect(flood, 12000); // 2000 * 2 + 1500 = 5500, floor 12000
      expect(p.ackWaitMs(20000, Random(), flood: true), 41500); // 40000 + 1500
      expect(p.ackWaitMs(20000, Random(), flood: true, lastTry: true), 83000);
      expect(p.ackWaitMs(200000, Random(), flood: true), 120000);
    });
  });

  group('late acks', () {
    test('an ack after Not delivered upgrades to Delivered, with the radio trip time', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(120000);
      expect(get(m.id).state, MessageState.failed);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1001, tripMs: 41234)); // try 2's code
      final a = get(m.id);
      expect(a.state, MessageState.acked);
      expect(a.ackMs, 41234);
      expect(a.expectedAck, 1001, reason: 'records which try got through');
      expect(a.failReason, isNull);
    });

    test('a late ack for round 1 while the manual Retry is still queued confirms it and sends nothing more', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(120000);
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

    test('retry with a changed expected ack: the old code and the new code both confirm', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(120000); // codes 1000, 1001, 1002
      expect(h.service.retryFailed(m.id), isTrue);
      await h.service.pump(); // round 2, try 1: code 1003
      expect(get(m.id).expectedAck, 1003);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1002)); // round 1, try 3
      expect(get(m.id).state, MessageState.acked);
      expect(h.store.outbox.count(), 0);
    });

    test('an ack arriving while the next try is being handed to the radio is not overwritten', () async {
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
      expect(h.store.outbox.attemptsFor(m.id).length, 2, reason: 'the try that went out is still logged');
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1001)); // the second try's ack: harmless
      expect(get(m.id).state, MessageState.acked);
    });
  });

  group('reply implies delivered', () {
    test('a reply while we wait: Probably delivered, no further tries', () async {
      h.bob();
      final m = sendDm('Sounds like our network is working lol');
      await h.service.pump();
      h.clock.advance(5000);
      h.service.handleInbound(fromBob('Yes, yes it is.'));
      expect(get(m.id).state, MessageState.likelyDelivered);
      expect(h.store.outbox.count(), 0);
      await runFor(120000);
      expect(h.sink.directs.length, 1, reason: 'no duplicate for a message they answered');
      final ui = deliveryUi(get(m.id), radioConnected: true, nowMs: h.clock.ms);
      expect(ui.stage, DeliveryStage.likely);
      expect(ui.word, 'Probably delivered (they replied)');
      expect(deliveryLabel(get(m.id)), 'Probably delivered (they replied)');
    });

    test('a reply after Not delivered (no ack) turns it into Probably delivered; Retry all skips it', () async {
      h.bob();
      final m = sendDm('Ok see a bug in messaging');
      await runFor(120000);
      expect(get(m.id).state, MessageState.failed);
      h.service.handleInbound(fromBob('Copy that.'));
      expect(get(m.id).state, MessageState.likelyDelivered);
      expect(get(m.id).failReason, isNull);
      expect(h.store.messages.byState(const [MessageState.failed]), isEmpty, reason: 'the Retry all banner lists failed only');
      expect(h.service.retryFailed(m.id), isFalse);
    });

    test('a real ack still upgrades Probably delivered to Delivered', () async {
      h.bob();
      final m = sendDm('hi');
      await h.service.pump();
      h.service.handleInbound(fromBob('yo'));
      expect(get(m.id).state, MessageState.likelyDelivered);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
      expect(get(m.id).state, MessageState.acked);
    });

    test('never-sent messages and non-ack failures stay as they are', () async {
      h.bob();
      h.sink.connected = false;
      final queued = sendDm('still queued');
      await h.service.pump();
      h.service.handleInbound(fromBob('hello'));
      expect(get(queued.id).state, MessageState.queued, reason: 'never went out: they cannot have it');
      h.sink.connected = true;
      h.service.notifyRadioReady();
      await h.service.pump();
      expect(get(queued.id).state, MessageState.sent);
    });

    test('a message given up because the radio was away (never sent) stays Not delivered after a reply', () async {
      h.bob();
      h.sink.connected = false;
      final m = sendDm('never went out');
      h.clock.advance(7 * 3600 * 1000);
      await h.service.pump();
      expect(get(m.id).failReason, FailReason.notConnected);
      h.service.handleInbound(fromBob('hi?'));
      expect(get(m.id).state, MessageState.failed);
    });

    test('a reply older than our message, or far later, proves nothing', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(120000);
      h.clock.advance(31 * 60 * 1000);
      h.service.handleInbound(fromBob('much later'));
      expect(get(m.id).state, MessageState.failed);
    });

    test('a room post is not a reply from the room', () async {
      h.bob(type: ContactType.room);
      final m = h.service.send(radioId: radioA, convKey: ConvKey.room(bobKey.substring(0, 12)), text: 'post');
      await h.service.pump();
      h.service.handleInbound(
        InboundDirectText(
          radioId: radioA,
          senderPrefix: bobKey.substring(0, 12),
          timestamp: 1760000200,
          text: 'someone else',
          txtType: 2,
          signerPrefix: 'ca01ca01',
        ),
      );
      expect(get(m.id).state, MessageState.sent);
    });

    test('conversation list shows the soft state', () {
      expect(deliveryFor(const LastMessageInfo(direction: Direction.outgoing, state: MessageState.likelyDelivered), isChannel: false), RowDelivery.likely);
    });
  });

  group('radio link drops during the wait', () {
    test('the last try\'s wait ending while disconnected is not Not delivered; one more try after reconnect', () async {
      h.bob();
      final m = sendDm('hi');
      await runFor(40000); // three tries out
      expect(h.sink.directs.length, 3);
      h.sink.connected = false;
      await runFor(120000);
      expect(get(m.id).state, isNot(MessageState.failed), reason: 'the ack may have come while the phone was away');
      h.sink.connected = true;
      h.service.notifyRadioReady();
      await runFor(15000);
      expect(h.sink.directs.length, 4);
      h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1003));
      expect(get(m.id).state, MessageState.acked);
    });

    test('an ack after a reconnect for a try sent before it still matches (state is persisted)', () async {
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
      final ui = deliveryUi(get(m.id), radioConnected: true, nowMs: h.clock.ms, maxAttempts: 3);
      expect(ui.word, 'Waiting for confirmation');
      expect(ui.stage, DeliveryStage.sent);
    });
  });
}
