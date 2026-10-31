import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/chat/session_adapter.dart';
import 'package:meshsonar/radio/inbound.dart' as r;
import 'package:meshsonar/radio/session.dart' as r;

import 'support.dart';

/// Only the RadioSession members the adapter touches are implemented; anything else would throw, which is the point.
class FakeSession implements r.RadioSession {
  @override
  String? selfPublicKey = radioA;
  @override
  bool isConnected = true;
  @override
  bool chatActive = false;
  Future<void> Function(r.InboundMessage)? persister;
  final eventsC = StreamController<r.RadioEvent>.broadcast(sync: true);
  r.SendResult nextSend = const r.SendResult.accepted(1000, expectedAck: 77, estTimeoutMs: 4200, flood: true);
  final sentContacts = <(String, String, int, int?)>[];
  final sentChannels = <(int, String)>[];
  final updated = <r.RadioContact>[];
  r.ContactListing listing = const r.ContactListing(totalOnRadio: 0, contacts: [], mostRecentLastMod: 0);
  int getContactsCalls = 0;
  int? lastSince;
  @override
  r.DeviceLimits? limits = const r.DeviceLimits(maxContacts: 100);
  final onRadio = <String, r.RadioContact>{};
  final resets = <String>[];
  final fetched = <String>[];

  @override
  Stream<r.RadioEvent> get events => eventsC.stream;
  @override
  void setInboundPersister(Future<void> Function(r.InboundMessage message)? persist) => persister = persist;
  @override
  Future<r.SendResult> sendContactMessage(String publicKeyHex, String text, {int attempt = 0, int? timestamp, r.FloodScope? scope}) async {
    sentContacts.add((publicKeyHex, text, attempt, timestamp));
    return nextSend;
  }

  @override
  Future<r.SendResult> sendChannelMessage(int channelIndex, String text, {r.FloodScope? scope}) async {
    sentChannels.add((channelIndex, text));
    return nextSend;
  }

  @override
  Future<void> addOrUpdateContact(r.RadioContact contact) async {
    updated.add(contact);
    onRadio[contact.publicKeyHex] = contact;
  }

  @override
  Future<r.ContactListing> downloadContacts({int since = 0, void Function(r.RadioContact contact, int received, int total)? onContact}) async {
    getContactsCalls++;
    lastSince = since;
    var i = 0;
    for (final c in listing.contacts) {
      onContact?.call(c, ++i, listing.totalOnRadio);
    }
    return listing;
  }

  @override
  Future<r.RadioContact?> getContact(String publicKeyHex) async {
    fetched.add(publicKeyHex);
    return onRadio[publicKeyHex];
  }

  @override
  Future<bool> resetContactPath(String publicKeyHex) async {
    resets.add(publicKeyHex);
    return true;
  }

  @override
  Future<r.ContactPolicy> getContactPolicy() async => const r.ContactPolicy(askBeforeAdding: false);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

r.InboundMessage chanMsg(int ts, String full, {int pathLen = 2}) => r.InboundMessage(
    kind: r.InboundKind.channel,
    channelIndex: 1,
    senderName: 'Ann',
    text: full.substring(full.indexOf(': ') + 2),
    fullText: full,
    txtType: 0,
    senderTimestamp: ts,
    receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
    snrDb: 6,
    pathLen: pathLen,
    raw: Uint8List(0));

void main() {
  late Harness h;
  late FakeSession s;
  late RadioSessionChatAdapter a;
  setUp(() async {
    h = Harness();
    s = FakeSession();
    a = RadioSessionChatAdapter(s, lookupContact: (k) => h.store.contacts.get(radioA, k));
    await h.channel(1, 'Ohio', ChannelKind.private);
    h.bob(path: true);
    a.bind(h.service);
    await Future<void>.delayed(Duration.zero);
  });

  test('bind turns chat on and installs a persister that stores before returning', () async {
    expect(s.chatActive, isTrue);
    await s.persister!(chanMsg(100, 'Ann: hi all'));
    final ch = h.store.channels.bySlot(radioA, 1)!;
    expect(h.store.messages.page(ch.convKey).messages.single.text, 'hi all');
    // the same frame again (reconnect resync): still one row
    await s.persister!(chanMsg(100, 'Ann: hi all'));
    expect(h.store.messages.count(), 1);
    await a.dispose();
    expect(s.persister, isNull);
    expect(s.chatActive, isFalse);
  });

  test('direct (0xFF) path becomes "no hops"; DM frames map prefix, signer and cli type', () async {
    await s.persister!(chanMsg(5, 'Ann: x', pathLen: 0xFF));
    expect(h.store.messages.page(h.store.channels.bySlot(radioA, 1)!.convKey).messages.single.pathLen, isNull);
    final m = RadioSessionChatAdapter.mapInbound(
        radioA,
        r.InboundMessage(
            kind: r.InboundKind.contact,
            senderPrefixHex: bobKey.substring(0, 12),
            signerPrefixHex: 'aabbccdd',
            text: 't',
            fullText: 't',
            txtType: 2,
            senderTimestamp: 9,
            receivedAt: DateTime.fromMillisecondsSinceEpoch(0),
            pathLen: 3,
            raw: Uint8List(0))) as InboundDirectText;
    expect(m.signerPrefix, 'aabbccdd');
    expect(m.txtType, 2);
    expect(m.pathLen, 3);
  });

  test('persister refuses (throws) when the radio identity is unknown, so the radio keeps the message', () async {
    s.selfPublicKey = null;
    await expectLater(s.persister!(chanMsg(1, 'A: b')), throwsStateError);
    expect(h.store.messages.count(), 0);
  });

  test('SEND_CONFIRMED event acks the waiting DM', () async {
    final m = h.service.send(radioId: radioA, convKey: h.bobConv, text: 'hello');
    await h.service.pump(); // FakeSink is the service's sink; the adapter is exercised separately below
    h.store.messages.update(m.id, expectedAck: 1000);
    s.eventsC.add(r.SendConfirmedEvent(DateTime.now(), ack: 1000, tripMs: 800));
    expect(h.store.messages.get(m.id)!.state, MessageState.acked);
  });

  test('sendDirect: accepted, queued and failures map to the chat vocabulary', () async {
    final ok = await a.sendDirect(radioId: radioA, contactPublicKey: bobKey, text: 'x', timestamp: 55, attempt: 1, forceFlood: false);
    expect((ok.expectedAck, ok.estTimeoutMs, ok.flood), (77, 4200, true));
    expect(s.sentContacts.single, (bobKey, 'x', 1, 55));
    expect(s.updated.map((c) => c.publicKeyHex), [bobKey], reason: 'the radio did not have Bob: the phone (master) put him back first');

    s.nextSend = const r.SendResult.queued(55);
    await expectLater(a.sendDirect(radioId: radioA, contactPublicKey: bobKey, text: 'x', timestamp: 55, attempt: 0, forceFlood: false), throwsA(isA<RadioBusy>()));
    for (final (f, matcher) in <(r.SendFailure, Matcher)>[
      (r.SendFailure.notConnected, isA<RadioNotConnected>()),
      (r.SendFailure.radioBusy, isA<RadioBusy>()),
      (r.SendFailure.noSuchContact, isA<RadioTargetMissing>()),
      (r.SendFailure.noSuchChannel, isA<RadioTargetMissing>()),
      (r.SendFailure.tooLong, isA<RadioRejected>()),
      (r.SendFailure.unsupported, isA<RadioRejected>()),
      (r.SendFailure.radioError, isA<RadioRejected>()),
    ]) {
      s.nextSend = r.SendResult.failed(f);
      await expectLater(a.sendDirect(radioId: radioA, contactPublicKey: bobKey, text: 'x', timestamp: 55, attempt: 0, forceFlood: false), throwsA(matcher), reason: '$f');
    }
  });

  test('forceFlood resets the stored path on the radio first (RESET_PATH, not a rewrite of the contact)', () async {
    await a.sendDirect(radioId: radioA, contactPublicKey: bobKey, text: 'x', timestamp: 55, attempt: 4, forceFlood: true);
    expect(s.resets, [bobKey]);
    expect(s.sentContacts, hasLength(1));
  });

  test('sendChannel adopts the timestamp the session used', () async {
    s.nextSend = const r.SendResult.accepted(4242);
    expect(await a.sendChannel(radioId: radioA, slot: 1, text: 'hi', timestamp: 1), 4242);
    expect(s.sentChannels.single, (1, 'hi'));
  });

  test('outbox adopts the session timestamp for a channel message (echo matching depends on it)', () async {
    final stamping = _Stamping(FakeSink(), 999999);
    final h2 = Harness();
    final ch2 = await h2.channel(1, 'Ohio', ChannelKind.private);
    final svc2 = _serviceWith(h2, stamping);
    final m2 = svc2.send(radioId: radioA, convKey: ch2.convKey, text: 'stamped');
    await svc2.pump();
    final got = h2.store.messages.get(m2.id)!;
    expect(got.tsSender, 999999);
    h2.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: 999999, text: 'Me: stamped'));
    expect(h2.store.messages.get(m2.id)!.repeatsHeard, 1);
  });

  test('contact sync merges radio fields, keeps the phone-side favourite/custom name/notes, and follows the cursor', () async {
    h.store.contacts.upsert(h.store.contacts.get(radioA, bobKey)!.copyWith(favourite: true, customName: 'Bobby', notes: 'tall'));
    s.listing = r.ContactListing(totalOnRadio: 1, mostRecentLastMod: 500, contacts: [
      r.RadioContact(publicKeyHex: bobKey, type: 2, name: 'Bob Repeater', outPath: Uint8List.fromList([7]), outPathLen: 1, lat: 39.1, lon: -84.5, lastAdvert: 1234, lastMod: 500),
    ]);
    await a.syncContacts();
    final c = h.store.contacts.get(radioA, bobKey)!;
    expect(c.name, 'Bob Repeater');
    expect(c.type, ContactType.repeater);
    expect(c.favourite, isTrue);
    expect(c.customName, 'Bobby');
    expect(c.notes, 'tall');
    expect(c.outPath, [7]);
    expect(c.lat, 39.1);
    expect(c.onRadio, isTrue);
    await a.syncContacts();
    expect(s.lastSince, 499, reason: 'incremental, from one second before the cursor (a change in the same second must not be missed)');
    // a path update push reads that one contact back, not the whole list
    final before = s.getContactsCalls;
    s.onRadio[bobKey] = r.RadioContact(publicKeyHex: bobKey, type: 2, name: 'Bob Repeater', outPath: Uint8List.fromList([7, 8]), outPathLen: 2, lastMod: 600);
    s.eventsC.add(r.PathUpdatedEvent(DateTime.now(), bobKey));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(s.getContactsCalls, before);
    expect(h.store.contacts.get(radioA, bobKey)!.outPathLen, 2);
  });

  test('adverts: known contacts update, unknown ones only land in the Discover list', () async {
    s.eventsC.add(r.AdvertHeardEvent(DateTime.now(), carolKey, isNew: true, contact: r.RadioContact(publicKeyHex: carolKey, type: 2, name: 'Hill', outPath: Uint8List(0), lat: 1, lon: 2, lastAdvert: 10)));
    expect(h.store.adverts.list(radioA).single.name, 'Hill');
    expect(h.store.contacts.get(radioA, carolKey), isNull);
    s.eventsC.add(r.AdvertHeardEvent(DateTime.now(), bobKey, isNew: false));
    expect(h.store.contacts.get(radioA, bobKey)!.name, 'Bob', reason: 'an empty name from a bare advert push must not wipe the stored name');
  });
}

class _Stamping implements OutboundMessageSink {
  final FakeSink inner;
  final int ts;
  _Stamping(this.inner, this.ts);
  @override
  bool get canSend => true;
  @override
  Future<SendReceipt> sendDirect({required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt, required bool forceFlood}) =>
      inner.sendDirect(radioId: radioId, contactPublicKey: contactPublicKey, text: text, timestamp: timestamp, attempt: attempt, forceFlood: forceFlood);
  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp}) async => ts;
}

ChatService _serviceWith(Harness h, OutboundMessageSink sink) =>
    ChatService(store: h.store, sink: sink, nowMs: h.clock.call, selfName: () => 'Me', policy: const RetryPolicy(jitterMs: 0, minGapMs: 0), autoTimer: false);
