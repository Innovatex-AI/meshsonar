// The claim flows, every branch, end to end over the real companion link and frame layouts with a fake radio, a fake
// repeater and a fake server (test/support/claim_fakes.dart). Time is faked: a 15-minute window runs instantly.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/claim_flow.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/protocol.dart';

import '../support/claim_fakes.dart';

const _password = 'hunter2-Admin';

class _Rig {
  final FakeRepeater rep;
  final ClaimFakeTransport radio;
  final MeshCoreCompanionLink link;
  final FakeClaimClient server;
  final FakeClock clock;
  final MemoryClaimRestoreStore store;
  _Rig(this.rep, this.radio, this.link, this.server, this.clock, this.store);

  static Future<_Rig> make({String name = 'Hilltop', String? guest, int radioAheadSecs = 0}) async {
    final rep = FakeRepeater(key: keyBytes(5), name: name, adminPassword: _password, guestPassword: guest);
    final radio = await ClaimFakeTransport.create(repeaters: [rep]);
    radio.radioAheadSecs = radioAheadSecs;
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 300));
    await link.start();
    final clock = FakeClock();
    return _Rig(rep, radio, link, FakeClaimClient(observed: [rep], clock: clock.now), clock, MemoryClaimRestoreStore());
  }

  RepeaterClaimFlow flow({ClaimTiming timing = const ClaimTiming(), ClaimRestoreStore? store}) => RepeaterClaimFlow(
      radio: link, client: server, driverKey: 'DRIVERKEY', store: store ?? this.store, timing: timing, now: clock.now, wait: clock.wait);

  Future<ClaimFlowState> claim({RepeaterClaimFlow? f, String password = _password}) =>
      (f ?? flow()).run(pubkey: rep.keyHex, password: password, nodeName: rep.name);

  Iterable<Uint8List> frames(int cmd) => radio.sentFrames.where((f) => f[0] == cmd);
  Future<void> close() => link.close();
}

void main() {
  group('composeClaimName', () {
    test('short names keep everything, long names are cut so the code fits an advert with a position (23 bytes)', () {
      expect(composeClaimName('Hilltop', 'MS7K12'), 'Hilltop MS7K12');
      final long = composeClaimName('A' * 31, 'MS7K12');
      expect(long, '${'A' * 16} MS7K12');
      expect(utf8.encode(long).length, 23);
      expect(utf8.encode(composeClaimName('x' * 31, 'MS7K12')).length, lessThanOrEqualTo(maxAdvertNameBytesWithPosition));
    });
    test('never splits a multi-byte character; drops characters set name refuses; empty name is just the code', () {
      final n = composeClaimName('ÄÖÜÄÖÜÄÖÜÄÖÜ', 'MS7K12'); // 2 bytes each
      expect(utf8.encode(n).length, lessThanOrEqualTo(23));
      expect(n.endsWith(' MS7K12'), isTrue);
      expect(n.contains('�'), isFalse);
      expect(composeClaimName('a:b,c[d]*?', 'MS7K12'), 'abcd MS7K12');
      expect(composeClaimName('', 'MS7K12'), 'MS7K12');
      expect(restoreCommands('Hilltop'), ['set name Hilltop', 'advert']);
    });
  });

  group('claim my radio (signature)', () {
    late ClaimFakeTransport radio;
    late MeshCoreCompanionLink link;
    late FakeClaimClient server;
    late FakeClock clock;
    setUp(() async {
      radio = await ClaimFakeTransport.create();
      link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
      await link.start();
      clock = FakeClock();
      server = FakeClaimClient(clock: clock.now);
    });
    tearDown(() => link.close());

    OwnRadioClaimFlow flow() => OwnRadioClaimFlow(radio: link, client: server, driverKey: 'DRIVERKEY', now: clock.now, wait: clock.wait);

    test('happy path: server challenge, the radio signs with its own key, the server verifies a real Ed25519 signature', () async {
      final states = <ClaimStep>[];
      final f = flow();
      f.states.listen((s) => states.add(s.step));
      final r = await f.run();
      expect(r.outcome, ClaimOutcome.verified);
      expect(r.claim!.pubkey, radio.keyHex);
      expect(r.claim!.method, ClaimMethod.signature);
      expect(states, containsAllInOrder([ClaimStep.starting, ClaimStep.signing, ClaimStep.completing, ClaimStep.done]));
      expect(server.claims, hasLength(1));
      expect(server.startedKinds, ['sign']);
    });

    test('no radio connected', () async {
      await link.close();
      final r = await flow().run();
      expect(r.outcome, ClaimOutcome.noRadio);
      expect(server.startedKinds, isEmpty, reason: 'nothing asked of the server');
    });

    test('server refusals are worded: 409 someone else, 429 slow down (with minutes), 403, 5xx', () async {
      server.startError = const CmatException('claimed', status: 409);
      var r = await flow().run();
      expect(r.outcome, ClaimOutcome.serverRefused);
      expect(r.serverStatus, 409);
      expect(r.message, contains('claim'));
      server.startError = const CmatException('slow', status: 429, retryAfterSec: 600);
      r = await flow().run();
      expect(r.message, contains('10 min'));
      server.startError = const CmatException('boom', status: 503);
      r = await flow().run();
      expect(r.outcome, ClaimOutcome.serverUnavailable);
      server.startError = const CmatException('network error: down');
      r = await flow().run();
      expect(r.outcome, ClaimOutcome.serverUnavailable);
    });

    test('own radio already yours: shown as such, nothing signed', () async {
      server.startError = ClaimAlreadyYours(NodeClaim(pubkey: radio.keyHex));
      final r = await flow().run();
      expect(r.outcome, ClaimOutcome.alreadyYours);
      expect(radio.sentFrames.where((f) => f[0] == Cmd.signStart), isEmpty);
    });

    test('firmware cannot sign', () async {
      radio.signUnsupported = true;
      final r = await flow().run();
      expect(r.outcome, ClaimOutcome.signFailed);
      expect(r.message, contains('Update'));
    });

    test('server says the signature does not match (422) and the challenge expired (410)', () async {
      server.completeError = const CmatException('bad', status: 422);
      expect((await flow().run()).outcome, ClaimOutcome.signatureRejected);
      server.completeError = const CmatException('gone', status: 410);
      expect((await flow().run()).outcome, ClaimOutcome.expired);
    });

    test('radio disconnects mid-claim', () async {
      final f = flow();
      final fut = f.run();
      radio.drop();
      final r = await fut;
      expect(r.outcome, anyOf(ClaimOutcome.radioLost, ClaimOutcome.noRadio));
    });

    test('cancel while waiting for the server', () async {
      final f = flow();
      final fut = f.run();
      f.cancel();
      expect((await fut).outcome, ClaimOutcome.cancelled);
    });
  });

  group('claim a repeater (login only: nothing on the repeater is changed)', () {
    test('happy path: admin login, then the server is told; NO command is sent to the repeater and its name is untouched', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final states = <ClaimStep>[];
      final f = r.flow();
      f.states.listen((s) => states.add(s.step));
      final res = await r.claim(f: f);
      expect(res.outcome, ClaimOutcome.verified);
      expect(res.claim!.pubkey, r.rep.keyHex);
      expect(res.claim!.method, ClaimMethod.login);
      expect(r.rep.name, 'Hilltop', reason: 'the repeater was not touched');
      expect(r.rep.cliLog, isEmpty, reason: 'not a single CLI command');
      expect(r.rep.adverts, isEmpty, reason: 'no advert');
      expect(r.radio.sentFrames.where((f) => f[0] == Cmd.sendTxtMsg), isEmpty);
      expect(states, containsAllInOrder([ClaimStep.starting, ClaimStep.loggingIn, ClaimStep.completing, ClaimStep.done]));
      expect(r.server.startedKinds, ['login']);
      expect(r.server.lastAttest!['isAdmin'], isTrue);
      expect(r.server.lastAttest!['radioPubKey'], r.radio.keyHex);
      expect(r.radio.contacts, contains(r.rep.keyHex), reason: 'the repeater was added as a contact so the radio can log in');
      expect(await r.store.load(), isEmpty);
    });

    test('the admin password reaches only the radio: never the server, never disk', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      await r.claim();
      expect(r.server.wire, isNotEmpty);
      expect(r.server.wire.join('\n'), isNot(contains(_password)));
      expect(jsonEncode((await r.store.load()).map((p) => p.toJson()).toList()), isNot(contains(_password)));
    });

    test('a guest password logs in but is refused: not admin, the server is never asked to complete', () async {
      final r = await _Rig.make(guest: 'guestpw');
      addTearDown(r.close);
      final res = await r.claim(password: 'guestpw');
      expect(res.outcome, ClaimOutcome.notAdmin);
      expect(r.server.claims, isEmpty);
      expect(r.server.wire.where((w) => w.startsWith('claim-complete')), isEmpty);
      expect(r.rep.cliLog, isEmpty);
    });

    test('wrong password (the repeater stays silent): "no answer", nothing changed, nothing claimed', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final res = await r.claim(password: 'wrong');
      expect(res.outcome, ClaimOutcome.loginSilent);
      expect(r.server.claims, isEmpty);
    });

    test('repeater out of range: the same "no answer"', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.inRange = false;
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.loginSilent);
    });

    test('no radio connected: asks to connect, nothing asked of the server', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      await r.link.close();
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.noRadio);
      expect(r.server.startedKinds, isEmpty);
    });

    test('radio contact table full: worded, nothing changed', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.radio.contactsFull = true;
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.noContact);
    });

    test('server says no at the start (429 / 403) or at the end (422 not admin): worded, nothing claimed', () async {
      for (final st in [429, 403, 409]) {
        final r = await _Rig.make();
        r.server.startError = CmatException('no', status: st);
        final res = await r.claim();
        expect(res.outcome, ClaimOutcome.serverRefused, reason: 'status $st');
        expect(res.serverStatus, st);
        await r.close();
      }
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.completeError = const CmatException('not admin', status: 422);
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.serverRefused);
      expect(r.server.claims, isEmpty);
      expect(r.rep.cliLog, isEmpty);
    });

    test('already yours (409 owner you): shown as such, no login, no password needed', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.startError = ClaimAlreadyYours(NodeClaim(pubkey: r.rep.keyHex, nodeType: ClaimNodeType.repeater, method: ClaimMethod.login, verifiedAt: r.clock.now()));
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.alreadyYours);
      expect(r.radio.sentFrames.where((f) => f[0] == Cmd.sendLogin), isEmpty);
    });

    test('radio disconnects while logging in: worded, nothing changed', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.inRange = false; // the login would wait
      final f = r.flow();
      final fut = r.claim(f: f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      r.radio.drop();
      final res = await fut;
      expect(res.outcome, anyOf(ClaimOutcome.radioLost, ClaimOutcome.loginSilent));
      expect(r.server.claims, isEmpty);
    });

    test('cancel while logging in: cancelled, nothing changed', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.inRange = false;
      final f = r.flow();
      final fut = r.claim(f: f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      f.cancel();
      final res = await fut;
      expect(res.outcome, ClaimOutcome.cancelled);
      expect(r.server.claims, isEmpty);
    });

    test('finish a failed restore later: runRestoreOnly logs in again and confirms', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.name = 'Hilltop MS7K99';
      final pending = PendingRestore(pubkey: r.rep.keyHex, originalName: 'Hilltop', since: r.clock.now());
      await r.store.put(pending);
      final res = await r.flow().runRestoreOnly(pending: pending, password: _password);
      expect(res.restore, RestoreState.confirmed);
      expect(r.rep.name, 'Hilltop');
      expect(await r.store.load(), isEmpty);
      // wrong password: nothing changes, record stays
      final r2 = await _Rig.make();
      addTearDown(r2.close);
      r2.rep.name = 'Hilltop MS7K99';
      await r2.store.put(PendingRestore(pubkey: r2.rep.keyHex, originalName: 'Hilltop', since: r2.clock.now()));
      final bad = await r2.flow().runRestoreOnly(
          pending: PendingRestore(pubkey: r2.rep.keyHex, originalName: 'Hilltop', since: r2.clock.now()), password: 'nope');
      expect(bad.outcome, ClaimOutcome.loginSilent);
      expect(bad.restore, RestoreState.failed);
      expect(await r2.store.load(), hasLength(1));
    });

  });
}
