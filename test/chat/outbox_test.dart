import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'support.dart';

void main() {
  late Harness h;
  setUp(() => h = Harness());

  ChatMessage sendDm(String text) => h.service.send(radioId: radioA, convKey: h.bobConv, text: text);
  ChatMessage get(String id) => h.store.messages.get(id)!;

  test('flood DM: sent, then acked; ack time measured', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent);
    expect(get(m.id).route, Route.flood);
    expect(h.sink.directs.single.forceFlood, isTrue);
    h.clock.advance(2500);
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
    final a = get(m.id);
    expect(a.state, MessageState.acked);
    expect(a.ackMs, 2500);
    expect(h.store.outbox.count(), 0);
  });

  test('flood DM without ack: 3 attempts, same timestamp, then gives up with noAck', () async {
    h.bob();
    final m = sendDm('hi');
    for (var i = 0; i < 6; i++) {
      await h.service.pump();
      h.clock.advance(20000);
    }
    expect(h.sink.directs.length, 3);
    expect(h.sink.directs.map((d) => d.ts).toSet().length, 1, reason: 'retries keep the sender timestamp so receivers dedupe');
    expect(h.sink.directs.map((d) => d.attempt), [0, 1, 2]);
    final f = get(m.id);
    expect(f.state, MessageState.failed);
    expect(f.failReason, FailReason.noAck);
    expect(f.failReason!.describe(), isNotEmpty);
    expect(h.store.outbox.count(), 0);
  });

  test('direct path: 5 attempts, direct first, last one floods', () async {
    h.bob(path: true);
    final m = sendDm('hi');
    for (var i = 0; i < 12; i++) {
      await h.service.pump();
      h.clock.advance(20000);
    }
    expect(h.sink.directs.length, 5);
    expect(h.sink.directs.map((d) => d.forceFlood), [false, false, false, false, true]);
    expect(get(m.id).state, MessageState.failed);
  });

  test('a late ack for an earlier attempt still confirms (also after give-up)', () async {
    h.bob();
    final m = sendDm('hi');
    for (var i = 0; i < 6; i++) {
      await h.service.pump();
      h.clock.advance(20000);
    }
    expect(get(m.id).state, MessageState.failed);
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000)); // attempt 1's code
    expect(get(m.id).state, MessageState.acked);
    expect(get(m.id).failReason, isNull);
  });

  test('ack for an unknown code is ignored', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 77));
    expect(get(m.id).state, MessageState.sent);
  });

  test('radio not connected: stays queued, consumes no attempts, sends after reconnect', () async {
    h.bob();
    h.sink.connected = false;
    final m = sendDm('hi');
    for (var i = 0; i < 5; i++) {
      await h.service.pump();
      h.clock.advance(11000);
    }
    expect(get(m.id).state, MessageState.queued);
    expect(get(m.id).attempt, 0);
    h.sink.connected = true;
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent);
    expect(get(m.id).attempt, 1);
  });

  test('queued too long while disconnected: gives up with notConnected', () async {
    h.bob();
    h.sink.connected = false;
    final m = sendDm('hi');
    h.clock.advance(7 * 3600 * 1000);
    await h.service.pump();
    expect(get(m.id).state, MessageState.failed);
    expect(get(m.id).failReason, FailReason.notConnected);
  });

  test('radio busy backs off then succeeds; permanently busy gives up', () async {
    h.bob();
    h.sink.failNext = const RadioBusy();
    final m = sendDm('hi');
    await h.service.pump();
    expect(get(m.id).state, MessageState.queued);
    expect(h.store.outbox.get(m.id)!.dueAtMs, greaterThan(h.clock.ms));
    h.clock.advance(5000);
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent);

    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
    final m2 = sendDm('again');
    for (var i = 0; i < 40; i++) {
      h.sink.failNext = const RadioBusy();
      await h.service.pump();
      h.clock.advance(31000);
    }
    expect(get(m2.id).state, MessageState.failed);
    expect(get(m2.id).failReason, FailReason.radioBusy);
  });

  test('radio rejects: fails at once with radioRejected', () async {
    h.bob();
    h.sink.failNext = const RadioRejected();
    final m = sendDm('hi');
    await h.service.pump();
    expect(get(m.id).failReason, FailReason.radioRejected);
  });

  test('channel message: one attempt, no retries, no ack expected', () async {
    final ch = await h.channel(1, 'Ohio', ChannelKind.private);
    final m = h.service.send(radioId: radioA, convKey: ch.convKey, text: 'hello');
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent);
    expect(h.sink.channels.single.slot, 1);
    expect(h.store.outbox.count(), 0);
    h.clock.advance(600000);
    await h.service.pump();
    expect(h.sink.channels.length, 1);
  });

  test('channel no longer on the radio: failed with unknownChannel', () async {
    final ch = await h.channel(1, 'Ohio', ChannelKind.private);
    final m = h.service.send(radioId: radioA, convKey: ch.convKey, text: 'hello');
    h.store.db.raw.execute('UPDATE channels SET slot = NULL WHERE id = ?', [ch.id]);
    await h.service.pump();
    expect(get(m.id).failReason, FailReason.unknownChannel);
  });

  test('manual retry and cancel', () async {
    h.bob();
    h.sink.failNext = const RadioRejected();
    final m = sendDm('hi');
    await h.service.pump();
    expect(h.service.retryFailed(m.id), isTrue);
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent);
    expect(h.service.cancel(m.id), isTrue);
    expect(get(m.id).failReason, FailReason.cancelled);
    expect(h.service.retryFailed('nope'), isFalse);
  });

  test('messages are sent in order, one gap apart', () async {
    final hh = Harness(policy: const RetryPolicy(jitterMs: 0, minGapMs: 1000));
    hh.bob();
    hh.service.send(radioId: radioA, convKey: hh.bobConv, text: 'one');
    hh.service.send(radioId: radioA, convKey: hh.bobConv, text: 'two');
    await hh.service.pump();
    expect(hh.sink.directs.map((d) => d.text), ['one']);
    hh.clock.advance(1100);
    await hh.service.pump();
    expect(hh.sink.directs.map((d) => d.text), ['one', 'two']);
  });

  group('survives restart', () {
    test('in-flight and queued messages are recovered from disk', () async {
      final dir = Directory.systemTemp.createTempSync('chat_restart');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/chat.db';
      final secrets = InMemorySecretStore();
      final clock = FakeClock();

      var store = ChatStore.open(sqlite3.open(path), secrets, wal: true);
      final sink1 = FakeSink();
      var svc = ChatService(store: store, sink: sink1, nowMs: clock.call, newId: () => 'id${clock.ms}', policy: const RetryPolicy(jitterMs: 0, minGapMs: 0), autoTimer: false);
      store.contacts.upsert(Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'Bob'));
      final conv = ConvKey.dm(bobKey.substring(0, 12));
      final first = svc.send(radioId: radioA, convKey: conv, text: 'one');
      await svc.pump(); // sent, waiting for ack
      clock.advance(5);
      final second = svc.send(radioId: radioA, convKey: conv, text: 'two'); // queued, never pumped
      // simulate a crash mid-send: message 'two' stuck in `sending`
      store.messages.update(second.id, state: MessageState.sending, attempt: 1);
      store.close();

      // "restart"
      store = ChatStore.open(sqlite3.open(path), secrets, wal: true);
      final sink2 = FakeSink()..nextAck = 5000;
      svc = ChatService(store: store, sink: sink2, nowMs: clock.call, policy: const RetryPolicy(jitterMs: 0, minGapMs: 0), autoTimer: false);
      svc.start();
      clock.advance(1);
      await svc.pump();
      expect(sink2.directs.map((d) => d.text), ['two'], reason: 'the unsent one goes out, with its original timestamp');
      expect(sink2.directs.single.ts, second.tsSender);
      expect(store.messages.get(second.id)!.state, MessageState.sent);
      // the first was waiting for an ack: its retry timer survived too
      clock.advance(30000);
      await svc.pump();
      expect(sink2.directs.where((d) => d.text == 'one'), isNotEmpty);
      // and an ack for attempt 1 of the first message (sent before the restart) is still matched
      svc.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
      expect(store.messages.get(first.id)!.state, MessageState.acked);
      store.close();
    });
  });
}
