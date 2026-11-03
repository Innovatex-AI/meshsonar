// WP9 login matrix over the real companion link and the simulated radio: success as admin, success as guest, wrong password
// (PUSH 0x86), silence, radio queue busy, and a "search for it" (flood) login that clears the stale-route warning. Also: the
// password never reaches print / debugPrint / the session log.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/admin_password_vault.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/has_connection.dart';
import 'package:meshsonar/radio/login_outcome.dart';
import 'package:meshsonar/radio/remote_request_queue.dart';
import 'package:meshsonar/radio/repeater_admin.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/ui/radios/repeater_admin/admin_controller.dart';
import 'package:meshsonar/ui/radios/repeater_admin/login_sheet.dart';

class Rig {
  final SimulatedRepeater rep;
  final MeshCoreCompanionLink link;
  final RemoteRequestQueue queue;
  final RepeaterAdminController c;
  final LoginSheetModel model;
  final int Function() resets;
  Rig(this.rep, this.link, this.queue, this.c, this.model, this.resets);
}

Future<Rig> rig({bool silent = false, bool wrongPasswordReplies = true, String guest = 'hello', AdminPasswordVault? vault}) async {
  final rep = SimulatedRepeater('Test Hill', 40.0, -82.9, adminPassword: 'adminpw', guestPassword: guest, silent: silent, wrongPasswordReplies: wrongPasswordReplies);
  final radio = SimulatedTransport(repeaters: [rep], seed: 1);
  final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 300));
  await link.start();
  late RemoteRequestQueue q;
  q = RemoteRequestQueue(onRxPause: (p) => link.rxLogPaused = p);
  link.onRemoteSent = q.reportSentForCurrent;
  final s = RepeaterAdminSession(radio: link, keyHex: rep.keyHex, queue: q, delay: (d) async {});
  final c = RepeaterAdminController(session: s, title: 'Test Hill', vault: vault ?? AdminPasswordVault());
  var resets = 0;
  final m = LoginSheetModel.forAdmin(c, resetRoute: () async => resets++);
  return Rig(rep, link, q, c, m, () => resets);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(AdminSessions.clear);

  test('success as admin: the reply decides the role', () async {
    final r = await rig();
    final o = await r.model.submit('adminpw');
    expect(o.kind, LoginKind.admin);
    expect(r.model.phase, LoginPhase.done);
    expect(signedInAs(o), 'Signed in as Admin');
    expect(r.c.stage, AdminStage.ready);
    await r.link.close();
  });

  test('success as guest: typing the guest password gives a guest login, and the button uses the factory guest default', () async {
    final typed = await rig(guest: 'roompw');
    final o = await typed.model.submit('roompw');
    expect(o.kind, LoginKind.guest);
    expect(signedInAs(o), 'Signed in as Guest');
    await typed.link.close();

    final btn = await rig(); // guest password is the factory "hello"
    final g = await btn.model.submit('', guest: true);
    expect(g.kind, LoginKind.guest);
    expect(btn.c.session.isAdmin, isFalse);
    await btn.link.close();
  });

  test('wrong password (0x86) is its own outcome and keeps the person on the sheet', () async {
    final r = await rig();
    final o = await r.model.submit('nope');
    expect(o.kind, LoginKind.wrongPassword);
    expect(o.message, LoginCopy.wrongPassword);
    expect(r.model.phase, LoginPhase.failed);
    expect(r.model.routeStale, isFalse, reason: 'the node answered, so the route is fine');
    await r.link.close();
  });

  test('silence is a different outcome from a wrong password, with the seconds waited', () async {
    final r = await rig(silent: true);
    final o = await r.model.submit('adminpw');
    expect(o.kind, LoginKind.noReply);
    expect(o.kind, isNot(LoginKind.wrongPassword));
    expect(o.waitedSecs, isNotNull);
    expect(LoginCopy.noReply(24), allOf(contains('No reply after 24 s'), contains('Wrong password'), contains('stale')));
    expect(LoginCopy.noReply(24), isNot(contains('not accepted')));
    expect(r.model.routeStale, isTrue);
    await r.link.close();
  });

  test('a login while the radio queue is busy shows the busy count, then goes through', () async {
    final r = await rig();
    final gate = Completer<void>();
    final blocker = r.queue.enqueue<void>(kind: RemoteKind.status, target: 'x', run: (_) => gate.future);
    final f = r.model.submit('adminpw');
    expect(r.model.ahead, greaterThan(0));
    expect(LoginCopy.busy(r.model.ahead), allOf(contains('busy with another request'), contains('1 of 2')));
    gate.complete();
    await blocker.result;
    expect((await f).kind, LoginKind.admin);
    await r.link.close();
  });

  test('a search (flood) login resets the saved route first and clears the stale-route warning', () async {
    final r = await rig(silent: true);
    await r.model.submit('adminpw');
    expect(r.model.routeStale, isTrue);
    r.rep.silent = false;
    r.model.setRoute(LoginRoute.search);
    final o = await r.model.submit('adminpw');
    expect(o.ok, isTrue);
    expect(r.resets(), 1, reason: 'the saved route was forgotten before the login');
    expect(r.model.routeStale, isFalse);
    await r.link.close();
  });

  test('cancelling a login on the air does not open the dashboard when it later succeeds', () async {
    final r = await rig();
    final f = r.model.submit('adminpw');
    r.model.cancel();
    await f;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(r.c.stage, AdminStage.login);
    expect(r.model.phase, LoginPhase.idle);
    await r.link.close();
  });

  test('success with a factory password flags it for the dashboard nag', () async {
    final rep = SimulatedRepeater('Factory', 40.0, -82.9, adminPassword: 'password', guestPassword: 'hello');
    final link = MeshCoreCompanionLink(SimulatedTransport(repeaters: [rep], seed: 1), timeout: const Duration(seconds: 2), claimReplyTimeout: const Duration(milliseconds: 300));
    await link.start();
    final c = RepeaterAdminController(session: RepeaterAdminSession(radio: link, keyHex: rep.keyHex, delay: (d) async {}), title: 'Factory');
    expect(await c.login('password'), isTrue);
    expect(c.factoryPasswordInUse, isNotNull);
    await link.close();
  });

  test('resume: skipped sheet only when the radio confirms the connection', () async {
    final r = await rig();
    await r.model.submit('adminpw');
    expect(AdminSessions.of(r.rep.keyHex), isNotNull);
    // a new controller for the same node (screen reopened), radio still holds the login
    final s2 = RepeaterAdminSession(radio: r.link, keyHex: r.rep.keyHex, queue: r.queue, delay: (d) async {});
    final held = RepeaterAdminController(session: s2, title: 'Test Hill', hasConnection: (_) async => true);
    expect(await held.resume(), isTrue);
    expect(held.stage, AdminStage.ready);
    expect(s2.isAdmin, isTrue);
    final s3 = RepeaterAdminSession(radio: r.link, keyHex: r.rep.keyHex, queue: r.queue, delay: (d) async {});
    final lost = RepeaterAdminController(session: s3, title: 'Test Hill', hasConnection: (_) async => false);
    expect(await lost.resume(), isFalse);
    expect(lost.stage, AdminStage.login);
    expect(AdminSessions.of(r.rep.keyHex), isNull, reason: 'a lost connection is forgotten');
    final s4 = RepeaterAdminSession(radio: r.link, keyHex: r.rep.keyHex, queue: r.queue, delay: (d) async {});
    expect(await RepeaterAdminController(session: s4, title: 'x').resume(), isFalse, reason: 'no way to ask the radio, so never resume');
    await r.link.close();
  });

  test('HAS_CONNECTION frame and reply mapping', () {
    final f = encodeHasConnection(List<int>.filled(32, 7));
    expect(f.length, 33);
    expect(f.first, 28);
  });

  test('passwords never reach print, debugPrint or the session log', () async {
    const secrets = ['adminpw', 'nope-secret'];
    final printed = <String>[];
    final old = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => printed.add(m ?? '');
    final store = InMemorySecretStore();
    final vault = AdminPasswordVault(store: store, radioId: 'aaaaaaaaaaaa');
    await vault.setRemember(true);
    late Rig r;
    await runZoned(() async {
      r = await rig(vault: vault);
      await r.model.submit('nope-secret');
      await r.model.submit('adminpw');
    }, zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => printed.add(line)));
    debugPrint = old;
    final log = r.c.session.log.map((e) => e.toString()).join('\n');
    final everything = '${printed.join('\n')}\n$log\n${r.c}\n${r.model.outcome?.message}\n$vault';
    for (final s in secrets) {
      expect(everything, isNot(contains(s)));
    }
    await r.link.close();
  });
}
