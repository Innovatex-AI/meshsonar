import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/claim_radio.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/radio_session_impl.dart';
import 'package:meshsonar/radio/repeater_admin.dart';
import 'package:meshsonar/radio/repeater_settings.dart';
import 'package:meshsonar/radio/repeater_wire.dart';

import '../support/repeater_admin_fake.dart';

Uint8List key(int n) => Uint8List.fromList(List<int>.generate(32, (i) => (n * 7 + i * 3) & 0xff)..[0] = 0xdf);

class Rig {
  final FakeAdminRepeater rep;
  final AdminFakeTransport radio;
  final MeshCoreCompanionLink link;
  final RepeaterAdminSession session;
  Rig(this.rep, this.radio, this.link, this.session);
  Future<void> close() => link.close();
  SettingDef def(String k) => settingFor(k)!;
}

Future<Rig> rig({String password = 'secret', AdminLimits limits = const AdminLimits(), bool login = true, void Function(FakeAdminRepeater)? setup}) async {
  final rep = FakeAdminRepeater(key: key(1));
  setup?.call(rep);
  final radio = AdminFakeTransport({rep.keyHex: rep});
  final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 250));
  await link.start();
  final s = RepeaterAdminSession(radio: link, keyHex: rep.keyHex, limits: limits, delay: (d) async {});
  if (login) await s.login(password);
  return Rig(rep, radio, link, s);
}

void main() {
  group('login', () {
    test('admin login works and a wrong password is plain silence', () async {
      final r = await rig(login: false);
      await expectLater(r.session.login('nope'), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.silent)));
      expect(r.session.loggedIn, isFalse);
      final ok = await r.session.login('secret');
      expect(ok.isAdmin, isTrue);
      expect(r.session.isAdmin, isTrue);
      await r.close();
    });

    test('a blank password is never sent, and a password over 15 bytes is refused (the radio would cut it)', () async {
      final r = await rig(login: false);
      await expectLater(r.session.login(''), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.refused)));
      await expectLater(r.session.login('x' * 16), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.refused)));
      expect(r.radio.sentFrames.where((f) => f[0] == 26), isEmpty, reason: 'no login frame left the phone');
      await r.close();
    });

    test('a guest login reads status but cannot use the CLI, the ACL or any write', () async {
      final r = await rig(password: 'guest');
      expect(r.session.isAdmin, isFalse);
      expect((await r.session.readStatus()).batteryV, closeTo(3.86, 0.01));
      await expectLater(r.session.readAcl(), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.notAdmin)));
      await expectLater(r.session.readSetting(r.def('name')), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.notAdmin)));
      expect(r.rep.received, isEmpty);
      await r.close();
    });

    test('commands before a login are refused without touching the radio', () async {
      final r = await rig(login: false);
      await expectLater(r.session.readStatus(), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.notLoggedIn)));
      expect(r.radio.sentFrames.where((f) => f[0] == 27), isEmpty);
      await r.close();
    });
  });

  group('reads (binary requests beat CLI text)', () {
    test('snapshot: status, telemetry, identity and a clock within seconds', () async {
      final r = await rig();
      final steps = <String>[];
      final snap = await r.session.readSnapshot(onStep: steps.add);
      expect(snap.problems, isEmpty);
      expect(snap.stats!.upTimeSecs, 149365);
      expect(snap.stats!.noiseFloorDbm, -108);
      expect(snap.telemetry!.voltageV, 3.86);
      expect(snap.telemetry!.temperatureC, 45.0);
      expect(snap.identity.name, 'INNO-OB-2');
      expect(snap.identity.board, 'Heltec V4.3 OLED');
      expect(snap.clock!.skewSecs.abs(), lessThanOrEqualTo(2));
      expect(steps, containsAllInOrder(['Status', 'Telemetry', 'Clock', 'Name and firmware']));
      expect(r.session.boardLimits.maxTxDbm, 28, reason: 'a Heltec V4 reads tx 28, so the cap follows the board');
      await r.close();
    });

    test('neighbours are paged until the repeater total, trusting the counts not the padded length', () async {
      final r = await rig(setup: (rep) {
        rep.neighbours
          ..clear()
          ..addAll([for (var i = 0; i < 20; i++) RepeaterNeighbour(i.toRadixString(16).padLeft(8, '0'), 60 * i, i / 4)]);
      });
      final n = await r.session.readNeighbours();
      expect(n.length, 20);
      expect(n[19].prefixHex, '00000013');
      expect(n[19].snrDb, 19 / 4);
      await r.close();
    });

    test('zero neighbours is a normal answer', () async {
      final r = await rig(setup: (rep) => rep.neighbours.clear());
      expect(await r.session.readNeighbours(), isEmpty);
      await r.close();
    });

    test('access list (admin) shows roles by key prefix', () async {
      final r = await rig(setup: (rep) => rep.acl['a9b1acd3a408${'00' * 26}'] = 3);
      final acl = await r.session.readAcl();
      expect(acl.map((e) => e.prefixHex), contains('a9b1acd3a408'));
      expect(acl.map((e) => e.prefixHex), contains(r.radio.keyHex.substring(0, 12)));
      await r.close();
    });

    test('anonymous requests work without a login and are limited locally to 3 per 180 s', () async {
      final r = await rig(login: false);
      expect((await r.session.readClockAnon()).epochSecs, closeTo(DateTime.now().millisecondsSinceEpoch / 1000, 3));
      expect(await r.session.readRegionsAnon(), ['*', 'cmh']);
      await r.session.readClockAnon();
      await expectLater(r.session.readClockAnon(), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.rateLimited)));
      expect(r.radio.sentFrames.where((f) => f[0] == 57).length, 3, reason: 'the 4th never left the phone');
      await r.close();
    });

    test('the repeater\'s own anonymous limiter (4 per window, shared) shows up as silence, not a hang', () async {
      final r = await rig(login: false, limits: const AdminLimits(anonMax: 10));
      for (var i = 0; i < 4; i++) {
        await r.session.readClockAnon();
      }
      await expectLater(r.session.readClockAnon(), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.silent)));
      await r.close();
    });

    test('a binary request nobody answers is silent after the retries', () async {
      final r = await rig(setup: (rep) => rep.dropBinaryAnswers = 10);
      await expectLater(r.session.readNeighbours(), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.silent)));
      expect(r.radio.sentFrames.where((f) => f[0] == 50).length, 3, reason: '1 try + 2 retries: reads are idempotent');
      await r.close();
    });

    test('one lost binary answer is retried and succeeds', () async {
      final r = await rig(setup: (rep) => rep.dropBinaryAnswers = 1);
      expect((await r.session.readNeighbours()).length, 3);
      await r.close();
    });

    test('requests started together are serialised (one outstanding at a time)', () async {
      final r = await rig();
      final out = await Future.wait([r.session.readStatus(), r.session.readNeighbours(), r.session.readTelemetry(), r.session.readAcl()]);
      expect((out[0] as RepeaterStats).upTimeSecs, 149365);
      expect((out[1] as List).length, 3);
      expect((out[2] as RepeaterTelemetry).voltageV, 3.86);
      expect((out[3] as List).isNotEmpty, isTrue);
      await r.close();
    });

    test('"Using airtime" goes on while a request runs and off after', () async {
      final r = await rig();
      final seen = <bool>[];
      final sub = r.session.activity.listen(seen.add);
      await r.session.readStatus();
      await Future<void>.delayed(Duration.zero);
      expect(seen, [true, false]);
      expect(r.session.usingAirtime, isFalse);
      await sub.cancel();
      await r.close();
    });
  });

  group('CLI under loss and the replay rule', () {
    test('40 reads in a row with 1 reply in 7 lost all succeed (idempotent retries, strictly increasing timestamps)', () async {
      final r = await rig(setup: (rep) => rep.lossEvery = 7);
      final v = await r.session.readSettings();
      expect(v.values.where((x) => x.state == ReadState.silent), isEmpty);
      expect(v['name']!.value, 'INNO-OB-2');
      expect(v['radio']!.value, '910.5250244,62.5,7,5');
      expect(v['tx']!.value, '28');
      expect(v['dutycycle']!.value, '50.0%');
      expect(r.session.log.where((e) => e.kind == AdminLogKind.error), isNotEmpty);
      await r.close();
    });

    test('a retried read never trips the repeater\'s replay check (the retry gets a newer timestamp)', () async {
      final r = await rig(setup: (rep) => rep.dropNextReplies = 1);
      final v = await r.session.readSetting(r.def('name'));
      expect(v.value, 'INNO-OB-2');
      expect(r.rep.received.where((c) => c == 'get name').length, 2, reason: 'asked twice, answered once');
      await r.close();
    });

    test('unsupported keys read as unsupported, not as errors', () async {
      final r = await rig();
      final v = await r.session.readSetting(r.def('radio'));
      expect(v.ok, isTrue);
      final gone = await r.session.console('get bootloader.ver');
      expect((gone as ConsoleReply).text, contains('unsupported'));
      await r.close();
    });

    test('commands carry a tag and a stale reply to another command is never taken for the answer', () async {
      final r = await rig();
      await r.session.readSetting(r.def('name'));
      await r.session.readSetting(r.def('tx'));
      expect(r.rep.sentReplies.every((x) => RegExp(r'^\d\d\|').hasMatch(x)), isTrue);
      await r.close();
    });
  });

  group('writes: confirm, send once, read back, undo', () {
    test('rename: plan shows current -> new, apply verifies, undo puts it back', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('name'), 'Hilltop 2');
      expect(plan.current, 'INNO-OB-2');
      expect(plan.next, 'Hilltop 2');
      expect(plan.consequence, contains('Hilltop 2'));
      expect(r.rep.name, 'INNO-OB-2', reason: 'planning changes nothing');
      final done = await r.session.apply(plan, Confirmation.yes);
      expect(done.outcome, ApplyOutcome.verified);
      expect(done.readBack, 'Hilltop 2');
      expect(r.rep.name, 'Hilltop 2');
      expect(done.canUndo, isTrue);
      final back = await r.session.planUndo(done);
      expect(back.next, 'INNO-OB-2');
      final undone = await r.session.apply(back, Confirmation.yes);
      expect(undone.outcome, ApplyOutcome.verified);
      expect(r.rep.name, 'INNO-OB-2');
      await r.close();
    });

    test('nothing is sent without the confirm step', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('name'), 'X1');
      final before = r.rep.received.length;
      await expectLater(r.session.apply(plan, const Confirmation()), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.refused)));
      expect(r.rep.received.length, before);
      expect(r.rep.name, 'INNO-OB-2');
      await r.close();
    });

    test('the write reply is lost: read-back verifies and the write is NOT sent twice', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('tx'), '20');
      r.rep.dropOncePrefix = 'set tx';
      final done = await r.session.apply(plan, Confirmation.yes);
      expect(done.outcome, ApplyOutcome.verified);
      expect(done.replyLost, isTrue);
      expect(r.rep.received.where((c) => c.startsWith('set tx')).length, 1, reason: 'a write is never blindly retried');
      await r.close();
    });

    test('the write never arrived: reported as not applied, still not resent', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('tx'), '20');
      r.rep.ignoreOncePrefix = 'set tx';
      final done = await r.session.apply(plan, Confirmation.yes);
      expect(done.outcome, ApplyOutcome.notApplied);
      expect(r.rep.prefs['tx'], '28');
      expect(r.rep.received.where((c) => c.startsWith('set tx')), isEmpty);
      expect(done.canUndo, isFalse);
      await r.close();
    });

    test('the repeater refuses (Error reply): rejected, nothing changed', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('tx'), '20');
      r.rep.errorOncePrefix = 'set tx';
      final done = await r.session.apply(plan, Confirmation.yes);
      expect(done.outcome, ApplyOutcome.rejected);
      expect(r.rep.prefs['tx'], '28');
      await r.close();
    });

    test('cannot read it back: "unverified", never left unknown, and a re-check settles it', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('tx'), '20');
      // the reply to the write and every read after it are lost
      r.rep.dropAllReplies = true;
      final done = await r.session.apply(plan, Confirmation.yes);
      expect(done.outcome, ApplyOutcome.unverified);
      r.rep.dropAllReplies = false;
      final again = await r.session.recheck(done);
      expect(again.outcome, ApplyOutcome.verified);
      await r.close();
    });

    test('a value the repeater turns into something else is a mismatch', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('agc.reset.interval'), '20');
      expect(plan.next, '20');
      final done = await r.session.apply(plan, Confirmation.yes);
      expect(done.outcome, ApplyOutcome.verified, reason: '20 is a multiple of 4');
      await r.close();
    });

    test('validation: ranges, bad characters, byte limits, odd advert minutes', () async {
      final r = await rig();
      for (final bad in [
        ('name', 'Bad[Name'),
        ('name', ''),
        ('name', 'x' * 32),
        ('name', ' lead'),
        ('lat', '91'),
        ('lat', 'abc'),
        ('lon', '-181'),
        ('tx', '0'),
        ('tx', '29'),
        ('flood.max', '65'),
        ('flood.advert.interval', '2'),
        ('advert.interval', '59'),
        ('advert.interval', '181'),
        ('dutycycle', '0'),
        ('radio', '100,62.5,7,5'),
        ('radio', '910.5,62.5,13,5'),
        ('repeat', 'maybe'),
        ('loop.detect', 'paranoid'),
        ('agc.reset.interval', '1021'),
        ('guest.password', ''),
        ('guest.password', 'x' * 16),
      ]) {
        await expectLater(r.session.plan(r.def(bad.$1), bad.$2), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.refused)),
            reason: '${bad.$1} = "${bad.$2}"');
      }
      expect(r.rep.received.where((c) => c.startsWith('set')), isEmpty, reason: 'nothing invalid reached the repeater');
      await r.close();
    });

    test('tx power is capped by the board: 28 allowed on a Heltec V4, 22 on an unknown board', () async {
      final r = await rig();
      await r.session.readIdentity();
      await r.session.plan(r.def('tx'), '28');
      await r.close();
      final u = await rig(setup: (rep) => rep.board = 'Some Board');
      await u.session.readIdentity();
      await expectLater(u.session.plan(u.def('tx'), '23'), throwsA(isA<AdminException>()));
      expect((await u.session.plan(u.def('tx'), '22')).next, '22');
      await u.close();
    });

    test('repeat OFF needs the typed phrase; repeat ON does not; "on"/"off" are sent exactly', () async {
      final r = await rig();
      final off = await r.session.plan(r.def('repeat'), 'off');
      expect(off.typedPhrase, 'REPEAT OFF');
      expect(off.danger, Danger.disruptive);
      await expectLater(r.session.apply(off, Confirmation.yes), throwsA(isA<AdminException>()));
      await expectLater(r.session.apply(off, const Confirmation(acknowledged: true, typed: 'repeat off')), throwsA(isA<AdminException>()), reason: 'case matters');
      expect(r.rep.prefs['repeat'], 'on');
      final done = await r.session.apply(off, const Confirmation(acknowledged: true, typed: 'REPEAT OFF'));
      expect(done.outcome, ApplyOutcome.verified);
      expect(r.rep.received.last, 'get repeat');
      expect(r.rep.received.where((c) => c.startsWith('set repeat')), ['set repeat off']);
      final on = await r.session.plan(r.def('repeat'), 'on');
      expect(on.typedPhrase, isNull);
      await r.session.apply(on, Confirmation.yes);
      expect(r.rep.prefs['repeat'], 'on');
      await r.close();
    });

    test('radio parameters: typed phrase, saved, flagged as needing a reboot, compared to 3 decimals', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('radio'), '910.525, 62.5, 7, 5');
      expect(plan.noChange, isTrue, reason: '910.5250244 is 910.525 to the radio\'s own precision');
      final p2 = await r.session.plan(r.def('radio'), '869.618,62.5,8,5');
      expect(p2.danger, Danger.disruptive);
      expect(p2.effect, TakesEffect.afterReboot);
      expect(p2.typedPhrase, 'RADIO');
      expect(p2.consequence, contains('off the air'));
      await expectLater(r.session.apply(p2, const Confirmation(acknowledged: true, typed: 'ok')), throwsA(isA<AdminException>()));
      final done = await r.session.apply(p2, const Confirmation(acknowledged: true, typed: 'RADIO'));
      expect(done.outcome, ApplyOutcome.verified);
      expect(done.needsReboot, isTrue);
      expect(r.session.pendingReboot, {'radio'});
      expect(r.rep.rebootCount, 0, reason: 'applying never reboots by itself');
      await r.close();
    });

    test('flood.max under 3 is disruptive-typed', () async {
      final r = await rig();
      expect((await r.session.plan(r.def('flood.max'), '2')).typedPhrase, 'LOW LIMIT');
      expect((await r.session.plan(r.def('flood.max'), '10')).typedPhrase, isNull);
      await r.close();
    });

    test('owner.info and positions round trip', () async {
      final r = await rig();
      final p = await r.session.plan(r.def('owner.info'), 'Call me|73 de KE4BFI');
      expect((await r.session.apply(p, Confirmation.yes)).outcome, ApplyOutcome.verified);
      final lat = await r.session.plan(r.def('lat'), '40.1');
      expect(lat.next, '40.100000');
      expect((await r.session.apply(lat, Confirmation.yes)).outcome, ApplyOutcome.verified);
      await r.close();
    });

    test('a write needs an admin login', () async {
      final r = await rig(password: 'guest');
      await expectLater(r.session.plan(r.def('name'), 'x'), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.notAdmin)));
      await r.close();
    });

    test('writes are spaced: two writes in a row wait the write gap', () async {
      final waits = <Duration>[];
      final r = await rig();
      final s = RepeaterAdminSession(radio: r.link, keyHex: r.rep.keyHex, delay: (d) async => waits.add(d));
      await s.login('secret');
      final a = await s.plan(r.def('af'), '2');
      await s.apply(a, Confirmation.yes);
      final b = await s.plan(r.def('af'), '3');
      await s.apply(b, Confirmation.yes);
      expect(waits, isNotEmpty);
      expect(waits.first, lessThanOrEqualTo(const Duration(seconds: 2)));
      await r.close();
    });
  });

  group('passwords', () {
    test('guest password: set, verified by an internal read-back, never shown or logged', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('guest.password'), 'hunter22');
      expect(plan.current, isNull);
      expect(plan.toString(), isNot(contains('hunter22')));
      final done = await r.session.apply(plan, Confirmation.yes);
      expect(done.outcome, ApplyOutcome.verified);
      expect(done.readBack, isNull);
      expect(done.canUndo, isFalse);
      expect(r.rep.guestPassword, 'hunter22');
      final everything = [...r.session.log.map((e) => e.toString()), r.session.toString(), r.session.debugState().toString(), done.replyText ?? '', plan.consequence, plan.toString()].join('\n');
      expect(everything, isNot(contains('hunter22')));
      await r.close();
    });

    test('admin password: bricking, typed phrase, reply echo is masked, verified from the echo, then proven by a login', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('password'), 'newpass99');
      expect(plan.danger, Danger.bricking);
      expect(plan.typedPhrase, 'CHANGE PASSWORD');
      await expectLater(r.session.apply(plan, Confirmation.yes), throwsA(isA<AdminException>()));
      expect(r.rep.adminPassword, 'secret');
      final done = await r.session.apply(plan, const Confirmation(acknowledged: true, typed: 'CHANGE PASSWORD'));
      expect(done.outcome, ApplyOutcome.verified);
      expect(done.replyText, 'password now: ••••');
      expect(r.rep.adminPassword, 'newpass99');
      final everything = [...r.session.log.map((e) => e.toString()), r.session.toString(), r.session.debugState().toString(), done.toString(), done.replyText ?? ''].join('\n');
      expect(everything, isNot(contains('newpass99')));
      expect(everything, isNot(contains('secret')));
      expect(await r.session.testPassword('newpass99'), isTrue);
      await r.close();
    });

    test('admin password change whose reply is lost is "unverified" until a login proves it', () async {
      final r = await rig();
      final plan = await r.session.plan(r.def('password'), 'newpass99');
      r.rep.dropOncePrefix = 'password ';
      final done = await r.session.apply(plan, const Confirmation(acknowledged: true, typed: 'CHANGE PASSWORD'));
      expect(done.outcome, ApplyOutcome.unverified);
      expect(await r.session.testPassword('newpass99'), isTrue);
      expect(await r.session.testPassword('wrongpass1'), isFalse);
      await r.close();
    });

    test('every bricking setting has a typed phrase; every disruptive one at least asks for acknowledgement', () {
      for (final d in repeaterSettings) {
        if (d.danger == Danger.bricking) {
          expect(d.typedPhrase(null, 'x'), isNotNull, reason: d.key);
        }
        if (d.secret) expect(d.display('anything'), '••••');
      }
      expect(repeaterSettings.where((d) => d.key == 'prv.key' || d.key == 'freq'), isEmpty, reason: 'identity key and freq are never settable');
    });
  });

  group('actions', () {
    test('adverts: confirmed, exact strings, 30 s cooldown', () async {
      var now = DateTime(2026, 11, 1, 12);
      final r = await rig();
      final s = RepeaterAdminSession(radio: r.link, keyHex: r.rep.keyHex, clock: () => now, delay: (d) async {});
      await s.login('secret');
      await expectLater(s.sendAdvert(flood: true, confirmation: const Confirmation()), throwsA(isA<AdminException>()));
      expect(r.rep.adverts, isEmpty);
      expect((await s.sendAdvert(flood: true, confirmation: Confirmation.yes)).ok, isTrue);
      expect((await s.sendAdvert(flood: false, confirmation: Confirmation.yes)).ok, isTrue);
      expect(r.rep.adverts, ['flood', 'zerohop']);
      await expectLater(s.sendAdvert(flood: true, confirmation: Confirmation.yes), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.rateLimited)));
      now = now.add(const Duration(seconds: 31));
      expect((await s.sendAdvert(flood: true, confirmation: Confirmation.yes)).ok, isTrue);
      expect(r.rep.received.where((c) => c.startsWith('advert')), ['advert', 'advert.zerohop', 'advert']);
      await r.close();
    });

    test('sync clock: moves a repeater that is behind; a repeater that is ahead stays and says why', () async {
      final r = await rig(setup: (rep) => rep.clockOffsetSecs = -300);
      expect((await r.session.readClock()).skewSecs, closeTo(-300, 3));
      final res = await r.session.syncClock(Confirmation.yes);
      expect(res.ok, isTrue, reason: res.message);
      expect(r.rep.clockOffsetSecs.abs(), lessThan(5));
      await r.close();
      final ahead = await rig(setup: (rep) => rep.clockOffsetSecs = 900);
      final res2 = await ahead.session.syncClock(Confirmation.yes);
      expect(res2.ok, isFalse);
      expect(res2.message, contains('never sets its clock backwards'));
      await ahead.close();
    });

    test('reboot needs the typed word, sends exactly "reboot", and the return is detected by the uptime dropping', () async {
      final r = await rig();
      await expectLater(r.session.reboot(Confirmation.yes), throwsA(isA<AdminException>()));
      expect(r.rep.rebootCount, 0);
      final before = (await r.session.readStatus()).upTimeSecs;
      await r.session.reboot(const Confirmation(acknowledged: true, typed: 'REBOOT'));
      expect(r.rep.rebootCount, 1);
      expect(r.rep.received.last, 'reboot');
      final back = await r.session.waitForReturn(uptimeBeforeSecs: before, attempts: 2);
      expect(back, isNotNull);
      await r.close();
    });

    test('discover neighbours is rate limited by its own cooldown', () async {
      final r = await rig();
      expect((await r.session.discoverNeighbours(Confirmation.yes)).message, 'OK - Discover sent');
      await expectLater(r.session.discoverNeighbours(Confirmation.yes), throwsA(isA<AdminException>()));
      await r.close();
    });

    test('a CLI rate limit stops a runaway loop instead of flooding the mesh', () async {
      final r = await rig(limits: const AdminLimits(cliMax: 5, maxAutoWait: Duration.zero));
      for (var i = 0; i < 5; i++) {
        await r.session.readSetting(r.def('name'));
      }
      await expectLater(r.session.readSetting(r.def('name')), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.rateLimited)));
      expect(r.rep.received.length, 5);
      await r.close();
    });
  });

  group('regions', () {
    test('tree, home and default are read; a truncated tree falls back to the allowed/denied lists', () async {
      final r = await rig();
      final info = await r.session.readRegions();
      expect(info.nodes.map((n) => n.name), ['*', 'cmh']);
      expect(info.nodes[1].depth, 1);
      expect(info.defaultScope, 'cmh');
      expect(info.truncated, isFalse);
      await r.close();
      final big = await rig(setup: (rep) {
        for (var i = 0; i < 30; i++) {
          rep.regions.add(FakeRegion('region-number-$i', '*', i.isEven));
        }
      });
      final info2 = await big.session.readRegions();
      expect(info2.truncated, isTrue);
      expect(info2.has('cmh'), isTrue);
      await big.close();
    });

    test('default region must already exist: a typo does not create a region (the firmware would)', () async {
      final r = await rig();
      final info = await r.session.readRegions();
      await expectLater(r.session.setDefaultRegion('cmhh', known: info, confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      expect(r.rep.regions.length, 2);
      expect(r.rep.received.where((c) => c.startsWith('region default ')), isEmpty);
      r.rep.regions.add(FakeRegion('dayton', '*', true));
      final info2 = await r.session.readRegions();
      final done = await r.session.setDefaultRegion('dayton', known: info2, confirmation: Confirmation.yes);
      expect(done.outcome, ApplyOutcome.verified);
      expect(r.rep.defaultRegion, 'dayton');
      await r.close();
    });

    test('allow / deny flood saves and reads back; denying "*" needs DENY ALL', () async {
      final r = await rig();
      final info = await r.session.readRegions();
      final done = await r.session.setRegionFlood('cmh', allow: false, known: info, confirmation: Confirmation.yes);
      expect(done.outcome, ApplyOutcome.verified);
      expect(r.rep.regions.firstWhere((x) => x.name == 'cmh').floodAllowed, isFalse);
      expect(r.rep.received, containsAllInOrder(['region denyf cmh', 'region save', 'region get cmh']));
      await expectLater(r.session.setRegionFlood('*', allow: false, known: info, confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      final all = await r.session.setRegionFlood('*', allow: false, known: info, confirmation: const Confirmation(acknowledged: true, typed: 'DENY ALL'));
      expect(all.outcome, ApplyOutcome.verified);
      await r.close();
    });

    test('region load is never sent (it would swallow the next admin\'s commands)', () async {
      final r = await rig();
      final c = await r.session.console('region load');
      expect(c, isA<ConsoleRefused>());
      expect(r.rep.received, isEmpty);
      await r.close();
    });
  });

  group('access list', () {
    final other = 'a9b1acd3a408${'11' * 26}';
    test('remove another entry: verified; setperm always carries the permission', () async {
      final r = await rig(setup: (rep) => rep.acl[other] = 3);
      final done = await r.session.removeAclEntry(other.substring(0, 12), confirmation: Confirmation.yes);
      expect(done.outcome, ApplyOutcome.verified);
      expect(r.rep.received.where((c) => c.startsWith('setperm')), ['setperm ${other.substring(0, 12)} 0']);
      await r.close();
    });

    test('your own radio cannot be removed or demoted', () async {
      final r = await rig();
      final me = r.radio.keyHex;
      await expectLater(r.session.removeAclEntry(me.substring(0, 12), confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      await expectLater(r.session.setAclRole(me, AclRole.readOnly, confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      expect(r.rep.received.where((c) => c.startsWith('setperm')), isEmpty);
      await r.close();
    });

    test('a role change needs the full key; admin needs GRANT ADMIN', () async {
      final r = await rig();
      await expectLater(r.session.setAclRole(other.substring(0, 12), AclRole.readOnly, confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      await expectLater(r.session.setAclRole(other, AclRole.admin, confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      final done = await r.session.setAclRole(other, AclRole.admin, confirmation: const Confirmation(acknowledged: true, typed: 'GRANT ADMIN'));
      expect(done.outcome, ApplyOutcome.verified);
      await r.close();
    });

    test('bad hex is refused before anything is sent', () async {
      final r = await rig();
      await expectLater(r.session.removeAclEntry('zz', confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      await expectLater(r.session.removeAclEntry('abc', confirmation: Confirmation.yes), throwsA(isA<AdminException>()));
      await r.close();
    });
  });

  group('console', () {
    test('reads run; the prefix-matching traps are refused and never reach the repeater', () async {
      final r = await rig();
      expect((await r.session.console('ver') as ConsoleReply).text, contains('v1.17.1.5'));
      expect((await r.session.console('get name') as ConsoleReply).text, '> INNO-OB-2');
      for (final bad in ['advertXYZ', 'rebootnow', 'verbose', 'clockwork', 'reboot', 'poweroff', 'erase', 'password x', 'get guest.password', 'set prv.key ab', 'start ota', 'region load', 'setperm ab', 'tempradio 1,2,3,4,5', 'get acl', 'foo']) {
        expect(await r.session.console(bad), isA<ConsoleRefused>(), reason: bad);
      }
      expect(r.rep.received, ['ver', 'get name']);
      expect(r.rep.adverts, isEmpty);
      expect(r.rep.rebootCount, 0);
      await r.close();
    });

    test('a typed write becomes a plan that must be confirmed like any other', () async {
      final r = await rig();
      final c = await r.session.console('set name Console Test');
      expect(c, isA<ConsolePlan>());
      expect(r.rep.name, 'INNO-OB-2');
      expect((await r.session.apply((c as ConsolePlan).plan, Confirmation.yes)).outcome, ApplyOutcome.verified);
      expect(r.rep.name, 'Console Test');
      final bad = await r.session.console('set name Bad:Name');
      expect(bad, isA<ConsoleRefused>());
      final unknown = await r.session.console('set made.up 1');
      expect(unknown, isA<ConsoleRefused>());
      await r.close();
    });

    test('an action is confirmed first', () async {
      final r = await rig();
      final c = await r.session.console('advert.zerohop');
      expect(c, isA<ConsoleAction>());
      expect(r.rep.adverts, isEmpty);
      await r.session.runConsoleAction(c as ConsoleAction, Confirmation.yes);
      expect(r.rep.adverts, ['zerohop']);
      await r.close();
    });
  });

  group('observer (read only)', () {
    test('only status commands are sent; server URLs lose their credentials', () async {
      final r = await rig(setup: (rep) => rep.isObserver = true);
      final raw = await r.session.readObserverRaw();
      expect(raw['get mqtt.status'], contains('5: custom (ok)'));
      expect(raw['get mqtt5.server'], 'wss://mqtt.meshsonar.com:443/mqtt');
      expect(r.rep.received.every((c) => c.startsWith('get mqtt') || c == 'memory'), isTrue);
      expect(r.rep.received.any((c) => c.contains('password') || c.contains('token') || c.contains('username')), isFalse);
      expect(redactUrl('wss://u:p@host/x'), 'wss://host/x');
      await r.close();
    });
  });

  group('link loss', () {
    test('a dropped radio is a radioLost error, not a hang', () async {
      final r = await rig();
      r.radio.drop();
      await expectLater(r.session.readStatus(), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.radioLost)));
      await r.close();
    });
  });

  test('CLI replies never reach the chat inbound (a repeater\'s answer is not a DM)', () async {
    final r = await rig();
    final session = LinkRadioSession(r.link);
    final seen = <InboundMessage>[];
    final sub = session.inbound.listen(seen.add);
    await r.session.readSetting(r.def('name'));
    await r.session.readSetting(r.def('tx'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen, isEmpty);
    expect(r.rep.sentReplies, isNotEmpty);
    await sub.cancel();
    await r.close();
  });

  test('fake repeater mimics the blank-password re-admit finding (so the app must never send a blank one)', () {
    final rep = FakeAdminRepeater(key: key(2));
    expect(rep.login('aa' * 32, ''), isNull);
    expect(rep.login('aa' * 32, 'secret'), 3);
    expect(rep.login('aa' * 32, ''), 3, reason: 'LIVE: blank re-admits a key already in the ACL');
    expect(rep.login('bb' * 32, ''), isNull);
    expect(rep.login('bb' * 32, 'wrongpass'), isNull);
  });

  test('ClaimRadio login of the real companion link is untouched', () {
    expect(MeshCoreCompanionLink, isNotNull);
    expect(ClaimRadioError.values.length, 5);
  });
}
