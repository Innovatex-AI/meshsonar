import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';

const _key = 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854';

Map<String, dynamic> sample() => {
  'status': {
    'state': 'partial',
    'reason': 'No observers yet',
    'computedAt': '2026-10-24T01:36:14.831Z',
    'source': 'x',
  },
  'rows': [
    {
      'key': _key,
      'hashPrefix': 'da5d',
      'name': 'INNO-ALBANY-WEST',
      'role': 'repeater',
      'lat': 40.078675,
      'lon': -82.854534,
      'firstSeenAt': '2026-09-24T22:52:22.000Z',
      'lastHeardAt': '2026-10-24T01:23:00.414Z',
      'relays24h': 75,
      'adverts24h': 7,
      'neighbours': 27,
      'observers24h': 1,
      'heardHoursPct': 54.2,
      'snrMeanDb': 8.5,
      'signalGrade': 'B',
      'hashSizeBytes': 2,
      'ambiguous': false,
      'status': 'active',
    },
    {
      'key': 'e5' * 32,
      'hashPrefix': 'e5',
      'name': null,
      'role': 'room',
      'lat': null,
      'lon': null,
      'firstSeenAt': null,
      'lastHeardAt': null,
      'relays24h': null,
      'adverts24h': null,
      'neighbours': null,
      'observers24h': null,
      'heardHoursPct': null,
      'snrMeanDb': null,
      'signalGrade': null,
      'hashSizeBytes': null,
      'ambiguous': true,
      'status': 'new',
    },
  ],
  'counts': {'active': 1, 'quiet': 0, 'new': 1, 'stale': 0},
};

void main() {
  test('parses a full row and a row of nulls', () {
    final r = RegionRepeaters.fromJson(sample(), regionSlug: 'cmh');
    expect(r.status.state, 'partial');
    expect(r.status.reason, 'No observers yet');
    expect(r.rows, hasLength(2));
    final a = r.rows[0];
    expect(a.key, _key);
    expect(a.displayName, 'INNO-ALBANY-WEST');
    expect(a.lat, 40.078675);
    expect(a.lastHeardAt, DateTime.utc(2026, 10, 24, 1, 23, 0, 414));
    expect(a.neighbours, 27);
    expect(a.snrMeanDb, 8.5);
    expect(a.signalGrade, 'B');
    expect(a.hashSizeBytes, 2);
    expect(a.status, RepeaterActivity.active);
    final b = r.rows[1];
    expect(
      b.displayName,
      'e5',
      reason: 'no name falls back to the hash prefix',
    );
    expect(b.hasPosition, isFalse);
    expect(b.lastHeardAt, isNull);
    expect(b.snrMeanDb, isNull);
    expect(b.ambiguous, isTrue);
    expect(b.status, RepeaterActivity.fresh);
    expect(r.counts[RepeaterActivity.fresh], 1);
    expect(r.positioned, hasLength(1));
  });

  test('malformed bodies throw', () {
    expect(
      () => RegionRepeaters.fromJson([]),
      throwsA(isA<RegionRepeatersException>()),
    );
    expect(
      () => RegionRepeaters.fromJson({
        'status': {'state': 'ready'},
      }),
      throwsA(isA<RegionRepeatersException>()),
    );
    expect(
      () => RegionRepeaters.fromJson({'rows': []}),
      throwsA(isA<RegionRepeatersException>()),
    );
    final bad = sample();
    (bad['rows'] as List).add({'name': 'no key'});
    expect(
      () => RegionRepeaters.fromJson(bad),
      throwsA(isA<RegionRepeatersException>()),
    );
    final notObj = sample();
    notObj['rows'] = [...(notObj['rows'] as List), 5];
    expect(
      () => RegionRepeaters.fromJson(notObj),
      throwsA(isA<RegionRepeatersException>()),
    );
  });

  test(
    'uri: region host as given; hub host + slug resolves to the region host',
    () {
      expect(
        regionRepeatersUri('https://day.meshsonar.com', 'day').toString(),
        'https://day.meshsonar.com/api/cmh/region-repeaters',
      );
      expect(
        regionRepeatersUri('https://meshsonar.com', 'cvg').toString(),
        'https://cvg.meshsonar.com/api/cmh/region-repeaters',
      );
      expect(
        () => regionRepeatersUri('', 'cmh'),
        throwsA(isA<RegionRepeatersException>()),
      );
    },
  );

  test('fetch: ok, HTTP error, bad JSON, network failure', () async {
    Uri? seen;
    final ok = MockClient((req) async {
      seen = req.url;
      return http.Response(jsonEncode(sample()), 200);
    });
    final r = await fetchRegionRepeaters(
      'https://cmh.meshsonar.com',
      'cmh',
      client: ok,
    );
    expect(r.rows, hasLength(2));
    expect(
      seen.toString(),
      'https://cmh.meshsonar.com/api/cmh/region-repeaters',
    );
    expect(
      () => fetchRegionRepeaters(
        'https://cmh.meshsonar.com',
        'cmh',
        client: MockClient((_) async => http.Response('no', 400)),
      ),
      throwsA(isA<RegionRepeatersException>()),
    );
    expect(
      () => fetchRegionRepeaters(
        'https://cmh.meshsonar.com',
        'cmh',
        client: MockClient((_) async => http.Response('<html>', 200)),
      ),
      throwsA(isA<RegionRepeatersException>()),
    );
    expect(
      () => fetchRegionRepeaters(
        'https://cmh.meshsonar.com',
        'cmh',
        client: MockClient((_) async => throw http.ClientException('down')),
      ),
      throwsA(isA<RegionRepeatersException>()),
    );
  });
}
