// Contacts and DMs end to end: the real command queue, session and adapter over the simulated radio (which follows the
// firmware's table, auto-add and ACK rules), with a real ChatStore. Time is sped up (timeScale) so a 350 contact download
// that takes ~22 s on a real radio runs in well under a second.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/contact_manager.dart';
import 'package:meshsonar/chat/delivery_text.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/session_adapter.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/crypto.dart' as c;
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/session_manager.dart';
import 'package:meshsonar/radio/simulator.dart';

Future<void> until(bool Function() test, {int ms = 4000, String? why}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $ms ms${why == null ? '' : ': $why'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const fast = RetryPolicy(timeoutFactor: 0.05, slackMs: 20, jitterMs: 0, minWaitMs: 120, maxWaitMs: 400, minGapMs: 0, busyBaseMs: 30, notConnectedRecheckMs: 50);

class Rig {
  final SimulatedRadioScanner scanner;
  final RadioSessionManager mgr;
  late LinkRadioSession session;
  late SimulatedTransport radio;
  late ChatStore store;
  late ChatService chat;
  late RadioSessionChatAdapter adapter;
  String get radioId => session.selfPublicKey!;
  ContactManager get cm => chat.contacts;

  Rig({int extra = 0, int maxContacts = 100, bool autoAdd = true, int pace = 10, double scale = 50, int linkTimeoutMs = 2000})
      : scanner = SimulatedRadioScanner(seed: 3, timeScale: scale, extraContacts: extra, maxContacts: maxContacts, autoAddSupported: autoAdd, contactFramePaceMs: pace),
        mgr = RadioSessionManager(
            linkFactory: (t) => MeshCoreCompanionLink(t, timeout: Duration(milliseconds: linkTimeoutMs), messagePollInterval: const Duration(milliseconds: 80)));

  Future<void> connect({ChatStore? withStore, bool bindAdapter = true, RetryPolicy policy = fast}) async {
    session = await mgr.connect(scanner, SimulatedRadioScanner.device);
    radio = scanner.lastTransport!;
    store = withStore ?? ChatStore.inMemory();
    adapter = RadioSessionChatAdapter(session);
    chat = ChatService(store: store, sink: adapter, selfName: () => 'Me', policy: policy);
    if (bindAdapter) adapter.bind(chat);
  }

  Future<void> close() async {
    await chat.dispose();
    await mgr.dispose();
  }
}

String keyOf(String name) => toHex(SimulatedContact(name).publicKey);

void main() {
  group('contact download', () {
    test('350 contacts: all arrive, progress is reported, an incremental run after it reads nothing, well inside 30 s', () async {
      final rig = Rig(extra: 341, maxContacts: 400);
      await rig.connect(bindAdapter: false);
      final seen = <int>[];
      final sub = rig.chat.contacts.states.listen((s) => seen.add(s.received));
      rig.adapter.bind(rig.chat);
      final sw = Stopwatch()..start();
      await until(() => rig.chat.contacts.state.phase == SyncPhase.idle && rig.chat.contacts.state.lastSyncMs != null, ms: 30000);
      sw.stop();
      expect(rig.store.contacts.count(rig.radioId), 350);
      expect(rig.chat.contacts.state.radioCount, 350);
      expect(rig.chat.contacts.state.capacity, 400);
      expect(rig.store.contacts.countOnRadio(rig.radioId), 350);
      expect(seen.where((n) => n > 0 && n < 350), isNotEmpty, reason: 'progress is visible while it runs');
      expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
      // the second run is the cheap one
      final frames = rig.radio.sentFrames.length;
      await rig.cm.syncNow();
      expect(rig.radio.sentFrames.skip(frames).where((f) => f[0] == Cmd.getContacts), hasLength(1));
      expect(rig.store.contacts.count(rig.radioId), 350);
      await sub.cancel();
      await rig.close();
      // ignore: avoid_print
      print('350 contacts synced in ${sw.elapsedMilliseconds} ms (sim, time x50)');
    });

    test('at the real BLE pace (about 16 frames a second) 350 contacts take about 22 s of radio time', () async {
      // 62 ms between frames, run 25x faster: ~0.9 s of wall time for the ~22 s the user would wait
      final rig = Rig(extra: 341, maxContacts: 400, pace: 62, scale: 25, linkTimeoutMs: 4000);
      await rig.connect();
      await until(() => rig.chat.contacts.state.lastSyncMs != null, ms: 30000);
      expect(rig.store.contacts.count(rig.radioId), 350);
      await rig.close();
    });

    test('repeated runs and a forced full re-read are idempotent', () async {
      final rig = Rig(extra: 40);
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      final before = [for (final c in rig.store.contacts.list(rig.radioId)) (c.publicKey, c.name, c.lat, c.outPathLen)];
      for (var i = 0; i < 3; i++) {
        await rig.cm.syncNow();
      }
      await rig.cm.syncNow(full: true);
      expect([for (final c in rig.store.contacts.list(rig.radioId)) (c.publicKey, c.name, c.lat, c.outPathLen)], before);
      await rig.close();
    });

    test('the link drops half way: what arrived is kept, then a fresh connection completes the list with no duplicates', () async {
      final store = ChatStore.inMemory();
      final rig = Rig(extra: 200, maxContacts: 300);
      await rig.connect(withStore: store, bindAdapter: false);
      rig.radio.dropAfterContactFrames = 90;
      rig.adapter.bind(rig.chat);
      await until(() => rig.cm.state.phase == SyncPhase.failed || rig.cm.state.phase == SyncPhase.offline, ms: 8000, why: 'sync should fail');
      final partial = store.contacts.count(rig.radioId);
      expect(partial, inInclusiveRange(1, 120), reason: 'saved as it came');
      expect(store.db.setting('contacts.cursor:${rig.radioId}'), isNull);
      await rig.chat.dispose();
      await rig.mgr.dispose();

      // the radio comes back (a new link to the same radio) and the same book carries on
      final rig2 = Rig(extra: 200, maxContacts: 300);
      await rig2.connect(withStore: store);
      await until(() => rig2.cm.state.lastSyncMs != null, ms: 8000);
      expect(store.contacts.count(rig2.radioId), 209);
      expect(store.contacts.countOnRadio(rig2.radioId), 209);
      await rig2.close();
    });
  });

  group('new nodes (the radio asks first)', () {
    test('ask-first radio: a new node is offered, never added to the radio; Add puts it on with the advert\'s own time; Ignore hides it', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      await rig.cm.setPolicy(rig.cm.state.policy!.copyWith(askBeforeAdding: true));
      expect(rig.radio.manualAddContacts & 1, 1);
      final tableBefore = rig.radio.contactCount;
      rig.radio.injectNewAdvert('Zed N8ZED', lat: 40.2, lon: -82.9);
      rig.radio.injectNewAdvert('Yan N8YAN');
      await until(() => rig.cm.nearby().length == 2);
      expect(rig.radio.contactCount, tableBefore, reason: 'nothing was added behind the user\'s back');
      expect(rig.store.contacts.get(rig.radioId, keyOf2('Zed N8ZED')), isNull);
      final zed = rig.cm.nearby().firstWhere((a) => a.name == 'Zed N8ZED');
      expect(zed.lat, closeTo(40.2, 1e-6));
      expect(zed.type, ContactType.companion);
      final r = await rig.cm.addNearby(zed);
      expect(r.ok && r.onRadio, isTrue);
      expect(rig.radio.contactCount, tableBefore + 1);
      expect(rig.cm.nearby().map((a) => a.name), ['Yan N8YAN']);
      rig.cm.ignoreNearby(keyOf2('Yan N8YAN'));
      expect(rig.cm.nearby(), isEmpty);
      await rig.close();
    });

    test('auto-add radio (factory): the node is on the radio at once; the phone reads it back, so the book has it', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      rig.radio.injectNewAdvert('Auto N8AUTO');
      await until(() => rig.store.contacts.get(rig.radioId, keyOf2('Auto N8AUTO')) != null);
      final c = rig.store.contacts.get(rig.radioId, keyOf2('Auto N8AUTO'))!;
      expect(c.onRadio, isTrue);
      expect(c.source, ContactSource.radio);
      expect(rig.cm.nearby(), isEmpty);
      expect(rig.cm.shouldOfferAskFirst, isTrue, reason: 'the radio fills itself: offer the user the ask-first switch');
      await rig.close();
    });

    test('per-type auto-add: repeaters still added, people are asked about', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      await rig.cm.setPolicy(rig.cm.state.policy!.copyWith(askBeforeAdding: true, autoAddRepeaters: true));
      expect(rig.radio.autoAddConfig & AutoAddFlags.repeater, AutoAddFlags.repeater);
      rig.radio.injectNewAdvert('Tower R1', type: AdvType.repeater);
      rig.radio.injectNewAdvert('Person P1');
      await until(() => rig.store.contacts.get(rig.radioId, keyOf2('Tower R1')) != null);
      await until(() => rig.cm.nearby().length == 1);
      expect(rig.cm.nearby().single.name, 'Person P1');
      await rig.close();
    });

    test('older firmware without the auto-add commands: the policy says so and the ask-first switch still works', () async {
      final rig = Rig(autoAdd: false);
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      expect(rig.cm.state.policy!.autoAddSupported, isFalse);
      await rig.cm.setPolicy(rig.cm.state.policy!.copyWith(askBeforeAdding: true));
      expect(rig.radio.manualAddContacts & 1, 1);
      await rig.close();
    });

    test('changing the policy hands the radio\'s other settings back unchanged (SET_OTHER_PARAMS overwrites all four)', () async {
      final rig = Rig();
      await rig.connect(bindAdapter: false);
      await rig.session.setContactPolicy((await rig.session.getContactPolicy()).copyWith(askBeforeAdding: true));
      final f = rig.radio.sentFrames.lastWhere((f) => f[0] == Cmd.setOtherParams);
      expect(f.length, 5);
      expect(f[1] & 1, 1);
      await rig.close();
    });
  });

  group('contact commands over the simulated radio', () {
    test('get, remove (true then false), reset path, and that a removed contact cannot be messaged', () async {
      final rig = Rig();
      await rig.connect(bindAdapter: false);
      final ann = keyOf('Ann KE8ANN');
      expect((await rig.session.getContact(ann))!.name, 'Ann KE8ANN');
      expect(await rig.session.getContact('cd' * 32), isNull);
      expect(await rig.session.resetContactPath(ann), isTrue);
      expect(await rig.session.resetContactPath('cd' * 32), isFalse);
      expect(await rig.session.removeContact(ann), isTrue);
      expect(await rig.session.removeContact(ann), isFalse);
      expect((await rig.session.sendContactMessage(ann, 'hi')).failure, SendFailure.noSuchContact);
      await rig.close();
    });

    test('export and share need an advert the radio heard itself; a contact the phone wrote has none', () async {
      final rig = Rig();
      await rig.connect(bindAdapter: false);
      final ann = keyOf('Ann KE8ANN');
      expect(await rig.session.exportContactAdvert(ann), isNull);
      expect(await rig.session.shareContactZeroHop(ann), isFalse);
      rig.radio.injectNewAdvert('Heard H1'); // auto-add: the radio keeps the packet
      await until(() => rig.radio.contactKeys.contains(keyOf2('Heard H1')));
      final raw = await rig.session.exportContactAdvert(keyOf2('Heard H1'));
      expect(raw, isNotNull);
      expect(decodeAdvertPacket(raw!)!.name, 'Heard H1');
      expect(await rig.session.shareContactZeroHop(keyOf2('Heard H1')), isTrue);
      await rig.close();
    });

    test('importing an advert in ask-first mode is answered OK and then pushed as a new node, not added', () async {
      final rig = Rig();
      await rig.connect(bindAdapter: false);
      await rig.session.setContactPolicy((await rig.session.getContactPolicy()).copyWith(askBeforeAdding: true));
      final events = <RadioEvent>[];
      rig.session.events.listen(events.add);
      final key = List<int>.generate(32, (i) => 0x60 + i);
      final before = rig.radio.contactCount;
      await rig.session.importContactAdvert(buildUnsignedAdvertPacket(key, type: 2, name: 'Imported', timestamp: 1760000000, lat: 40, lon: -83));
      await until(() => events.whereType<AdvertHeardEvent>().isNotEmpty);
      final e = events.whereType<AdvertHeardEvent>().single;
      expect((e.isNew, e.contact!.name, e.contact!.type), (true, 'Imported', AdvType.repeater));
      expect(rig.radio.contactCount, before);
      // junk is refused
      await expectLater(rig.session.importContactAdvert(Uint8List.fromList(List.filled(120, 7))), throwsA(isA<CompanionException>()));
      await rig.close();
    });

    test('the radio answers TABLE_FULL to a new contact: RadioTableFull', () async {
      final rig = Rig(maxContacts: 9);
      await rig.connect(bindAdapter: false);
      await expectLater(
          rig.session.addOrUpdateContact(RadioContact(publicKeyHex: 'ef' * 32, type: 1, name: 'No room', outPath: Uint8List(0))), throwsA(isA<RadioTableFull>()));
      await rig.close();
    });
  });

  group('radio table full', () {
    test('a node heard with no room: the state says full, suggestions name who could go, freeing a slot clears it', () async {
      final rig = Rig(maxContacts: 10); // 2 people + 7 repeaters = 9 of 10
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      rig.radio.injectNewAdvert('One N1'); // takes the last slot
      await until(() => rig.store.contacts.get(rig.radioId, keyOf2('One N1')) != null);
      rig.radio.injectNewAdvert('Two N2'); // full: NEW_ADVERT + CONTACTS_FULL
      await until(() => rig.cm.state.tableFull);
      expect(rig.radio.contactCount, 10);
      expect(rig.cm.state.radioCount, 10);
      final cand = rig.cm.cleanupSuggestions();
      expect(cand, isNotEmpty);
      final n = await rig.cm.removeFromRadio([cand.first.contact.publicKey]);
      expect(n, 1);
      expect(rig.cm.state.tableFull, isFalse);
      expect(rig.radio.contactCount, 9);
      expect(rig.store.contacts.count(rig.radioId), 10, reason: 'the phone kept the contact it took off the radio');
      await rig.close();
    });

    test('adding a contact to a full radio frees the least useful slot by itself and tells the user', () async {
      final rig = Rig(maxContacts: 9);
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      expect(rig.radio.contactCount, 9);
      final notice = rig.cm.notices.first;
      final r = await rig.cm.addByKey('ab' * 32, name: 'Newcomer');
      expect(r.onRadio, isTrue);
      expect(rig.radio.contactCount, 9);
      expect((await notice).message, contains('taken off the radio'));
      await rig.close();
    });
  });

  group('direct messages', () {
    test('first DM floods, is acknowledged, the radio learns the route, the phone reads it back, the next DM goes direct', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      final ann = keyOf('Ann KE8ANN');
      final conv = ConvKey.dm(ann.substring(0, 12));
      final m1 = rig.chat.send(radioId: rig.radioId, convKey: conv, text: 'hello Ann');
      await until(() => rig.store.messages.get(m1.id)!.state == MessageState.acked, why: 'first DM acked');
      expect(rig.store.messages.get(m1.id)!.route, Route.flood);
      expect(rig.radio.sentDirect.single.attempt, 0);
      await until(() => rig.store.contacts.get(rig.radioId, ann)!.hasPath, why: 'PUSH_PATH_UPDATED read back');
      expect(rig.store.contacts.get(rig.radioId, ann)!.pathHops, 1);
      final m2 = rig.chat.send(radioId: rig.radioId, convKey: conv, text: 'second one');
      await until(() => rig.store.messages.get(m2.id)!.state == MessageState.acked, why: 'second DM acked');
      expect(rig.store.messages.get(m2.id)!.route, Route.direct);
      expect(rig.store.outbox.attemptsFor(m2.id).single.route, Route.direct);
      expect(rig.store.messages.get(m2.id)!.ackMs, isNotNull);
      expect(rig.store.contacts.get(rig.radioId, ann)!.lastHeardMs, isNotNull);
      await rig.close();
    });

    test('no acknowledgement: three flood tries with the same timestamp, then it gives up with the reason in words', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      rig.radio.dropAcks = true;
      final bob = keyOf('Bob W8BOB');
      final m = rig.chat.send(radioId: rig.radioId, convKey: ConvKey.dm(bob.substring(0, 12)), text: 'anyone there');
      await until(() => rig.store.messages.get(m.id)!.state == MessageState.failed, ms: 8000, why: 'gives up');
      final got = rig.store.messages.get(m.id)!;
      expect(got.failReason, FailReason.noAck);
      expect(rig.radio.sentDirect.map((d) => d.attempt), [0, 1, 2]);
      expect(rig.radio.sentDirect.map((d) => d.timestamp).toSet(), hasLength(1));
      expect(rig.store.outbox.attemptsFor(m.id), hasLength(3));
      expect(describeFailure(got, rig.store.outbox.attemptsFor(m.id)), allOf(contains('3 tries'), contains('flooded')));
      // Retry starts again from zero and, once acks flow, completes; the receiver sees one message (same timestamp)
      rig.radio.dropAcks = false;
      expect(rig.chat.retryFailed(m.id), isTrue);
      await until(() => rig.store.messages.get(m.id)!.state == MessageState.acked, ms: 8000);
      expect(rig.radio.sentDirect.map((d) => d.timestamp).toSet(), hasLength(1));
      await rig.close();
    });

    test('the radio let the contact go: the phone puts it back first, the DM still goes out', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      final ann = keyOf('Ann KE8ANN');
      expect(rig.radio.dropContactSilently(ann), isTrue); // radio forgets, nobody tells the phone
      final m = rig.chat.send(radioId: rig.radioId, convKey: ConvKey.dm(ann.substring(0, 12)), text: 'still reachable?');
      await until(() => rig.store.messages.get(m.id)!.state == MessageState.acked, why: 'delivered after re-adding');
      expect(rig.radio.contactKeys, contains(ann));
      await rig.close();
    });

    test('"always flood" for a contact: even with a saved route the DM floods', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      final ann = keyOf('Ann KE8ANN');
      final conv = ConvKey.dm(ann.substring(0, 12));
      final m1 = rig.chat.send(radioId: rig.radioId, convKey: conv, text: 'learn a route');
      await until(() => rig.store.messages.get(m1.id)!.state == MessageState.acked);
      await until(() => rig.store.contacts.get(rig.radioId, ann)!.hasPath);
      rig.cm.setForceFlood(ann, true);
      final m2 = rig.chat.send(radioId: rig.radioId, convKey: conv, text: 'flood anyway');
      await until(() => rig.store.messages.get(m2.id)!.state == MessageState.acked);
      expect(rig.store.messages.get(m2.id)!.route, Route.flood);
      await rig.close();
    });

    test('"Reset path": the saved route is forgotten on both sides and the next DM floods', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      final ann = keyOf('Ann KE8ANN');
      final conv = ConvKey.dm(ann.substring(0, 12));
      final m1 = rig.chat.send(radioId: rig.radioId, convKey: conv, text: 'learn a route');
      await until(() => rig.store.messages.get(m1.id)!.state == MessageState.acked);
      await until(() => rig.store.contacts.get(rig.radioId, ann)!.hasPath);
      await rig.cm.resetPath(ann);
      expect(rig.store.contacts.get(rig.radioId, ann)!.hasPath, isFalse);
      expect(rig.radio.contactCommandLog, contains('reset $ann'));
      final m2 = rig.chat.send(radioId: rig.radioId, convKey: conv, text: 'after reset');
      await until(() => rig.store.messages.get(m2.id)!.state == MessageState.acked);
      expect(rig.store.messages.get(m2.id)!.route, Route.flood);
      await rig.close();
    });

    test('a DM from a known contact is stored, marks them heard, and a retry of the same text is one row', () async {
      final rig = Rig();
      await rig.connect();
      await until(() => rig.cm.state.lastSyncMs != null);
      final ann = keyOf('Ann KE8ANN');
      expect(rig.radio.injectDirectMessage('Ann KE8ANN', 'on my way', timestamp: 1760000100), isTrue);
      expect(rig.radio.injectDirectMessage('Ann KE8ANN', 'on my way', timestamp: 1760000100), isTrue); // her retry
      await until(() => rig.store.messages.page(ConvKey.dm(ann.substring(0, 12))).messages.isNotEmpty);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(rig.store.messages.page(ConvKey.dm(ann.substring(0, 12))).messages, hasLength(1));
      expect(rig.store.contacts.get(rig.radioId, ann)!.lastHeardMs, isNotNull);
      await rig.close();
    });
  });
}

/// The key the simulator derives for an advert from [name] (simulator.dart injectNewAdvert).
String keyOf2(String name) => toHex(c.sha256(utf8.encode('meshsonar-sim-advert:$name')));
