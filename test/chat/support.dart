import 'dart:async';
import 'dart:typed_data';

import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/chat/store.dart';

const radioA = 'aa00000000000000000000000000000000000000000000000000000000000001';
const bobKey = 'b0b0000000000000000000000000000000000000000000000000000000000001';
const carolKey = 'ca01000000000000000000000000000000000000000000000000000000000002';

class FakeClock {
  int ms;
  FakeClock([this.ms = 1760000000000]);
  int call() => ms;
  void advance(int dMs) => ms += dMs;
}

class SentDirect {
  final String key, text;
  final int ts, attempt;
  final bool forceFlood;
  SentDirect(this.key, this.text, this.ts, this.attempt, this.forceFlood);
}

class FakeSink implements OutboundMessageSink {
  bool connected = true;
  Object? failNext; // an OutboundFailure to throw once
  int nextAck = 1000;
  final directs = <SentDirect>[];
  final channels = <({int slot, String text, int ts})>[];
  int estTimeoutMs = 4000;

  @override
  bool get canSend => connected;

  @override
  Future<SendReceipt> sendDirect({required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt, required bool forceFlood}) async {
    if (!connected) throw const RadioNotConnected();
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    directs.add(SentDirect(contactPublicKey, text, timestamp, attempt, forceFlood));
    return SendReceipt(flood: forceFlood, expectedAck: nextAck++, estTimeoutMs: estTimeoutMs);
  }

  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp}) async {
    if (!connected) throw const RadioNotConnected();
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    channels.add((slot: slot, text: text, ts: timestamp));
    return timestamp;
  }
}

class FakeSource implements InboundMessageSource {
  final _c = StreamController<InboundEvent>.broadcast(sync: true);
  @override
  Stream<InboundEvent> get events => _c.stream;
  void add(InboundEvent e) => _c.add(e);
}

/// Deterministic ids and clock; no timer.
class Harness {
  final clock = FakeClock();
  final sink = FakeSink();
  final source = FakeSource();
  final secrets = InMemorySecretStore();
  late final ChatStore store = ChatStore.inMemory(secrets: secrets);
  late final ChatService service;
  var _id = 0;

  Harness({RetryPolicy policy = const RetryPolicy(jitterMs: 0, minGapMs: 0)}) {
    service = ChatService(
      store: store,
      source: source,
      sink: sink,
      nowMs: clock.call,
      selfName: () => 'Me',
      newId: () => 'm${_id++}',
      policy: policy,
      autoTimer: false,
    );
  }

  Contact bob({bool path = false, ContactType type = ContactType.companion}) {
    final c = Contact(radioId: radioA, publicKey: bobKey, type: type, name: 'Bob', outPath: path ? Uint8List.fromList([1, 2]) : null, outPathLen: path ? 2 : -1);
    store.contacts.upsert(c);
    return c;
  }

  Future<Channel> channel(int slot, String name, ChannelKind kind) =>
      store.channels.save(Channel(radioId: radioA, slot: slot, name: name, kind: kind), secret: Uint8List.fromList(List.filled(16, slot + 1)));

  String get bobConv => ConvKey.dm(bobKey.substring(0, 12));
}
