import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/repeater_detail_api.dart';

final _key = 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854';
String fixture() =>
    File('test/fixtures/region_repeater_cmh.json').readAsStringSync();

void main() {
  test('parses a real region-repeater answer', () {
    final d = RepeaterDetailData.parse(jsonDecode(fixture()));
    expect(d.status.isReady, isTrue);
    expect(d.row!.key, _key);
    expect(d.row!.displayName, 'INNO-ALBANY-WEST');
    expect(d.row!.role, 'repeater');
    expect(d.row!.hasPosition, isTrue);
    expect(d.heatmap!.length, 7);
    expect(d.heatmap!.first.length, 24);
    expect(d.heatmapEnd, '2026-10-24');
    expect(d.heatmapDay(6), DateTime.utc(2026, 10, 24));
    expect(d.heatmapDay(0), DateTime.utc(2026, 10, 18));
    expect(d.neighbours, isNotEmpty);
    expect(d.neighbours.first.snrDb, isNull); // unknown stays null, not 0
    expect(d.observers.first.name, 'OH.FRA.ForestPark.OB');
    expect(d.reachMaxKm, 10.63);
    expect(d.snrHourly.first.mean, isNull);
  });

  test('heatmapDay falls back to computedAt when heatmapEnd is absent', () {
    final d = RepeaterDetailData.parse({
      'status': {'state': 'ready', 'computedAt': '2026-10-24T01:41:39.085Z'},
      'row': null,
      'heatmap': List.generate(7, (_) => List.filled(24, 0)),
    });
    expect(d.heatmapDay(6), DateTime.utc(2026, 10, 24));
  });

  test('tolerates malformed elements', () {
    final d = RepeaterDetailData.parse({
      'status': {'state': 'partial', 'reason': 'x'},
      'row': {'key': _key, 'name': 5, 'lat': 'a'},
      'neighbours': [
        1,
        {'name': 'no key'},
        {'key': 'abc', 'snrDb': 3},
      ],
      'heatmap': 'nope',
    });
    expect(d.row!.name, isNull);
    expect(d.row!.displayName, startsWith('Repeater '));
    expect(d.row!.hasPosition, isFalse);
    expect(d.neighbours.length, 1);
    expect(d.heatmap, isNull);
    expect(
      () => RepeaterDetailData.parse([]),
      throwsA(isA<RepeaterDetailException>()),
    );
  });

  test('fetch: URL, success', () async {
    late Uri seen;
    final c = MockClient((r) async {
      seen = r.url;
      return http.Response(fixture(), 200);
    });
    final d = await fetchRepeaterDetail(
      'https://cmh.meshsonar.com/',
      _key.toUpperCase(),
      client: c,
    );
    expect(
      seen.toString(),
      'https://cmh.meshsonar.com/api/cmh/region-repeater?key=$_key',
    );
    expect(d.row!.name, 'INNO-ALBANY-WEST');
  });

  test('fetch: 404, not_found body, 400, 500, network, bad key', () async {
    Future<RepeaterDetailFailure> kind(MockClient c, [String k = '']) async {
      try {
        await fetchRepeaterDetail(
          'https://x.org',
          k.isEmpty ? _key : k,
          client: c,
        );
      } on RepeaterDetailException catch (e) {
        return e.kind;
      }
      fail('expected throw');
    }

    expect(
      await kind(
        MockClient(
          (_) async =>
              http.Response('{"status":{"state":"not_found"},"row":null}', 404),
        ),
      ),
      RepeaterDetailFailure.notFound,
    );
    expect(
      await kind(
        MockClient(
          (_) async =>
              http.Response('{"status":{"state":"not_found"},"row":null}', 200),
        ),
      ),
      RepeaterDetailFailure.notFound,
    );
    expect(
      await kind(MockClient((_) async => http.Response('{}', 400))),
      RepeaterDetailFailure.badKey,
    );
    expect(
      await kind(MockClient((_) async => http.Response('oops', 500))),
      RepeaterDetailFailure.server,
    );
    expect(
      await kind(MockClient((_) async => http.Response('not json', 200))),
      RepeaterDetailFailure.unreadable,
    );
    expect(
      await kind(MockClient((_) async => throw const SocketException('down'))),
      RepeaterDetailFailure.network,
    );
    expect(
      await kind(MockClient((_) async => http.Response('{}', 200)), 'zz'),
      RepeaterDetailFailure.badKey,
    );
  });

  test('packetTypeName', () {
    expect(packetTypeName(4), 'Advert');
    expect(packetTypeName(99), 'Type 99');
  });
}
