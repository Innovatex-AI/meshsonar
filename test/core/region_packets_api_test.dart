import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_packets_api.dart';

const _live = {
  'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T01:36:09.559Z', 'source': 'meshsonar-observers'},
  'rows': [
    {
      'hash': '1d6048510a07acb8', 'type': 7, 'route': 1, 'firstAt': '2026-10-24T01:28:26.654Z',
      'observers': 1, 'minHops': 7, 'bestSnrDb': 12, 'originKey': null, 'originName': null,
    },
    {
      'hash': 'fb8e72da8f5a6102', 'type': 4, 'route': 2, 'firstAt': '2026-10-24T01:25:34.112Z',
      'observers': 3, 'minHops': 0, 'bestSnrDb': -3.5, 'originKey': 'ab', 'originName': 'Hilltop',
    },
    {'type': 5}, // unusable: skipped
  ],
  'nextCursor': 'abc',
};

void main() {
  test('parses a real region-packets page', () {
    final p = PacketPage.fromJson(_live);
    expect(p.status.state, SourcedState.ready);
    expect(p.rows, hasLength(2));
    expect(p.rows[0].bestSnrDb, 12.0);
    expect(p.rows[0].minHops, 7);
    expect(p.rows[1].originName, 'Hilltop');
    expect(p.rows[1].firstAt.isUtc, isTrue);
    expect(p.nextCursor, 'abc');
    expect(packetTypeName(7), 'Anonymous request');
    expect(packetTypeName(14), 'Type 14');
    expect(packetRouteName(2), 'Direct');
  });

  test('parses pending status with empty rows and null SNR', () {
    final p = PacketPage.fromJson({
      'status': {'state': 'pending', 'reason': 'No trusted observers in this region yet.'},
      'rows': [],
      'nextCursor': null,
    });
    expect(p.status.state, SourcedState.pending);
    expect(p.status.reason, contains('observers'));
    expect(p.rows, isEmpty);
    expect(PacketRow.tryParse({'hash': 'a', 'firstAt': '2026-01-01T00:00:00Z'})!.bestSnrDb, isNull);
  });

  test('request carries limit, route, type, cursor on the region host', () async {
    late Uri seen;
    final api = HttpRegionPacketsApi(Uri.parse('https://day.meshsonar.com'), client: MockClient((r) async {
      seen = r.url;
      return http.Response(jsonEncode(_live), 200);
    }));
    await api.packets(limit: 500, route: 2, type: 4, cursor: 'c');
    expect(seen.path, '/api/cmh/region-packets');
    expect(seen.queryParameters, {'limit': '200', 'route': '2', 'type': '4', 'cursor': 'c'});
  });

  test('errors: 400 message, busy statuses, garbage body, network', () async {
    Future<PacketsException> run(http.Response Function() f) async {
      final api = HttpRegionPacketsApi(Uri.parse('https://x.org'), client: MockClient((_) async => f()));
      try {
        await api.packets();
      } on PacketsException catch (e) {
        return e;
      }
      fail('expected throw');
    }

    final bad = await run(() => http.Response('{"error":"type must be 0 to 15"}', 400));
    expect(bad.message, 'type must be 0 to 15');
    expect(bad.busy, isFalse);
    expect((await run(() => http.Response('slow down', 429))).busy, isTrue);
    expect((await run(() => http.Response('', 503))).busy, isTrue);
    expect((await run(() => http.Response('<html>', 200))).message, contains('unreadable'));
    final net = HttpRegionPacketsApi(Uri.parse('https://x.org'), client: MockClient((_) async => throw http.ClientException('down')));
    expect(net.packets(), throwsA(isA<PacketsException>()));
  });
}
