// region-rf and region-ext-growth clients: tolerant parsing (bad rows skipped, unknown is null), the silent-observer
// gap, weak-SNR share, the website's finding sentence, cumulative growth, and the shared fetch (host-scoped
// /api/cmh/ path, 404 = not published, errors, the ETag cache's offline "as of" header).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_dataset_fetch.dart';
import 'package:meshsonar/core/region_growth_api.dart';
import 'package:meshsonar/core/region_overview_api.dart' show RegionDataState;
import 'package:meshsonar/core/region_rf_api.dart';

/// Shape of the cmh body recorded Oct 24 2026, trimmed: INNO-OB-2 silent since 2026-10-21 16:00 UTC.
Map<String, dynamic> rfBody() => {
      'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T21:39:09.315Z', 'source': 'meshsonar-observers'},
      'observers': [
        {
          'key': 'df0136c20a99f519', 'name': 'INNO-OB-2', 'meanDbm': -97.1, 'maxDbm': -88.1, //
          'series': [
            {'at': '2026-10-21T16:00:00.000Z', 'dbm': -97.5},
            {'at': '2026-10-21T15:00:00.000Z', 'dbm': -96.0},
            {'at': 'bad', 'dbm': -90},
            {'at': '2026-10-21T14:00:00.000Z', 'dbm': null},
          ],
        },
        {
          'key': 'e066d11b64aa', 'name': null, 'meanDbm': -77.6, 'maxDbm': -67.8,
          'series': [
            {'at': '2026-10-24T21:00:00.000Z', 'dbm': -72.9},
          ],
        },
        {'name': 'no key'},
      ],
      'noiseByHour': [
        {'hour': 1, 'meanDbm': -85.2},
        {'hour': 0, 'meanDbm': -85.7},
        {'hour': 30, 'meanDbm': -1},
        {'hour': 2, 'meanDbm': null},
      ],
      'snrHistogram': [
        {'n': 20, 'fromDb': -12, 'toDb': -10},
        {'n': 30, 'fromDb': 0, 'toDb': 2},
        {'n': 50, 'fromDb': -2, 'toDb': 0},
      ],
    };

Map<String, dynamic> growthBody() => {
      'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T21:42:47.541Z', 'source': 'external sources (CoreScope, MeshCore Map)'},
      'basis': {'1': 'source', '2': 'observed'},
      'churn': [
        {'gone': 0, 'week': '2026-10-19', 'appeared': 7},
        {'gone': 1, 'week': '2026-08-31', 'appeared': 2},
      ],
      'daily': [
        {'day': '2026-10-23', 'merged': 2, 'bySource': {'1': 2, '2': 112}},
        {'day': '2026-09-24', 'merged': 1, 'bySource': {'1': 1}},
        {'day': 'nope', 'merged': 4},
      ],
      'roles': [{'n': 103, 'role': 'repeater'}, {'n': 40, 'role': 'companion'}],
      'before': {'merged': 37, 'bySource': {'1': 37}},
      'firmware': [],
      'hashSizes': [{'n': 32, 'bytes': 2}, {'n': 23, 'bytes': 1}],
    };

void main() {
  group('region-rf', () {
    test('parses, sorts, skips bad rows', () {
      final r = RegionRf.parse(rfBody());
      expect(r.status.state, RegionDataState.ready);
      expect(r.observers, hasLength(2));
      expect(r.observers.first.series.map((p) => p.dbm), [-96.0, -97.5]);
      expect(r.observers.first.lastAt, DateTime.utc(2026, 10, 21, 16));
      expect(r.observers.last.label, 'e066d11b…');
      expect([for (final h in r.noiseByHour) h.hour], [0, 1, 2]);
      expect(r.noiseByHour.last.meanDbm, isNull);
      expect([for (final b in r.snrHistogram) b.fromDb], [-12, -2, 0]);
    });

    test('the observer silent since Oct 21 is named; the live one is not', () {
      final r = RegionRf.parse(rfBody());
      final silent = r.silentObservers(r.status.computedAt!);
      expect(silent.map((o) => o.name), ['INNO-OB-2']);
    });

    test('weak-signal share and the website finding', () {
      final r = RegionRf.parse(rfBody());
      expect(r.weakSnrShare, closeTo(0.7, 1e-9)); // 20 + 50 of 100 at or below 0 dB
      expect(r.finding(),
          '2 of 2 observers sit above -100 dBm, where interference is likely. Noisiest: e066d11b… at -78 dBm. Across observers it is highest at 01:00 UTC.');
      final quiet = RegionRf.parse({
        'status': {'state': 'ready'},
        'observers': [
          {'key': 'aa', 'name': 'Quiet', 'meanDbm': -112, 'series': []},
        ],
      });
      expect(quiet.finding(hourText: (h) => 'x'), 'No observer is above -100 dBm. Noisiest: Quiet at -112 dBm.');
    });

    test('pending with no data is empty, the reason kept', () {
      final r = RegionRf.parse({
        'status': {'state': 'pending', 'reason': 'No trusted observers in this region yet.'},
        'observers': [],
        'noiseByHour': [],
        'snrHistogram': [],
      });
      expect(r.isEmpty, isTrue);
      expect(r.status.state, RegionDataState.pending);
      expect(r.status.reason, 'No trusted observers in this region yet.');
      expect(r.finding(), isNull);
    });
  });

  group('region-ext-growth', () {
    test('parses, sorts, cumulative from before', () {
      final g = RegionGrowth.parse(growthBody());
      expect(g.churn.first.week, '2026-08-31');
      expect(g.daily.map((d) => d.day), ['2026-09-24', '2026-10-23']);
      expect([for (final c in g.cumulative()) c.$2], [38, 40]);
      expect(g.total, 40);
      expect(g.hasObservedBasis, isTrue);
      expect(g.firmware, isEmpty);
      expect(g.hashSizes.first, (1, 23));
      expect(g.isEmpty, isFalse);
      expect(RegionGrowth.parse({'status': {'state': 'pending'}}).isEmpty, isTrue);
    });
  });

  group('fetch', () {
    test('host-scoped /api/cmh/ path; days query; body kept', () async {
      final seen = <Uri>[];
      final c = MockClient((req) async {
        seen.add(req.url);
        return http.Response(jsonEncode(req.url.path.endsWith('region-rf') ? rfBody() : growthBody()), 200);
      });
      final rf = await RegionRfApi('https://day.meshsonar.com/', client: c).fetch();
      final g = await RegionGrowthApi('https://day.meshsonar.com', client: c).fetch();
      expect(seen.map((u) => u.toString()), [
        'https://day.meshsonar.com/api/cmh/region-rf',
        'https://day.meshsonar.com/api/cmh/region-ext-growth?days=365',
      ]);
      expect(rf.ok && g.ok, isTrue);
      expect(rf.body, contains('INNO-OB-2'));
      expect(rf.offlineAsOf, isNull);
    });

    test('offline copy from the ETag cache carries its as-of time', () async {
      final c = MockClient((req) async => http.Response(jsonEncode(rfBody()), 200,
          headers: {'x-meshsonar-cache': 'offline', 'x-meshsonar-as-of': '2026-10-24T18:00:00.000Z'}));
      final r = await RegionRfApi('https://cmh.meshsonar.com', client: c).fetch();
      expect(r.offlineAsOf, DateTime.utc(2026, 10, 24, 18));
    });

    test('404 is "not published", 500 quotes the server, garbage is unreadable, network failure', () async {
      Future<RegionFetch<RegionRf>> get(http.Response Function() f) =>
          RegionRfApi('https://x.meshsonar.com', client: MockClient((_) async => f())).fetch();
      final nf = await get(() => http.Response('<html>', 404));
      expect(nf.notFound, isTrue);
      expect((await get(() => http.Response('{"error":"boom"}', 500))).error, 'boom');
      expect((await get(() => http.Response('not json', 200))).error, 'The server sent something unreadable.');
      expect((await get(() => http.Response('[1]', 200))).error, 'The server sent something unreadable.');
      final net = await RegionRfApi('https://x.meshsonar.com', client: MockClient((_) async => throw http.ClientException('down'))).fetch();
      expect(net.error, 'No connection to the server.');
    });
  });
}
