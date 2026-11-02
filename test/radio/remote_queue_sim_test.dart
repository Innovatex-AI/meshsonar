// The remote request queue over the real companion link and the simulated radio (radio/simulator.dart): wrong password
// (PUSH 0x86) and silence are different results, SENT's est_timeout reaches the queue, the Rx log is paused around a request.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/remote_request_queue.dart';
import 'package:meshsonar/radio/repeater_admin.dart';
import 'package:meshsonar/radio/simulator.dart';

class Rig {
  final SimulatedTransport radio;
  final MeshCoreCompanionLink link;
  final RemoteRequestQueue queue;
  final SimulatedRepeater rep;
  final RepeaterAdminSession session;
  final List<bool> rxPauses;
  Rig(this.radio, this.link, this.queue, this.rep, this.session, this.rxPauses);
}

Future<Rig> rig({bool silent = false, bool wrongPasswordReplies = true}) async {
  final rep = SimulatedRepeater('Test Hill', 40.0, -82.9, adminPassword: 'adminpw', guestPassword: 'guestpw', silent: silent, wrongPasswordReplies: wrongPasswordReplies);
  final radio = SimulatedTransport(repeaters: [rep], seed: 1);
  final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 300));
  await link.start();
  final pauses = <bool>[];
  late RemoteRequestQueue q;
  q = RemoteRequestQueue(onRxPause: (p) {
    pauses.add(p);
    link.rxLogPaused = p;
  });
  link.onRemoteSent = q.reportSentForCurrent;
  final s = RepeaterAdminSession(radio: link, keyHex: rep.keyHex, queue: q, delay: (d) async {});
  return Rig(radio, link, q, rep, s, pauses);
}

void main() {
  test('admin and guest logins succeed through the queue', () async {
    final r = await rig();
    expect((await r.session.login('adminpw')).isAdmin, isTrue);
    expect(r.session.isAdmin, isTrue);
    final g = await rig();
    expect((await g.session.login('guestpw')).isAdmin, isFalse);
    expect(g.session.loggedIn, isTrue);
    await r.link.close();
    await g.link.close();
  });

  test('wrong password (0x86) is a refusal, silence is a timeout: two different results', () async {
    final wrong = await rig();
    await expectLater(
        wrong.session.login('nope'), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.radio).having((e) => e.message, 'message', contains('refused'))));
    expect(wrong.session.loggedIn, isFalse);

    final quiet = await rig(silent: true);
    await expectLater(quiet.session.login('adminpw'), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.silent)));

    // the queue records them as different states
    final w = await rig();
    final r1 = w.queue.enqueue<void>(
        kind: RemoteKind.login,
        target: w.rep.keyHex,
        run: (_) => w.link.login(w.rep.keyHex, 'nope'),
        isRefused: (_) => true);
    await r1.result;
    expect(r1.state, RemoteState.refused);
    final q2 = await rig(silent: true);
    final r2 = q2.queue.enqueue<void>(
        kind: RemoteKind.login,
        target: q2.rep.keyHex,
        run: (_) => q2.link.login(q2.rep.keyHex, 'adminpw'),
        isNoReply: (e) => e.toString().contains('silent') || e.toString().contains('did not answer'),
        isRefused: (e) => !(e.toString().contains('silent') || e.toString().contains('did not answer')));
    await r2.result;
    expect(r2.state, RemoteState.noReply);
    for (final x in [wrong, quiet, w, q2]) {
      await x.link.close();
    }
  });

  test('a login is sent exactly once on silence (never auto-retried)', () async {
    final r = await rig(silent: true);
    await expectLater(r.session.login('adminpw'), throwsA(isA<AdminException>()));
    expect(r.radio.remoteLoginLog.length, 1);
    await r.link.close();
  });

  test('SENT est_timeout reaches the request in flight; the Rx log is paused during it and resumed after', () async {
    final r = await rig();
    r.rep.estTimeoutMs = 1700;
    await r.session.login('adminpw');
    expect(r.rxPauses, [true, false]);
    expect(r.link.rxLogPaused, isFalse);
    // watch a request while it runs
    final seen = Completer<RemoteRequest>();
    final h = r.queue.enqueue<void>(kind: RemoteKind.status, target: r.rep.keyHex, run: (ctx) async {
      expect(r.link.rxLogPaused, isTrue);
      await r.link.statusBytes(r.rep.keyHex);
      seen.complete(ctx.request);
    });
    await h.result;
    expect((await seen.future).estTimeout, const Duration(milliseconds: 1700));
    expect(h.flood, isFalse);
    await r.link.close();
  });

  test('Rx log packets are dropped at the link edge while paused and flow again after', () async {
    final r = await rig();
    final got = <Object>[];
    r.link.rxPackets.listen(got.add);
    r.link.rxLogPaused = true;
    r.radio.injectChatter('Bob', 'hello');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(got, isEmpty);
    expect(r.link.rxLogDroppedWhilePaused, greaterThan(0));
    r.link.rxLogPaused = false;
    r.radio.injectChatter('Bob', 'again');
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(got, isNotEmpty);
    await r.link.close();
  });

  test('status auto refresh is dropped while a login is out, runs when idle', () async {
    final r = await rig();
    await r.session.login('adminpw');
    final login = r.queue.enqueue<void>(kind: RemoteKind.login, target: r.rep.keyHex, run: (_) => Future<void>.delayed(const Duration(milliseconds: 50)));
    await expectLater(r.session.readStatus(background: true), throwsA(isA<AdminException>().having((e) => e.kind, 'kind', AdminErrorKind.busy)));
    await login.result;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final st = await r.session.readStatus(background: true);
    expect(st.batteryV, closeTo(3.86, 0.01));
    expect(r.radio.remoteStatusLog.length, 1, reason: 'the dropped refresh never reached the radio');
    await r.link.close();
  });

  test('two sessions sharing one queue never overlap on the radio', () async {
    final a = SimulatedRepeater('A Hill', 40.0, -82.9, adminPassword: 'a');
    final b = SimulatedRepeater('B Hill', 40.1, -82.8, adminPassword: 'b');
    final radio = SimulatedTransport(repeaters: [a, b], seed: 2);
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 300));
    await link.start();
    final q = RemoteRequestQueue();
    final sa = RepeaterAdminSession(radio: link, keyHex: a.keyHex, queue: q, delay: (d) async {});
    final sb = RepeaterAdminSession(radio: link, keyHex: b.keyHex, queue: q, delay: (d) async {});
    var concurrent = 0, maxC = 0;
    q.requests.addListener(() {
      final active = q.requests.value.where((r) => r.state == RemoteState.sending || r.state == RemoteState.waitingForReply).length;
      maxC = active > maxC ? active : maxC;
      concurrent = active;
    });
    await Future.wait([sa.login('a'), sb.login('b')]);
    expect(maxC, 1);
    expect(concurrent, 0);
    expect(sa.isAdmin && sb.isAdmin, isTrue);
    await link.close();
  });
}
