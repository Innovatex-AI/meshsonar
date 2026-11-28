import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/db/outbox_repository.dart';
import 'package:meshsonar/chat/delivery_settings.dart';
import 'package:meshsonar/chat/message_log.dart';
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

  test('undo of deleting a queued message brings it back as failed (cancelled), never as a queued message nothing will send', () async {
    h.bob();
    final m = sendDm('hi');
    expect(get(m.id).state, MessageState.queued);
    expect(h.service.deleteMessage(m.id), isTrue);
    expect(h.store.outbox.count(), 0);
    h.service.restoreMessage(m);
    final back = get(m.id);
    expect(back.state, MessageState.failed);
    expect(back.failReason, FailReason.cancelled);
    await h.service.pump();
    expect(h.sink.directs, isEmpty, reason: 'nothing is sent from a restored message');
  });

  test('undo of deleting a delivered message restores it as it was', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
    final acked = get(m.id);
    h.service.deleteMessage(m.id);
    h.service.restoreMessage(acked);
    expect(get(m.id).state, MessageState.acked);
  });

  /// Pumps until nothing more happens by itself: each pass advances the clock past the wait of the try in flight.
  Future<void> runOut(Harness hh, {int passes = 24, int stepMs = 6000}) async {
    for (var i = 0; i < passes; i++) {
      await hh.service.pump();
      hh.clock.advance(stepMs);
    }
    await hh.service.pump();
  }

  test('no route on the radio: the radio floods; sent, then confirmed; trip time measured', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent);
    expect(get(m.id).route, Route.flood, reason: 'flood is what the radio reported, not a decision of the app');
    expect(h.sink.directs.single.flood, isTrue);
    expect(h.sink.resets, isEmpty, reason: 'no reset path before a send (build 76 sent one before every flood)');
    h.clock.advance(2500);
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
    final a = get(m.id);
    expect(a.state, MessageState.acked);
    expect(a.ackMs, 2500);
    expect(h.store.outbox.count(), 0);
  });

  test('the wait for a confirmation is the radio\'s estimate x 1.2: no minimum, no padding', () async {
    h.bob();
    h.sink.estTimeoutMs = 1000;
    final m = sendDm('hi');
    await h.service.pump();
    expect(h.store.outbox.get(m.id)!.dueAtMs - h.clock.ms, 1200);
    const p = RetryPolicy();
    expect(p.ackWaitMs(4000, Random(1)), 4800);
    expect(p.ackWaitMs(250, Random(1)), 300, reason: 'a short estimate gives a short wait (build 76 had floors of 6, 12 and 30 s)');
    expect(p.ackWaitMs(100000, Random(1)), 120000, reason: 'and a long one is not capped');
    expect(p.ackWaitMs(null, Random(1)), 5000, reason: 'only when the radio gave no estimate at all');
  });

  test('no route, never confirmed: 8 tries, try numbers 0..7, one timestamp, all floods, NO reset path, then Not delivered', () async {
    h.bob();
    final m = sendDm('hi');
    await runOut(h);
    expect(h.sink.directs.length, 8);
    expect(h.sink.directs.map((d) => d.attempt), [0, 1, 2, 3, 4, 5, 6, 7], reason: 'the try number reaches the radio untouched');
    expect(h.sink.directs.map((d) => d.ts).toSet().length, 1, reason: 'every try carries the same sender timestamp');
    expect(h.sink.directs.every((d) => d.flood), isTrue);
    expect(h.sink.resets, isEmpty, reason: 'the radio has no route and floods already: nothing to reset');
    final f = get(m.id);
    expect(f.state, MessageState.failed);
    expect(f.failReason, FailReason.noAck);
    expect(f.failReason!.describe(), isNotEmpty);
    expect(h.store.outbox.count(), 0);
  });

  test('route on the radio, never confirmed: 4 direct, ONE reset path, 4 flood', () async {
    h.bob(path: true);
    final m = sendDm('hi');
    await runOut(h);
    expect(h.sink.log, ['send', 'send', 'send', 'send', 'reset', 'send', 'send', 'send', 'send']);
    expect(h.sink.directs.map((d) => d.flood), [false, false, false, false, true, true, true, true]);
    expect(h.sink.directs.map((d) => d.attempt), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(h.sink.resets, [bobKey], reason: 'reset once per message, only after the direct tries are used up');
    expect(get(m.id).state, MessageState.failed);
    // Per-try state for the message details.
    final tries = h.store.outbox.attemptsFor(m.id);
    expect(tries.map((t) => t.attempt), [1, 2, 3, 4, 5, 6, 7, 8]);
    expect(tries.map((t) => t.wireAttempt), [0, 1, 2, 3, 4, 5, 6, 7]);
    expect(tries.map((t) => t.route), [Route.direct, Route.direct, Route.direct, Route.direct, Route.flood, Route.flood, Route.flood, Route.flood]);
    expect(tries.every((t) => t.routeKnown && t.outcome == TryOutcome.noConfirmation), isTrue);
    expect(tries.map((t) => t.resetBefore), [false, false, false, false, true, false, false, false]);
  });

  test('delivery settings: direct 2, flood 1 gives 2 direct, a reset, 1 flood; "try n of m" follows', () async {
    h.service.deliverySettings = const DeliverySettings(directTries: 2, floodTries: 1);
    h.bob(path: true);
    final m = sendDm('hi');
    await h.service.pump();
    expect(h.service.deliveryProgress(m.id).tryNumber, 1);
    expect(h.service.deliveryProgress(m.id).tryCount, 3);
    expect(h.store.outbox.get(m.id)!.maxAttempts, 3);
    await runOut(h);
    expect(h.sink.log, ['send', 'send', 'reset', 'send']);
    expect(get(m.id).state, MessageState.failed);
  });

  test('flood fallback off: only the direct tries, no reset path', () async {
    h.service.deliverySettings = const DeliverySettings(directTries: 3, floodTries: 4, floodFallback: false);
    h.bob(path: true);
    final m = sendDm('hi');
    await runOut(h);
    expect(h.sink.log, ['send', 'send', 'send']);
    expect(h.sink.directs.every((d) => !d.flood), isTrue);
    expect(get(m.id).failReason, FailReason.noAck);
  });

  test('delivery settings are clamped, stored in the chat database and survive a new service', () {
    h.service.deliverySettings = const DeliverySettings(directTries: 9, floodTries: -3, floodFallback: false);
    expect(h.service.deliverySettings, const DeliverySettings(directTries: 4, floodTries: 0, floodFallback: false));
    final again = ChatService(store: h.store, sink: h.sink, nowMs: h.clock.call, autoTimer: false);
    expect(again.deliverySettings, const DeliverySettings(directTries: 4, floodTries: 0, floodFallback: false));
    expect(DeliverySettings.defaults.totalTries, 8);
    expect(const DeliverySettings(floodFallback: false).totalTries, 4);
  });

  test('a message on its way keeps the plan it started with when the settings change', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    h.service.deliverySettings = const DeliverySettings(directTries: 1, floodTries: 0);
    expect(h.store.outbox.get(m.id)!.maxAttempts, 8);
  });

  test('long-press Send, flood chosen: ONE reset path before the first try, then the normal send; no second reset', () async {
    h.bob(path: true);
    final m = h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hi', forceFlood: true);
    await runOut(h);
    expect(h.sink.log.first, 'reset');
    expect(h.sink.log.where((x) => x == 'reset').length, 1);
    expect(h.sink.directs.length, 8);
    expect(h.sink.directs.every((d) => d.flood), isTrue, reason: 'the radio floods because it holds no route after the reset');
    expect(h.store.outbox.attemptsFor(m.id).first.resetBefore, isTrue);
  });

  test('a confirmation for an earlier try still confirms, also after Not delivered', () async {
    h.bob();
    final m = sendDm('hi');
    await runOut(h);
    expect(get(m.id).state, MessageState.failed);
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000, tripMs: 900)); // try 1's code
    expect(get(m.id).state, MessageState.acked);
    expect(get(m.id).failReason, isNull);
    final tries = h.store.outbox.attemptsFor(m.id);
    expect(tries.first.outcome, TryOutcome.confirmed);
    expect(tries.first.tripMs, 900);
    expect(tries.skip(1).every((t) => t.outcome == TryOutcome.noConfirmation), isTrue);
  });

  test('a confirmation with an unknown code changes nothing and is logged as not matched', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 77));
    expect(get(m.id).state, MessageState.sent);
    expect(h.service.log.recent().map((l) => l.text).join('\n'), contains('ack=0000004d NOT matched'));
  });

  test('the radio does not answer the send (reply lost): the try counts, the next try has the next number, and the confirmation of the lost try still matches', () async {
    h.bob();
    h.sink.failNext = const RadioNoAnswer();
    final m = sendDm('hi');
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent, reason: 'it may have gone out: we wait for its confirmation');
    expect(get(m.id).attempt, 1);
    final t1 = h.store.outbox.attemptsFor(m.id).single;
    expect(t1.outcome, TryOutcome.radioNoAnswer);
    expect(t1.routeKnown, isFalse, reason: 'the radio never said direct or flood, so the app does not claim either');
    expect(t1.expectedAck, isNotNull, reason: 'the code is computed on the phone before the send');
    h.clock.advance(6000);
    await h.service.pump();
    expect(h.sink.directs.single.attempt, 1, reason: 'try number 1 follows the unanswered try number 0 (build 76 resent 0)');
    // The confirmation for the try whose reply was lost arrives now: delivered.
    h.service.handleInbound(InboundAck(radioId: radioA, ackCode: t1.expectedAck!));
    expect(get(m.id).state, MessageState.acked);
  });

  test('"not a contact": the contact is put on the radio once and the same try is made again', () async {
    h.bob();
    h.sink.failNext = const RadioTargetMissing();
    final m = sendDm('hi');
    await h.service.pump();
    expect(h.sink.log, ['add', 'send']);
    expect(h.sink.added, [bobKey]);
    expect(h.sink.directs.single.attempt, 0);
    expect(get(m.id).state, MessageState.sent);
  });

  test('"not a contact" and the radio\'s list is full: Not delivered with that reason; nothing is removed to make room', () async {
    h.bob();
    h.sink
      ..failNext = const RadioTargetMissing()
      ..failAdd = const RadioContactsFull();
    final m = sendDm('hi');
    await h.service.pump();
    expect(get(m.id).state, MessageState.failed);
    expect(get(m.id).failReason, FailReason.contactListFull);
    expect(FailReason.contactListFull.describe(), startsWith('Your radio\'s contact list is full'));
    expect(h.sink.directs, isEmpty);
  });

  test('"not a contact" twice: Not delivered, said as it is', () async {
    h.bob();
    h.sink.failNext = const RadioTargetMissing();
    final m = sendDm('hi');
    await h.service.pump();
    h.clock.advance(6000);
    h.sink.failNext = const RadioTargetMissing();
    await h.service.pump();
    expect(get(m.id).failReason, FailReason.unknownContact);
    expect(h.sink.added.length, 1, reason: 'the contact is added once per message, not in a loop');
  });

  test('text limit: 160 bytes get the four tries that can carry them; 158 bytes get all eight; 161 are refused', () async {
    h.bob();
    final m160 = sendDm('a' * 160);
    expect(h.store.outbox.get(m160.id)!.maxAttempts, 4, reason: 'tries 5 and up carry 158 bytes at most');
    await runOut(h);
    expect(h.sink.directs.length, 4);
    expect(h.sink.directs.map((d) => d.attempt), [0, 1, 2, 3]);
    final m158 = sendDm('b' * 158);
    expect(h.store.outbox.get(m158.id)!.maxAttempts, 8);
    expect(() => sendDm('c' * 161), throwsA(isA<MessageTooLong>()));
    expect(ChatService.dmTextBytesForAllTries, 158);
  });

  test('rule 16: a contact who has never confirmed needs to add you; one confirmation ends that for good', () async {
    h.bob();
    expect(h.service.needsToAddYou(radioA, h.bobConv), isTrue);
    expect(needsToAddYouText, 'They need to add you as a contact before they can receive this');
    final m = sendDm('hi');
    await h.service.pump();
    h.clock.advance(1200);
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
    expect(get(m.id).state, MessageState.acked);
    expect(h.service.needsToAddYou(radioA, h.bobConv), isFalse);
    final bob = h.store.contacts.get(radioA, bobKey)!;
    expect(bob.everConfirmed, isTrue);
    // A fresh copy from the radio (a contact sync) must not wipe it.
    h.store.contacts.upsert(Contact(radioId: radioA, publicKey: bobKey, type: ContactType.companion, name: 'Bob again'));
    expect(h.store.contacts.get(radioA, bobKey)!.everConfirmed, isTrue);
    // A repeater or a room is not a person who has to add you.
    h.bob(type: ContactType.room);
    expect(h.service.needsToAddYou(radioA, h.bobConv), isFalse);
  });

  test('a reply from them proves nothing: no "Probably delivered" (decision D2)', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    h.clock.advance(1000);
    h.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: 99, text: 'hello back'));
    expect(get(m.id).state, MessageState.sent, reason: 'still waiting for its confirmation; it will be tried again');
    await runOut(h);
    expect(get(m.id).state, MessageState.failed);
    expect(h.sink.directs.length, 8);
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

  test('radio busy (no free packet): the same try is asked again after 0.5, 1 and 2 s; still busy after that gives up', () async {
    h.bob();
    h.sink.failNext = const RadioBusy();
    final m = sendDm('hi');
    await h.service.pump();
    expect(get(m.id).state, MessageState.queued);
    expect(get(m.id).attempt, 0, reason: 'a busy radio did not send: the try is not used up');
    expect(h.store.outbox.get(m.id)!.dueAtMs - h.clock.ms, 500);
    expect(h.store.outbox.attemptsFor(m.id), isEmpty);
    h.clock.advance(5000);
    await h.service.pump();
    expect(get(m.id).state, MessageState.sent);
    expect(h.sink.directs.single.attempt, 0);

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
    expect(h.sink.channelPriorities.single, CommandPriority.user, reason: 'chat stays at user priority');
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

  test('manual retry is a NEW send: new timestamp, try numbers from 0 again; a late confirmation of the first send still counts', () async {
    h.bob();
    final m = sendDm('hi');
    await runOut(h);
    expect(get(m.id).state, MessageState.failed);
    final firstTs = h.sink.directs.first.ts;
    h.clock.advance(60000);
    expect(h.service.retryFailed(m.id), isTrue);
    await h.service.pump();
    final again = h.sink.directs.last;
    expect(again.attempt, 0);
    expect(again.ts, greaterThan(firstTs), reason: 'build 76 reused the old timestamp: a packet the mesh had already seen');
    expect(get(m.id).tsSender, again.ts);
    expect(get(m.id).state, MessageState.sent);
    final p = h.service.deliveryProgress(m.id);
    expect(p.tries.length, 1, reason: 'the tries of this send');
    expect(p.earlierTries.length, 8, reason: 'the tries of the first send stay in the log');
    expect(p.tryNumber, 1);
    expect(p.tryCount, 8);
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1003)); // try 4 of the FIRST send
    expect(get(m.id).state, MessageState.acked);
    expect(h.service.retryFailed('nope'), isFalse);
  });

  test('Cancel on a message that is still retrying: no more tries; a confirmation that still arrives marks it delivered', () async {
    h.bob();
    final m = sendDm('hi');
    await h.service.pump();
    h.clock.advance(6000);
    await h.service.pump();
    expect(h.sink.directs.length, 2);
    expect(h.service.deliveryProgress(m.id).active, isTrue);
    expect(h.service.cancel(m.id), isTrue);
    expect(get(m.id).state, MessageState.failed);
    expect(get(m.id).failReason, FailReason.cancelled);
    expect(h.service.deliveryProgress(m.id).active, isFalse);
    expect(h.store.outbox.attemptsFor(m.id).last.outcome, TryOutcome.cancelled);
    await runOut(h, passes: 4);
    expect(h.sink.directs.length, 2, reason: 'nothing more is sent after Cancel');
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1001));
    expect(get(m.id).state, MessageState.acked);
    expect(h.service.cancel(m.id), isFalse);
  });

  test('the message log has a line per try and per confirmation, and never the message text', () async {
    h.bob(path: true);
    final m = sendDm('SECRET-WORDS-123');
    await runOut(h);
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1006, tripMs: 1234));
    h.service.handleInbound(const InboundAck(radioId: radioA, ackCode: 1006));
    final text = h.service.exportMessageLog(messageId: m.id);
    expect(text, contains('try 1 of 8 (try number 0'));
    expect(text, contains('try 5 of 8 (try number 4'));
    expect(text, contains('reset path before try 5: OK'));
    expect(text, contains('sent direct (the radio said so)'));
    expect(text, contains('sent flood (the radio said so)'));
    expect(text, contains('not delivered: no confirmation after 8 tries'));
    expect(text, contains('confirmation ack=000003ee matched try 7'));
    expect(text, contains('it had been marked not delivered'));
    expect(text, contains('again for an already delivered message'));
    expect(text, contains('Delivery settings: 4 direct tries, 4 flood tries, flood fallback on'));
    expect(text, contains('Times in UTC'), reason: 'an exported diagnostics log is UTC whatever the Time zone setting, and says so');
    expect(text, contains('2025-10-09 '), reason: 'the fake clock starts at 1760000000000 = 2025-10-09 08:53:20 UTC');
    expect(MessageLog.utcStamp(1760000000123), '2025-10-09 08:53:20.123');
    expect(h.service.exportMessageLog(messageId: m.id, formatTime: (ms) => 'T$ms'), contains('Times as shown in the app'));
    expect(text, isNot(contains('SECRET-WORDS-123')));
    expect(h.service.exportMessageLog(), isNot(contains('SECRET-WORDS-123')));
    expect(h.service.log.forMessage('no-such-message'), isEmpty);
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
      // the first was waiting for an ack: its retry timer survived too, and the next try has the next try number
      clock.advance(30000);
      await svc.pump();
      expect(sink2.directs.where((d) => d.text == 'one').map((d) => d.attempt), [1]);
      // and an ack for attempt 1 of the first message (sent before the restart) is still matched
      svc.handleInbound(const InboundAck(radioId: radioA, ackCode: 1000));
      expect(store.messages.get(first.id)!.state, MessageState.acked);
      store.close();
    });
  });
}
