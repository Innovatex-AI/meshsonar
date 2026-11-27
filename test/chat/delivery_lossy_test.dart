// Direct-message delivery end to end against the scripted lossy radio (test/radio/lossy_radio.dart): the real link, the
// real session, the real adapter, contact manager, outbox and chat service; only the radio and the mesh are scripted.
// Build 77, redesign round 3 part 1: "message routing needs to match the official MeshCore app, nothing extra, nothing
// less". Each test names the rule of the rebuild checklist or the defect (M1-M12) it pins.
//
// Real time, small numbers: the radio estimates 40 ms (direct) and 60 ms (flood), so a try waits 48 or 72 ms, and the
// link's reply timeout is 120 ms.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/contact_manager.dart';
import 'package:meshsonar/chat/db/outbox_repository.dart';
import 'package:meshsonar/chat/delivery_settings.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/outbox.dart';
import 'package:meshsonar/chat/session_adapter.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';

import '../radio/lossy_radio.dart';

const bob = 'b0b0000000000000000000000000000000000000000000000000000000000001';
const carol = 'ca01000000000000000000000000000000000000000000000000000000000002';

Future<void> until(bool Function() test, {int ms = 4000, String? why}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('condition not met in $ms ms${why == null ? '' : ': $why'}');
    await Future<void>.delayed(const Duration(milliseconds: 4));
  }
}

class Rig {
  final LossyRadio radio;
  late final MeshCoreCompanionLink link;
  late final LinkRadioSession session;
  late final ChatStore store;
  late final ChatService chat;
  late final RadioSessionChatAdapter adapter;
  Rig(this.radio);

  String get radioId => radio.publicKeyHex;
  ContactManager get cm => chat.contacts;
  String conv(String key) => ConvKey.dm(key.substring(0, 12));
  ChatMessage msg(String id) => store.messages.get(id)!;
  List<DeliveryAttempt> tries(String id) => store.outbox.attemptsFor(id);

  /// The codes of the commands the app gave the radio from position [from] on, without the message polls.
  List<int> codesFrom(int from) => [for (final f in radio.commands.skip(from)) if (f[0] != Cmd.syncNextMessage) f[0]];

  Future<void> start({ChatStore? withStore, DeliverySettings? settings}) async {
    link = MeshCoreCompanionLink(radio, timeout: const Duration(milliseconds: 120), messagePollInterval: const Duration(hours: 1));
    final info = await link.start();
    session = LinkRadioSession(link, info: info);
    store = withStore ?? ChatStore.inMemory();
    adapter = RadioSessionChatAdapter(session);
    chat = ChatService(
        store: store,
        sink: adapter,
        selfName: () => 'Me',
        policy: const RetryPolicy(minGapMs: 0, noEstimateWaitMs: 70, busyBaseMs: 15, notConnectedRecheckMs: 30));
    if (settings != null) chat.deliverySettings = settings;
    chat.start();
    adapter.bind(chat);
    await until(() => cm.state.lastSyncMs != null, why: 'first contact sync');
    chat.notifyRadioReady();
  }

  ChatMessage send(String key, String text, {bool flood = false}) => chat.send(radioId: radioId, convKey: conv(key), text: text, forceFlood: flood);

  Future<void> settled(String id, MessageState state, {int ms = 4000}) => until(() => msg(id).state == state, ms: ms, why: 'message $id to be ${state.name}, is ${msg(id).state.name}');

  Future<void> close() async {
    await adapter.dispose();
    await chat.dispose();
    await session.close();
  }
}

void main() {
  late Rig rig;
  late LossyRadio radio;
  setUp(() {
    radio = LossyRadio();
    rig = Rig(radio);
  });
  tearDown(() => rig.close());

  group('the tries (rules 4, 7, 9)', () {
    test('4 direct, ONE reset path, 4 flood; try numbers 0..7 untouched; the same timestamp on every try: the bytes of tries 1-8', () async {
      radio
        ..addContact(bob, route: [0x11, 0x22])
        ..confirmAfter = (_) => null; // nobody ever confirms
      await rig.start();
      final from = radio.commands.length;
      final m = rig.send(bob, 'hello bob');
      await rig.settled(m.id, MessageState.failed);

      expect(rig.codesFrom(from), [
        Cmd.sendTxtMsg, Cmd.sendTxtMsg, Cmd.sendTxtMsg, Cmd.sendTxtMsg, //
        Cmd.resetPath, //
        Cmd.sendTxtMsg, Cmd.sendTxtMsg, Cmd.sendTxtMsg, Cmd.sendTxtMsg,
      ], reason: 'nothing else goes to the radio: no contact write, no sync loop, no stats read, no second reset');
      expect(radio.resets.single.key, bob);
      expect(radio.sends.map((s) => s.flood), [false, false, false, false, true, true, true, true], reason: 'the RADIO decided: direct while it held a route');

      // The bytes: [2][txt_type 0][try number][timestamp LE32][6-byte contact prefix][text].
      final ts = m.tsSender;
      final tsBytes = [ts & 0xff, (ts >> 8) & 0xff, (ts >> 16) & 0xff, (ts >> 24) & 0xff];
      // ignore: avoid_print
      print('SEND_TXT_MSG frames of one message, tries 1-8 (hex):');
      for (var i = 0; i < 8; i++) {
        final f = radio.sends[i].frame;
        // ignore: avoid_print
        print('  try ${i + 1}: ${toHex(f)}');
        expect(f, [2, 0, i, ...tsBytes, 0xb0, 0xb0, 0, 0, 0, 0, ...'hello bob'.codeUnits], reason: 'try ${i + 1}');
      }
      expect(radio.sends.map((s) => s.attempt), [0, 1, 2, 3, 4, 5, 6, 7], reason: 'M1: build 76 cut the try number to 0-3, so try 5 was the bytes of try 1');
      expect(radio.sends.map((s) => s.timestamp).toSet(), {ts});
      expect(radio.sends.any((s) => s.droppedAsDuplicate), isFalse, reason: 'eight different packets on the air: none is a packet the mesh has already seen');
      expect(radio.sendHex.toSet(), hasLength(8));

      expect(rig.msg(m.id).failReason, FailReason.noAck);
      final t = rig.tries(m.id);
      expect(t.map((a) => a.attempt), [1, 2, 3, 4, 5, 6, 7, 8]);
      expect(t.map((a) => a.wireAttempt), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(t.map((a) => a.route), [Route.direct, Route.direct, Route.direct, Route.direct, Route.flood, Route.flood, Route.flood, Route.flood]);
      expect(t.every((a) => a.outcome == TryOutcome.noConfirmation), isTrue);
      expect(t.map((a) => a.estTimeoutMs), [40, 40, 40, 40, 60, 60, 60, 60], reason: 'the radio\'s own estimate for each try');
      expect(t.map((a) => a.expectedAck), radio.sends.map((s) => s.ack), reason: 'the phone computes the same confirmation code as the radio');
    });

    test('a contact with no route: every try is a flood because the radio decides that; NO reset is sent', () async {
      radio
        ..addContact(bob)
        ..confirmAfter = (_) => null;
      await rig.start();
      final from = radio.commands.length;
      final m = rig.send(bob, 'anyone there');
      await rig.settled(m.id, MessageState.failed);
      expect(rig.codesFrom(from), List.filled(8, Cmd.sendTxtMsg));
      expect(radio.resets, isEmpty, reason: 'M2: build 76 sent RESET_PATH before every try it classed as a flood');
      expect(radio.sends.every((s) => s.flood), isTrue);
      expect(radio.sends.map((s) => s.attempt), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(rig.tries(m.id).every((a) => a.route == Route.flood && a.routeKnown), isTrue);
    });

    test('M2: a stale "no route" on the PHONE does not wipe the route the radio learned', () async {
      radio.addContact(bob, route: [0x11]);
      await rig.start();
      // The phone missed a path update: its copy says "no route".
      rig.store.contacts.setPath(rig.radioId, bob, null, -1);
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.acked);
      expect(radio.resets, isEmpty);
      expect(radio.contacts[bob]!.hasRoute, isTrue);
      expect(radio.sends.single.flood, isFalse);
      expect(rig.msg(m.id).route, Route.direct, reason: 'rule 11: shown as the radio reported it, not as the phone assumed');
    });

    test('rule 6: the wait for a confirmation is the radio\'s estimate x 1.2', () async {
      radio
        ..addContact(bob)
        ..estFloodMs = 250
        ..confirmAfter = (_) => null;
      await rig.start();
      final m = rig.send(bob, 'hi');
      await until(() => rig.tries(m.id).isNotEmpty && rig.tries(m.id).first.outcome == TryOutcome.waiting);
      final wait = rig.store.outbox.get(m.id)!.dueAtMs - rig.tries(m.id).first.sentAtMs;
      expect(wait, inInclusiveRange(300, 340), reason: '250 ms x 1.2, counted from the radio\'s answer');
      rig.chat.cancel(m.id);
    });

    test('rule 10: settings direct 2 / flood 1, flood fallback off, and Cancel on a message still retrying', () async {
      radio
        ..addContact(bob, route: [0x11])
        ..addContact(carol, route: [0x22])
        ..confirmAfter = (_) => null;
      await rig.start(settings: const DeliverySettings(directTries: 2, floodTries: 1));
      var from = radio.commands.length;
      final m = rig.send(bob, 'two then one');
      await until(() => rig.msg(m.id).attempt >= 1);
      expect(rig.chat.deliveryProgress(m.id).tryCount, 3);
      await rig.settled(m.id, MessageState.failed);
      expect(rig.codesFrom(from), [Cmd.sendTxtMsg, Cmd.sendTxtMsg, Cmd.resetPath, Cmd.sendTxtMsg]);

      rig.chat.deliverySettings = const DeliverySettings(directTries: 3, floodTries: 4, floodFallback: false);
      from = radio.commands.length;
      final m2 = rig.send(carol, 'no fallback');
      await rig.settled(m2.id, MessageState.failed);
      expect(rig.codesFrom(from), [Cmd.sendTxtMsg, Cmd.sendTxtMsg, Cmd.sendTxtMsg], reason: 'fallback off: no reset path, no flood tries');
      expect(radio.contacts[carol]!.hasRoute, isTrue);

      rig.chat.deliverySettings = DeliverySettings.defaults;
      radio.estDirectMs = 400; // slow enough to cancel in the middle
      from = radio.commands.length;
      final m3 = rig.send(carol, 'cancel me');
      await until(() => rig.msg(m3.id).attempt == 2);
      expect(rig.chat.deliveryProgress(m3.id).active, isTrue);
      expect(rig.chat.cancel(m3.id), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(rig.codesFrom(from), [Cmd.sendTxtMsg, Cmd.sendTxtMsg], reason: 'no more tries after Cancel');
      expect(rig.msg(m3.id).failReason, FailReason.cancelled);
    });

    test('long-press Send, flood chosen: one reset path, then the normal send (the official way)', () async {
      radio.addContact(bob, route: [0x11]);
      await rig.start();
      final from = radio.commands.length;
      final m = rig.send(bob, 'by flood please', flood: true);
      await rig.settled(m.id, MessageState.acked);
      expect(rig.codesFrom(from).take(2), [Cmd.resetPath, Cmd.sendTxtMsg]);
      expect(radio.sends.single.flood, isTrue);
      expect(radio.sends.single.attempt, 0);
      expect(rig.msg(m.id).route, Route.flood);
      expect(rig.tries(m.id).single.resetBefore, isTrue);
    });

    test('text limit: 160 bytes go out on tries 1-4 only (158 from the fifth try); the radio is never given a try it would refuse', () async {
      radio
        ..addContact(bob)
        ..confirmAfter = (_) => null;
      await rig.start();
      final m = rig.send(bob, 'x' * 160);
      expect(rig.store.outbox.get(m.id)!.maxAttempts, 4);
      await rig.settled(m.id, MessageState.failed);
      expect(radio.sends.map((s) => s.attempt), [0, 1, 2, 3]);
      final m2 = rig.send(bob, 'y' * 158);
      await rig.settled(m2.id, MessageState.failed);
      expect(radio.sends.skip(4).map((s) => s.attempt), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(() => rig.send(bob, 'z' * 161), throwsA(isA<MessageTooLong>()));
    });
  });

  group('confirmations (rules 5, 8; defects M4, M5, M7)', () {
    test('lost reply: the radio\'s SENT never arrives; the try counts, the next try number follows, the confirmation of the lost try delivers it', () async {
      radio.addContact(bob);
      await rig.start();
      radio
        ..loseReply(Cmd.sendTxtMsg)
        ..confirmAfter = (s) => s.attempt == 0 ? const Duration(milliseconds: 150) : null; // after the 120 ms reply timeout
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.acked);
      final t = rig.tries(m.id);
      expect(t.first.outcome, TryOutcome.confirmed, reason: 'M7: build 76 threw this confirmation away because no try held its code');
      expect(t.first.routeKnown, isFalse, reason: 'the radio never said direct or flood for that try, and the app does not guess');
      expect(radio.sends.first.attempt, 0);
      if (radio.sends.length > 1) expect(radio.sends[1].attempt, 1, reason: 'build 76 resent the same try number after "busy"');
      expect(rig.msg(m.id).failReason, isNull);
    });

    test('late reply: SENT arrives after the timeout and is discarded as a stray; the next try gets its own reply and is confirmed', () async {
      radio.addContact(bob);
      await rig.start();
      radio
        ..delayReply(Cmd.sendTxtMsg, const Duration(milliseconds: 160)) // try 1: its SENT comes 40 ms after the app gave up
        ..delayReply(Cmd.sendTxtMsg, const Duration(milliseconds: 80)) // try 2: in flight when that late SENT lands
        ..confirmAfter = (s) => s.attempt == 1 ? const Duration(milliseconds: 150) : null;
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.acked);
      final t = rig.tries(m.id);
      expect(t.map((a) => a.outcome), [TryOutcome.radioNoAnswer, TryOutcome.confirmed]);
      expect(t.map((a) => a.wireAttempt), [0, 1]);
      expect(t[1].routeKnown, isTrue);
      expect(rig.session.strayFrames, 1, reason: 'M4: before build 77 the late SENT became the reply to the next command and everything shifted by one');
      final log = rig.chat.exportMessageLog(messageId: m.id);
      expect(log, contains('! no reply to SEND_TXT_MSG after 120ms'));
      expect(log, contains('discarded: the late reply to a send that already timed out'));
    });

    test('late confirmation: it arrives after the message was marked Not delivered, and the message becomes Delivered', () async {
      radio.addContact(bob);
      await rig.start(settings: const DeliverySettings(directTries: 2, floodTries: 0));
      radio.confirmAfter = (s) => s.attempt == 1 ? const Duration(milliseconds: 400) : null;
      final m = rig.send(bob, 'slow mesh');
      await rig.settled(m.id, MessageState.failed);
      expect(rig.msg(m.id).failReason, FailReason.noAck);
      await rig.settled(m.id, MessageState.acked);
      expect(rig.msg(m.id).failReason, isNull);
      expect(rig.tries(m.id).map((a) => a.outcome), [TryOutcome.noConfirmation, TryOutcome.confirmed]);
      expect(rig.chat.exportMessageLog(messageId: m.id), contains('it had been marked not delivered'));
    });

    test('confirmation of an earlier try: try 1 is confirmed while try 3 is waiting; delivered, and no further try goes out', () async {
      radio.addContact(bob);
      await rig.start();
      radio.confirmAfter = (s) => s.attempt == 0 ? const Duration(milliseconds: 170) : null; // tries wait 72 ms each
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.acked);
      final t = rig.tries(m.id);
      expect(t.first.outcome, TryOutcome.confirmed);
      expect(t.length, greaterThanOrEqualTo(2), reason: 'later tries were already out');
      expect(t.skip(1).every((a) => a.outcome == TryOutcome.noConfirmation), isTrue);
      final sent = radio.sends.length;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(radio.sends.length, sent, reason: 'delivered: nothing more is sent');
      expect(rig.chat.exportMessageLog(messageId: m.id), contains('matched try 1 (an earlier try)'));
    });

    test('duplicate confirmations and a confirmation nobody asked for change nothing and are logged', () async {
      radio.addContact(bob);
      await rig.start();
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.acked);
      radio
        ..push(encodeSendConfirmed(radio.sends.single.ack, 15))
        ..push(encodeSendConfirmed(0x0badc0de, 15));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(rig.msg(m.id).state, MessageState.acked);
      final log = rig.chat.exportMessageLog();
      expect(log, contains('again for an already delivered message'));
      expect(log, contains('confirmation ack=0badc0de NOT matched'));
    });

    test('rule 13 / M5: no sync loop after a send; between the send and its confirmation the app gives the radio nothing', () async {
      radio.addContact(bob);
      await rig.start();
      await Future<void>.delayed(const Duration(milliseconds: 40)); // the connect-time reads are done
      final from = radio.commands.length;
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.acked);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect([for (final f in radio.commands.skip(from)) f[0]], [Cmd.sendTxtMsg],
          reason: 'build 76 followed every send with a SYNC_NEXT_MESSAGE loop, contact re-reads and a stats probe');
    });
  });

  group('M1: packets the mesh has already seen', () {
    test('a manual retry is a NEW send: new timestamp, try number 0, a packet the mesh has not seen', () async {
      radio
        ..addContact(bob)
        ..confirmAfter = (_) => null;
      await rig.start(settings: const DeliverySettings(directTries: 2, floodTries: 0));
      final m = rig.send(bob, 'please arrive');
      await rig.settled(m.id, MessageState.failed);
      final first = radio.sends.first;
      await Future<void>.delayed(const Duration(milliseconds: 1050)); // the next second
      radio.confirmAfter = (_) => const Duration(milliseconds: 15);
      expect(rig.chat.retryFailed(m.id), isTrue);
      await rig.settled(m.id, MessageState.acked);
      final again = radio.sends.last;
      expect(again.attempt, 0);
      expect(again.timestamp, greaterThan(first.timestamp));
      expect(again.droppedAsDuplicate, isFalse, reason: 'build 76 restarted at try 0 with the OLD timestamp: byte for byte the first packet, dropped by every node');
      expect(toHex(again.frame), isNot(toHex(first.frame)));
      final p = rig.chat.deliveryProgress(m.id);
      expect(p.earlierTries.length, 2);
      expect(p.tries.single.outcome, TryOutcome.confirmed);
    });

    test('the lossy radio itself: a byte-identical packet is dropped by the mesh and never confirmed (what build 76 sent)', () async {
      radio.addContact(bob);
      await rig.start();
      final a = await rig.session.sendContactMessage(bob, 'same', attempt: 0, timestamp: 500);
      final b = await rig.session.sendContactMessage(bob, 'same', attempt: 0, timestamp: 500); // build 76's "Try again"
      final c = await rig.session.sendContactMessage(bob, 'same', attempt: 4, timestamp: 500); // a real fifth try
      expect((a.isAccepted, b.isAccepted, c.isAccepted), (true, true, true), reason: 'the radio says SENT every time');
      expect(radio.sends.map((s) => s.droppedAsDuplicate), [false, true, false]);
    });
  });

  group('incoming (rules 13, 14)', () {
    test('the other side\'s retries arrive as duplicates (same sender, timestamp, text) and are one message; a new text is another', () async {
      radio.addContact(bob);
      await rig.start();
      radio
        ..incomingDm(bob, 'did you get this', timestamp: 1000)
        ..incomingDm(bob, 'did you get this', timestamp: 1000) // their try 2
        ..incomingDm(bob, 'did you get this', timestamp: 1000) // their try 3
        ..incomingDm(bob, 'and this', timestamp: 1001);
      await until(() => rig.store.messages.page(rig.conv(bob)).messages.length >= 2);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final got = rig.store.messages.page(rig.conv(bob)).messages.map((m) => m.text).toList()..sort();
      expect(got, ['and this', 'did you get this']);
      expect(radio.offlineQueue, isEmpty, reason: 'read until the radio said there are no more');
    });

    test('a reply from them does not mark our unconfirmed message delivered (decision D2)', () async {
      radio
        ..addContact(bob)
        ..confirmAfter = (_) => null;
      await rig.start(settings: const DeliverySettings(directTries: 2, floodTries: 0));
      final m = rig.send(bob, 'you there?');
      await until(() => rig.msg(m.id).attempt >= 1);
      radio.incomingDm(bob, 'yes', timestamp: 2000);
      await rig.settled(m.id, MessageState.failed);
      expect(radio.sends.length, 2, reason: 'both tries were made');
    });
  });

  group('contacts on the radio (rules 12, 15, 16; decision D1; defect M3)', () {
    test('not a contact: the radio says NOT_FOUND, the contact is added as NEW with route unknown, the same try is made again', () async {
      await rig.start(); // the radio has no contacts
      rig.store.contacts.upsert(Contact(
          radioId: rig.radioId, publicKey: bob, type: ContactType.companion, name: 'Bob', outPath: Uint8List.fromList([0x77, 0x78]), outPathLen: 2, lastAdvertTs: 1760001234));
      final from = radio.commands.length;
      final m = rig.send(bob, 'first message');
      await rig.settled(m.id, MessageState.acked);
      expect(rig.codesFrom(from).take(4), [Cmd.sendTxtMsg, Cmd.getContactByKey, Cmd.addUpdateContact, Cmd.sendTxtMsg]);
      final w = radio.contactWrites.single;
      expect(w.key, bob);
      expect(w.outPathLen, 0xFF, reason: 'rule 15: "unknown", never "direct", and never the route the phone remembered');
      expect(w.outPath, isEmpty);
      expect(radio.contacts[bob]!.lastAdvert, 1760001234);
      expect(radio.sends.single.attempt, 0, reason: 'a "not a contact" answer uses up no try');
      expect(radio.sends.single.flood, isTrue);
    });

    test('table full: "Your radio\'s contact list is full"; nothing is removed from the radio to make room (D1)', () async {
      radio
        ..maxContacts = 2
        ..addContact(carol, name: 'Carol')
        ..addContact('dd' * 32, name: 'Dave');
      await rig.start();
      rig.store.contacts.upsert(Contact(radioId: rig.radioId, publicKey: bob, type: ContactType.companion, name: 'Bob'));
      final m = rig.send(bob, 'hello');
      await rig.settled(m.id, MessageState.failed);
      expect(rig.msg(m.id).failReason, FailReason.contactListFull);
      expect(rig.msg(m.id).failReason!.describe(), startsWith(radioContactListFullText));
      expect(radioContactListFullText, 'Your radio\'s contact list is full');
      expect(rig.chat.radioContactListFull, isTrue);
      expect(rig.cm.state.tableFull, isTrue);
      expect(radio.commands.where((f) => f[0] == Cmd.removeContact), isEmpty, reason: 'build 76 evicted a little-used contact here');
      expect(radio.contacts.keys, containsAll([carol, 'dd' * 32]));
      expect(radio.sends, isEmpty);
    });

    test('M3: connecting writes NO contact to the radio; the route the radio learned survives a phone with a stale copy', () async {
      radio
        ..addContact(bob, route: [0x42, 0x43], lastAdvert: 1770000000, lat: 39.5, lon: -82.5)
        ..addContact(carol, name: 'Carol');
      final store = ChatStore.inMemory();
      // The phone: Bob as a favourite with a stale route and old advert time; Carol with a route the radio does not have; and
      // a contact with a conversation that the radio does not hold.
      store.contacts
        ..upsert(Contact(radioId: radio.publicKeyHex, publicKey: bob, type: ContactType.companion, name: 'Bob', favourite: true, onRadio: true, outPath: Uint8List.fromList([0x99]), outPathLen: 1, lastAdvertTs: 1700000000))
        ..upsert(Contact(radioId: radio.publicKeyHex, publicKey: carol, type: ContactType.companion, name: 'Carol', onRadio: true, outPath: Uint8List.fromList([0x55]), outPathLen: 1))
        ..upsert(Contact(radioId: radio.publicKeyHex, publicKey: 'ee' * 32, type: ContactType.companion, name: 'Eve', source: ContactSource.manual));
      store.messages.insert(ChatMessage(
          id: 'old', radioId: radio.publicKeyHex, convKind: ConvKind.dm, convKey: ConvKey.dm('ee' * 6), direction: Direction.incoming, tsSender: 1, tsLocalMs: 1, text: 'hi', state: MessageState.received, dedupeKey: 'k'));
      await rig.start(withStore: store);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(radio.contactWrites, isEmpty, reason: 'build 76 pushed the favourite flag and filled the table on every connect, with the phone\'s routes');
      expect(radio.contacts[bob]!.outPath, [0x42, 0x43]);
      expect(radio.contacts[carol]!.hasRoute, isFalse);
      expect(radio.commands.where((f) => f[0] == Cmd.appStart).length, 1, reason: 'no repeated APP_START during the contact sync');
      expect(radio.commands.where((f) => f[0] == Cmd.getStats), isEmpty);
      // The phone's mirror follows the radio.
      expect(store.contacts.get(radio.publicKeyHex, bob)!.routeIds, ['42', '43']);
      expect(store.contacts.get(radio.publicKeyHex, carol)!.hasPath, isFalse);
    });

    test('rule 15: an edit (favourite) reads the radio\'s copy first and writes its route, advert time and position back unchanged', () async {
      radio.addContact(bob, route: [0x42, 0x43], lastAdvert: 1770000000, lat: 39.5, lon: -82.5, flags: 0x10);
      await rig.start();
      // The phone's copy goes stale behind the app's back.
      rig.store.contacts.setPath(rig.radioId, bob, Uint8List.fromList([0x99]), 1);
      final from = radio.commands.length;
      rig.cm.setFavourite(bob, true);
      await until(() => radio.contactWrites.isNotEmpty);
      expect(rig.codesFrom(from), [Cmd.getContactByKey, Cmd.addUpdateContact]);
      final w = radio.contactWrites.single;
      expect(w.outPathLen, 2);
      expect(w.outPath, [0x42, 0x43], reason: 'the radio\'s current route, preserved');
      expect(w.flags, 0x11, reason: 'only the favourite bit changed; the radio\'s other flag bits are kept');
      final c = radio.contacts[bob]!;
      expect((c.lastAdvert, c.lat, c.lon), (1770000000, 39.5, -82.5));
    });

    test('rule 15: adding a contact by hand writes it once, as new, with route unknown', () async {
      await rig.start();
      final r = await rig.cm.addByKey(carol, name: 'Carol');
      expect(r.onRadio, isTrue);
      final w = radio.contactWrites.single;
      expect((w.key, w.outPathLen), (carol, 0xFF));
    });

    test('rule 12: when the radio says a route changed, the app reads that contact again', () async {
      radio
        ..addContact(bob)
        ..learnRouteOnFloodConfirm = true;
      await rig.start();
      final from = radio.commands.length;
      final m = rig.send(bob, 'learn a route');
      await rig.settled(m.id, MessageState.acked);
      await until(() => rig.store.contacts.get(rig.radioId, bob)!.hasPath, why: 'the route read back after PATH_UPDATED');
      expect(rig.codesFrom(from), [Cmd.sendTxtMsg, Cmd.getContactByKey]);
      expect(rig.store.contacts.get(rig.radioId, bob)!.routeIds, ['11']);
      // The next message goes direct, by the radio's decision.
      final m2 = rig.send(bob, 'now direct');
      await rig.settled(m2.id, MessageState.acked);
      expect(radio.sends.last.flood, isFalse);
      expect(rig.msg(m2.id).route, Route.direct);
    });

    test('rule 16: "They need to add you as a contact" until they have confirmed one message from us', () async {
      radio
        ..addContact(bob)
        ..confirmAfter = (_) => null; // their radio cannot decrypt: no confirmation ever
      await rig.start(settings: const DeliverySettings(directTries: 1, floodTries: 0));
      expect(rig.chat.needsToAddYou(rig.radioId, rig.conv(bob)), isTrue);
      final m = rig.send(bob, 'hello?');
      await rig.settled(m.id, MessageState.failed);
      expect(rig.chat.needsToAddYou(rig.radioId, rig.conv(bob)), isTrue);
      expect(needsToAddYouText, 'They need to add you as a contact before they can receive this');
      radio.confirmAfter = (_) => const Duration(milliseconds: 15); // they added us
      final m2 = rig.send(bob, 'hello again');
      await rig.settled(m2.id, MessageState.acked);
      expect(rig.chat.needsToAddYou(rig.radioId, rig.conv(bob)), isFalse);
      // It survives the next contact sync (a fresh copy from the radio does not know it).
      await rig.cm.syncNow(full: true);
      expect(rig.store.contacts.get(rig.radioId, bob)!.everConfirmed, isTrue);
    });
  });

  group('the radio is busy or away', () {
    test('busy (ERR TABLE_FULL, no free packet): the same try number is asked again; no try is used up', () async {
      radio
        ..addContact(bob)
        ..busySends = 2;
      await rig.start();
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.acked);
      expect(radio.commands.where((f) => f[0] == Cmd.sendTxtMsg).map((f) => f[2]), [0, 0, 0], reason: 'two "busy" answers, then it went');
      expect(rig.tries(m.id).single.attempt, 1);
      expect(rig.chat.exportMessageLog(messageId: m.id), contains('the radio is busy (no free packet)'));
    });

    test('busy four times in a row: Not delivered, with that reason', () async {
      radio
        ..addContact(bob)
        ..busySends = 10;
      await rig.start();
      final m = rig.send(bob, 'hi');
      await rig.settled(m.id, MessageState.failed);
      expect(rig.msg(m.id).failReason, FailReason.radioBusy);
      expect(radio.sends, isEmpty);
    });

    test('M11: a radio whose clock is ahead: room posts are stamped from the radio\'s clock, direct messages keep phone time', () async {
      radio
        ..clockAheadSecs = 500
        ..addContact(bob)
        ..addContact(carol, name: 'Room', type: 3);
      await rig.start();
      expect(rig.chat.radioClockAheadSecs, inInclusiveRange(499, 501));
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final dm = rig.send(bob, 'hi');
      final post = rig.chat.send(radioId: rig.radioId, convKey: ConvKey.room(carol.substring(0, 12)), text: 'post');
      expect(dm.tsSender, inInclusiveRange(now - 1, now + 2));
      expect(post.tsSender, inInclusiveRange(now + 498, now + 503));
      expect(rig.chat.exportMessageLog(), contains('Radio clock: '));
      await rig.settled(dm.id, MessageState.acked);
    });
  });

  test('the message log of one failed message: every command, reply code and step, exportable, with no message text', () async {
    radio
      ..addContact(bob, route: [0x11])
      ..confirmAfter = (_) => null;
    await rig.start(settings: const DeliverySettings(directTries: 1, floodTries: 1));
    final m = rig.send(bob, 'PRIVATE WORDS');
    await rig.settled(m.id, MessageState.failed);
    final text = rig.chat.exportMessageLog(messageId: m.id, header: ['App: test build']);
    // ignore: avoid_print
    print(text);
    expect(text, startsWith('MeshSonar message log\n'));
    expect(text, contains('App: test build'));
    expect(text, contains('queued: 2 tries (1 before the reset, fallback on), send 0'));
    expect(text, contains('> SEND_TXT_MSG(2) len=26 type=0 try=0'));
    expect(text, contains('< SENT(6) direct ack='));
    expect(text, contains('try 1 sent direct (the radio said so), est 40ms, waiting 48ms'));
    expect(text, contains('try 1 of 2: no confirmation within the wait'));
    expect(text, contains('> RESET_PATH(13) len=33 key=b0b0'));
    expect(text, contains('< OK(0) len=1 for RESET_PATH'));
    expect(text, contains('reset path before try 2: OK'));
    expect(text, contains('> SEND_TXT_MSG(2) len=26 type=0 try=1'));
    expect(text, contains('< SENT(6) flood ack='));
    expect(text, contains('not delivered: no confirmation after 2 tries'));
    expect(text, isNot(contains('PRIVATE WORDS')));
    expect(text, isNot(contains(bob)));
    expect(rig.chat.log.forMessage(m.id), isNotEmpty);
    expect(rig.chat.log.recent(limit: 5).length, 5);
  });
}
