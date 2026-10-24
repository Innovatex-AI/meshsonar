// Repeater list sync against a fake server: ETag/304, rate limits (launch / resume / force), back-off, the network
// capability check (404 = absent, quiet), the on-disk store (instant offline load, versioned, bounded) and privacy.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/repeater_sync.dart';

final k1 = 'da' * 32, k2 = 'db' * 32;

Map<String, dynamic> roster(List<Map<String, dynamic>> rows) => {
      'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T01:00:00Z'},
      'rows': rows,
      'counts': {'active': rows.length, 'quiet': 0, 'new': 0, 'stale': 0},
    };
Map<String, dynamic> row(String key, String name, {bool ambiguous = false, String? prefix}) => {
      'key': key,
      'hashPrefix': prefix ?? key.substring(0, 2),
      'name': name,
      'role': 'repeater',
      'lat': 40.0,
      'lon': -83.0,
      'ambiguous': ambiguous,
      'status': 'active',
    };

class FakeServer {
  final List<http.Request> seen = [];
  int rosterStatus = 200;
  int networkStatus = 404;
  Object rosterBody = roster([row(k1, 'Alpha')]);
  Object networkBody = {
    'v': 1,
    'asOf': '2026-10-24T09:00:00Z',
    'count': 1,
    'hidden': 0,
    'rows': [
      ['ab' * 32, 'Global', 40.2, -83.1, 2, null]
    ],
  };
  String rosterEtag = '"r1"';
  String networkEtag = '"n1"';
  Map<String, String> extraRosterHeaders = {};
  bool offline = false;

  int count(String path) => seen.where((r) => r.url.path.endsWith(path)).length;

  late final client = MockClient((req) async {
    seen.add(req);
    if (offline) throw const SocketException('offline');
    if (req.url.path.endsWith('/region-repeaters')) {
      if (rosterStatus != 200) return http.Response('{"error":"x"}', rosterStatus);
      if (req.headers['if-none-match'] == rosterEtag) return http.Response('', 304, headers: {'etag': rosterEtag});
      return http.Response(jsonEncode(rosterBody), 200, headers: {'etag': rosterEtag, ...extraRosterHeaders});
    }
    if (req.url.path.endsWith('/network-repeaters')) {
      if (networkStatus != 200) return http.Response('{"error":"not found"}', networkStatus);
      if (req.headers['if-none-match'] == networkEtag) return http.Response('', 304, headers: {'etag': networkEtag});
      return http.Response(jsonEncode(networkBody), 200, headers: {'etag': networkEtag});
    }
    return http.Response('nope', 404);
  });
}

class _Clock {
  DateTime t = DateTime.utc(2026, 10, 24, 12);
  DateTime call() => t;
  void advance(Duration d) => t = t.add(d);
}

void main() {
  late Directory dir;
  late FakeServer server;
  late _Clock clock;
  final hub = Uri.parse('https://meshsonar.com');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ms_rsync_');
    server = FakeServer();
    clock = _Clock();
  });
  tearDown(() async {
    await Future<void>.delayed(const Duration(milliseconds: 100)); // let unawaited store writes land
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  RepeaterSync make({bool store = true}) => RepeaterSync(
        store: store ? RepeaterSyncStore(dir) : null,
        rosterClient: () => server.client,
        networkClient: () => server.client,
        clock: clock.call,
        parseInIsolate: false,
      );

  test('launch fetches the roster; a second launch-trigger in the same run and a resume within 10 min do not', () async {
    final s = make();
    expect(await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch), isTrue);
    expect(s.roster('cmh')!.data.rows.single.name, 'Alpha');
    expect(s.rosterLabel('cmh'), 'Updated just now');
    expect(await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch), isFalse);
    clock.advance(const Duration(minutes: 5));
    expect(await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.resume), isFalse);
    expect(server.count('region-repeaters'), 1);
    clock.advance(const Duration(minutes: 6));
    expect(await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.resume), isTrue);
    expect(server.count('region-repeaters'), 2);
    expect(server.seen.last.headers['if-none-match'], '"r1"', reason: 'revalidates with the stored ETag');
    expect(s.rosterLabel('cmh'), 'Updated just now', reason: 'a 304 confirms the stored copy');
  });

  test('concurrent callers share one request; a forced refresh is floored so it cannot loop', () async {
    final s = make();
    await Future.wait([
      for (var i = 0; i < 5; i++) s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch),
    ]);
    expect(server.count('region-repeaters'), 1);
    await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.force);
    expect(server.count('region-repeaters'), 1, reason: 'within the force floor');
    clock.advance(const Duration(seconds: 11));
    await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.force);
    expect(server.count('region-repeaters'), 2);
  });

  test('errors keep the stored copy, label it offline, and back off', () async {
    final s = make();
    await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch);
    server.offline = true;
    clock.advance(const Duration(minutes: 11));
    expect(await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.resume), isFalse);
    expect(s.roster('cmh')!.data.rows, hasLength(1), reason: 'a failure never wipes the stored roster');
    expect(s.rosterLabel('cmh'), 'Offline - as of 11m ago');
    expect(s.regionSet('cmh').state, SyncState.stale);
    server.offline = false;
    server.rosterStatus = 500;
    clock.advance(const Duration(minutes: 11));
    await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.resume);
    expect(s.rosterError('cmh'), 'HTTP 500');
    expect(server.count('region-repeaters'), 3);
  });

  test('the shared ETag client\'s offline copy is not a confirmation', () async {
    server.extraRosterHeaders = {'x-meshsonar-cache': 'offline'};
    final s = make();
    expect(await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch), isFalse);
    expect(s.roster('cmh'), isNull);
    expect(s.regionSet('cmh').state, SyncState.failed);
  });

  test('a body that is not a roster is an error, not an empty list', () async {
    server.rosterBody = {'hello': 'world'};
    final s = make();
    await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch);
    expect(s.roster('cmh'), isNull);
    expect(s.rosterError('cmh'), contains('rows'));
  });

  test('network list absent (404): capability absent, quiet, no retry for 6 h; then available', () async {
    final logs = <String>[];
    final s = make()..log = logs.add;
    expect(await s.syncNetwork(server: hub, trigger: SyncTrigger.launch), isFalse);
    expect(s.networkCapability, NetworkCapability.absent);
    expect(s.networkError, isNull, reason: 'absent is not an error');
    expect(s.globalSet.state, SyncState.unsupported);
    expect(s.networkUsable(), isFalse);
    expect(logs.single, contains('not offered'));
    clock.advance(const Duration(hours: 5));
    await s.syncNetwork(server: hub, trigger: SyncTrigger.resume);
    expect(server.count('network-repeaters'), 1);
    // Persisted: a new run within the 6 h does not ask again either.
    await Future<void>.delayed(const Duration(milliseconds: 50)); // the meta write is not awaited
    final s2 = make();
    await s2.syncNetwork(server: hub, trigger: SyncTrigger.launch);
    expect(server.count('network-repeaters'), 1);
    server.networkStatus = 200;
    clock.advance(const Duration(hours: 2));
    expect(await s2.syncNetwork(server: hub, trigger: SyncTrigger.launch), isTrue);
    expect(s2.networkCapability, NetworkCapability.available);
    expect(s2.network!.data.rows.single.name, 'Global');
    expect(s2.networkUsable(), isTrue);
    expect(s2.globalSet.state, SyncState.ready);
    expect(s2.globalSet.attribution, contains('map.meshcore.io'));
    expect(server.seen.last.url.toString(), 'https://meshsonar.com/api/cmh/network-repeaters');
  });

  test('network list: at most once per 6 h unless forced; 304 revalidates', () async {
    server.networkStatus = 200;
    final s = make();
    await s.syncNetwork(server: hub, trigger: SyncTrigger.launch);
    clock.advance(const Duration(hours: 1));
    await s.syncNetwork(server: hub, trigger: SyncTrigger.resume);
    expect(server.count('network-repeaters'), 1);
    clock.advance(const Duration(seconds: 30));
    await s.syncNetwork(server: hub, trigger: SyncTrigger.force);
    expect(server.count('network-repeaters'), 2);
    expect(server.seen.last.headers['if-none-match'], '"n1"');
    expect(s.network!.data.rows, hasLength(1), reason: '304 keeps the stored rows');
  });

  test('stored lists load at once on the next launch, offline, before any network call', () async {
    server.networkStatus = 200;
    final s = make();
    await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch);
    await s.syncNetwork(server: hub, trigger: SyncTrigger.launch);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // unawaited writes
    server.offline = true;
    final before = server.seen.length;
    final s2 = make();
    await s2.load();
    expect(server.seen.length, before);
    expect(s2.roster('cmh')!.data.rows.single.name, 'Alpha');
    expect(s2.network!.data.rows.single.name, 'Global');
    expect(s2.networkCapability, NetworkCapability.available);
    clock.advance(const Duration(days: 2));
    expect(s2.rosterLabel('cmh'), 'Updated 2d ago');
    await s2.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch);
    expect(s2.rosterLabel('cmh'), 'Offline - as of 2d ago');
    clock.advance(const Duration(days: 1));
    expect(s2.rosterLabel('cmh'), 'Offline - as of 3d ago');
  });

  test('store: versioned (another version or a damaged file is ignored), bounded number of rosters', () async {
    await File('${dir.path}/network.json').writeAsString(jsonEncode({'v': 2, 'rows': []}));
    await File('${dir.path}/roster_cmh.json').writeAsString('{not json');
    final s = make();
    await s.load();
    expect(s.network, isNull);
    expect(s.roster('cmh'), isNull);
    final store = RepeaterSyncStore(dir, maxRosters: 2);
    final small = RepeaterSync(store: store, rosterClient: () => server.client, networkClient: () => server.client, clock: clock.call);
    for (final slug in ['a', 'b', 'c']) {
      clock.advance(const Duration(minutes: 1));
      await small.syncRoster(baseUrl: 'https://$slug.meshsonar.com', slug: slug, trigger: SyncTrigger.launch);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    final kept = await store.loadRosters();
    expect(kept.keys.toSet(), {'b', 'c'});
    expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.tmp')), isEmpty, reason: 'atomic writes leave no temp files');
  });

  test('privacy: GETs only, no driver key, no position, no identifier; region only in the host', () async {
    server.networkStatus = 200;
    final s = make();
    await s.syncRoster(baseUrl: 'https://meshsonar.com', slug: 'day', trigger: SyncTrigger.launch);
    await s.syncNetwork(server: hub, trigger: SyncTrigger.launch);
    for (final r in server.seen) {
      expect(r.method, 'GET');
      expect(r.url.hasQuery, isFalse);
      expect(r.body, isEmpty);
      expect(r.headers.keys.map((k) => k.toLowerCase()).toSet().difference({'accept', 'if-none-match'}), isEmpty);
    }
    expect(server.seen.first.url.host, 'day.meshsonar.com');
  });

  test('regionSet exposes positioned rows with room type and the roster time', () async {
    server.rosterBody = roster([row(k1, 'Alpha'), {...row(k2, 'Room'), 'role': 'room'}, {...row('dc' * 32, 'NoPos'), 'lat': null}]);
    final s = make(store: false);
    expect(s.regionSet('cmh').state, SyncState.idle);
    await s.syncRoster(baseUrl: 'https://cmh.meshsonar.com', slug: 'cmh', trigger: SyncTrigger.launch);
    final set = s.regionSet('cmh');
    expect(set.state, SyncState.ready);
    expect(set.rows.map((r) => r.name), ['Alpha', 'Room']);
    expect(set.rows.last.type, 3);
    expect(identical(set.rows, s.regionSet('cmh').rows), isTrue, reason: 'same identity until the data changes');
  });
}
