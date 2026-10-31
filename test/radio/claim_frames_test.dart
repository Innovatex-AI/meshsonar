// Claim frames: byte-exact encoders, decoders, and MeshCoreCompanionLink's login / CLI / status / sign calls against a
// fake radio that speaks the real frame layouts (layouts verified against MeshCore companion_radio/MyMesh.cpp, Oct 31 2026).
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';

import '../support/claim_fakes.dart';

Uint8List b(List<int> v) => Uint8List.fromList(v);

void main() {
  final key = keyBytes(1);
  final keyHex = toHex(key);

  group('command encoders', () {
    test('CMD_SEND_LOGIN = 26 + pub_key[32] + password + NUL, password cut to 15 bytes', () {
      final f = encodeSendLogin(key, 'hunter2');
      expect(f[0], 26);
      expect(f.sublist(1, 33), key);
      expect(f.sublist(33), [...'hunter2'.codeUnits, 0]);
      expect(encodeSendLogin(key, 'a' * 40).length, 1 + 32 + 15 + 1);
      expect(() => encodeSendLogin([1, 2, 3], 'x'), throwsArgumentError);
    });

    test('logout 29, status 27, get contact 30 carry the key', () {
      expect(encodeLogout(key), [29, ...key]);
      expect(encodeSendStatusReq(key), [27, ...key]);
      expect(encodeGetContactByKey(key), [30, ...key]);
    });

    test('CMD_ADD_UPDATE_CONTACT: key, type, flags, out_path_len 0xFF, 64 path bytes, name[32], last_advert, lat, lon', () {
      final f = encodeAddUpdateContact(key, type: AdvType.repeater, name: 'Hill');
      expect(f.length, 144);
      expect(f[0], 9);
      expect(f.sublist(1, 33), key);
      expect(f[33], 2);
      expect(f[34], 0);
      expect(f[35], 0xFF);
      expect(f.sublist(36, 100).every((x) => x == 0), isTrue);
      expect(String.fromCharCodes(f.sublist(100, 104)), 'Hill');
      expect(f[104], 0, reason: 'NUL padded');
    });

    test('CMD_SEND_TXT_MSG: txt_type, attempt, timestamp, 6-byte prefix, text', () {
      final f = encodeSendTxt(txtTypeCliCommand, 0, 0x01020304, key, 'get name');
      expect(f.sublist(0, 3), [2, 3, 0]);
      expect(f.sublist(3, 7), [4, 3, 2, 1]);
      expect(f.sublist(7, 13), key.sublist(0, 6));
      expect(String.fromCharCodes(f.sublist(13)), 'get name');
    });

    test('sign commands are 33, 34+chunk, 35; export self is 17', () {
      expect(encodeSignStart(), [33]);
      expect(encodeSignData([1, 2, 3]), [34, 1, 2, 3]);
      expect(encodeSignFinish(), [35]);
      expect(encodeExportSelfContact(), [17]);
    });
  });

  group('decoders', () {
    test('RESP_CODE_SENT', () {
      final f = decodeFrame(encodeSent(flood: true, tag: 0xAABBCCDD, estTimeoutMs: 1234)) as SentFrame;
      expect(f.flood, isTrue);
      expect(f.tag, 0xAABBCCDD);
      expect(f.estTimeoutMs, 1234);
    });

    test('LOGIN_SUCCESS admin, guest and the legacy 8-byte form (always not admin)', () {
      final a = decodeFrame(encodeLoginSuccess(key, isAdmin: true, firmwareLevel: 2)) as LoginSuccessPush;
      expect(a.isAdmin, isTrue);
      expect(a.prefixHex, keyHex.substring(0, 12));
      expect(a.firmwareLevel, 2);
      expect(a.aclPermissions, 3);
      final g = decodeFrame(encodeLoginSuccess(key, isAdmin: false)) as LoginSuccessPush;
      expect(g.isAdmin, isFalse);
      final legacy = encodeLoginSuccess(key, isAdmin: true, legacy: true);
      expect(legacy.length, 8);
      final l = decodeFrame(legacy) as LoginSuccessPush;
      expect(l.isAdmin, isFalse, reason: 'firmware: legacy is_admin = false');
      expect(l.firmwareLevel, isNull);
    });

    test('LOGIN_FAIL, STATUS_RESPONSE', () {
      expect((decodeFrame(encodeLoginFail(key)) as LoginFailPush).prefixHex, keyHex.substring(0, 12));
      final st = decodeFrame(encodeStatusResponse(key, const RepeaterStatus(
          battMilliVolts: 3900, txQueueLen: 2, noiseFloorDbm: -110, lastRssiDbm: -88, packetsRecv: 100, packetsSent: 50,
          airTimeSecs: 9, upTimeSecs: 86400, lastSnrDb: -3.25))) as StatusResponsePush;
      expect(st.status.battMilliVolts, 3900);
      expect(st.status.noiseFloorDbm, -110);
      expect(st.status.upTimeSecs, 86400);
      expect(st.status.lastSnrDb, -3.25);
      // an older repeater sends fewer fields: the rest read as zero / null, never a crash
      final short = b([Push.statusResponse, 0, ...key.take(6), ...List.filled(28, 0)]);
      expect((decodeFrame(short) as StatusResponsePush).status.lastSnrDb, isNull);
      expect(() => decodeFrame(b([Push.statusResponse, 0, 1, 2, 3, 4, 5, 6])), throwsA(isA<ProtocolException>()));
    });

    test('sign start / signature / export contact / contact', () {
      expect((decodeFrame(encodeSignStartResponse(8192)) as SignStartFrame).maxLen, 8192);
      expect((decodeFrame(encodeSignatureResponse(List.filled(64, 7))) as SignatureFrame).signature, List.filled(64, 7));
      expect(() => decodeFrame(b([Resp.signature, 1, 2])), throwsA(isA<ProtocolException>()));
      expect((decodeFrame(b([Resp.exportContact, 1, 2, 3])) as ExportContactFrame).packet, [1, 2, 3]);
      final c = decodeFrame(encodeContactFrame(key, type: AdvType.repeater, name: 'Hilltop')) as ContactFrame;
      expect(c.name, 'Hilltop');
      expect(c.type, 2);
      expect(c.publicKey, key);
    });

    test('contact text: V3 and pre-V3 forms, CLI_DATA reply text', () {
      final v3 = decodeFrame(encodeContactText(key, '> Hilltop', timestamp: 77, snrDb: 5.5)) as ContactTextFrame;
      expect(v3.text, '> Hilltop');
      expect(v3.txtType, txtTypeCliData);
      expect(v3.prefixHex, keyHex.substring(0, 12));
      expect(v3.timestamp, 77);
      expect(v3.snrDb, 5.5);
      final old = decodeFrame(encodeContactText(key, 'OK', v3: false)) as ContactTextFrame;
      expect(old.text, 'OK');
      expect(old.snrDb, isNull);
      expect(decodeFrame(b([Resp.contactMsgRecv, 1, 2])), isA<ContactMsgFrame>(), reason: 'too short to parse stays the plain frame');
    });
  });

  group('link over a fake radio', () {
    late ClaimFakeTransport radio;
    late FakeRepeater rep;
    late MeshCoreCompanionLink link;

    setUp(() async {
      rep = FakeRepeater(key: key, name: 'Hilltop', adminPassword: 'secret', guestPassword: 'guest');
      radio = await ClaimFakeTransport.create(repeaters: [rep]);
      link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 400));
      await link.start();
    });
    tearDown(() => link.close());

    test('selfPublicKey is SELF_INFO bytes 4-35', () {
      expect(link.selfPublicKey, radio.keyHex);
      expect(link.selfPublicKey!.length, 64);
    });

    test('login before the repeater is a contact: NOT_FOUND maps to noContact; ensureContact adds it once', () async {
      await expectLater(link.login(keyHex, 'secret'), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.noContact)));
      await link.ensureContact(keyHex, nodeType: AdvType.repeater, name: 'Hilltop');
      await link.ensureContact(keyHex, nodeType: AdvType.repeater, name: 'Hilltop');
      expect(radio.sentFrames.where((f) => f[0] == Cmd.addUpdateContact), hasLength(1));
      expect(radio.contacts, contains(keyHex));
    });

    test('contact list full', () async {
      radio.contactsFull = true;
      await expectLater(link.ensureContact(keyHex, nodeType: AdvType.repeater),
          throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.noContact)));
    });

    test('login: admin password -> isAdmin; guest password -> not admin', () async {
      await link.ensureContact(keyHex, nodeType: AdvType.repeater);
      expect((await link.login(keyHex, 'secret')).isAdmin, isTrue);
      expect((await link.login(keyHex, 'guest')).isAdmin, isFalse);
      final sent = radio.sentFrames.firstWhere((f) => f[0] == Cmd.sendLogin);
      expect(sent.sublist(33, sent.length - 1), 'secret'.codeUnits);
    });

    test('login with a wrong password: silence -> ClaimRadioError.silent (this is how a real repeater behaves)', () async {
      await link.ensureContact(keyHex, nodeType: AdvType.repeater);
      await expectLater(link.login(keyHex, 'nope'), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.silent)));
    });

    test('login out of range: silent; LOGIN_FAIL push: radio error', () async {
      await link.ensureContact(keyHex, nodeType: AdvType.repeater);
      rep.inRange = false;
      await expectLater(link.login(keyHex, 'secret'), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.silent)));
      rep.inRange = true;
      rep.failWithPush = true;
      await expectLater(link.login(keyHex, 'bad'), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.radio)));
    });

    test('radio disconnects while waiting for the login push: notConnected', () async {
      await link.ensureContact(keyHex, nodeType: AdvType.repeater);
      rep.inRange = false;
      final f = link.login(keyHex, 'secret');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      radio.drop();
      await expectLater(f, throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.notConnected)));
      expect(link.isConnected, isFalse);
    });

    test('CLI: get name / set name / advert echo through the offline queue', () async {
      await link.ensureContact(keyHex, nodeType: AdvType.repeater);
      await link.login(keyHex, 'secret');
      expect(await link.runCli(keyHex, 'get name'), '> Hilltop');
      expect(await link.runCli(keyHex, 'set name Hilltop MS7K12'), 'OK');
      expect(rep.name, 'Hilltop MS7K12');
      expect(await link.runCli(keyHex, 'advert'), 'OK - Advert sent');
      expect(rep.adverts, ['Hilltop MS7K12']);
      final cli = radio.sentFrames.where((f) => f[0] == Cmd.sendTxtMsg).first;
      expect(cli[1], txtTypeCliCommand);
    });

    test('CLI without an admin session or out of range gets no reply: silent', () async {
      await link.ensureContact(keyHex, nodeType: AdvType.repeater);
      await expectLater(link.runCli(keyHex, 'get name'), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.silent)));
    });

    test('status request returns the counters; null when the repeater is out of range', () async {
      await link.ensureContact(keyHex, nodeType: AdvType.repeater);
      final st = await link.status(keyHex);
      expect(st!.upTimeSecs, 3600);
      expect(st.battMilliVolts, 4100);
      rep.inRange = false;
      expect(await link.status(keyHex), isNull);
    });

    test('sign: the radio signs with its own key and the signature verifies (real Ed25519)', () async {
      final msg = Uint8List.fromList(List<int>.generate(300, (i) => i & 0xff)); // several SIGN_DATA chunks
      final sig = await link.sign(msg);
      expect(sig.length, 64);
      final ok = await cr.Ed25519().verify(msg,
          signature: cr.Signature(sig, publicKey: cr.SimplePublicKey(radio.publicKey, type: cr.KeyPairType.ed25519)));
      expect(ok, isTrue);
      final other = Uint8List.fromList([...msg]..[0] ^= 1);
      expect(
          await cr.Ed25519().verify(other,
              signature: cr.Signature(sig, publicKey: cr.SimplePublicKey(radio.publicKey, type: cr.KeyPairType.ed25519))),
          isFalse);
      expect(radio.sentFrames.where((f) => f[0] == Cmd.signData).length, 3);
    });

    test('sign on firmware without it: unsupported; too long for the radio', () async {
      radio.signUnsupported = true;
      await expectLater(link.sign(b([1])), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.unsupported)));
      radio.signUnsupported = false;
      await expectLater(link.sign(Uint8List(9000)), throwsA(isA<ClaimRadioException>()));
    });

    test('exportSelfAdvert returns the radio\'s advert packet', () async {
      final p = await link.exportSelfAdvert();
      expect(p.sublist(2), radio.publicKey);
    });

    test('commands after the radio dropped: notConnected', () async {
      radio.drop();
      await Future<void>.delayed(Duration.zero);
      await expectLater(link.sign(b([1])), throwsA(isA<ClaimRadioException>().having((e) => e.kind, 'kind', ClaimRadioError.notConnected)));
    });
  });
}
