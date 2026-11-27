// Round 3 rule 2 (defect M4): one command at a time, and each reply is matched to ITS command by reply code. A late or
// stray frame is discarded, never handed to the next command. Before build 77 the next frame from the radio was taken as
// the reply to whatever was waiting, so after one timeout every reply shifted by one: a message the radio did send was
// marked failed and its SENT was swallowed by the next command.
//
// Runs the real link against the scripted lossy radio (lossy_radio.dart). Also: rule 1 (start order), rule 3 (confirmed
// Bluetooth writes, frame size), defect M11 (the clock), and the link side of the message log.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/link_log.dart';
import 'package:meshsonar/radio/message_sync.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';

import 'lossy_radio.dart';

const bob = 'b0b0000000000000000000000000000000000000000000000000000000000001';
const carol = 'ca01000000000000000000000000000000000000000000000000000000000002';

void main() {
  late LossyRadio radio;
  late MeshCoreCompanionLink link;
  final log = <LinkLogEntry>[];

  Future<void> open({Duration timeout = const Duration(milliseconds: 120)}) async {
    link = MeshCoreCompanionLink(radio, timeout: timeout, messagePollInterval: const Duration(hours: 1))..onLog = log.add;
    await link.start();
  }

  setUp(() {
    radio = LossyRadio();
    log.clear();
  });
  tearDown(() => link.close());

  String lines() => log.map((e) => e.toString()).join('\n');

  test('start is DEVICE_QUERY declaring version 3, then APP_START, then the clock', () async {
    await open();
    expect(radio.commands.take(3).map((f) => f[0]), [Cmd.deviceQuery, Cmd.appStart, Cmd.setDeviceTime]);
    expect(radio.commands.first, [Cmd.deviceQuery, 3]);
    expect(radio.appTargetVer, 3);
    expect(link.selfInfo!.publicKey, radio.publicKeyHex);
    expect(link.radioClockAheadSecs, 0);
  });

  test('a clock the radio refuses to set back is read, not ignored: the difference is known and logged (M11)', () async {
    radio.clockAheadSecs = 90;
    await open();
    expect(radio.commands.map((f) => f[0]).take(4), [Cmd.deviceQuery, Cmd.appStart, Cmd.setDeviceTime, Cmd.getDeviceTime]);
    expect(link.radioClockAheadSecs, inInclusiveRange(89, 91));
    expect(lines(), contains('clock: the radio refused the phone time (ILLEGAL_ARG); it is'));
  });

  test('a reply that comes after its command timed out is discarded; the next command gets ITS OWN reply', () async {
    radio.addContact(bob);
    await open();
    // RESET_PATH's OK is held back past the timeout. The next command is GET_CONTACT_BY_KEY, which an OK cannot answer.
    radio.delayReply(Cmd.resetPath, const Duration(milliseconds: 170));
    await expectLater(link.resetContactPath(bob), throwsA(isA<TimeoutException>()));
    radio.delayReply(Cmd.getContactByKey, const Duration(milliseconds: 90));
    final got = await link.getContactByKey(bob); // in flight when the late OK arrives
    expect(got, isNotNull, reason: 'before build 77 the late OK was handed to this command: "unexpected reply OkFrame"');
    expect(got!.publicKeyHex, bob);
    expect(link.strayFrames, 1);
    expect(lines(), contains('! no reply to RESET_PATH after 120ms'));
    expect(lines(), contains('~ OK(0) len=1 discarded: not a reply to GET_CONTACT_BY_KEY'));
  });

  test('a late reply with nothing waiting is discarded too', () async {
    radio.addContact(bob);
    await open();
    radio.delayReply(Cmd.resetPath, const Duration(milliseconds: 150));
    await expectLater(link.resetContactPath(bob), throwsA(isA<TimeoutException>()));
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(link.strayFrames, 1);
    expect(lines(), contains('~ OK(0) len=1 discarded: no command was waiting'));
  });

  test('a send whose SENT comes late: the late SENT does not answer the NEXT send (recognised by its confirmation code)', () async {
    radio.addContact(bob);
    await open();
    radio.delayReply(Cmd.sendTxtMsg, const Duration(milliseconds: 170));
    await expectLater(link.sendContactFrame(bob, 'hi', attempt: 0, timestamp: 1000), throwsA(isA<TimeoutException>()));
    // Try number 1 goes out; the late SENT of try number 0 arrives while it waits for its own (held back 80 ms).
    radio.delayReply(Cmd.sendTxtMsg, const Duration(milliseconds: 80));
    final (f, _) = await link.sendContactFrame(bob, 'hi', attempt: 1, timestamp: 1000);
    expect(f, isA<SentFrame>());
    final own = expectedDmAck(sha256, timestamp: 1000, attempt: 1, text: 'hi', senderPublicKey: radio.publicKey);
    expect((f as SentFrame).tag, own, reason: 'this command\'s own reply, not the earlier try\'s');
    expect(link.strayFrames, 1);
    expect(lines(), contains('discarded: the late reply to a send that already timed out'));
  });

  test('a contact list that stalls: the contact frames that arrive afterwards are strays, not replies to later commands', () async {
    radio
      ..addContact(bob, name: 'Bob')
      ..addContact(carol, name: 'Carol');
    await open(timeout: const Duration(milliseconds: 100));
    radio
      ..stallContactsAfter = 1 // the second CONTACT frame comes late (30 ms after the app gave up), END never
      ..stalledContactDelay = const Duration(milliseconds: 130);
    await expectLater(link.getContacts(), throwsA(isA<TimeoutException>()));
    // GET_CONTACT_BY_KEY for Bob is in flight when Carol's stray CONTACT frame lands: it must not be taken as Bob.
    radio.delayReply(Cmd.getContactByKey, const Duration(milliseconds: 70));
    final c = await link.getContactByKey(bob);
    expect(c!.publicKeyHex, bob);
    expect(c.name, 'Bob');
    expect(link.strayFrames, 1);
    expect(lines(), contains('~ CONTACT(3) key=ca01 path_len=unknown discarded: not a reply to GET_CONTACT_BY_KEY'));
    expect(lines(), contains('! GET_CONTACTS stopped after 1 of 2'));
  });

  test('a popped incoming message is not lost to a shifted reply: SYNC only takes message frames or NO_MORE', () async {
    radio.addContact(bob);
    await open();
    final got = <InboundMessage>[];
    link.inboundMessages.listen(got.add);
    radio.delayReply(Cmd.resetPath, const Duration(milliseconds: 150));
    await expectLater(link.resetContactPath(bob), throwsA(isA<TimeoutException>()));
    radio.incomingDm(bob, 'still here', timestamp: 77); // MSG_WAITING: a drain starts; the late OK lands in the middle
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(got.map((m) => m.text), ['still here']);
    expect(link.strayFrames, 1);
  });

  test('no message sync is started after a send (rule 13): SYNC only on MSG_WAITING and on connect', () async {
    radio.addContact(bob);
    await open();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final before = radio.commands.where((f) => f[0] == Cmd.syncNextMessage).length;
    expect(before, 1, reason: 'the one drain on connect');
    await link.sendContactFrame(bob, 'hi', timestamp: 5);
    await link.sendChannelFrame(0, 'hello');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(radio.commands.where((f) => f[0] == Cmd.syncNextMessage).length, before, reason: 'build 76 drained after every send');
    radio.incomingDm(bob, 'yo', timestamp: 9);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(radio.commands.where((f) => f[0] == Cmd.syncNextMessage).length, before + 2, reason: 'the push: one message, then NO_MORE');
  });

  test('the backup message poll holds off while a direct message waits for its confirmation', () async {
    var hold = true;
    var asked = 0;
    final src = _CountingSource(() => asked++);
    final sync = MessageSync(src, pollInterval: const Duration(milliseconds: 20))..holdPoll = () => hold;
    final sub = sync.messages.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(asked, 0, reason: 'held: no poll frames next to the confirmation push');
    sync.requestDrain(); // a MSG_WAITING push is never held
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(asked, 1);
    hold = false;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(asked, greaterThan(1));
    await sub.cancel();
    sync.dispose();
    radio.addContact(bob);
    await open();
    expect(link.awaitingConfirmation, isFalse);
    radio.confirmAfter = (_) => null;
    await link.sendContactFrame(bob, 'hi', timestamp: 5);
    expect(link.awaitingConfirmation, isTrue, reason: 'for the radio\'s estimate x 1.2 after its SENT');
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(link.awaitingConfirmation, isFalse);
  });

  test('the session passes the try number through and remembers whose confirmation a code is, also when SENT was lost', () async {
    radio.addContact(bob);
    await open();
    final session = LinkRadioSession(link, info: link.selfInfo);
    final events = <RadioEvent>[];
    session.events.listen(events.add);
    radio.loseReply(Cmd.sendTxtMsg);
    final r = await session.sendContactMessage(bob, 'hi', attempt: 6, timestamp: 4242);
    expect(r.status, SendStatus.queued, reason: 'no answer: it may still have gone out');
    expect(radio.sends.single.attempt, 6);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final ev = events.whereType<SendConfirmedEvent>().single;
    expect(ev.ack, radio.sends.single.ack);
    expect(ev.contactKeyHex, bob, reason: 'the code was computed on the phone before the send');
    expect(session.strayFrames, 0);
    expect(session.radioClockAheadSecs, 0);
    expect((await session.cachedContactPolicy()).askBeforeAdding, isFalse);
    expect(radio.commands.where((f) => f[0] == Cmd.appStart).length, 1, reason: 'the cached policy read sends no second APP_START');
  });

  group('message log, link side', () {
    test('one line per command and per reply code; a send shows its try number, never its text', () async {
      radio.addContact(bob);
      await open();
      await link.sendContactFrame(bob, 'TOP-SECRET-TEXT', attempt: 3, timestamp: 1234);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final all = lines();
      expect(all, contains('> DEVICE_QUERY(22) len=2 ver=3'));
      expect(all, contains('< DEVICE_INFO(13)'));
      expect(all, contains('> SEND_TXT_MSG(2) len=28 type=0 try=3 ts=1234 to=b0b0 text=15b'));
      expect(all, matches(RegExp(r'< SENT\(6\) flood ack=[0-9a-f]{8} est=60ms for SEND_TXT_MSG after \d+ms')));
      expect(all, matches(RegExp(r'\* SEND_CONFIRMED\(0x82\) ack=[0-9a-f]{8} trip=15ms')));
      expect(all, isNot(contains('TOP-SECRET-TEXT')));
      expect(all, isNot(contains(bob)), reason: 'a contact appears as 4 hex characters, never its whole key');
    });

    test('the describe functions never print a payload: channel text, a PIN, a login password, a contact name, a private key', () {
      final secret = Uint8List.fromList(List<int>.generate(16, (i) => 0xC0 + i));
      final frames = <Uint8List>[
        encodeSendChannelText(2, 99, 'CHANNEL-WORDS'),
        encodeSetChannel(1, 'PrivateGroup', secret),
        encodeSendLogin(fromHex(bob), 'hunter2'),
        encodeSetDevicePin(123456),
        encodeAddUpdateContact(fromHex(bob), type: 1, name: 'Bob Real Name', lat: 39.9, lon: -82.9),
        encodeImportPrivateKey(List<int>.filled(64, 0xEE)),
        encodeRunCliCommand('set password s3cret'),
      ];
      for (final f in frames) {
        final line = describeCommandForLog(f);
        for (final bad in ['CHANNEL-WORDS', 'PrivateGroup', 'hunter2', '123456', 'Bob Real Name', 's3cret', 'eeee', 'c0c1', '39.9']) {
          expect(line, isNot(contains(bad)), reason: line);
        }
        expect(line, contains('len=${f.length}'));
      }
      expect(describeCommandForLog(encodeSendChannelText(2, 99, 'CHANNEL-WORDS')), 'SEND_CHANNEL_TXT_MSG(3) len=20 slot=2 ts=99 text=13b');
      expect(describeReplyForLog(encodePrivateKey(List<int>.filled(64, 0xEE))), 'PRIVATE_KEY(14) len=65');
      expect(describeReplyForLog(encodeContactText(fromHex(bob), 'incoming words', txtType: 0, timestamp: 5)), startsWith('CONTACT_MSG_RECV_V3(16) from=b0b0 len='));
      expect(describeReplyForLog(encodeErr(ErrCode.tableFull)), 'ERR(1) TABLE_FULL');
    });
  });

  group('Bluetooth writes (rule 3)', () {
    test('a confirmed write whenever the radio allows one (build 76 wrote unconfirmed whenever it could)', () {
      expect(planBleWrite(frameBytes: 40, canWriteWithResponse: true, canWriteWithoutResponse: true), isTrue);
      expect(planBleWrite(frameBytes: 40, canWriteWithResponse: true, canWriteWithoutResponse: false), isTrue);
      expect(planBleWrite(frameBytes: 40, canWriteWithResponse: false, canWriteWithoutResponse: true), isFalse, reason: 'only when the radio offers nothing else');
    });

    test('a frame longer than the link carries is refused, not written and lost', () {
      expect(planBleWrite(frameBytes: 173, canWriteWithResponse: true, canWriteWithoutResponse: true, maxWriteBytes: 182), isTrue);
      expect(() => planBleWrite(frameBytes: 173, canWriteWithResponse: true, canWriteWithoutResponse: true, maxWriteBytes: 20),
          throwsA(isA<FrameTooLongForLink>().having((e) => e.maxBytes, 'max', 20).having((e) => e.frameBytes, 'frame', 173)));
      expect(planBleWrite(frameBytes: 173, canWriteWithResponse: true, canWriteWithoutResponse: true, maxWriteBytes: null), isTrue, reason: 'unknown size: as before');
    });

    test('the session reports a frame that does not fit as "too long", with the numbers', () async {
      final small = _SmallLink(radio, 60);
      radio.addContact(bob);
      link = MeshCoreCompanionLink(small, timeout: const Duration(milliseconds: 120), messagePollInterval: const Duration(hours: 1));
      await link.start();
      final session = LinkRadioSession(link, info: link.selfInfo);
      final r = await session.sendContactMessage(bob, 'x' * 100, timestamp: 1);
      expect(r.failure, SendFailure.tooLong);
      expect(r.detail, allOf(contains('60'), contains('113')));
      expect(radio.sends, isEmpty);
    });
  });
}

class _CountingSource implements MessageSource {
  final void Function() onAsk;
  _CountingSource(this.onAsk);
  @override
  bool get isConnected => true;
  @override
  Future<Frame> syncNextMessage() async {
    onAsk();
    return decodeFrame(encodeNoMoreMessages());
  }
}

/// A transport whose link carries at most [maxWrite] bytes per write.
class _SmallLink implements ByteTransport {
  final LossyRadio inner;
  final int maxWrite;
  _SmallLink(this.inner, this.maxWrite);
  @override
  Stream<Uint8List> get incoming => inner.incoming;
  @override
  bool get isConnected => inner.isConnected;
  @override
  Future<void> disconnect() => inner.disconnect();
  @override
  Future<void> send(Uint8List frame) async {
    planBleWrite(frameBytes: frame.length, canWriteWithResponse: true, canWriteWithoutResponse: true, maxWriteBytes: maxWrite);
    return inner.send(frame);
  }
}
