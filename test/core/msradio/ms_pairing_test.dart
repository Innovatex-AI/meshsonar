// MeshSonar radio pairing (brief section B; meshsonar-firmware docs/APP-INTEGRATION.md section 3): the contract's test
// vector, the whole signed and approval flows on a fake radio (MockClient), and the signing guard.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cr;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/msradio/msradio.dart';
import 'package:meshsonar/core/person_identity.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/crypto.dart';

Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));

/// A clock that moves only when the flow waits.
class FakeTime {
  DateTime now = DateTime.utc(2026, 11, 28, 12);
  final List<Duration> waits = [];
  DateTime call() => now;
  Future<void> wait(Duration d) async {
    waits.add(d);
    now = now.add(d);
  }
}

class Rig {
  final FakeMsRadio radio;
  final FakeTime time;
  final MsAppNonces nonces;
  final MsTokenStore tokens;
  final InMemoryMsSecretKv kv;
  final MsRadioDiscovery discovery;
  final List<Uint8List> signed = [];
  Rig._(this.radio, this.time, this.nonces, this.tokens, this.kv, this.discovery);

  factory Rig({FakeMsRadio? radio}) {
    final t = FakeTime();
    final r = radio ?? FakeMsRadio(clock: t.call);
    final kv = InMemoryMsSecretKv();
    return Rig._(r, t, MsAppNonces(clock: t.call, random: math.Random(3)), MsTokenStore(kv), kv,
        MsRadioDiscovery(client: r.client, browser: r.browser, addresses: InMemoryMsAddressStore()));
  }

  MsPairingFlow flow({MsSigner? sign, bool noSign = false, String? key}) => MsPairingFlow(
        radioKey: key ?? radio.keyHex,
        discovery: discovery,
        tokens: tokens,
        nonces: nonces,
        sign: noSign
            ? null
            : sign ??
                (d) async {
                  signed.add(d);
                  return radio.sign(d);
                },
        apiFactory: (base) => MsRadioApi(baseUrl: base, client: radio.client, wait: time.wait),
        clock: time.call,
        wait: time.wait,
      );
}

void main() {
  group('contract test vector (APP-INTEGRATION.md 3.1)', () {
    test('hello_sig and pair_sig verify against key; the texts are what the app builds', () async {
      expect(msHelloText(MsTestVector.key, MsTestVector.appNonce, MsTestVector.nonce), MsTestVector.hello);
      expect(msPairText(MsTestVector.key, MsTestVector.nonce, MsTestVector.appNonce), MsTestVector.pair);
      expect(await msVerifyEd25519(MsTestVector.key, utf8.encode(MsTestVector.hello), MsTestVector.helloSig), isTrue);
      expect(await msVerifyEd25519(MsTestVector.key, utf8.encode(MsTestVector.pair), MsTestVector.pairSig), isTrue);
      expect(await msVerifyEd25519(MsTestVector.key.toUpperCase(), utf8.encode(MsTestVector.pair), MsTestVector.pairSig.toUpperCase()), isTrue);
      // crossed or changed texts do not verify
      expect(await msVerifyEd25519(MsTestVector.key, utf8.encode(MsTestVector.pair), MsTestVector.helloSig), isFalse);
      expect(await msVerifyEd25519(MsTestVector.key, utf8.encode('${MsTestVector.hello}x'), MsTestVector.helloSig), isFalse);
      expect(await msVerifyEd25519('00' * 32, utf8.encode(MsTestVector.hello), MsTestVector.helloSig), isFalse);
      expect(await msVerifyEd25519(MsTestVector.key, utf8.encode(MsTestVector.hello), 'zz'), isFalse);
    });

    test('the seed 00..1f gives the vector key and signatures (the fake radio and the simulator use it)', () async {
      final kp = await cr.Ed25519().newKeyPairFromSeed(MsTestVector.seed);
      expect(toHex((await kp.extractPublicKey()).bytes), MsTestVector.key);
      final r = FakeMsRadio();
      expect(toHex(await r.sign(b(MsTestVector.hello))), MsTestVector.helloSig);
      expect(toHex(await r.sign(b(MsTestVector.pair))), MsTestVector.pairSig);
    });
  });

  group('signablePairText guard', () {
    final key = MsTestVector.key;
    late FakeTime t;
    late MsAppNonces n;
    setUp(() {
      t = FakeTime();
      n = MsAppNonces(clock: t.call, random: math.Random(1));
    });

    test('accepts exactly the pairing text for this key with a fresh app nonce, once', () {
      final an = n.issue();
      expect(an, matches(RegExp(r'^[0-9a-f]{32}$')));
      final text = 'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:$an';
      expect(signablePairText(b(text), key, nonces: n), text);
      expect(signablePairText(b(text), key, nonces: n), isNull, reason: 'a nonce is signed at most once');
    });

    test('the key argument may be upper case; the text may not', () {
      final an = n.issue();
      final text = 'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:$an';
      expect(signablePairText(b(text), key.toUpperCase(), nonces: n), text);
      final an2 = n.issue();
      expect(signablePairText(b('meshsonar-app-pair:v1:${key.toUpperCase()}:${MsTestVector.nonce}:$an2'), key, nonces: n), isNull);
      expect(signablePairText(b('meshsonar-app-pair:v1:$key:${MsTestVector.nonce.toUpperCase()}:$an2'), key, nonces: n), isNull);
      expect(signablePairText(b('meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:${an2.toUpperCase()}'), key, nonces: n), isNull);
    });

    test('refuses every other text', () {
      final an = n.issue();
      final good = 'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:$an';
      final bad = <String>[
        // the login-proof text (signableProofText's format)
        'meshsonar-login:v1:meshsonar.com:connect:$key:${'ab' * 16}:1795000000',
        // a broker login token
        'v1_$key',
        'v1_${MsTestVector.pair}',
        // the hello text (the radio signs that one, never the app)
        'meshsonar-app-hello:v1:$key:$an:${MsTestVector.nonce}',
        // another radio's key
        'meshsonar-app-pair:v1:${'cd' * 32}:${MsTestVector.nonce}:$an',
        // wrong version / purpose / shape
        'meshsonar-app-pair:v2:$key:${MsTestVector.nonce}:$an',
        'meshsonar-app-pairx:v1:$key:${MsTestVector.nonce}:$an',
        '$good:extra',
        '$good ',
        ' $good',
        '${good}x',
        'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}',
        'meshsonar-app-pair:v1:$key:${MsTestVector.nonce.substring(2)}:$an',
        'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:${an.substring(2)}',
        'meshsonar-app-pair:v1:$key:${'zz' * 16}:$an',
        // nonces swapped (the app nonce must be the LAST field)
        'meshsonar-app-pair:v1:$key:$an:${MsTestVector.nonce}',
        '',
      ];
      for (final s in bad) {
        expect(signablePairText(b(s), key, nonces: n), isNull, reason: s);
      }
      expect(signablePairText(Uint8List.fromList([0xff, 0xfe, 0xfd]), key, nonces: n), isNull);
      // the good one still works afterwards (nothing above used the nonce up)
      expect(signablePairText(b(good), key, nonces: n), good);
    });

    test('refuses a nonce the app did not issue', () {
      expect(signablePairText(b(MsTestVector.pair), key, nonces: n), isNull);
    });

    test('refuses a stale nonce (2 minutes)', () {
      final an = n.issue();
      final text = 'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:$an';
      t.now = t.now.add(const Duration(minutes: 1, seconds: 59));
      expect(n.isFresh(an), isTrue);
      t.now = t.now.add(const Duration(seconds: 1));
      expect(signablePairText(b(text), key, nonces: n), isNull);
    });

    test('refuses a bad key argument', () {
      final an = n.issue();
      final text = 'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:$an';
      expect(signablePairText(b(text), key.substring(2), nonces: n), isNull);
      expect(signablePairText(b(text), '', nonces: n), isNull);
    });

    test('the login-proof guard is unchanged and refuses the pairing text', () {
      final an = n.issue();
      final pair = 'meshsonar-app-pair:v1:$key:${MsTestVector.nonce}:$an';
      expect(signableProofText(b(pair), key), isNull);
      final login = 'meshsonar-login:v1:meshsonar.com:connect:$key:${'ab' * 16}:1795000000';
      expect(signableProofText(b(login), key), login);
    });
  });

  group('signed pairing on the fake radio', () {
    test('the whole flow: finding -> starting -> verifyingRadio -> signing -> finishing -> paired; token stored', () async {
      final rig = Rig();
      final f = rig.flow();
      final steps = <MsPairStep>[];
      f.states.listen((s) => steps.add(s.step));
      final r = await f.pairSigned();
      expect(r.step, MsPairStep.paired, reason: r.message);
      expect(r.via, 'sign');
      await Future<void>.delayed(Duration.zero); // broadcast events arrive in a microtask
      expect(steps, containsAllInOrder([MsPairStep.finding, MsPairStep.starting, MsPairStep.verifyingRadio, MsPairStep.signing, MsPairStep.finishing, MsPairStep.paired]));
      final token = await rig.tokens.read(rig.radio.keyHex);
      expect(token, isNotNull);
      expect(rig.radio.issuedTokens, contains(token));
      expect(f.api!.token, token);
      // the radio signed exactly the text the app built
      expect(rig.signed, hasLength(1));
      expect(utf8.decode(rig.signed.single), rig.radio.lastFinishText);
      expect(utf8.decode(rig.signed.single), startsWith('meshsonar-app-pair:v1:${MsTestVector.key}:'));
      // the token works
      final st = await f.api!.status();
      expect(st.device!.key, MsTestVector.key);
      expect(rig.radio.requests.where((q) => q.startsWith('GET /api/app/v1/info')), isNotEmpty, reason: '/info key check first');
    });

    test('a known address is confirmed with /info before pairing', () async {
      final rig = Rig();
      final r = await rig.flow().pairSigned(address: '192.168.1.77');
      expect(r.paired, isTrue);
      expect(rig.radio.requests.first, 'GET /api/app/v1/info');
    });

    test('wrong key in /info: wrongRadio, nothing signed, no pair/start', () async {
      final rig = Rig();
      rig.radio.infoKeyOverride = 'cd' * 32;
      final r = await rig.flow().pairSigned(address: '192.168.1.99');
      expect(r.step, MsPairStep.wrongRadio);
      expect(r.message, 'This is not the radio you are connected to.');
      expect(rig.signed, isEmpty);
      expect(rig.radio.requests.where((q) => q.contains('pair/start')), isEmpty);
    });

    test('bad radio_sig: wrongRadio before anything is signed', () async {
      final rig = Rig();
      rig.radio.badRadioSig = true;
      final r = await rig.flow().pairSigned();
      expect(r.step, MsPairStep.wrongRadio);
      expect(rig.signed, isEmpty);
      expect(rig.radio.requests.where((q) => q.contains('pair/finish')), isEmpty);
      expect(await rig.tokens.read(rig.radio.keyHex), isNull);
    });

    test('a radio that signs hello with ANOTHER key than the Bluetooth key: wrongRadio', () async {
      // the Wi-Fi radio holds another key but claims the Bluetooth key in /info and pair/start
      final other = FakeMsRadio(seed: Uint8List.fromList(List<int>.filled(32, 9)));
      await other.ready();
      other.infoKeyOverride = MsTestVector.key;
      final rig = Rig(radio: other);
      final r = await rig.flow(key: MsTestVector.key).pairSigned(address: '192.168.1.77');
      expect(r.step, MsPairStep.wrongRadio);
      expect(rig.signed, isEmpty);
    });

    test('a sign_text that differs from the app\'s own text: nothing is signed', () async {
      final rig = Rig();
      rig.radio.signTextOverride = 'v1_please-sign-me';
      final r = await rig.flow().pairSigned();
      expect(r.step, MsPairStep.failed);
      expect(rig.signed, isEmpty);
    });

    test('410 on finish: expired, no token', () async {
      final rig = Rig();
      rig.radio.finishStatus = 410;
      final r = await rig.flow().pairSigned();
      expect(r.step, MsPairStep.expired);
      expect(r.message, 'That pairing request expired. Start again.');
      expect(await rig.tokens.read(rig.radio.keyHex), isNull);
    });

    test('403 on finish (bad signature): refused', () async {
      final rig = Rig();
      final r = await rig.flow(sign: (d) async => Uint8List(64)).pairSigned();
      expect(r.step, MsPairStep.refused);
      expect(r.message, 'Bad signature.');
    });

    test('429: rateLimited', () async {
      final rig = Rig();
      rig.radio.rateLimited = true;
      final r = await rig.flow().pairSigned();
      expect(r.step, MsPairStep.rateLimited);
      expect(rig.signed, isEmpty);
    });

    test('the Bluetooth sign fails: signFailed', () async {
      final rig = Rig();
      final r = await rig.flow(sign: (d) async => throw const ClaimRadioException(ClaimRadioError.notConnected, 'gone')).pairSigned();
      expect(r.step, MsPairStep.signFailed);
      expect(rig.radio.requests.where((q) => q.contains('pair/finish')), isEmpty);
    });

    test('no Bluetooth signer: signFailed, pointing to approval', () async {
      final rig = Rig();
      final r = await rig.flow(noSign: true).pairSigned();
      expect(r.step, MsPairStep.signFailed);
      expect(r.message, contains('Ask on the radio'));
    });

    test('not on Wi-Fi: notOnWifi', () async {
      final rig = Rig();
      rig.radio.offline = true;
      final r = await rig.flow().pairSigned();
      expect(r.step, MsPairStep.notOnWifi);
    });

    test('signing goes through the guard: a nonce that went stale while signing is not signed', () async {
      final rig = Rig();
      // the radio takes so long to answer pair/start that the app nonce is 2 minutes old when the guard runs
      final f = MsPairingFlow(
        radioKey: rig.radio.keyHex,
        discovery: rig.discovery,
        tokens: rig.tokens,
        nonces: rig.nonces,
        sign: (d) async {
          rig.signed.add(d);
          return rig.radio.sign(d);
        },
        apiFactory: (base) => _SlowStartApi(base, rig),
        clock: rig.time.call,
        wait: rig.time.wait,
      );
      final r = await f.pairSigned();
      expect(r.step, MsPairStep.failed);
      expect(rig.signed, isEmpty);
    });
  });

  group('approval pairing on the fake radio', () {
    test('yes: asking -> waiting -> paired, polled every 1.5 s', () async {
      final rig = Rig();
      rig.radio.askAfterPolls = 3;
      final f = rig.flow(noSign: true);
      final steps = <MsPairStep>[];
      f.states.listen((s) => steps.add(s.step));
      final r = await f.pairByApproval();
      expect(r.step, MsPairStep.paired);
      expect(r.via, 'approve');
      await Future<void>.delayed(Duration.zero);
      expect(steps, containsAllInOrder([MsPairStep.finding, MsPairStep.asking, MsPairStep.waiting, MsPairStep.paired]));
      expect(rig.time.waits, everyElement(const Duration(milliseconds: 1500)));
      expect(rig.time.waits, hasLength(3));
      expect(await rig.tokens.read(rig.radio.keyHex), isNotNull);
    });

    test('no: refused', () async {
      final rig = Rig();
      rig.radio.askAnswer = FakeAskAnswer.no;
      final r = await rig.flow(noSign: true).pairByApproval();
      expect(r.step, MsPairStep.refused);
      expect(await rig.tokens.read(rig.radio.keyHex), isNull);
    });

    test('locked: locked', () async {
      final rig = Rig();
      rig.radio.askAnswer = FakeAskAnswer.locked;
      final r = await rig.flow(noSign: true).pairByApproval();
      expect(r.step, MsPairStep.locked);
    });

    test('a locked radio says locked at once', () async {
      final rig = Rig();
      rig.radio.locked = true;
      final r = await rig.flow(noSign: true).pairByApproval();
      expect(r.step, MsPairStep.locked);
      expect(rig.time.waits, hasLength(1));
    });

    test('no answer: expired after the 60 s window', () async {
      final rig = Rig();
      rig.radio.askAnswer = FakeAskAnswer.wait;
      final r = await rig.flow(noSign: true).pairByApproval();
      expect(r.step, MsPairStep.expired);
      final waited = rig.time.waits.fold(Duration.zero, (a, b) => a + b);
      expect(waited, greaterThanOrEqualTo(const Duration(seconds: 60)));
      expect(waited, lessThan(const Duration(seconds: 62)));
    });

    test('another device already waiting: failed with the radio\'s text', () async {
      final rig = Rig();
      rig.radio.askBusy = true;
      final r = await rig.flow(noSign: true).pairByApproval();
      expect(r.step, MsPairStep.failed);
      expect(r.message, 'Another device is already waiting for an answer.');
    });

    test('cancel stops the poll', () async {
      final rig = Rig();
      rig.radio.askAnswer = FakeAskAnswer.wait;
      late MsPairingFlow f;
      f = MsPairingFlow(
        radioKey: rig.radio.keyHex,
        discovery: rig.discovery,
        tokens: rig.tokens,
        nonces: rig.nonces,
        apiFactory: (base) => MsRadioApi(baseUrl: base, client: rig.radio.client),
        clock: rig.time.call,
        wait: (d) async {
          await rig.time.wait(d);
          if (rig.time.waits.length == 2) f.cancel();
        },
      );
      final r = await f.pairByApproval();
      expect(r.step, MsPairStep.cancelled);
    });
  });
}

/// An API whose pair/start answers after the app nonce has gone stale (3 minutes of fake time).
class _SlowStartApi extends MsRadioApi {
  final Rig rig;
  _SlowStartApi(Uri base, this.rig) : super(baseUrl: base, client: rig.radio.client);

  @override
  Future<MsPairStart> pairStart({required String appNonce, required String app}) async {
    final s = await super.pairStart(appNonce: appNonce, app: app);
    rig.time.now = rig.time.now.add(const Duration(minutes: 3));
    return s;
  }
}
