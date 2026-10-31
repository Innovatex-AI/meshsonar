// How the sync service reacts to every non-200 answer and to a dead network: it stops hammering, keeps every ping on
// the phone and loses nothing (a ping is marked synced only after a 200).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/messages.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/sync_service.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

void main() {
  late Directory tmp;
  late JsonlDriveStore store;
  late FileSettingsStore settings;
  late DefaultSyncService sync;
  final requests = <int>[]; // pings per request
  final stored = <String>{};
  http.Response? Function(int pings)? script;

  setUp(() async {
    requests.clear();
    stored.clear();
    script = null;
    tmp = await Directory.systemTemp.createTemp('meshsonar_codes_');
    store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
    settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
    await settings.save(const Settings(driverKey: 'ms_testkey_0123456789abcdef', keyStatus: DriverKeyStatus.approved));
    final client = MockClient((req) async {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      final pings = (body['pings'] as List).cast<Map<String, dynamic>>();
      requests.add(pings.length);
      final s = script?.call(pings.length);
      if (s != null) return s;
      var n = 0, d = 0;
      for (final x in pings) {
        stored.add(x['id'] as String) ? n++ : d++;
      }
      return http.Response(
          jsonEncode({'sessionId': body['session']['id'], 'stored': n, 'duplicate': d, 'rejected': 0, 'rejections': []}), 200);
    });
    sync = DefaultSyncService(store: store, client: HttpCmatClient(Uri.parse('https://cmat.test'), client: client), settings: settings);
  });
  tearDown(() async => tmp.delete(recursive: true));

  Future<String> drive(int n) async {
    final s = makeSession();
    await store.startSession(s);
    final base = DateTime.now().toUtc().subtract(const Duration(hours: 5));
    final lines = StringBuffer();
    for (var i = 0; i < n; i++) {
      lines.writeln(jsonEncode(makePing(i, ts: base.add(Duration(milliseconds: i))).toJson()));
    }
    await File(p.join(tmp.path, 'drives', 'sessions', s.id, 'pings.jsonl')).writeAsString(lines.toString());
    await store.endSession(s.id, DateTime.now().toUtc());
    return s.id;
  }

  http.Response json(int code, Map<String, dynamic> b, {Map<String, String> h = const {}}) =>
      http.Response(jsonEncode(b), code, headers: h);

  test('429 with Retry-After: the run stops at the first request, reports the wait, loses nothing', () async {
    final ids = [await drive(5), await drive(5), await drive(5)];
    script = (_) => json(429, {'error': 'rate limited'}, h: {'retry-after': '30'});
    final r = await sync.syncAll();
    expect(requests, hasLength(1), reason: 'no hammering: the other drives are not even tried');
    expect(r.retryAfterSec, 30);
    expect(r.error, contains('slow down'));
    for (final id in ids) {
      expect(await store.unsyncedPings(id), hasLength(5));
    }
    // Later, the server is happy: everything goes up.
    script = null;
    final ok = await sync.syncAll();
    expect(ok.error, isNull);
    expect(ok.stored, 15);
    expect(ok.retryAfterSec, isNull);
  });

  test('429 without Retry-After defaults to 60 s', () async {
    await drive(3);
    script = (_) => json(429, {'error': 'x'});
    final r = await sync.syncAll();
    expect(r.retryAfterSec, DefaultSyncService.defaultRetryAfterSec);
  });

  test('5xx stops the run and keeps everything', () async {
    final ids = [await drive(4), await drive(4)];
    script = (_) => json(503, {'error': 'database unavailable'}, h: {'retry-after': '120'});
    final r = await sync.syncAll();
    expect(requests, hasLength(1));
    expect(r.error, contains('503'));
    expect(r.retryAfterSec, 120);
    expect(friendlySyncError(r.error!), contains('server had a problem'));
    for (final id in ids) {
      expect(await store.unsyncedPings(id), hasLength(4));
    }
    script = (_) => json(500, {'error': 'boom'});
    final r500 = await sync.syncAll();
    expect(r500.error, contains('500'));
    expect(r500.retryAfterSec, isNull, reason: 'only 429 / 503 carry a wait');
  });

  test('network down stops after the first session instead of timing out once per queued drive', () async {
    await drive(3);
    await drive(3);
    await drive(3);
    var attempts = 0;
    final client = MockClient((req) async {
      attempts++;
      throw http.ClientException('connection reset');
    });
    final s2 = DefaultSyncService(store: store, client: HttpCmatClient(Uri.parse('https://cmat.test'), client: client), settings: settings);
    final r = await s2.syncAll();
    expect(attempts, 1);
    expect(r.error, isNotNull);
    expect(friendlySyncError(r.error!), contains('reach the server'));
  });

  test('413 splits the chunk until the server takes it; all pings arrive exactly once', () async {
    final id = await drive(3000);
    script = (n) => n > 700 ? json(413, {'error': 'payload too large'}) : null; // null = the normal 200
    final r = await sync.syncSession(id);
    expect(r.error, isNull);
    expect(r.stored, 3000);
    expect(stored, hasLength(3000));
    expect(await store.unsyncedPings(id), isEmpty);
    expect(requests.first, 3000);
    expect(requests.where((n) => n <= 700).fold<int>(0, (a, b) => a + b), 3000);
  });

  test('413 on a single ping is reported, the ping stays', () async {
    final id = await drive(1);
    script = (_) => json(413, {'error': 'too large'});
    final r = await sync.syncSession(id);
    expect(r.error, contains('413'));
    expect(friendlySyncError(r.error!), contains('too large'));
    expect(await store.unsyncedPings(id), hasLength(1));
  });

  test('friendly texts for rate limit and server errors', () {
    expect(friendlySyncError('HTTP 429: the server asked us to slow down'), contains('slow down'));
    expect(friendlySyncError('HTTP 502: the server had a problem'), contains('server had a problem'));
  });
}
