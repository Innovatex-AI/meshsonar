// The claim flows, every branch, end to end over the real companion link and frame layouts with a fake radio, a fake
// repeater and a fake server (test/support/claim_fakes.dart). Time is faked: a 15-minute window runs instantly.
import 'dart:convert';
import 'dart:io';
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

  group('claim a repeater (advert code + name restore)', () {
    test('a radio whose clock is AHEAD of the phone still gets answers: commands are stamped from the radio clock (real-radio bug: "could not read the repeater\'s name")', () async {
      for (final ahead in [0, 5, 3600, 86400 * 400]) {
        final r = await _Rig.make(radioAheadSecs: ahead);
        final res = await r.claim();
        expect(res.outcome, ClaimOutcome.verified, reason: 'radio ${ahead}s ahead');
        expect(r.rep.name, 'Hilltop');
        expect(r.rep.cliLog.first, 'get name', reason: 'the very first command was answered');
        await r.close();
      }
    });

    test('every command to a repeater carries a strictly newer timestamp than the one before (equal = retry, older = replay: both ignored)', () async {
      final r = await _Rig.make(radioAheadSecs: 60);
      addTearDown(r.close);
      await r.claim();
      final ts = r.radio.sentFrames.where((f) => f[0] == Cmd.sendTxtMsg).map((f) => ByteData.sublistView(f).getUint32(3, Endian.little)).toList();
      expect(ts.length, greaterThanOrEqualTo(6));
      for (var i = 1; i < ts.length; i++) {
        expect(ts[i], greaterThan(ts[i - 1]), reason: 'command $i');
      }
      final phoneNow = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      expect(ts.first, greaterThanOrEqualTo(phoneNow + 55), reason: 'stamped from the radio clock, not the phone clock');
    });

    test('happy path: logs in as admin, name gets the code, advert, observer hears it, name is restored and confirmed', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final states = <ClaimStep>[];
      final f = r.flow();
      f.states.listen((s) => states.add(s.step));
      final res = await r.claim(f: f);
      expect(res.outcome, ClaimOutcome.verified);
      expect(res.claim!.pubkey, r.rep.keyHex);
      expect(res.restore, RestoreState.confirmed);
      expect(res.nameAtRisk, isFalse);
      expect(r.rep.name, 'Hilltop', reason: 'name put back');
      // the advert that carried the code, then the restore advert
      expect(r.rep.adverts.first, 'Hilltop ${res.code}');
      expect(r.rep.adverts.last, 'Hilltop');
      expect(r.rep.cliLog, ['get name', 'set name Hilltop ${res.code}', 'advert', 'set name Hilltop', 'advert', 'get name']);
      expect(states, containsAllInOrder([
        ClaimStep.starting, ClaimStep.loggingIn, ClaimStep.readingName, ClaimStep.settingName, ClaimStep.advertising,
        ClaimStep.waitingForObserver, ClaimStep.restoring, ClaimStep.done,
      ]));
      expect(await r.store.load(), isEmpty, reason: 'nothing left to restore');
      expect(r.server.startedKinds, ['advert']);
      expect(r.radio.contacts, contains(r.rep.keyHex), reason: 'the repeater was added as a contact so the radio can log in');
    });

    test('the admin password reaches only the radio: never the server, never the restore record on disk', () async {
      final dir = await Directory.systemTemp.createTemp('claim_store');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/restore.json');
      final r = await _Rig.make();
      addTearDown(r.close);
      r.clock.realDelay = const Duration(milliseconds: 5); // keep the code on the name long enough for the test to act
      r.server.observerWorks = false;
      final store = FileClaimRestoreStore(file);
      // make the restore fail so the record stays on disk while we look at it
      final f = r.flow(store: store, timing: const ClaimTiming(restoreBackoff: [Duration.zero]));
      final fut = r.claim(f: f);
      while (r.rep.adverts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      r.rep.dropAllReplies = true;
      final res = await fut;
      expect(res.restore, RestoreState.failed);
      expect(r.server.wire, isNotEmpty);
      expect(r.server.wire.join('\n'), isNot(contains(_password)));
      final onDisk = await file.readAsString();
      expect(onDisk, isNot(contains(_password)));
      expect(onDisk, contains('Hilltop'));
      expect(res.message, isNot(contains(_password)));
      expect((await store.load()).single.originalName, 'Hilltop');
      await store.remove(r.rep.keyHex);
      expect(await store.load(), isEmpty);
    });

    test('a 31-byte name is cut for the code (fits one advert with a position) and the FULL name is restored', () async {
      final longName = 'The Very Long Hilltop Repeat31';
      final r = await _Rig.make(name: longName);
      addTearDown(r.close);
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.verified);
      expect(utf8.encode(r.rep.adverts.first).length, lessThanOrEqualTo(maxAdvertNameBytesWithPosition));
      expect(r.rep.adverts.first.endsWith(res.code!), isTrue, reason: 'the code is never the part that gets cut');
      expect(r.rep.name, longName);
    });

    test('guest login: not admin, nothing touched', () async {
      final r = await _Rig.make(guest: 'guestpw');
      addTearDown(r.close);
      final res = await r.claim(password: 'guestpw');
      expect(res.outcome, ClaimOutcome.notAdmin);
      expect(res.restore, RestoreState.notNeeded);
      expect(r.rep.cliLog, isEmpty);
      expect(r.rep.adverts, isEmpty);
      expect(r.rep.name, 'Hilltop');
    });

    test('wrong password: the repeater stays silent -> loginSilent (out of range or wrong password), nothing touched', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final res = await r.claim(password: 'wrong');
      expect(res.outcome, ClaimOutcome.loginSilent);
      expect(res.message, contains('password'));
      expect(res.message, contains('out of range'));
      expect(r.rep.cliLog, isEmpty);
    });

    test('repeater out of range: loginSilent', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.inRange = false;
      expect((await r.claim()).outcome, ClaimOutcome.loginSilent);
      expect(r.rep.cliLog, isEmpty);
    });

    test('LOGIN_FAIL push: loginRefused', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.failWithPush = true;
      expect((await r.claim(password: 'bad')).outcome, ClaimOutcome.loginRefused);
    });

    test('radio cannot add the repeater (contact list full): noContact', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.radio.contactsFull = true;
      expect((await r.claim()).outcome, ClaimOutcome.noContact);
    });

    test('server refuses claim-start (409): the radio is never touched', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.startError = const CmatException('claimed', status: 409);
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.serverRefused);
      expect(r.radio.sentFrames.where((f) => f[0] == Cmd.sendLogin), isEmpty);
    });

    test('claim-start says 409 owner "you": already yours, no login, no password prompt, the name is untouched', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final existing = NodeClaim(pubkey: r.rep.keyHex, nodeType: ClaimNodeType.repeater, method: ClaimMethod.advert);
      r.server.startError = ClaimAlreadyYours(existing);
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.alreadyYours);
      expect(res.claim!.pubkey, r.rep.keyHex);
      expect(res.restore, RestoreState.notNeeded);
      expect(r.radio.sentFrames.where((f) => f[0] == Cmd.sendLogin || f[0] == Cmd.sendTxtMsg), isEmpty);
      expect(r.rep.cliLog, isEmpty);
      expect(r.rep.name, 'Hilltop');
      expect(await r.store.load(), isEmpty);
    });

    test('no radio / bad key', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final bad = await r.flow().run(pubkey: 'nothex', password: 'x');
      expect(bad.outcome, ClaimOutcome.serverRefused);
      await r.link.close();
      expect((await r.claim()).outcome, ClaimOutcome.noRadio);
    });

    test('the SET NAME reply is lost but it took effect: read back, flow carries on and restores', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.dropOncePrefix = 'set name Hilltop MS';
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.verified);
      expect(r.rep.cliLog.where((c) => c.startsWith('set name Hilltop MS')), hasLength(1), reason: 'taken as done after the read-back, not sent twice');
      expect(r.rep.name, 'Hilltop');
    });

    test('repeater refuses the new name: setNameFailed, name untouched, nothing to restore wrongly', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.refuseSetName = true;
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.setNameFailed);
      expect(r.rep.adverts.where((a) => a.contains('MS')), isEmpty, reason: 'no advert carried a code');
    });

    test('no observer in range: the code stays on the name only for the hold time, the name is restored, the claim expires', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.observerWorks = false;
      final startedAt = r.clock.now();
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.expired);
      expect(res.restore, RestoreState.confirmed);
      expect(r.rep.name, 'Hilltop');
      // the code sat on the name for about the hold time (90 s), not the whole 15 minutes
      expect(r.rep.adverts.where((a) => a.contains(res.code!)), hasLength(2), reason: 'first advert + one more shout');
      expect(res.message, contains('observer'));
      expect(r.clock.now().difference(startedAt), greaterThanOrEqualTo(const Duration(minutes: 15)),
          reason: 'it then kept listening until the code expired');
    });

    test('an observer reports late, after the name is already back: still verified', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.hearAfterPolls = 25; // beyond the hold window (90 s / 5 s = 18 polls)
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.verified);
      expect(res.restore, RestoreState.confirmed);
      expect(r.rep.name, 'Hilltop');
    });

    test('server blips while polling do not fail the claim', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.statusErrorsLeft = 3;
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.verified);
    });

    test('the user cancels while waiting: the name is ALWAYS restored', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.observerWorks = false;
      final f = r.flow();
      final fut = r.claim(f: f);
      // cancel as soon as the code is on the repeater's name
      while (!r.rep.name.contains('MS')) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      f.cancel();
      final res = await fut;
      expect(res.outcome, ClaimOutcome.cancelled);
      expect(res.restore, RestoreState.confirmed);
      expect(r.rep.name, 'Hilltop');
      expect(await r.store.load(), isEmpty);
    });

    test('cancel before anything is changed', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final f = r.flow();
      final fut = r.claim(f: f);
      f.cancel();
      final res = await fut;
      expect(res.outcome, ClaimOutcome.cancelled);
      expect(r.rep.name, 'Hilltop');
    });

    test('restore fails (repeater stops answering): retries, then shows the exact commands and keeps the record', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.clock.realDelay = const Duration(milliseconds: 5); // keep the code on the name long enough for the test to act
      r.server.observerWorks = false;
      final f = r.flow(timing: const ClaimTiming(restoreBackoff: [Duration.zero, Duration(seconds: 1), Duration(seconds: 1)]));
      final fut = r.claim(f: f);
      // after the advert carrying the code goes out, the repeater goes quiet (it moved out of range, say)
      while (r.rep.adverts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      r.rep.dropAllReplies = true;
      final res = await fut;
      expect(res.restore, RestoreState.failed);
      expect(res.nameAtRisk, isTrue);
      expect(res.restoreCommands, ['set name Hilltop', 'advert']);
      expect(res.message, contains('commands below'));
      final saved = await r.store.load();
      expect(saved.single.originalName, 'Hilltop', reason: 'remembered so it can be finished later');
      expect(r.rep.name, 'Hilltop', reason: 'the commands did land even though replies were lost');
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

    test('a name left over from an earlier failed attempt: the SAVED original is kept, not the code-bearing name', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.rep.name = 'Hilltop MS7K99'; // an earlier attempt never restored this
      await r.store.put(PendingRestore(pubkey: r.rep.keyHex, originalName: 'Hilltop', since: r.clock.now()));
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.verified);
      expect(res.originalName, 'Hilltop');
      expect(r.rep.name, 'Hilltop');
    });

    test('radio drops while the code is on the name: the flow waits, and restores as soon as a radio is attached', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.clock.realDelay = const Duration(milliseconds: 5); // keep the code on the name long enough for the test to act
      r.server.observerWorks = false;
      final f = r.flow();
      final fut = r.claim(f: f);
      while (r.rep.adverts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      r.radio.drop();
      // a new BLE connection to the same radio (same contact list is gone: the fake radio keeps it)
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(r.rep.name, contains('MS'), reason: 'still carries the code while the radio is away');
      final radio2 = await ClaimFakeTransport.create(repeaters: [r.rep]);
      final link2 = MeshCoreCompanionLink(radio2, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 300));
      await link2.start();
      addTearDown(link2.close);
      f.attachRadio(link2);
      final res = await fut;
      expect(res.restore, RestoreState.confirmed);
      expect(r.rep.name, 'Hilltop');
      expect(res.outcome, ClaimOutcome.radioLost);
      expect(res.message, contains('back to normal'));
      expect(await r.store.load(), isEmpty);
    });

    test('the radio never comes back and the user stops waiting: the record stays, with the commands', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.clock.realDelay = const Duration(milliseconds: 5); // keep the code on the name long enough for the test to act
      r.server.observerWorks = false;
      final f = r.flow();
      final fut = r.claim(f: f);
      while (r.rep.adverts.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      r.radio.drop();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      f.cancel();
      final res = await fut;
      expect(res.restore, RestoreState.failed);
      expect(res.restoreCommands, ['set name Hilltop', 'advert']);
      expect((await r.store.load()).single.pubkey, r.rep.keyHex);
    });

    test('app resumed wakes a sleeping flow (the clock is checked again at once)', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      final f = r.flow();
      final fut = r.claim(f: f);
      f.appResumed();
      expect((await fut).outcome, ClaimOutcome.verified);
    });

    test('the second advert goes out halfway through the hold time', () async {
      final r = await _Rig.make();
      addTearDown(r.close);
      r.server.hearAfterPolls = 12; // 60 s of polls: after the half-hold shout (45 s), before the end (90 s)
      final res = await r.claim();
      expect(res.outcome, ClaimOutcome.verified);
      expect(r.rep.adverts.where((a) => a.contains('MS')).length, 2);
    });
  });
}
