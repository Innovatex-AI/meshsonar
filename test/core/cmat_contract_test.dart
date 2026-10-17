// Contract test: the app's store + client + sync against CMAT's REAL endpoint code
// (meshcore-insights src/lib/drive/handlers.ts + validate.ts, in-memory store), served by bun from
// test/fixtures/cmat_server.ts. If this passes, MeshSonar and the server agree on the wire format.
// Skips when bun or the CMAT checkout isn't present. CMAT_DIR=<meshcore-insights checkout>, BUN=<bun> (cmat_env.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/sync_service.dart';
import 'package:path/path.dart' as p;

import 'cmat_env.dart';
import 'helpers.dart';

const adminKey = 'contract-admin-key-0123456789';

void main() {
  // CMAT_DIR / BUN as in cmat_env.dart; skipped with the reason when either is missing.
  final bun = findBun();
  final skip = contractSkipReason('src/lib/drive/handlers.ts');

  Process? server;
  late Uri base;
  final stderrBuf = StringBuffer();

  setUpAll(() async {
    if (skip != null) return;
    final script = p.join(Directory.current.path, 'test', 'fixtures', 'cmat_server.ts');
    server = await Process.start(bun!, ['run', script, adminKey, cmatDir()]);
    server!.stderr.transform(utf8.decoder).listen(stderrBuf.write);
    final lines = server!.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final portLine = await lines.firstWhere((l) => l.startsWith('PORT ')).timeout(const Duration(seconds: 20),
        onTimeout: () => throw StateError('bun server did not start: $stderrBuf'));
    lines.listen((_) {});
    base = Uri.parse('http://127.0.0.1:${int.parse(portLine.substring(5).trim())}');
  });

  tearDownAll(() async {
    server?.kill();
    await server?.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  });

  Future<Map<String, dynamic>> admin(Map<String, Object?> body) async {
    final r = await http.post(base.resolve('/api/cmh/driver-admin'),
        headers: {'x-admin-key': adminKey, 'content-type': 'application/json'}, body: jsonEncode(body));
    expect(r.statusCode, 200, reason: r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> serverState() async =>
      jsonDecode((await http.get(base.resolve('/__test/state'))).body) as Map<String, dynamic>;

  test('request key → approve → upload real drive → re-sync duplicates → end reported', () async {
    final tmp = await Directory.systemTemp.createTemp('meshsonar_contract_');
    addTearDown(() => tmp.delete(recursive: true));
    final client = HttpCmatClient(base);
    final settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));

    // 1. Request a key: pending in approval mode.
    final req = await client.requestKey(name: 'Andy Contract', callsign: 'ke4bfi', email: 'andy@example.org');
    expect(req.status, DriverKeyStatus.pending);
    expect(req.key, startsWith('ms_'));
    expect(req.display, 'KE4BFI');
    expect((await client.status(req.key)).status, DriverKeyStatus.pending);

    // Pending key can't upload: 403 surfaces as "key not approved", nothing changes locally.
    final store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
    final session = makeSession(startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)));
    await store.startSession(session);
    final base0 = DateTime.now().toUtc().subtract(const Duration(minutes: 90));
    final pings = <DrivePing>[
      for (var i = 0; i < 40; i++) makePing(i, ts: base0.add(Duration(seconds: i * 30))),
      // Fully-null-optional heard-nothing ping and an rx ping.
      DrivePing(id: newId(), ts: base0.add(const Duration(minutes: 21)), lat: 40.13, lon: -82.94),
      DrivePing(
          id: newId(), ts: base0.add(const Duration(minutes: 22)), lat: 40.131, lon: -82.941, kind: PingKind.rx,
          noiseFloorDbm: -101.5, echoes: const [Echo(repeater: 'DF0136', snrDb: -12.25, rssiDbm: -118, hops: 3, path: ['ab', 'cd', 'df'])]),
    ];
    for (final x in pings) {
      await store.appendPing(session.id, x);
    }
    expect(pings.where((x) => x.heardNothing), isNotEmpty);
    expect(pings.where((x) => x.neighbor != null), isNotEmpty);
    expect(pings.where((x) => x.echoes.any((e) => (e.path?.length ?? 0) > 1)), isNotEmpty);

    await settings.save(Settings(serverUrl: base.toString(), driverKey: req.key, keyStatus: DriverKeyStatus.approved));
    final sync = DefaultSyncService(store: store, client: client, settings: settings);
    final denied = await sync.syncSession(session.id);
    expect(denied.error, 'key not approved');
    expect(await store.unsyncedPings(session.id), hasLength(pings.length));

    // 2. Admin approves.
    final approved = await admin({'action': 'approve', 'driverId': req.driverId});
    expect(approved['status'], 'approved');
    expect((await client.status(req.key)).status, DriverKeyStatus.approved);

    // 3. Upload through the real sync path.
    final r1 = await sync.syncSession(session.id);
    expect(r1.error, isNull);
    expect(r1.stored, pings.length);
    expect(r1.duplicate, 0);
    expect(r1.rejected, 0);
    expect(await store.unsyncedPings(session.id), isEmpty);
    expect((await store.sessions()).single.syncedCount, pings.length);

    var st = await serverState();
    final srvSession = (st['sessions'] as List).cast<Map>().singleWhere((s) => s['id'] == session.id);
    expect(srvSession['pingCount'], pings.length);
    expect(srvSession['label'], session.label);
    expect(srvSession['endedAt'], isNull);
    final srvPings = {for (final x in (st['pings'] as List).cast<Map>()) x['id']: x};
    for (final x in pings) {
      expect(srvPings[x.id], isNotNull, reason: 'ping ${x.id} not stored');
      expect(srvPings[x.id]!['echoes'], x.echoes.length);
      expect(srvPings[x.id]!['neighbor'], x.neighbor != null);
    }

    // 4. Re-send everything (e.g. a lost 200): the server reports duplicates, stores nothing new.
    final again = await client.upload(req.key, DriveBatch(app: sync.app, session: session, pings: pings));
    expect(again.stored, 0);
    expect(again.duplicate, pings.length);
    expect(again.rejected, 0);

    // 5. End the drive: one empty-pings upload tells the server the end time, once.
    final end = DateTime.now().toUtc();
    await store.endSession(session.id, end);
    final r2 = await sync.syncSession(session.id);
    expect(r2.error, isNull);
    expect(r2.sessions, 1);
    st = await serverState();
    final ended = (st['sessions'] as List).cast<Map>().singleWhere((s) => s['id'] == session.id);
    expect(DateTime.parse(ended['endedAt'] as String).millisecondsSinceEpoch, end.millisecondsSinceEpoch);
    expect(ended['pingCount'], pings.length);
    final r3 = await sync.syncSession(session.id);
    expect(r3.sessions, 0);

    // 6. The export file is accepted unchanged by the server too.
    final f = await store.exportSession(session.id, sync.app, Directory(p.join(tmp.path, 'out')));
    final resp = await http.post(base.resolve('/api/cmh/drive-upload'),
        headers: {'x-driver-key': req.key, 'content-type': 'application/json'}, body: await f.readAsString());
    expect(resp.statusCode, 200, reason: resp.body);
    final rj = jsonDecode(resp.body) as Map;
    expect(rj['rejected'], 0);
    expect(rj['duplicate'], pings.length);

    // 7. Repeaters endpoint parses.
    final reps = await client.repeaters(req.key);
    expect(reps.single.name, 'Test Repeater');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('12,001 pings sync in 3 requests and the real server stores all of them', () async {
    final tmp = await Directory.systemTemp.createTemp('meshsonar_contract_big_');
    addTearDown(() => tmp.delete(recursive: true));
    final client = HttpCmatClient(base);
    final req = await client.requestKey(name: 'Bulk Driver');
    await admin({'action': 'approve', 'driverId': req.driverId});
    final settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
    await settings.save(Settings(driverKey: req.key, keyStatus: DriverKeyStatus.approved));
    final store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
    final session = makeSession(startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 6)));
    await store.startSession(session);
    final t0 = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    final buf = StringBuffer();
    for (var i = 0; i < 12001; i++) {
      buf.writeln(jsonEncode(makePing(i, ts: t0.add(Duration(milliseconds: i * 500))).toJson()));
    }
    await File(p.join(tmp.path, 'drives', 'sessions', session.id, 'pings.jsonl')).writeAsString(buf.toString());
    final r = await DefaultSyncService(store: store, client: client, settings: settings).syncSession(session.id);
    expect(r.error, isNull);
    expect(r.stored, 12001);
    expect(r.rejected, 0);
    final st = await serverState();
    expect((st['sessions'] as List).cast<Map>().singleWhere((s) => s['id'] == session.id)['pingCount'], 12001);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('pings the real validator rejects are recorded locally and not re-sent; good ones stored', () async {
    final tmp = await Directory.systemTemp.createTemp('meshsonar_contract_rej_');
    addTearDown(() => tmp.delete(recursive: true));
    final client = HttpCmatClient(base);
    final req = await client.requestKey(name: 'Reject Driver');
    await admin({'action': 'approve', 'driverId': req.driverId});
    final settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
    await settings.save(Settings(driverKey: req.key, keyStatus: DriverKeyStatus.approved));
    final store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
    final session = makeSession();
    await store.startSession(session);
    final t = DateTime.now().toUtc().subtract(const Duration(minutes: 10));
    final good = makePing(1, ts: t);
    final badSnr = DrivePing(id: newId(), ts: t, lat: 40.1, lon: -82.9, echoes: const [Echo(repeater: 'aa', snrDb: 99)]);
    final badHex = DrivePing(id: newId(), ts: t, lat: 40.1, lon: -82.9, echoes: const [Echo(repeater: 'abc')]);
    final nullIsland = DrivePing(id: newId(), ts: t, lat: 0, lon: 0);
    for (final x in [good, badSnr, badHex, nullIsland]) {
      await store.appendPing(session.id, x);
    }
    final sync = DefaultSyncService(store: store, client: client, settings: settings);
    final r = await sync.syncSession(session.id);
    expect(r.error, isNull);
    expect(r.stored, 1);
    expect(r.rejected, 3);
    expect(await store.rejectedIds(session.id), {badSnr.id, badHex.id, nullIsland.id});
    expect(await store.unsyncedPings(session.id), isEmpty);
    expect(await store.pings(session.id), hasLength(4)); // kept locally
    final r2 = await sync.syncSession(session.id);
    expect(r2.stored + r2.duplicate + r2.rejected, 0);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('unknown key → 401; revoked key → status revoked and upload 403', () async {
    final client = HttpCmatClient(base);
    await expectLater(client.status('ms_this_key_does_not_exist_000'),
        throwsA(isA<CmatException>().having((e) => e.status, 'status', 401)));
    final req = await client.requestKey(name: 'Revoked Driver');
    await admin({'action': 'approve', 'driverId': req.driverId});
    await admin({'action': 'revoke', 'driverId': req.driverId});
    expect((await client.status(req.key)).status, DriverKeyStatus.revoked);
    await expectLater(
        client.upload(req.key, DriveBatch(app: const AppInfo(), session: makeSession(), pings: const [])),
        throwsA(isA<CmatException>().having((e) => e.status, 'status', 403)));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));
}
