import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_overview_api.dart';

const overviewJson = {
  'status': {
    'state': 'partial',
    'reason': 'No MeshSonar observers in this region yet.',
    'computedAt': '2026-10-24T01:36:10.228Z',
    'source': 'x',
  },
  'packets24h': 612,
  'observersOnline': 1,
  'observersTotal': 9,
  'repeaters': 326,
  'repeatersHeard24h': 64,
  'packetsPerHour': [
    {'at': '2026-10-23T02:00:00.000Z', 'n': 7},
    {'at': '2026-10-23T03:00:00.000Z', 'n': 28},
    {'bad': true},
  ],
  'lastPacketAt': null,
  'recentEvents': [
    {
      'type': 'repeater_new',
      'key': 'ab',
      'detail': 'X appeared',
      'at': '2026-10-23T00:01:21.620Z',
    },
    {'type': 'link_lost'},
  ],
};

void main() {
  test(
    'overview parses all fields, drops malformed rows, keeps null as null',
    () {
      final o = RegionOverview.fromJson(overviewJson);
      expect(o.status.state, RegionDataState.partial);
      expect(o.status.reason, contains('No MeshSonar observers'));
      expect(o.packets24h, 612);
      expect(o.observersOnline, 1);
      expect(o.observersTotal, 9);
      expect(o.repeaters, 326);
      expect(o.repeatersHeard24h, 64);
      expect(o.packetsPerHour.map((h) => h.n), [7, 28]);
      expect(o.lastPacketAt, isNull);
      expect(o.recentEvents.single.detail, 'X appeared');
    },
  );

  test('missing numbers stay null, missing status is unavailable', () {
    final o = RegionOverview.fromJson({});
    expect(o.packets24h, isNull);
    expect(o.status.state, RegionDataState.unavailable);
    expect(
      RegionDataStatus.fromJson({'state': 'ready', 'reason': null}).state,
      RegionDataState.ready,
    );
    expect(
      RegionDataStatus.fromJson({'state': 'wat'}).state,
      RegionDataState.unavailable,
    );
  });

  test('observers parse; lastSeen is the newer of packet/status', () {
    final r = RegionObservers.fromJson({
      'status': {'state': 'ready', 'reason': null},
      'rows': [
        {
          'key': 'df01',
          'name': 'INNO-OB-2',
          'online': true,
          'lastPacketAt': '2026-10-21T16:19:35.152Z',
          'lastStatusAt': '2026-10-22T16:15:33.699Z',
          'packetsPerHour': 64,
          'noiseFloorDbm': -97,
          'lat': null,
          'trusted': true,
          'source': 'meshsonar',
        },
        {'key': 'e121c196a', 'online': false},
        {'name': 'no key'},
        'junk',
      ],
    });
    expect(r.rows.length, 2);
    final a = r.rows.first;
    expect(a.packetsPerHour, 64);
    expect(a.noiseFloorDbm, -97);
    expect(a.lastSeen, DateTime.utc(2026, 10, 22, 16, 15, 33, 699));
    expect(r.rows.last.displayName, 'e121c196…');
    expect(r.rows.last.lastSeen, isNull);
    expect(r.rows.last.source, 'corescope');
  });

  test(
    'api hits <base>/api/cmh/<name> and maps failures to readable errors',
    () async {
      final seen = <Uri>[];
      var api = RegionOverviewApi(
        'https://cmh.example/',
        client: MockClient((req) async {
          seen.add(req.url);
          return http.Response(jsonEncode(overviewJson), 200);
        }),
      );
      expect((await api.overview()).repeaters, 326);
      expect(
        seen.single.toString(),
        'https://cmh.example/api/cmh/region-overview',
      );

      api = RegionOverviewApi(
        'https://cmh.example',
        client: MockClient(
          (_) async => http.Response('{"error":"per region"}', 400),
        ),
      );
      await expectLater(
        api.observers(),
        throwsA(
          isA<RegionApiException>().having((e) => e.message, 'm', 'per region'),
        ),
      );

      api = RegionOverviewApi(
        'https://cmh.example',
        client: MockClient((_) async => http.Response('nope', 200)),
      );
      await expectLater(api.overview(), throwsA(isA<RegionApiException>()));

      api = RegionOverviewApi(
        'https://cmh.example',
        client: MockClient((_) async => throw Exception('down')),
      );
      await expectLater(
        api.overview(),
        throwsA(
          isA<RegionApiException>().having(
            (e) => e.message,
            'm',
            contains('Could not reach'),
          ),
        ),
      );
    },
  );
}
