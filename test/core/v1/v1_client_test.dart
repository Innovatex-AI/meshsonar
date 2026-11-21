// The /v1 client base (AZ-3.1): envelope, error shape, cursor paging, the "not live" fallback, and the Network reads
// (summary, pulse, regions) against the contract fixtures copied from meshsonar-infra docs/planning/analyzer-fixtures/
// into test/fixtures/analyzer/.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/core/v1/network_api.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();

http.Response json(String body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(body, status, headers: {'content-type': 'application/json', ...headers});

void main() {
  setUp(resetV1NotLive);

  group('envelope', () {
    test('summary.json parses: data, meta, sources, window', () async {
      final seen = <Uri>[];
      final api = NetworkApi('https://cmh.meshsonar.com', client: MockClient((r) async {
        seen.add(r.url);
        return json(fixture('summary'));
      }));
      final r = await api.summary();
      expect(seen.single.path, '/v1/summary');
      expect(seen.single.queryParameters, {'window': '24h'});
      expect(r.source, NetworkReadSource.v1);
      final s = r.data;
      expect(s.nodesActive24h['repeater'], 151);
      expect(s.nodesTotal['companion'], 611);
      expect(s.nodesSilent, 9);
      expect(s.observersOnlineTotal, 26);
      expect(s.observersTotalAll, 39);
      expect(s.packetsLastHour, 640);
      expect(s.packets24h, 14320);
      expect(s.packetsPerHour.length, 4);
      expect(s.packetsPerHour.last.$2, 640);
      expect(s.byType24h['GRP_TXT'], 5230);
      expect(s.hashSize['1'], 0.61);
      expect(s.channelMessages24h, 489);
      expect(s.pulseOpen, 1);
      expect(s.pulseTopKind, 'traffic_spike');
      expect(s.lastPacketAt, DateTime.utc(2026, 11, 20, 14, 14, 40));
      final m = r.meta!;
      expect(m.apiVersion, '1.0');
      expect(m.region!.slug, 'cmh');
      expect(m.region!.kind, 'region');
      expect(m.status.state, RegionDataState.ready);
      expect(m.sources.keys, containsAll(['meshsonar', 'meshsonar-phone', 'src_12', 'src_31']));
      expect(m.sources['src_12']!.kind, 'outside');
      expect(m.window!.name, '24h');
      expect(m.window!.rollup, 'e3_hour');
    });

    test('pulse.json parses as a page, most serious first', () async {
      final api = NetworkApi('https://cmh.meshsonar.com', client: MockClient((r) async {
        expect(r.url.path, '/v1/pulse');
        expect(r.url.queryParameters['state'], 'open');
        return json(fixture('pulse'));
      }));
      final r = (await api.pulse())!;
      expect(r.data.map((e) => e.id), ['pl_01JD2', 'pl_01JD7'], reason: 'warn before info');
      final warn = r.data.first;
      expect(warn.kind, 'repeater_silent');
      expect(warn.subjects.single.name, 'Riverside RPT');
      expect(warn.subjects.single.role, 'repeater');
      expect(warn.webLink!.path, startsWith('/nodes/'));
      expect(r.data.last.endedAt, isNull);
    });

    test('regions.json: the bare body (no envelope) parses, groups too', () async {
      final api = NetworkApi('https://meshsonar.com', client: MockClient((r) async {
        expect(r.url.path, '/v1/regions');
        return json(fixture('regions'));
      }));
      final r = await api.regions();
      expect(r.source, NetworkReadSource.v1);
      expect(r.regions.single.slug, 'cmh');
      expect(r.regions.single.url, 'https://cmh.meshsonar.com');
      expect(r.regions.single.group, 'ohio');
      expect(r.regions.single.timezone, 'America/New_York');
      expect(r.groups.single.members, ['CMH', 'CVG', 'DAY']);
    });

    test('an unknown field or enum value is kept, not a failure', () async {
      final body = jsonDecode(fixture('pulse')) as Map<String, dynamic>;
      (body['data'] as List).first['severity'] = 'catastrophic';
      (body['data'] as List).first['newField'] = 1;
      final api = NetworkApi('https://cmh.meshsonar.com', client: MockClient((r) async => json(jsonEncode(body))));
      final r = (await api.pulse())!;
      expect(r.data.any((e) => e.severity == 'catastrophic'), isTrue);
    });
  });

  group('errors', () {
    final examples = (jsonDecode(fixture('error')) as Map<String, dynamic>)['examples'] as List;

    for (final ex in examples.cast<Map<String, dynamic>>()) {
      final status = ex['status'] as int;
      final body = ex['body'] as Map<String, dynamic>;
      final code = (body['error'] as Map)['code'] as String;
      test('error.json $status $code parses to a V1Error', () async {
        final headers = <String, String>{for (final e in ((ex['headers'] as Map?) ?? const {}).entries) (e.key as String).toLowerCase(): e.value as String};
        final c = V1Client('https://cmh.meshsonar.com', client: MockClient((r) async => json(jsonEncode(body), status, headers)));
        try {
          await c.get('packets', (d) => d);
          fail('no error');
        } on V1Error catch (e) {
          expect(e.status, status);
          expect(e.code, code);
          expect(e.message, (body['error'] as Map)['message']);
          expect(e.requestId, startsWith('req_'));
          if (status == 429) {
            expect(e.rateLimited, isTrue);
            expect(e.retryAfter, 12);
          }
          if (status == 404) expect(e.notFound, isTrue);
          if (status == 400) expect(e.at, 0);
        }
        expect(c.knownNotLive, isFalse, reason: 'a v1 error body means /v1 IS live');
      });
    }

    test('a network failure is an offline V1Error', () async {
      final c = V1Client('https://cmh.meshsonar.com', client: MockClient((r) async => throw http.ClientException('down')));
      await expectLater(c.get('summary', (d) => d), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
    });

    test('a 500 without a v1 body is an error, not "not live"', () async {
      final c = V1Client('https://cmh.meshsonar.com', client: MockClient((r) async => json('{"error":"boom"}', 500)));
      await expectLater(c.get('summary', (d) => d), throwsA(isA<V1Error>().having((e) => e.message, 'message', 'boom')));
      expect(c.knownNotLive, isFalse);
    });
  });

  group('paging', () {
    test('V1Pager follows page.next until it is null; limit and cursor go on the query', () async {
      final asked = <Map<String, String>>[];
      final base = jsonDecode(fixture('pulse')) as Map<String, dynamic>;
      final c = V1Client('https://cmh.meshsonar.com', client: MockClient((r) async {
        asked.add(r.url.queryParameters);
        final cursor = r.url.queryParameters['cursor'];
        final b = Map<String, dynamic>.of(base);
        b['data'] = [(base['data'] as List)[cursor == null ? 0 : 1]];
        b['page'] = {'limit': 1, 'next': cursor == null ? 'Y3Vyc29yMQ' : null};
        return json(jsonEncode(b));
      }));
      final pager = V1Pager<PulseEvent>((cur) => c.getPage('pulse', PulseEvent.tryParse, cursor: cur, limit: 1));
      expect((await pager.next()).single.id, 'pl_01JD7');
      expect(pager.done, isFalse);
      expect((await pager.next()).single.id, 'pl_01JD2');
      expect(pager.done, isTrue);
      expect(await pager.next(), isEmpty);
      expect(pager.items.length, 2);
      expect(asked.first, {'limit': '1'});
      expect(asked.last, {'cursor': 'Y3Vyc29yMQ', 'limit': '1'});
    });
  });

  group('falls back silently while /v1 is not live', () {
    final overview = jsonEncode({
      'status': {'state': 'ready'},
      'packets24h': 900,
      'observersOnline': 3,
      'observersTotal': 5,
      'repeaters': 40,
      'repeatersHeard24h': 31,
      'packetsPerHour': [],
      'recentEvents': [],
    });

    test('summary: a 404 with no v1 body reads region-overview, and the host is not asked /v1 again', () async {
      final paths = <String>[];
      final client = MockClient((r) async {
        paths.add(r.url.path);
        if (r.url.path.startsWith('/v1/')) return http.Response('<html>Not found</html>', 404);
        return json(overview);
      });
      final api = NetworkApi('https://cmh.meshsonar.com', client: client);
      final r = await api.summary();
      expect(r.source, NetworkReadSource.legacy);
      expect(r.data.packets24h, 900);
      expect(r.data.repeatersActive24h, 31);
      expect(r.data.observersOnlineTotal, 3);
      expect(r.data.nodesSilent, isNull, reason: 'unknown stays null, never zero');
      expect(paths, ['/v1/summary', '/api/cmh/region-overview']);
      await api.summary();
      expect(paths.skip(2), ['/api/cmh/region-overview'], reason: 'remembered as not live');
    });

    test('summary: a 200 that is not an envelope (the site shell) also falls back', () async {
      final api = NetworkApi('https://cmh.meshsonar.com', client: MockClient((r) async {
        if (r.url.path.startsWith('/v1/')) return http.Response('<!doctype html><title>MeshSonar</title>', 200);
        return json(overview);
      }));
      expect((await api.summary()).source, NetworkReadSource.legacy);
    });

    test('pulse: null (no legacy pulse read), so the chip hides', () async {
      final api = NetworkApi('https://cmh.meshsonar.com', client: MockClient((r) async => http.Response('nope', 404)));
      expect(await api.pulse(), isNull);
    });

    test('regions: falls back to regions-index', () async {
      final api = NetworkApi('https://meshsonar.com', client: MockClient((r) async {
        if (r.url.path == '/v1/regions') return http.Response('', 404);
        expect(r.url.path, '/api/cmh/regions-index');
        return json(jsonEncode({
          'asOf': '2026-11-20T00:00:00Z',
          'regions': [
            {'code': 'CMH', 'slug': 'cmh', 'name': 'Columbus', 'url': 'https://cmh.meshsonar.com', 'bbox': [-83.25, 39.8, -82.75, 40.15]}
          ],
        }));
      }));
      final r = await api.regions();
      expect(r.source, NetworkReadSource.legacy);
      expect(r.regions.single.code, 'CMH');
    });

    test('post: 202 Accepted is a success (the report receipt); a bare 429 is rate_limited with Retry-After; sent once', () async {
      var calls = 0;
      var status = 202;
      final c = V1Client('https://cmh.meshsonar.com', client: MockClient((r) async {
        calls++;
        expect(r.method, 'POST');
        if (status == 429) return http.Response('slow down', 429, headers: {'retry-after': '90'});
        return http.Response(
            jsonEncode({
              'data': {'id': 'rep_1', 'status': 'received'},
              'meta': {'apiVersion': '1.0', 'status': {'state': 'ready', 'reason': null}},
            }),
            202,
            headers: {'content-type': 'application/json'});
      }));
      final env = await c.post('messages/aa/report', {'reason': 'spam'}, (d) => (d as Map)['id']);
      expect(env.data, 'rep_1');
      expect(calls, 1);
      status = 429;
      await expectLater(c.post('messages/aa/report', {'reason': 'spam'}, (d) => d),
          throwsA(isA<V1Error>().having((e) => e.code, 'code', 'rate_limited').having((e) => e.retryAfter, 'retryAfter', 90)));
      expect(calls, 2, reason: 'never retried by the client');
      expect(c.knownNotLive, isFalse);
    });

    test('the not-live memory expires', () async {
      var now = DateTime.utc(2026, 11, 20, 12);
      final c = V1Client('https://cmh.meshsonar.com', clock: () => now, client: MockClient((r) async => http.Response('', 404)));
      await expectLater(c.get('summary', (d) => d), throwsA(isA<V1NotLive>()));
      expect(c.knownNotLive, isTrue);
      now = now.add(notLiveMemory + const Duration(minutes: 1));
      expect(c.knownNotLive, isFalse);
    });
  });
}
