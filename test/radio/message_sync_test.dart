import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/message_sync.dart';
import 'package:meshsonar/radio/protocol.dart';

/// A radio whose offline queue we control; every SYNC_NEXT_MESSAGE pops one frame, like the firmware.
class FakeSource implements MessageSource {
  final List<Uint8List> queue = [];
  final List<String> log = [];
  bool connected = true;
  Duration latency = Duration.zero;
  @override
  bool get isConnected => connected;
  @override
  Future<Frame> syncNextMessage() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    log.add('sync');
    return decodeFrame(queue.isEmpty ? encodeNoMoreMessages() : queue.removeAt(0));
  }
}

final aKey = List<int>.generate(32, (i) => i + 1);

void main() {
  late FakeSource src;
  late MessageSync sync;

  setUp(() {
    src = FakeSource();
    sync = MessageSync(src, clock: () => DateTime.utc(2026, 11, 1), pollInterval: const Duration(milliseconds: 40));
  });
  tearDown(() => sync.dispose());

  test('channel and contact frames become typed messages; NO_MORE_MESSAGES ends the drain', () async {
    src.queue.addAll([
      encodeChannelMsg(2, 'Ann: hello there', timestamp: 1700000001, pathLen: 3, snrDb: 5.25),
      encodeContactText(aKey, 'dm text', txtType: txtTypePlain, timestamp: 1700000002, pathLen: 0xFF, snrDb: -2.5),
    ]);
    final got = <InboundMessage>[];
    sync.messages.listen(got.add);
    await sync.drain();
    expect(got, hasLength(2));
    final ch = got[0];
    expect(ch.kind, InboundKind.channel);
    expect(ch.channelIndex, 2);
    expect(ch.senderName, 'Ann');
    expect(ch.text, 'hello there');
    expect(ch.fullText, 'Ann: hello there');
    expect(ch.senderTimestamp, 1700000001);
    expect(ch.snrDb, 5.25);
    expect(ch.pathLen, 3);
    expect(ch.hops, 3);
    expect(ch.raw.first, Resp.channelMsgRecvV3);
    expect(ch.receivedAt, DateTime.utc(2026, 11, 1));
    final dm = got[1];
    expect(dm.kind, InboundKind.contact);
    expect(dm.senderPrefixHex, '010203040506');
    expect(dm.text, 'dm text');
    expect(dm.wasDirect, isTrue);
    expect(dm.snrDb, -2.5);
    expect(dm.conversationKey, 'dm:010203040506');
    expect(src.queue, isEmpty);
    expect(src.log.length, 3, reason: 'two messages and the NO_MORE_MESSAGES answer');
  });

  test('legacy (pre-V3) frames carry no SNR', () async {
    src.queue.add(encodeChannelMsg(0, 'Bob: hi', timestamp: 5, v3: false));
    src.queue.add(encodeContactText(aKey, 'old dm', txtType: txtTypePlain, timestamp: 6, v3: false));
    final got = <InboundMessage>[];
    sync.messages.listen(got.add);
    await sync.drain();
    expect(got.map((m) => m.snrDb), [null, null]);
    expect(got.map((m) => m.text), ['hi', 'old dm']);
  });

  test('a signed DM (txt_type 2) keeps the signer prefix out of the text', () async {
    src.queue.add(encodeContactText(aKey, 'signed words', txtType: 2, timestamp: 9, signer4: [0xAA, 0xBB, 0xCC, 0xDD]));
    final got = <InboundMessage>[];
    sync.messages.listen(got.add);
    await sync.drain();
    expect(got.single.text, 'signed words');
    expect(got.single.signerPrefixHex, 'aabbccdd');
    expect(got.single.txtType, 2);
  });

  test('persist-first: each message is saved BEFORE the next SYNC_NEXT_MESSAGE goes out', () async {
    src.queue.addAll([for (var i = 0; i < 3; i++) encodeChannelMsg(1, 'A: m$i', timestamp: 100 + i)]);
    final order = <String>[];
    final s2 = MessageSync(_Spy(src, order), pollInterval: const Duration(hours: 1));
    s2.persist = (m) async {
      order.add('persist ${m.text} (radio queue left: ${src.queue.length})');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      order.add('saved ${m.text}');
    };
    final seen = <String>[];
    s2.messages.listen((m) => seen.add(m.text));
    await s2.drain();
    s2.dispose();
    expect(order, [
      'syncNext', 'persist m0 (radio queue left: 2)', 'saved m0',
      'syncNext', 'persist m1 (radio queue left: 1)', 'saved m1',
      'syncNext', 'persist m2 (radio queue left: 0)', 'saved m2',
      'syncNext', // NO_MORE
    ]);
    expect(seen, ['m0', 'm1', 'm2'], reason: 'emitted after persisted, in order');
  });

  test('a persister that fails 3 times: counted, reported, the message is still emitted and the drain goes on', () async {
    src.queue.addAll([encodeChannelMsg(1, 'A: one', timestamp: 1), encodeChannelMsg(1, 'A: two', timestamp: 2)]);
    var calls = 0;
    sync.persist = (m) async {
      calls++;
      if (m.text == 'one') throw StateError('disk full');
    };
    final failed = <String>[];
    sync.onPersistError = (m, e) => failed.add(m.text);
    final got = <String>[];
    sync.messages.listen((m) => got.add(m.text));
    await sync.drain();
    expect(got, ['one', 'two']);
    expect(failed, ['one']);
    expect(sync.persistFailures, 1);
    expect(calls, 4, reason: '3 tries for one, 1 for two');
  });

  test('idempotent: draining the same frames twice yields each message once (retried DMs too)', () async {
    final frames = [
      encodeChannelMsg(1, 'A: same', timestamp: 77),
      encodeContactText(aKey, 'dm', txtType: txtTypePlain, timestamp: 78),
    ];
    final got = <String>[];
    sync.messages.listen((m) => got.add(m.text));
    src.queue.addAll(frames);
    await sync.drain();
    src.queue.addAll(frames); // replay
    await sync.drain();
    expect(got, ['same', 'dm']);
    expect(sync.duplicates, 2);
    // the same text with a NEW sender timestamp is a different message
    src.queue.add(encodeChannelMsg(1, 'A: same', timestamp: 79));
    await sync.drain();
    expect(got, ['same', 'dm', 'same']);
  });

  test('the same text on another channel is another message', () async {
    final got = <String>[];
    sync.messages.listen((m) => got.add(m.conversationKey));
    src.queue.addAll([encodeChannelMsg(1, 'A: x', timestamp: 5), encodeChannelMsg(2, 'A: x', timestamp: 5)]);
    await sync.drain();
    expect(got, ['ch:1', 'ch:2']);
  });

  test('binary channel datagrams in the queue are stepped over, not a reason to stop', () async {
    src.queue.addAll([
      encodeChannelDataRecv(1, 0x0102, [1, 2, 3]),
      encodeChannelMsg(1, 'A: after the datagram', timestamp: 3),
    ]);
    final got = <String>[];
    sync.messages.listen((m) => got.add(m.text));
    await sync.drain();
    expect(got, ['after the datagram']);
    expect(src.queue, isEmpty);
  });

  test('CLI replies (txt_type 1) go to the claim hook only, never into chat', () async {
    src.queue.add(encodeContactText(aKey, '> INNO-OB-2', txtType: txtTypeCliData, timestamp: 4));
    final claim = <String>[];
    sync.onContactText = (f) => claim.add(f.text);
    final got = <InboundMessage>[];
    sync.messages.listen(got.add);
    await sync.drain();
    expect(claim, ['> INNO-OB-2']);
    expect(got, isEmpty);
  });

  test('a drain requested while one runs goes round once more (a message queued at the last moment is not missed)', () async {
    src.latency = const Duration(milliseconds: 20);
    src.queue.add(encodeChannelMsg(1, 'A: first', timestamp: 1));
    final got = <String>[];
    sync.messages.listen((m) => got.add(m.text));
    final first = sync.drain();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    src.queue.add(encodeChannelMsg(1, 'A: late', timestamp: 2));
    final second = sync.drain();
    await Future.wait([first, second]);
    expect(got, ['first', 'late']);
  });

  test('polling fallback: a lost PUSH_MSG_WAITING does not strand a message (starts with the first listener)', () async {
    src.queue.add(encodeChannelMsg(1, 'A: stranded', timestamp: 1));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(src.queue, hasLength(1), reason: 'no listener, no polling: same as before chat existed');
    final got = <String>[];
    final sub = sync.messages.listen((m) => got.add(m.text));
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(got, ['stranded']);
    await sub.cancel();
    final polls = src.log.length;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(src.log.length, polls, reason: 'last listener gone: polling stops');
  });

  test('polling is quiet while disconnected', () async {
    src.connected = false;
    src.queue.add(encodeChannelMsg(1, 'A: x', timestamp: 1));
    sync.messages.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(src.log, isEmpty);
  });

  test('splitSenderPrefix: first ": " ends the name; no prefix keeps the text', () {
    expect(splitSenderPrefix('Ann: hi: there'), ('Ann', 'hi: there'));
    expect(splitSenderPrefix('no prefix here'), (null, 'no prefix here'));
    expect(splitSenderPrefix(': leading'), (null, ': leading'));
  });
}

class _Spy implements MessageSource {
  final FakeSource inner;
  final List<String> log;
  _Spy(this.inner, this.log);
  @override
  bool get isConnected => inner.isConnected;
  @override
  Future<Frame> syncNextMessage() {
    log.add('syncNext');
    return inner.syncNextMessage();
  }
}
