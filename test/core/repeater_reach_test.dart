// repeater-reach with a driver key: tolerant parser, the HTTP contract (header, query, errors), and the on-disk cache.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/repeater_reach.dart';

const _key = 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854';

Map<String, dynamic> body({bool bands = true}) => <String, Object?>{
      'key': _key,
      'cellDeg': 0.0025,
      'cells': [
        {'lat': 40.00125, 'lon': -83.00125, 'pings': 4, 'bestSnr': 7.5, 'medianSnr': 3, 'lastAt': '2026-10-24T14:00:00.000Z'},
        {'lat': 40.00375, 'lon': -83.00125, 'pings': 1, 'bestSnr': null, 'medianSnr': null, 'lastAt': '2026-10-24T13:00:00.000Z'},
        {'lat': 'x', 'lon': 1, 'pings': 1}, // bad row, skipped
      ],
      'totals': <String, Object?>{
        'heardPings': 5, 'drives': 2, 'drivers': 2, 'bestSnr': 7.5, 'medianSnr': 3,
        'farthestKm': 3.2, 'lastHeardAt': '2026-10-24T14:00:00.000Z',
      },
      'snrByDistance': bands
          ? [
              for (final k in ['0-1', '1-2', '2-5', '5-10', '10-20', '20+']) {'km': k, 'pings': k == '0-1' ? 3 : 0, 'medianSnr': k == '0-1' ? 4.5 : null},
              {'km': '99-100', 'pings': 1, 'medianSnr': 1}, // unknown band, skipped
            ]
          : [],
      'asOf': '2026-10-24T15:00:00.000Z',
    };

void main() {
  group('parse', () {
    test('cells, totals, six bands; bad rows skipped; unknown is null never 0', () {
      final r = RepeaterReach.parse(body());
      expect(r.cells, hasLength(2));
      expect(r.cells[1].bestSnr, isNull);
      expect(r.totals.heardPings, 5);
      expect(r.totals.farthestKm, 3.2);
      expect(r.totals.lastHeardAt, DateTime.utc(2026, 10, 24, 14));
      expect(r.snrByDistance, hasLength(6));
      expect(r.snrByDistance.first.medianSnr, 4.5);
      expect(r.snrByDistance.last.toKm, isNull);
      expect(r.snrByDistance[1].medianSnr, isNull);
      expect(r.isEmpty, isFalse);
    });
    test('no position: no bands and no farthest', () {
      final b = body(bands: false);
      (b['totals'] as Map<String, Object?>)['farthestKm'] = null;
      final r = RepeaterReach.parse(b);
      expect(r.snrByDistance, isEmpty);
      expect(r.totals.farthestKm, isNull);
    });
    test('empty answer and unreadable answer', () {
      final e = RepeaterReach.parse({'key': 'ab', 'cells': [], 'totals': {'heardPings': 0}, 'snrByDistance': []});
      expect(e.isEmpty, isTrue);
      expect(() => RepeaterReach.parse({'nope': 1}), throwsFormatException);
    });
    test('encode then parse round trips', () {
      final r = RepeaterReach.parse(body());
      final again = RepeaterReach.parse(encodeReach(r));
      expect(again.cells.length, r.cells.length);
      expect(again.totals.drives, 2);
      expect(again.snrByDistance.length, 6);
    });
  });

  group('client', () {
    test('sends x-driver-key, the key lowercased and the repeater position at 5 decimals', () async {
      late http.Request seen;
      final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode(body()), 200);
      }));
      final r = await c.repeaterReach('KEY-1', _key.toUpperCase(), lat: 40.123456789, lon: -83.1);
      expect(seen.method, 'GET');
      expect(seen.url.path, '/api/cmh/repeater-reach');
      expect(seen.url.queryParameters, {'key': _key, 'lat': '40.12346', 'lon': '-83.10000'});
      expect(seen.headers['x-driver-key'], 'KEY-1');
      expect(r.totals.heardPings, 5);
    });
    test('without a position sends neither lat nor lon', () async {
      late Uri seen;
      final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
        seen = req.url;
        return http.Response(jsonEncode(body(bands: false)), 200);
      }));
      await c.repeaterReach('k', _key);
      expect(seen.queryParameters.keys, ['key']);
    });
    test('401, 403, 429 and an unreadable body become CmatException with the status', () async {
      for (final s in [401, 403, 429, 500]) {
        final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => http.Response('{"error":"no"}', s)));
        await expectLater(c.repeaterReach('k', _key), throwsA(isA<CmatException>().having((e) => e.status, 'status', s)));
      }
      final bad = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => http.Response('{"hello":1}', 200)));
      await expectLater(bad.repeaterReach('k', _key), throwsA(isA<CmatException>()));
    });
  });

  group('cache', () {
    late Directory dir;
    var now = DateTime.utc(2026, 10, 25, 12);
    setUp(() {
      dir = Directory.systemTemp.createTempSync('ms_reach_');
      now = DateTime.utc(2026, 10, 25, 12);
    });
    tearDown(() => dir.deleteSync(recursive: true));
    RepeaterReachCache cache({Directory? d, int max = 40, int perMinute = 50}) =>
        RepeaterReachCache(dir: d ?? dir, clock: () => now, maxEntries: max, maxPerMinute: perMinute);
    Future<RepeaterReach> ok() async => RepeaterReach.parse(body());

    test('fresh for 10 minutes, asked again after; survives a restart; no driver key on disk', () async {
      final c = cache();
      var asks = 0;
      Future<RepeaterReach> ask() {
        asks++;
        return ok();
      }

      await c.get('x.org', _key, withPosition: true, fetch: ask);
      now = now.add(const Duration(minutes: 9));
      await c.get('x.org', _key, withPosition: true, fetch: ask);
      expect(asks, 1);
      expect((await cache().get('x.org', _key, withPosition: true, fetch: ask)).offline, isFalse);
      expect(asks, 1, reason: 'a new cache on the same folder serves the stored answer');
      now = now.add(const Duration(minutes: 2));
      await c.get('x.org', _key, withPosition: true, fetch: ask);
      expect(asks, 2);
      for (final f in dir.listSync().whereType<File>()) {
        expect(f.readAsStringSync(), isNot(contains('KEY')));
      }
    });
    test('position and no position are separate entries; hosts are separate', () async {
      final c = cache();
      var asks = 0;
      Future<RepeaterReach> ask() {
        asks++;
        return ok();
      }

      await c.get('x.org', _key, withPosition: true, fetch: ask);
      await c.get('x.org', _key, withPosition: false, fetch: ask);
      await c.get('y.org', _key, withPosition: true, fetch: ask);
      expect(asks, 3);
    });
    test('a failed ask (network, 429, 500) serves the stored copy flagged offline; nothing stored rethrows', () async {
      final c = cache();
      await c.get('x.org', _key, withPosition: true, fetch: ok);
      now = now.add(const Duration(hours: 1));
      for (final e in [const CmatException('network error: down'), const CmatException('slow', status: 429), const CmatException('boom', status: 500)]) {
        final r = await c.get('x.org', _key, withPosition: true, fetch: () => Future.error(e));
        expect(r.offline, isTrue, reason: '${e.status}');
        expect(r.fetchedAt, DateTime.utc(2026, 10, 25, 12));
      }
      await expectLater(cache(d: Directory('${dir.path}/other')).get('x.org', _key, withPosition: true, fetch: () => Future.error(const CmatException('network error'))),
          throwsA(isA<CmatException>()));
    });
    test('401 and 403 never serve a stored copy and drop it', () async {
      final c = cache();
      await c.get('x.org', _key, withPosition: true, fetch: ok);
      now = now.add(const Duration(hours: 1));
      await expectLater(c.get('x.org', _key, withPosition: true, fetch: () => Future.error(const CmatException('no', status: 403))),
          throwsA(isA<CmatException>().having((e) => e.status, 'status', 403)));
      await expectLater(c.get('x.org', _key, withPosition: true, fetch: () => Future.error(const CmatException('no', status: 401))),
          throwsA(isA<CmatException>()));
    });
    test('LRU cap, per-minute budget, bad keys never touch disk or the server', () async {
      final c = cache(max: 2);
      for (var i = 0; i < 4; i++) {
        await c.get('x.org', 'abcdef0$i', withPosition: false, fetch: ok);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')), hasLength(2));
      final b = cache(d: Directory('${dir.path}/b'), perMinute: 1);
      await b.get('x.org', 'abcdef00', withPosition: false, fetch: ok);
      await expectLater(b.get('x.org', 'abcdef01', withPosition: false, fetch: ok), throwsA(isA<CmatException>().having((e) => e.status, 's', 429)));
      await expectLater(b.get('x.org', '../etc', withPosition: false, fetch: ok), throwsA(isA<CmatException>()));
      expect(b.serverAsks, 1);
      await b.clear();
    });
  });
}
