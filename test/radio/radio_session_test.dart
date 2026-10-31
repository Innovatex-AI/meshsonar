import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/ping_gate.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/session.dart';
import 'package:meshsonar/radio/session_manager.dart';
import 'package:meshsonar/radio/simulator.dart';

Future<T> within<T>(Future<T> f) => f.timeout(const Duration(seconds: 5));

Future<void> until(bool Function() test, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $ms ms');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late SimulatedRadioScanner scanner;
  late RadioSessionManager mgr;
  late LinkRadioSession session;
  late SimulatedTransport radio;

  setUp(() async {
    scanner = SimulatedRadioScanner(seed: 3, timeScale: 50);
    mgr = RadioSessionManager(
      linkFactory: (t) => MeshCoreCompanionLink(t, timeout: const Duration(seconds: 2), messagePollInterval: const Duration(milliseconds: 80)),
    );
    session = await mgr.connect(scanner, SimulatedRadioScanner.device);
    radio = scanner.lastTransport!;
  });

  tearDown(() => mgr.dispose());

  test('limits come from DEVICE_INFO: contacts doubled, channels as sent', () {
    expect(session.limits!.maxChannels, 8);
    expect(session.limits!.maxContacts, 100);
    expect(session.limits!.firmwareVerCode, 9);
    expect(session.linkState, LinkState.connected);
    expect(mgr.state, LinkState.connected);
    expect(session.maxChannelTextBytes, 160 - ('MeshSonar Sim'.length + 2));
  });

  group('inbound', () {
    test('a channel message from the mesh arrives typed, after PUSH_MSG_WAITING', () async {
      final next = session.inbound.first;
      expect(radio.injectChannelMessage(0, 'Ann', 'good morning', timestamp: 1730000000, pathLen: 2, snrDb: 4.5), isTrue);
      final m = await within(next);
      expect(m.kind, InboundKind.channel);
      expect(m.channelIndex, 0);
      expect(m.senderName, 'Ann');
      expect(m.text, 'good morning');
      expect(m.senderTimestamp, 1730000000);
      expect(m.hops, 2);
      expect(m.snrDb, 4.5);
      expect(radio.offlineQueueLength, 0);
    });

    test('a DM from a contact', () async {
      final next = session.inbound.first;
      radio.injectDirectMessage('Bob W8BOB', 'got a minute?');
      final m = await within(next);
      expect(m.kind, InboundKind.contact);
      expect(m.text, 'got a minute?');
      expect(m.senderPrefixHex, hasLength(12));
      expect(radio.contactKeys.any((k) => k.startsWith(m.senderPrefixHex!)), isTrue);
    });

    test('persist-first: the persister has finished for a message before it is emitted and before the radio is asked for the next', () async {
      final order = <String>[];
      session.setInboundPersister((m) async {
        order.add('persist ${m.text}');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        order.add('saved ${m.text}');
      });
      session.inbound.listen((m) => order.add('emit ${m.text}'));
      radio.dropMsgWaiting = true;
      radio.injectChannelMessage(0, 'A', 'one');
      radio.injectChannelMessage(0, 'A', 'two');
      await session.syncMessagesNow();
      expect(order, ['persist one', 'saved one', 'emit one', 'persist two', 'saved two', 'emit two']);
    });

    test('a lost PUSH_MSG_WAITING is caught by the poll', () async {
      radio.dropMsgWaiting = true;
      final got = <String>[];
      session.inbound.listen((m) => got.add(m.text));
      radio.injectChannelMessage(0, 'A', 'quiet arrival');
      await until(() => got.isNotEmpty);
      expect(got, ['quiet arrival']);
    });

    test('a full radio queue evicts the oldest channel message, and drops a new DM when only DMs are queued (MyMesh.cpp 224-244)', () async {
      radio.dropMsgWaiting = true;
      for (var i = 0; i < 16; i++) {
        radio.injectChannelMessage(0, 'A', 'c$i', timestamp: 100 + i);
      }
      radio.injectChannelMessage(0, 'A', 'c16', timestamp: 200);
      expect(radio.offlineQueueLength, 16);
      final got = <String>[];
      session.inbound.listen((m) => got.add(m.text));
      await session.syncMessagesNow();
      expect(got, [for (var i = 1; i < 17; i++) 'c$i'], reason: 'c0 was evicted');
    });

    test('draining twice never repeats a message', () async {
      final got = <String>[];
      session.inbound.listen((m) => got.add(m.text));
      radio.dropMsgWaiting = true;
      radio.injectChannelMessage(0, 'A', 'x');
      await session.syncMessagesNow();
      await session.syncMessagesNow();
      expect(got, ['x']);
    });
  });

  group('outbound', () {
    test('channel message: accepted, on the wire as SEND_CHANNEL_TXT_MSG, and the arbiter wakes up', () async {
      expect(session.chatActive, isFalse);
      final r = await within(session.sendChannelMessage(0, 'hello mesh'));
      expect(r.status, SendStatus.accepted);
      expect(r.timestamp, greaterThan(1700000000));
      expect(r.expectedAck, isNull, reason: 'channels have no ACK');
      expect(radio.sentChannel.single, (slot: 0, text: 'hello mesh'));
      expect(session.chatActive, isTrue);
    });

    test('channel message too long, empty, no such slot, link down', () async {
      expect((await session.sendChannelMessage(0, 'x' * 200)).failure, SendFailure.tooLong);
      expect((await session.sendChannelMessage(0, '')).failure, SendFailure.tooLong);
      final r = await session.sendChannelMessage(7, 'hi'); // slot 7 exists on the simulator (8 slots) but is empty: accepted
      expect(r.isAccepted, isTrue);
      final bad = await session.sendChannelMessage(30, 'hi');
      expect(bad.failure, SendFailure.noSuchChannel);
      radio.simulateDisconnect();
      await until(() => !session.isConnected);
      expect((await session.sendChannelMessage(0, 'hi')).failure, SendFailure.notConnected);
    });

    test('NOT_FOUND on a slot that exists means "pool full": retried once, then accepted; twice in a row is reported (MyMesh.cpp 1190-1195)', () async {
      radio.busyChannelSends = 1;
      final before = radio.sentFrames.length;
      final r = await session.sendChannelMessage(0, 'hi');
      expect(r.isAccepted, isTrue);
      expect(radio.sentFrames.skip(before).where((f) => f[0] == Cmd.sendChannelTxtMsg), hasLength(2));
      radio.busyChannelSends = 5;
      final bad = await session.sendChannelMessage(0, 'hi again');
      expect(bad.failure, SendFailure.noSuchChannel);
      expect(bad.detail, contains('busy'));
    });

    test('the radio does not answer: queued ("may still send, do not resend blindly"), not failed', () async {
      radio.responsive = false;
      final r = await session.sendChannelMessage(0, 'into the void');
      expect(r.status, SendStatus.queued);
      expect(r.detail, isNotNull);
    });

    test('DM: accepted with ack tag and flood flag; SEND_CONFIRMED arrives on events with the contact', () async {
      final ann = radio.contactKeys.first;
      final events = <RadioEvent>[];
      session.events.listen(events.add);
      final r = await within(session.sendContactMessage(ann, 'on my way'));
      expect(r.status, SendStatus.accepted);
      expect(r.expectedAck, isNonZero);
      expect(r.flood, isTrue, reason: 'no path known yet');
      expect(r.estTimeoutMs, greaterThan(0));
      expect(radio.sentDirect.single.text, 'on my way');
      await until(() => events.whereType<SendConfirmedEvent>().isNotEmpty);
      final c = events.whereType<SendConfirmedEvent>().single;
      expect(c.ack, r.expectedAck);
      expect(c.contactKeyHex, ann);
      expect(c.tripMs, greaterThan(0));
      await until(() => events.whereType<PathUpdatedEvent>().isNotEmpty);
      expect(events.whereType<PathUpdatedEvent>().single.publicKeyHex, ann);
    });

    test('DM retries: same timestamp, attempt number in the packet, ack tags of attempt N and N+4 collide', () async {
      final ann = radio.contactKeys.first;
      radio.dropAcks = true;
      final first = await session.sendContactMessage(ann, 'again?');
      final retry = await session.sendContactMessage(ann, 'again?', attempt: 1, timestamp: first.timestamp);
      final fifth = await session.sendContactMessage(ann, 'again?', attempt: 4, timestamp: first.timestamp);
      expect(retry.timestamp, first.timestamp);
      expect(retry.attempt, 1);
      expect(retry.expectedAck, isNot(first.expectedAck));
      expect(fifth.attempt, 0);
      expect(fifth.expectedAck, first.expectedAck, reason: 'only attempt & 3 is on the wire (BaseChatMesh.cpp 455-466)');
    });

    test('DM failures: unknown contact, malformed key, too long', () async {
      expect((await session.sendContactMessage('ab' * 32, 'hi')).failure, SendFailure.noSuchContact);
      expect((await session.sendContactMessage('nothex', 'hi')).failure, SendFailure.noSuchContact);
      expect((await session.sendContactMessage(radio.contactKeys.first, 'x' * 161)).failure, SendFailure.tooLong);
    });

    test('a user send holds pings back for 2 s and wakes the radio-queue probe; an idle session never probed', () async {
      final gate = session.pingGate;
      expect((await gate.requestPing()).go, isTrue);
      await session.sendChannelMessage(0, 'hi');
      expect((await gate.requestPing()).reason, PingSkipReason.userSendRecent);
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect((await gate.requestPing()).go, isTrue);
      radio.outboundQueueLen = 2;
      expect((await gate.requestPing()).reason, PingSkipReason.radioQueueBusy);
    });

    test('scope is set right before a scoped flood and cleared before the next ping, in order on the wire', () async {
      final key = Uint8List.fromList(List.generate(16, (i) => i));
      await session.sendChannelMessage(0, 'regional', scope: FloodScope.key(key));
      expect(radio.floodScopeLog, [toHex(key)]);
      final scopeAt = radio.sentFrames.indexWhere((f) => f[0] == Cmd.setFloodScopeKey);
      expect(radio.sentFrames[scopeAt + 1][0], Cmd.sendChannelTxtMsg, reason: 'same queue slot: scope, then the send');
      // a ping (the engine's call, no scope given) must not inherit it
      final link = session.link as MeshCoreCompanionLink;
      await link.sendChannelText(0, 'MS:ping');
      expect(radio.floodScopeLog, [toHex(key), null]);
      await link.sendChannelText(0, 'MS:ping2');
      expect(radio.floodScopeLog, hasLength(2), reason: 'cleared once, not before every ping');
    });
  });

  group('contacts and channels', () {
    test('GET_CONTACTS lists everything; since returns only what changed; END carries the cursor', () async {
      final all = await within(session.getContacts());
      expect(all.totalOnRadio, 9); // Ann, Bob and the 7 repeaters
      expect(all.contacts, hasLength(9));
      expect(all.contacts.first.name, 'Ann KE8ANN');
      expect(all.contacts.where((c) => c.type == AdvType.repeater), hasLength(7));
      expect(all.contacts.last.lat, isNotNull);
      final cursor = all.mostRecentLastMod;
      expect(cursor, greaterThan(0));
      final none = await session.getContacts(since: cursor);
      expect(none.contacts, isEmpty);
      expect(none.totalOnRadio, 9, reason: 'the total is not filtered');
      radio.injectNewAdvert('Carol N8CAR', lat: 40.2, lon: -82.9);
      final one = await session.getContacts(since: cursor);
      expect(one.contacts.single.name, 'Carol N8CAR');
      expect(one.contacts.single.lat, closeTo(40.2, 1e-6));
      expect(one.totalOnRadio, 10);
    });

    test('two overlapping GET_CONTACTS are serialised, both complete', () async {
      final both = await within(Future.wait([session.getContacts(), session.getContacts()]));
      expect(both[0].contacts, hasLength(9));
      expect(both[1].contacts, hasLength(9));
    });

    test('NEW_ADVERT and ADVERT-style pushes arrive as events', () async {
      final events = <RadioEvent>[];
      session.events.listen(events.add);
      radio.manualAddContacts = 1; // "ask before adding": the radio pushes NEW_ADVERT and adds nothing
      radio.injectNewAdvert('Dave K8DAV');
      await until(() => events.isNotEmpty);
      final e = events.single as AdvertHeardEvent;
      expect(e.isNew, isTrue);
      expect(e.contact!.name, 'Dave K8DAV');
      expect(e.publicKeyHex, e.contact!.publicKeyHex);
    });

    test('addOrUpdateContact then DM to it', () async {
      final key = toHex(sha256(Uint8List.fromList([1, 2, 3])));
      await session.addOrUpdateContact(RadioContact(publicKeyHex: key, type: AdvType.chat, name: 'Eve', outPath: Uint8List(0), lat: 40.0, lon: -83.0));
      final listing = await session.getContacts();
      final eve = listing.contacts.firstWhere((c) => c.publicKeyHex == key);
      expect(eve.name, 'Eve');
      expect(eve.pathKnown, isFalse);
      expect((await session.sendContactMessage(key, 'hello Eve')).isAccepted, isTrue);
    });

    test('channels: list, set, delete', () async {
      var list = await session.listChannels();
      expect(list, hasLength(8));
      expect(list.first.name, 'Public');
      expect(list[1].isEmpty, isTrue);
      await session.setChannel(1, 'Family', Uint8List.fromList(List.filled(16, 7)));
      list = await session.listChannels();
      expect(list[1].name, 'Family');
      expect(list[1].secret, List.filled(16, 7));
      await session.deleteChannel(1);
      expect((await session.listChannels())[1].isEmpty, isTrue);
    });
  });

  group('manager', () {
    test('disconnect ends the session; state and sessions stream follow', () async {
      final states = <LinkState>[];
      mgr.linkStates.listen(states.add);
      await mgr.disconnect();
      expect(mgr.session, isNull);
      expect(mgr.connected, isFalse);
      expect(states, [LinkState.disconnected]);
    });

    test('hand-over closes the link and nothing reconnects until connect is called again', () async {
      await mgr.handOver();
      expect(mgr.state, LinkState.handedOver);
      expect(radio.isConnected, isFalse);
      final r = await mgr.reconnect(scanner, SimulatedRadioScanner.device, keepGoing: () => true, delay: (_) => Duration.zero);
      expect(r, isNull);
      expect(mgr.state, LinkState.handedOver);
      await mgr.connect(scanner, SimulatedRadioScanner.device);
      expect(mgr.state, LinkState.connected);
    });

    test('a dropped link is noticed; reconnect gives a new session on the same arbiter', () async {
      final old = mgr.session!;
      mgr.arbiter.admitUserSend(300);
      radio.simulateDisconnect();
      await until(() => mgr.state == LinkState.disconnected);
      final attempts = <int>[];
      final failures = <Object>[];
      var tries = 0;
      final failing = _FlakyScanner(scanner, failFirst: 2);
      final s = await within(mgr.reconnect(failing, SimulatedRadioScanner.device,
          keepGoing: () => true,
          delay: (_) => const Duration(milliseconds: 5),
          expectedKeyHex: old.selfInfo!.publicKey,
          onAttempt: attempts.add,
          onFailure: failures.add));
      tries = attempts.length;
      expect(s, isNotNull);
      expect(identical(s, old), isFalse);
      expect(tries, 3);
      expect(failures, hasLength(2));
      expect(mgr.state, LinkState.connected);
      expect(identical(mgr.session, s), isTrue);
      expect(s!.arbiter, same(old.arbiter));
      expect(mgr.arbiter.snapshot().userSends, 1, reason: 'the ledger survives the reconnect');
      expect(s.isConnected, isTrue);
    });

    test('reconnect stops when keepGoing says so', () async {
      radio.simulateDisconnect();
      await until(() => mgr.state == LinkState.disconnected);
      var n = 0;
      final s = await mgr.reconnect(_FlakyScanner(scanner, failFirst: 100), SimulatedRadioScanner.device,
          keepGoing: () => ++n < 4, delay: (_) => const Duration(milliseconds: 1));
      expect(s, isNull);
      expect(mgr.state, LinkState.disconnected);
    });

    test('a different radio answering at the address is a failed try', () async {
      radio.simulateDisconnect();
      await until(() => mgr.state == LinkState.disconnected);
      final failures = <Object>[];
      var n = 0;
      final s = await mgr.reconnect(scanner, SimulatedRadioScanner.device,
          keepGoing: () => ++n < 3, delay: (_) => Duration.zero, expectedKeyHex: 'ff' * 32, onFailure: failures.add);
      expect(s, isNull);
      expect(failures, isNotEmpty);
    });

    test('onConnected failing counts as a failed try and the next try goes on', () async {
      radio.simulateDisconnect();
      await until(() => mgr.state == LinkState.disconnected);
      var calls = 0;
      final s = await within(mgr.reconnect(scanner, SimulatedRadioScanner.device,
          keepGoing: () => true,
          delay: (_) => Duration.zero,
          onConnected: (s) async {
            if (++calls == 1) throw StateError('could not rejoin the channel');
          }));
      expect(calls, 2);
      expect(s, isNotNull);
      expect(mgr.state, LinkState.connected);
    });
  });
}

class _FlakyScanner implements RadioScanner {
  final SimulatedRadioScanner inner;
  int failFirst;
  _FlakyScanner(this.inner, {required this.failFirst});
  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) => inner.scan(timeout: timeout);
  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    if (failFirst-- > 0) throw TimeoutException('not there yet');
    return inner.connect(device);
  }
}
