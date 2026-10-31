import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/sync_service.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

/// A small stand-in for CMAT's drive-upload: dedupes by ping id, rejects pings whose lat is exactly 0 (via [badIds]),
/// and can be told to fail with a status or a network error.
class FakeServer {
  final Set<String> stored = {};
  final Set<String> badIds = {};
  final List<Map<String, dynamic>> uploads = [];
  int? failStatus;
  bool networkDown = false;
  int failAfter = -1; // fail (network) on the nth upload (0-based); -1 = never

  late final MockClient client = MockClient((req) async {
    if (networkDown || (failAfter >= 0 && uploads.length == failAfter)) {
      throw http.ClientException('connection reset');
    }
    if (failStatus != null) {
      return http.Response(jsonEncode({'error': 'driver key is revoked', 'status': 'revoked'}), failStatus!);
    }
    expect(req.url.path, '/api/cmh/drive-upload');
    final body = jsonDecode(req.body) as Map<String, dynamic>;
    expect(shapeProblems(body), isEmpty);
    final pings = (body['pings'] as List).cast<Map<String, dynamic>>();
    expect(pings.length, lessThanOrEqualTo(5000));
    uploads.add(body);
    var s = 0, d = 0;
    final rejections = <Map<String, dynamic>>[];
    for (final (i, ping) in pings.indexed) {
      final id = ping['id'] as String;
      if (badIds.contains(id)) {
        rejections.add({'index': i, 'id': id, 'reason': 'lat/lon missing or out of range'});
      } else if (stored.add(id)) {
        s++;
      } else {
        d++;
      }
    }
    return http.Response(
        jsonEncode({
          'sessionId': body['session']['id'], 'stored': s, 'duplicate': d, 'rejected': rejections.length,
          'rejections': rejections.take(20).toList(),
        }),
        200);
  });
}

void main() {
  late Directory tmp;
  late JsonlDriveStore store;
  late FileSettingsStore settings;
  late FakeServer server;
  late DefaultSyncService sync;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshsonar_sync_');
    store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
    settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
    await settings.save(const Settings(driverKey: 'ms_testkey_0123456789abcdef', keyStatus: DriverKeyStatus.approved));
    server = FakeServer();
    sync = DefaultSyncService(
        store: store, client: HttpCmatClient(Uri.parse('https://cmat.test'), client: server.client), settings: settings);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<DriveSession> drive(int n, {DateTime? endedAt, DateTime? startedAt}) async {
    final s = makeSession(startedAt: startedAt, endedAt: null);
    await store.startSession(s);
    final base = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    for (var i = 0; i < n; i++) {
      await store.appendPing(s.id, makePing(i, ts: base.add(Duration(milliseconds: i * 100))));
    }
    if (endedAt != null) await store.endSession(s.id, endedAt);
    return (await store.session(s.id))!;
  }

  test('a Simulator drive is never uploaded (made-up data stays off the community map)', () async {
    final base = makeSession();
    final s = DriveSession(
        id: base.id,
        startedAt: base.startedAt,
        radio: base.radio,
        antenna: base.antenna,
        companion: const Companion(firmware: 'v1.18.0-sim', name: 'MeshSonar Sim'));
    expect(s.isSimulated, isTrue);
    await store.startSession(s);
    await store.appendPing(s.id, makePing(0, ts: DateTime.now().toUtc()));
    final r = await sync.syncSession(s.id);
    expect(r.error, isNull);
    expect(r.stored, 0);
    final all = await sync.syncAll();
    expect(all.error, isNull);
    expect(server.uploads, isEmpty);
    expect(await store.unsyncedPings(s.id), hasLength(1), reason: 'kept on the phone');
  });

  test('no key → error, nothing uploaded', () async {
    await settings.save(const Settings());
    final s = await drive(3);
    final r = await sync.syncSession(s.id);
    expect(r.error, isNotNull);
    expect(server.uploads, isEmpty);
    expect(await store.unsyncedPings(s.id), hasLength(3));
  });

  test('key not approved (pending) → error, nothing uploaded', () async {
    await settings.save(const Settings(driverKey: 'ms_testkey_0123456789abcdef', keyStatus: DriverKeyStatus.pending));
    await drive(3);
    final r = await sync.syncAll();
    expect(r.error, 'key not approved');
    expect(server.uploads, isEmpty);
  });

  test('uploads unsynced pings, marks them synced after 200, heard-nothing pings included', () async {
    final s = await drive(10);
    final r = await sync.syncSession(s.id);
    expect(r.error, isNull);
    expect(r.stored, 10);
    expect(r.sessions, 1);
    expect(server.uploads, hasLength(1));
    final sent = (server.uploads.single['pings'] as List).cast<Map>();
    expect(sent.where((e) => (e['echoes'] as List).isEmpty && e['neighbor'] == null), isNotEmpty);
    expect(server.uploads.single['session']['id'], s.id);
    expect(server.uploads.single['app']['name'], 'MeshSonar');
    expect(await store.unsyncedPings(s.id), isEmpty);
    expect((await store.sessions()).single.syncedCount, 10);
  });

  test('12,001 pings → 3 requests of ≤5,000, all marked synced', () async {
    final s = makeSession();
    await store.startSession(s);
    // Write the jsonl directly for speed; same format appendPing produces.
    final base = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    final lines = StringBuffer();
    for (var i = 0; i < 12001; i++) {
      lines.writeln(jsonEncode(makePing(i, ts: base.add(Duration(milliseconds: i))).toJson()));
    }
    await File(p.join(tmp.path, 'drives', 'sessions', s.id, 'pings.jsonl')).writeAsString(lines.toString());
    final r = await sync.syncSession(s.id);
    expect(r.error, isNull);
    expect(server.uploads.map((u) => (u['pings'] as List).length), [5000, 5000, 2001]);
    expect(r.stored, 12001);
    expect(await store.unsyncedPings(s.id), isEmpty);
  });

  test('re-sync after success sends nothing (no double upload)', () async {
    final s = await drive(5);
    await sync.syncSession(s.id);
    final r = await sync.syncSession(s.id);
    expect(server.uploads, hasLength(1));
    expect(r.stored, 0);
    expect(r.sessions, 0);
  });

  test('overlapping sync calls never upload the same pings twice', () async {
    await drive(7);
    final rs = await Future.wait([sync.syncAll(), sync.syncAll(), sync.syncAll()]);
    expect(server.uploads, hasLength(1));
    expect(rs.map((r) => r.stored).reduce((a, b) => a + b), 7);
    expect(rs.map((r) => r.duplicate).reduce((a, b) => a + b), 0);
  });

  test('retry after a mid-sync network failure: confirmed chunks not re-sent, rest sent next time', () async {
    final sync2 = DefaultSyncService(
        store: store,
        client: HttpCmatClient(Uri.parse('https://cmat.test'), client: server.client),
        settings: settings,
        chunkSize: 4);
    final s = await drive(10);
    server.failAfter = 1; // second request dies
    final r1 = await sync2.syncSession(s.id);
    expect(r1.error, contains('network'));
    expect(r1.stored, 4);
    expect(await store.unsyncedPings(s.id), hasLength(6));
    server.failAfter = -1;
    final r2 = await sync2.syncSession(s.id);
    expect(r2.error, isNull);
    expect(r2.stored, 6);
    expect(r2.duplicate, 0);
    expect(server.stored, hasLength(10));
    expect(await store.unsyncedPings(s.id), isEmpty);
  });

  test('server already has the pings (lost 200) → counted duplicate and marked synced', () async {
    final s = await drive(4);
    server.stored.addAll((await store.pings(s.id)).map((e) => e.id));
    final r = await sync.syncSession(s.id);
    expect(r.duplicate, 4);
    expect(r.stored, 0);
    expect(await store.unsyncedPings(s.id), isEmpty);
  });

  test('403 → "key not approved", nothing marked, data kept', () async {
    final s = await drive(5, endedAt: DateTime.now().toUtc());
    server.failStatus = 403;
    final r = await sync.syncSession(s.id);
    expect(r.error, 'key not approved');
    expect(await store.unsyncedPings(s.id), hasLength(5));
    expect(await store.endReported(s.id), isNull);
    expect(await store.rejectedIds(s.id), isEmpty);
  });

  test('403 in syncAll stops after the first session', () async {
    await drive(2, startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)));
    await drive(2, startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)));
    var calls = 0;
    final c = MockClient((_) async {
      calls++;
      return http.Response(jsonEncode({'error': 'driver key is revoked', 'status': 'revoked'}), 403);
    });
    final s2 = DefaultSyncService(store: store, client: HttpCmatClient(Uri.parse('https://cmat.test'), client: c), settings: settings);
    final r = await s2.syncAll();
    expect(r.error, 'key not approved');
    expect(calls, 1);
  });

  test('network down → error reported, all data kept for next time', () async {
    final s = await drive(6, endedAt: DateTime.now().toUtc());
    server.networkDown = true;
    final r = await sync.syncSession(s.id);
    expect(r.error, isNotNull);
    expect(await store.unsyncedPings(s.id), hasLength(6));
    expect(await store.pings(s.id), hasLength(6));
    expect(await store.endReported(s.id), isNull);
    server.networkDown = false;
    final r2 = await sync.syncSession(s.id);
    expect(r2.error, isNull);
    expect(r2.stored, 6);
  });

  test('rejected pings are kept locally, not marked synced, and never re-sent', () async {
    final s = await drive(6);
    final all = await store.pings(s.id);
    server.badIds.addAll([all[1].id, all[4].id]);
    final r = await sync.syncSession(s.id);
    expect(r.stored, 4);
    expect(r.rejected, 2);
    expect(await store.rejectedIds(s.id), {all[1].id, all[4].id});
    expect(await store.unsyncedPings(s.id), isEmpty);
    expect(await store.pings(s.id), hasLength(6));
    expect((await store.sessions()).single.syncedCount, 4);
    // Next sync: nothing to send.
    await sync.syncSession(s.id);
    expect(server.uploads, hasLength(1));
  });

  test('more than 20 rejections: unnamed rejects are found by re-sending, good pings all synced', () async {
    final s = await drive(60);
    final all = await store.pings(s.id);
    final bad = [for (var i = 0; i < 60; i += 2) all[i].id]; // 30 bad, only 20 reported per answer
    server.badIds.addAll(bad);
    final r = await sync.syncSession(s.id);
    expect(r.error, isNull);
    expect(r.stored, 30);
    expect(r.rejected, 30);
    expect(await store.rejectedIds(s.id), bad.toSet());
    expect(await store.unsyncedPings(s.id), isEmpty);
    expect(server.stored, hasLength(30));
    expect(server.uploads.length, 2);
  });

  test('ended session with everything synced sends one empty-pings upload, once', () async {
    final s = await drive(3);
    await sync.syncSession(s.id); // pings synced while still driving
    expect(server.uploads, hasLength(1));
    final end = DateTime.now().toUtc();
    await store.endSession(s.id, end);
    final r = await sync.syncSession(s.id);
    expect(r.error, isNull);
    expect(server.uploads, hasLength(2));
    expect(server.uploads.last['pings'], isEmpty);
    expect(server.uploads.last['session']['ended_at'], end.toIso8601String());
    expect(await store.endReported(s.id), end);
    await sync.syncSession(s.id);
    await sync.syncAll();
    expect(server.uploads, hasLength(2));
  });

  test('ended session whose pings go up in the same sync does not send an extra empty upload', () async {
    final s = await drive(3, endedAt: DateTime.now().toUtc());
    await sync.syncSession(s.id);
    expect(server.uploads, hasLength(1));
    expect(server.uploads.single['session']['ended_at'], isNotNull);
    await sync.syncSession(s.id);
    expect(server.uploads, hasLength(1));
  });

  test('ended session with zero pings at all still reports its end once', () async {
    await drive(0, endedAt: DateTime.now().toUtc());
    await sync.syncAll();
    await sync.syncAll();
    expect(server.uploads, hasLength(1));
    expect(server.uploads.single['pings'], isEmpty);
  });

  test('a still-open session with nothing to send makes no request', () async {
    await drive(0);
    final r = await sync.syncAll();
    expect(server.uploads, isEmpty);
    expect(r.error, isNull);
  });

  test('syncAll totals across sessions', () async {
    await drive(3, startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 3)));
    await drive(4, startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)));
    final r = await sync.syncAll();
    expect(r.sessions, 2);
    expect(r.stored, 7);
    expect(r.error, isNull);
  });

  test('unknown session id → error', () async {
    final r = await sync.syncSession(newId());
    expect(r.error, isNotNull);
  });

  test('works with a DriveStore that has no ledger (in-memory rejected/end tracking)', () async {
    final mem = _MemStore();
    final s = makeSession(endedAt: DateTime.now().toUtc());
    await mem.startSession(s);
    final pings = [for (var i = 0; i < 3; i++) makePing(i)];
    for (final x in pings) {
      await mem.appendPing(s.id, x);
    }
    server.badIds.add(pings[0].id);
    final sv = DefaultSyncService(
        store: mem, client: HttpCmatClient(Uri.parse('https://cmat.test'), client: server.client), settings: settings);
    final r = await sv.syncSession(s.id);
    expect(r.stored, 2);
    expect(r.rejected, 1);
    await sv.syncSession(s.id);
    expect(server.uploads, hasLength(1));
  });

  test('a renamed drive re-sends its session (new label) once, even with every ping already up', () async {
    final s = await drive(3, endedAt: DateTime.now().toUtc());
    await sync.syncSession(s.id);
    expect(server.uploads, hasLength(1));
    await store.renameSession(s.id, 'Route 3 north');
    expect((await store.sessions()).single.hasSomethingToSync, isTrue);
    final r = await sync.syncSession(s.id);
    expect(r.error, isNull);
    expect(server.uploads, hasLength(2));
    expect(server.uploads.last['pings'], isEmpty);
    expect(server.uploads.last['session']['label'], 'Route 3 north');
    expect(server.uploads.last['session']['ended_at'], isNotNull);
    expect(await store.sessionResendToken(s.id), isNull);
    await sync.syncAll();
    expect(server.uploads, hasLength(2), reason: 'sent once');
  });

  test('a rename with pings still to send rides on that upload (no extra request); open drives too', () async {
    final s = await drive(3);
    await store.renameSession(s.id, 'Morning loop');
    await sync.syncSession(s.id);
    expect(server.uploads, hasLength(1));
    expect(server.uploads.single['session']['label'], 'Morning loop');
    expect(await store.sessionResendToken(s.id), isNull);
    // Renamed while still open with nothing new: one session-only upload, ended_at still null.
    await store.renameSession(s.id, 'Evening loop');
    await sync.syncSession(s.id);
    expect(server.uploads, hasLength(2));
    expect(server.uploads.last['session']['label'], 'Evening loop');
    expect(server.uploads.last['session']['ended_at'], isNull);
    expect(await store.endReported(s.id), isNull);
  });

  test('a failed upload keeps the rename marked for the next sync', () async {
    final s = await drive(2, endedAt: DateTime.now().toUtc());
    await sync.syncSession(s.id);
    await store.renameSession(s.id, 'Renamed');
    server.networkDown = true;
    expect((await sync.syncSession(s.id)).error, isNotNull);
    expect(await store.sessionResendToken(s.id), isNotNull);
    server.networkDown = false;
    await sync.syncSession(s.id);
    expect(server.uploads.last['session']['label'], 'Renamed');
    expect(await store.sessionResendToken(s.id), isNull);
  });

  test('a drive closed after a crash (orphan) reports its end on the next sync', () async {
    final s = await drive(4, startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 6)));
    await sync.syncSession(s.id); // uploaded mid-drive, then the app was killed
    expect(server.uploads.single['session']['ended_at'], isNull);
    final closed = await closeOrphanedSessions(store);
    expect(closed, [s.id]);
    await sync.syncAll();
    expect(server.uploads, hasLength(2));
    final last = (await store.pings(s.id)).map((e) => e.ts).reduce((a, b) => a.isAfter(b) ? a : b);
    expect(server.uploads.last['session']['ended_at'], last.toIso8601String());
  });

  test('sessions(): a drive with rejected pings shows nothing left to sync after its upload', () async {
    final s = await drive(5, endedAt: DateTime.now().toUtc());
    server.badIds.add((await store.pings(s.id))[2].id);
    await sync.syncSession(s.id);
    final x = (await store.sessions()).single;
    expect(x.syncedCount, 4);
    expect(x.rejectedCount, 1);
    expect(x.unsyncedCount, 0);
    expect(x.hasSomethingToSync, isFalse);
  });
}

/// Minimal DriveStore without SyncLedger.
class _MemStore implements DriveStore {
  final Map<String, DriveSession> _s = {};
  final Map<String, List<DrivePing>> _p = {};
  final Map<String, Set<String>> _synced = {};
  @override
  Future<void> startSession(DriveSession session) async {
    _s[session.id] = session;
    _p[session.id] = [];
    _synced[session.id] = {};
  }

  @override
  Future<void> appendPing(String sessionId, DrivePing ping) async => _p[sessionId]!.add(ping);
  @override
  Future<void> endSession(String sessionId, DateTime endedAt) async => _s[sessionId] = _s[sessionId]!.copyWith(endedAt: endedAt);
  @override
  Future<void> renameSession(String sessionId, String? label) async => _s[sessionId] = _s[sessionId]!.copyWith(label: label);
  @override
  Future<DriveSession?> session(String sessionId) async => _s[sessionId];
  @override
  Future<List<SessionSummary>> sessions() async => [
        for (final s in _s.values)
          SessionSummary(session: s, pingCount: _p[s.id]!.length, heardCount: 0, syncedCount: _synced[s.id]!.length)
      ];
  @override
  Future<List<DrivePing>> pings(String sessionId) async => _p[sessionId]!;
  @override
  Future<List<DrivePing>> unsyncedPings(String sessionId) async =>
      _p[sessionId]!.where((x) => !_synced[sessionId]!.contains(x.id)).toList();
  @override
  Future<void> markSynced(String sessionId, Iterable<String> pingIds) async => _synced[sessionId]!.addAll(pingIds);
  @override
  Future<void> deleteSession(String sessionId) async => _s.remove(sessionId);
  @override
  Future<File> exportSession(String sessionId, AppInfo app, Directory outDir) => throw UnimplementedError();
}
