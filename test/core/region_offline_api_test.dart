// The region data APIs through the real EtagClient + RegionCache: online answers are stored; offline, the stored copy
// comes back flagged with its fetch time (the "Offline - as of" label); offline with nothing stored throws/fails with
// an offline flag so the panels can show their honest "No connection" state.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/etag_client.dart';
import 'package:meshsonar/core/region_analysis_api.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/core/region_packets_api.dart';
import 'package:meshsonar/core/region_reports_api.dart';
import 'package:meshsonar/core/region_stats_api.dart';

const _status = {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T10:00:00Z', 'source': 's'};

Object? _body(String path) {
  final name = path.split('/').last;
  return switch (name) {
    'region-overview' => {'status': _status, 'packets24h': 612, 'repeaters': 326},
    'region-observers' => {
        'status': _status,
        'rows': [
          {'key': 'abcdef0123', 'name': 'OBS-1', 'online': true},
        ],
      },
    'region-packets' => {
        'status': _status,
        'rows': [
          {'hash': 'a1', 'type': 5, 'route': 1, 'firstAt': '2026-10-24T09:00:00Z', 'observers': 2, 'minHops': 1},
        ],
      },
    'public-stats' => {'drives': 45, 'pings': 1715, 'km': 533.1},
    'leaderboard' => {'period': '30d', 'rows': []},
    'public-live' => {'activeDrivers': 1, 'pings15m': 3},
    'region-report' => {
        'region': {'slug': 'day', 'name': 'Dayton, US', 'code': 'DAY'},
      },
    'region-sources' => {'status': _status, 'sources': []},
    'region-activity' => {'status': _status, 'rows': []},
    'region-hash-stats' => {'status': _status, 'sizes': []},
    'region-path-stats' => {'status': _status, 'hopHistogram': []},
    'region-repeaters' => {'status': _status, 'rows': []},
    _ => null,
  };
}

void main() {
  late Directory dir;
  var now = DateTime.utc(2026, 10, 24, 12);
  var down = false;
  late EtagClient client;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('region_offline');
    now = DateTime.utc(2026, 10, 24, 12);
    down = false;
    client = EtagClient(
      MockClient((req) async {
        if (down) throw const SocketException('Network is unreachable');
        final b = _body(req.url.path);
        return b == null ? http.Response('{}', 404) : http.Response(jsonEncode(b), 200, headers: {'etag': '"v1"'});
      }),
      RegionCache(dir, clock: () => now),
      staleAfter: const Duration(milliseconds: 200),
    );
  });
  tearDown(() => dir.deleteSync(recursive: true));

  final fetchedAt = DateTime.utc(2026, 10, 24, 12);
  void goOffline() {
    down = true;
    now = now.add(const Duration(hours: 3));
  }

  test('helpers: offlineAsOfOf reads only offline answers; isNetworkFailure', () {
    expect(offlineAsOfOf(http.Response('', 200)), isNull);
    expect(offlineAsOfOf(http.Response('', 200, headers: {cacheSourceHeader: '304'})), isNull);
    expect(
        offlineAsOfOf(http.Response('', 200, headers: {cacheSourceHeader: 'offline', cacheAsOfHeader: '2026-10-24T09:00:00.000Z'})),
        DateTime.utc(2026, 10, 24, 9));
    expect(isNetworkFailure(const SocketException('x')), isTrue);
    expect(isNetworkFailure(http.ClientException('x')), isTrue);
    expect(isNetworkFailure(const FormatException('x')), isFalse);
  });

  test('region-* reads on any region host are cacheable under /api/cmh/ (Reports included); other paths are not', () {
    expect(EtagClient.isCacheable(Uri.parse('https://day.meshsonar.com/api/cmh/region-report')), isTrue);
    expect(EtagClient.isCacheable(Uri.parse('https://cvg.meshsonar.com/api/cmh/region-sources')), isTrue);
    expect(EtagClient.isCacheable(Uri.parse('https://day.meshsonar.com/api/day/region-report')), isFalse); // 404 path
    expect(EtagClient.isCacheable(Uri.parse('https://day.meshsonar.com/api/cmh/upload')), isFalse);
    expect(EtagClient.isCacheable(Uri.parse('https://day.meshsonar.com/api/cmh/public-live')), isFalse);
  });

  test('overview + observers: stored copy flagged offline with its fetch time; nothing stored throws offline', () async {
    final api = RegionOverviewApi('https://cmh.meshsonar.com', client: client);
    expect((await api.overview()).offlineAsOf, isNull);
    expect((await api.observers()).offlineAsOf, isNull);
    goOffline();
    final o = await api.overview();
    expect(o.packets24h, 612);
    expect(o.offlineAsOf, fetchedAt);
    final obs = await api.observers();
    expect(obs.rows.single.name, 'OBS-1');
    expect(obs.offlineAsOf, fetchedAt);
    final fresh = RegionOverviewApi('https://day.meshsonar.com', client: client); // another host: nothing stored
    await expectLater(fresh.overview(), throwsA(isA<RegionApiException>().having((e) => e.offline, 'offline', isTrue)));
  });

  test('a server error answer is not "offline"', () async {
    final api = RegionOverviewApi('https://x.test', client: MockClient((_) async => http.Response('{"error":"nope"}', 400)));
    await expectLater(api.overview(), throwsA(isA<RegionApiException>().having((e) => e.offline, 'offline', isFalse)));
  });

  test('stats + leaderboard stored; public-live is never stored and fails offline', () async {
    final api = RegionStatsApi('https://cmh.meshsonar.com', client: client);
    await api.stats();
    await api.leaderboard();
    await api.live();
    goOffline();
    final s = await api.stats();
    expect(s.drives, 45);
    expect(s.offlineAsOf, fetchedAt);
    expect((await api.leaderboard()).offlineAsOf, fetchedAt);
    await expectLater(api.live(), throwsA(isA<RegionStatsException>().having((e) => e.offline, 'offline', isTrue)));
  });

  test('packets: stored page flagged offline; nothing stored throws offline', () async {
    final api = HttpRegionPacketsApi(Uri.parse('https://cmh.meshsonar.com'), client: client);
    expect((await api.packets()).offlineAsOf, isNull);
    goOffline();
    final p = await api.packets();
    expect(p.rows.single.hash, 'a1');
    expect(p.offlineAsOf, fetchedAt);
    await expectLater(api.packets(route: 2), // a different query was never stored
        throwsA(isA<PacketsException>().having((e) => e.offline, 'offline', isTrue)));
  });

  test('reports: stored copy under /api/<slug>/ flagged offline; nothing stored is a network failure', () async {
    final api = RegionReportsApi('https://day.meshsonar.com', client: client);
    expect((await api.fetchReport('day')).offlineAsOf, isNull);
    await api.fetchSources('day');
    goOffline();
    final r = await api.fetchReport('day');
    expect(r.ok, isTrue);
    expect(r.offlineAsOf, fetchedAt);
    expect((await api.fetchSources('day')).offlineAsOf, fetchedAt);
    final other = await RegionReportsApi('https://cvg.meshsonar.com', client: client).fetchReport('cvg');
    expect(other.error?.kind, FetchErrorKind.network);
  });

  test('region-activity is stored without its sliding window and never sends a stale If-None-Match', () async {
    final seen = <String?>[];
    final c = EtagClient(MockClient((req) async {
      seen.add(req.headers['if-none-match']);
      return http.Response('{"rows":[]}', 200, headers: {'etag': '"w"'});
    }), RegionCache(dir, clock: () => now));
    final a = Uri.parse('https://day.meshsonar.com/api/cmh/region-activity?bucket=hour&since=2026-10-17T12:00:00.000Z&until=2026-10-24T12:00:00.000Z');
    final b = Uri.parse('https://day.meshsonar.com/api/cmh/region-activity?bucket=hour&since=2026-10-17T13:00:00.000Z&until=2026-10-24T13:00:00.000Z');
    expect(EtagClient.keyFor(EtagClient.storageUri(a)), EtagClient.keyFor(EtagClient.storageUri(b)));
    expect(EtagClient.storageUri(a).queryParameters, {'bucket': 'hour'});
    final other = Uri.parse('https://day.meshsonar.com/api/cmh/public-coverage?since=x');
    expect(EtagClient.storageUri(other), other, reason: 'only region-activity drops its window');
    await c.get(a);
    await c.get(b);
    expect(seen, [null, null]);
  });

  test('analysis: sections flagged offline with the oldest as-of; nothing stored is allOffline', () async {
    final api = RegionAnalysisApi('https://day.meshsonar.com', client: client, now: () => now);
    final live = await api.fetch();
    expect(live.offlineAsOf, isNull);
    expect(live.allOffline, isFalse);
    goOffline();
    // The activity window is hour-aligned to "now", so 3 h later it is a different URL; the stored window still serves.
    final a = await api.fetch();
    expect(a.roles.offlineAsOf, fetchedAt);
    expect(a.hash.offlineAsOf, fetchedAt);
    expect(a.activity.offlineAsOf, fetchedAt);
    expect(a.offlineAsOf, fetchedAt);
    expect(a.anyFailed, isFalse);
    expect(a.allOffline, isFalse);
    final none = await RegionAnalysisApi('https://cvg.meshsonar.com', client: client).fetch();
    expect(none.allOffline, isTrue);
  });
}
