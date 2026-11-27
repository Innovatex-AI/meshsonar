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

  /// What the fake radio reported in its SENT reply: true = flood (it had no route), false = direct.
  final bool flood;
  SentDirect(this.key, this.text, this.ts, this.attempt, this.flood);

  /// The build-76 name, kept because test/ui/chat/cr2_delivery_send_test.dart (another package's file) reads it. It now
  /// means "the radio flooded this try". Remove with that test's use.
  bool get forceFlood => flood;
}

/// A sink that behaves like a radio as far as delivery cares: it decides direct or flood from ITS route ([hasRoute]),
/// forgets the route on reset path, and reports what it did. It also records every reset and every contact add, in order
/// with the sends ([log]).
class FakeSink implements OutboundMessageSink, DeliveryRadioControl {
  bool connected = true;
  Object? failNext; // an OutboundFailure to throw once
  int nextAck = 1000;
  final directs = <SentDirect>[];
  final channels = <({int slot, String text, int ts})>[];

  /// The command queue class of each channel send, in order.
  final channelPriorities = <int>[];
  int estTimeoutMs = 4000;

  /// The radio holds a route to the contact: sends go direct until a reset path.
  bool hasRoute = false;

  /// Contact keys RESET_PATH was sent for.
  final resets = <String>[];

  /// Contact keys the outbox asked to put on the radio after "not a contact".
  final added = <String>[];

  /// What [addContactToRadio] throws (once); null = it works.
  Object? failAdd;

  /// "send", "reset", "add" in the order they reached the radio.
  final log = <String>[];

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
    log.add('send');
    directs.add(SentDirect(contactPublicKey, text, timestamp, attempt, !hasRoute));
    return SendReceipt(flood: !hasRoute, expectedAck: nextAck++, estTimeoutMs: estTimeoutMs);
  }

  @override
  Future<bool> resetPath({required String radioId, required String contactPublicKey}) async {
    if (!connected) throw const RadioNotConnected();
    log.add('reset');
    resets.add(contactPublicKey);
    hasRoute = false;
    return true;
  }

  @override
  Future<void> addContactToRadio({required String radioId, required String contactPublicKey}) async {
    if (!connected) throw const RadioNotConnected();
    log.add('add');
    added.add(contactPublicKey);
    final f = failAdd;
    if (f != null) {
      failAdd = null;
      throw f;
    }
  }

  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp, int priority = CommandPriority.user}) async {
    if (!connected) throw const RadioNotConnected();
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    channels.add((slot: slot, text: text, ts: timestamp));
    channelPriorities.add(priority);
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
  final FakeSink sink;
  final source = FakeSource();
  final secrets = InMemorySecretStore();
  late final ChatStore store = ChatStore.inMemory(secrets: secrets);
  late final ChatService service;
  var _id = 0;

  /// [selfName] is the radio's name (the `name: ` prefix the firmware adds to this phone's channel messages).
  Harness({RetryPolicy policy = const RetryPolicy(jitterMs: 0, minGapMs: 0), String selfName = 'Me'}) : this.withSink(FakeSink(), policy: policy, selfName: selfName);

  Harness.withSink(this.sink, {RetryPolicy policy = const RetryPolicy(jitterMs: 0, minGapMs: 0), String selfName = 'Me'}) {
    service = ChatService(
      store: store,
      source: source,
      sink: sink,
      nowMs: clock.call,
      selfName: () => selfName,
      newId: () => 'm${_id++}',
      policy: policy,
      autoTimer: false,
    );
  }

  /// Bob in the phone's book. [path] also gives the fake RADIO a route to him (the radio decides direct or flood).
  Contact bob({bool path = false, ContactType type = ContactType.companion}) {
    sink.hasRoute = path;
    final c = Contact(radioId: radioA, publicKey: bobKey, type: type, name: 'Bob', outPath: path ? Uint8List.fromList([1, 2]) : null, outPathLen: path ? 2 : -1);
    store.contacts.upsert(c);
    return c;
  }

  Future<Channel> channel(int slot, String name, ChannelKind kind) =>
      store.channels.save(Channel(radioId: radioA, slot: slot, name: name, kind: kind), secret: Uint8List.fromList(List.filled(16, slot + 1)));

  String get bobConv => ConvKey.dm(bobKey.substring(0, 12));
}
