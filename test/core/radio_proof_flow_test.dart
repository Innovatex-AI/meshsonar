// Radio proof at connect (ID step 2): every outcome, end to end over the real companion link frames with a fake radio that signs
// with a real Ed25519 key, and a fake server that verifies the signature. Time is faked for the polling.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/person_identity.dart';
import 'package:meshsonar/core/radio_proof_flow.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/protocol.dart';

import '../support/claim_fakes.dart';
import '../support/proof_fakes.dart';

void main() {
  late ClaimFakeTransport radio;
  late MeshCoreCompanionLink link;
  late FakeProofClient server;
  late FakeClock clock;

  setUp(() async {
    radio = await ClaimFakeTransport.create();
    link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
    await link.start();
    server = FakeProofClient();
    clock = FakeClock(DateTime.now());
  });
  tearDown(() => link.close());

  RadioProofFlow flow() => RadioProofFlow(radio: link, client: server, driverKey: 'DRIVERKEY', now: clock.now, wait: clock.wait);

  /// Runs until the question is asked, answers it, and returns the final state.
  Future<ProofFlowState> ask(RadioProofFlow f, {required bool join}) async {
    final asked = f.states.firstWhere((s) => s.asking);
    final done = f.run();
    await asked;
    f.decide(join: join);
    return done;
  }

  group('nobody owned it / you own it', () {
    test('claimed: the radio signs the server text with its own key, the server verifies a real signature', () async {
      final steps = <ProofStep>[];
      final f = flow();
      f.states.listen((s) => steps.add(s.step));
      final r = await f.run();
      expect(r.outcome, ProofOutcome.claimed);
      expect(r.claim!.pubkey, radio.keyHex);
      expect(r.message, contains('is yours now'));
      expect(r.ownershipChanged, isTrue);
      expect(steps, containsAllInOrder([ProofStep.starting, ProofStep.signing, ProofStep.completing, ProofStep.done]));
      expect(server.wire.first, 'start DRIVERKEY ${radio.keyHex}');
      expect(server.decides, 0);
    });

    test('yours: nothing to do, nothing changed', () async {
      server.answer = ProofKind.yours;
      final r = await flow().run();
      expect(r.outcome, ProofOutcome.yours);
      expect(r.ownershipChanged, isFalse);
    });
  });

  group('owned by someone else', () {
    setUp(() => server.answer = ProofKind.ownedByOther);

    test('asks "This radio is on KE4BFI\'s account. Is that you?" and waits; Yes joins', () async {
      final f = flow();
      final asked = f.states.firstWhere((s) => s.asking);
      final done = f.run();
      final q = await asked;
      expect(q.question, 'This radio is on KE4BFI\'s account. Is that you?');
      expect(q.canJoin, isTrue);
      expect(server.decides, 0, reason: 'nothing is decided until the person answers');
      f.decide(join: true);
      final r = await done;
      expect(r.outcome, ProofOutcome.joined);
      expect(server.decisions, [true]);
      expect(r.ownershipChanged, isTrue);
    });

    test('an anonymous owner has no name in the question (never an email)', () async {
      server.ownerName = null;
      final f = flow();
      final asked = f.states.firstWhere((s) => s.asking);
      unawaited(f.run());
      expect((await asked).question, 'This radio is on another account. Is that you?');
      f.cancel();
      await f.done;
    });

    test('No: the radio alone moves here', () async {
      server.decideAnswers = [DecideResult(DecideKind.taken, claim: NodeClaim(pubkey: radio.keyHex, nodeType: ClaimNodeType.companion))];
      final r = await ask(flow(), join: false);
      expect(r.outcome, ProofOutcome.taken);
      expect(server.decisions, [false]);
      expect(r.claim, isNotNull);
    });

    test('join_pending is polled until the owner approves (ask me first)', () async {
      server.askFirst = true;
      server.decideAnswers = [
        const DecideResult(DecideKind.joinPending, requestId: 'r1'),
        const DecideResult(DecideKind.joinPending, requestId: 'r1'),
        const DecideResult(DecideKind.joined),
      ];
      final start = clock.t;
      final f = flow();
      final seen = <ProofStep>[];
      f.states.listen((s) => seen.add(s.step));
      final r = await ask(f, join: true);
      expect(r.outcome, ProofOutcome.joined);
      expect(server.decides, 3);
      expect(seen, contains(ProofStep.waitingApproval));
      expect(clock.t.isAfter(start), isTrue, reason: 'the polls waited between asks');
    });

    test('join_pending then join_denied: nothing changes', () async {
      server.decideAnswers = [const DecideResult(DecideKind.joinPending), const DecideResult(DecideKind.joinDenied)];
      final r = await ask(flow(), join: true);
      expect(r.outcome, ProofOutcome.joinDenied);
      expect(r.ownershipChanged, isFalse);
    });

    test('a pending join that outlives decideUntil ends as expired', () async {
      server.decideUntil = clock.t.add(const Duration(seconds: 10));
      server.decideAnswers = [const DecideResult(DecideKind.joinPending)];
      final r = await ask(flow(), join: true);
      expect(r.outcome, ProofOutcome.expired);
    });

    test('canJoin false (device is signed in to an account): Yes is never sent, the radio is taken instead', () async {
      server.canJoin = false;
      server.decideAnswers = [DecideResult(DecideKind.taken, claim: NodeClaim(pubkey: radio.keyHex))];
      final f = flow();
      final asked = f.states.firstWhere((s) => s.asking);
      final done = f.run();
      expect((await asked).canJoin, isFalse);
      f.decide(join: true);
      final r = await done;
      expect(server.decisions, [false]);
      expect(r.outcome, ProofOutcome.taken);
    });

    test('refused device_has_account (outcome or 409 code)', () async {
      server.decideAnswers = [const DecideResult(DecideKind.refused, reason: 'device_has_account')];
      expect((await ask(flow(), join: true)).outcome, ProofOutcome.refused);
      server.decideAnswers = const [DecideResult(DecideKind.joined)];
      server.decideError = const CmatException('no', status: 409, code: 'device_has_account');
      expect((await ask(flow(), join: true)).outcome, ProofOutcome.refused);
    });

    test('409 changed (radio released or taken meanwhile) and 410 after decideUntil', () async {
      server.decideError = const CmatException('changed', status: 409, code: 'changed');
      expect((await ask(flow(), join: false)).outcome, ProofOutcome.changed);
      server.decideError = const CmatException('gone', status: 410);
      expect((await ask(flow(), join: false)).outcome, ProofOutcome.expired);
    });

    test('not answered before decideUntil: expired, nothing sent', () async {
      server.decideUntil = DateTime.now().add(const Duration(milliseconds: 40));
      final r = await flow().run();
      expect(r.outcome, ProofOutcome.expired);
      expect(server.decides, 0);
    });

    test('Not now (cancel) while asking: nothing decided', () async {
      final f = flow();
      final asked = f.states.firstWhere((s) => s.asking);
      final done = f.run();
      await asked;
      f.cancel();
      expect((await done).outcome, ProofOutcome.cancelled);
      expect(server.decides, 0);
    });
  });

  group('refusals and failures', () {
    test('the server asks for text that is not a MeshSonar login: never signed, never completed', () async {
      for (final bad in <String Function(String)>[
        (k) => 'v1_${k.toUpperCase()}',
        (k) => 'something else entirely',
        (k) => 'meshsonar-login:v1:meshsonar.com:connect:${'0' * 64}:${'ab' * 16}:1',
        (k) => 'meshsonar-login:v1:meshsonar.com:other:$k:${'ab' * 16}:1',
        (k) => 'meshsonar-claim:v1:$k:driver:1',
      ]) {
        server.textMaker = bad;
        final r = await flow().run();
        expect(r.outcome, ProofOutcome.refusedText, reason: bad(radio.keyHex));
        expect(server.completes, 0);
      }
      expect(radio.sentFrames.where((f) => f[0] == Cmd.signStart), isEmpty, reason: 'the radio was never asked to sign');
    });

    test('422 bad signature, 410 expired, 429 slow down, 404 off, 503', () async {
      server.completeError = const CmatException('bad', status: 422, code: 'bad_signature');
      expect((await flow().run()).outcome, ProofOutcome.signatureRejected);
      server.completeError = const CmatException('gone', status: 410);
      expect((await flow().run()).outcome, ProofOutcome.expired);
      server.completeError = null;
      server.startError = const CmatException('slow', status: 429);
      final slow = await flow().run();
      expect(slow.outcome, ProofOutcome.rateLimited);
      expect(slow.message, contains('Too many'));
      server.startError = const CmatException('not found', status: 404);
      expect((await flow().run()).outcome, ProofOutcome.serverUnavailable);
      server.startError = const CmatException('boom', status: 503);
      expect((await flow().run()).outcome, ProofOutcome.serverUnavailable);
    });

    test('no radio connected: the server is not asked', () async {
      await link.close();
      final r = await flow().run();
      expect(r.outcome, ProofOutcome.noRadio);
      expect(server.wire, isEmpty);
    });

    test('firmware cannot sign', () async {
      radio.signUnsupported = true;
      final r = await flow().run();
      expect(r.outcome, ProofOutcome.signFailed);
      expect(server.completes, 0);
    });
  });

  group('signableProofText', () {
    final key = 'ab' * 32;
    Uint8List b(String s) => Uint8List.fromList(utf8.encode(s));
    test('accepts only the server connect text for this radio', () {
      final ok = 'meshsonar-login:v1:meshsonar.com:connect:$key:${'0f' * 16}:1800000000';
      expect(signableProofText(b(ok), key), ok);
      expect(signableProofText(b(ok), key.toUpperCase()), ok);
      expect(signableProofText(b(ok), 'cd' * 32), isNull);
      expect(signableProofText(b('v1_$key'), key), isNull);
      expect(signableProofText(Uint8List.fromList([0xff, 0xfe, 0xfd]), key), isNull);
      expect(signableProofText(b('${ok}x:y'), key), isNull);
    });
  });
}
