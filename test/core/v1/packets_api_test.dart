// The Packets reads (AZ-3.2) in the three server states: `/v1` live (contract fixtures), `/v1` not live (today's
// `region-packets` / `region-packet` with the reduced field set and the filters it cannot apply named), and offline
// (the stored copy with its "as of" time, or a plain offline error). Plus paging, detail parsing for every fixture,
// more observations, the filter catalogue fallback, POST /v1/decode, and My radio matching by hash.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/etag_client.dart';
import 'package:meshsonar/core/network_request.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/v1/my_radio_packets.dart';
import 'package:meshsonar/core/v1/network_api.dart' show NetworkReadSource;
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/tools/rx_log.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();
http.Response json(String body, [int status = 200]) => http.Response(body, status, headers: {'content-type': 'application/json'});
const base = 'https://cmh.meshsonar.com';

const legacyPage = {
  'status': {'state': 'ready', 'reason': null},
  'rows': [
    {'hash': 'C4B06EE8FC39B187', 'type': 5, 'route': 1, 'firstAt': '2026-11-20T14:02:05.120Z', 'observers': 2, 'minHops': 4, 'bestSnrDb': 1.75},
    {'hash': '1add53ffce368256', 'type': 4, 'route': 1, 'firstAt': '2026-11-20T14:00:40.120Z', 'observers': 2, 'minHops': 1, 'bestSnrDb': 11.0, 'originName': 'Library Room'},
  ],
  'nextCursor': 'legacy-2',
};

const legacyDetail = {
  'status': {'state': 'ready', 'reason': null},
  'row': {'hash': 'c4b06ee8fc39b187', 'type': 5, 'route': 1, 'firstAt': '2026-11-20T14:02:05.120Z', 'observers': 2, 'minHops': 3, 'bestSnrDb': 1.75},
  'observations': [
    {'observer': 'd1a761a8', 'observerName': 'MS Westside', 'at': '2026-11-20T14:02:05.120Z', 'snrDb': 1.75, 'rssiDbm': -109, 'hops': 4, 'path': ['E2', 'a7', '3c', '4f']},
    {'observer': 'obs-9', 'at': '2026-11-20T14:02:06.000Z', 'snrDb': -3.0, 'hops': 3, 'path': ['e2', 'a7', '3c'], 'via': {'name': 'Scioto Mesh'}},
  ],
  'tree': {
    'hop': 'e2',
    'children': [
      {
        'hop': 'a7',
        'ambiguous': true,
        'children': [
          {
            'hop': '3c',
            'key': '3cd0c95448b8566d21060bfec77f420446b1122cb903ec140fe946603dbdfbd4',
            'name': 'Old Mill RPT',
            'confidence': 'low',
            'children': [
              {'hop': '4f', 'key': '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c', 'name': 'Hilltop RPT'}
            ]
          }
        ]
      }
    ]
  },
};

void main() {
  setUp(resetV1NotLive);

  group('/v1 live', () {
    test('the list parses grouped rows, paging cursors and meta; every filter goes to the server', () async {
      final seen = <Uri>[];
      final api = PacketsApi(base, client: MockClient((r) async {
        seen.add(r.url);
        return json(fixture('packets'));
      }));
      const f = PacketFilter(types: {'ADVERT', 'TRACE'}, channels: {'public'}, hopsMin: 2, source: PacketSourceFilter.ours);
      final p = await api.list(f, const PacketWindow.named('24h'));
      expect(seen.single.path, '/v1/packets');
      expect(seen.single.queryParameters, {
        'type': 'ADVERT,TRACE',
        'channel': 'public',
        'source': 'meshsonar,meshsonar-phone',
        'filter': 'hops >= 2',
        'window': '24h',
        'groupBy': 'hash',
        'limit': '100',
      });
      expect(p.source, NetworkReadSource.v1);
      expect(p.rows.length, 7);
      expect(p.rows.map((r) => r.hash).toSet().length, 7, reason: 'one row per hash');
      final pub = p.rows.firstWhere((r) => r.hash == 'c4b06ee8fc39b187');
      expect(pub.observerCount, 2);
      expect(pub.bestSnr, 1.75);
      expect(pub.channel!.id, 'public');
      expect(pub.title, 'Public: Kestrel-07: anyone hearing Hilltop this morning?');
      expect(p.rows.firstWhere((r) => r.typeName == 'ADVERT').origin!.name, 'Library Room');
      expect(p.rows.firstWhere((r) => r.hash == '1c26c203910896f0').scope!.name, '#cmh');
      expect(p.next, 'eyJ0IjoiMjAyNi0xMS0yMFQxNDowMDo0MC4xMjBaIiwiaCI6IjAwIn0');
      expect(p.prev, isNotNull);
      expect(p.approxTotal, 18342);
      expect(p.nodeListTrusted, isTrue);
      expect(p.sources['src_12']!.name, 'Ohio Valley CoreScope');
      // The next page sends the cursor with the same filters.
      await api.list(f, const PacketWindow.named('24h'), cursor: p.next);
      expect(seen.last.queryParameters['cursor'], p.next);
      expect(seen.last.queryParameters['type'], 'ADVERT,TRACE');
    });

    test('a since/until window is sent as RFC 3339', () async {
      Uri? seen;
      final api = PacketsApi(base, client: MockClient((r) async {
        seen = r.url;
        return json(fixture('packets'));
      }));
      await api.list(PacketFilter.none, PacketWindow.range(DateTime.utc(2026, 11, 20, 10), DateTime.utc(2026, 11, 20, 11)));
      expect(seen!.queryParameters['since'], '2026-11-20T10:00:00.000Z');
      expect(seen!.queryParameters['until'], '2026-11-20T11:00:00.000Z');
      expect(seen!.queryParameters.containsKey('window'), isFalse);
    });

    test('a bad filter is the server error with its position', () async {
      final api = PacketsApi(base, client: MockClient((r) async => json('{"error":{"code":"bad_filter","message":"unknown field","at":4,"requestId":"r1"}}', 400)));
      await expectLater(api.list(const PacketFilter(text: 'type = ADVERT'), PacketWindow.defaultWindow),
          throwsA(isA<V1Error>().having((e) => e.code, 'code', 'bad_filter').having((e) => e.at, 'at', 4)));
    });

    for (final name in [
      'advert-first-party',
      'grp-txt-outside-ambiguous',
      'grp-txt-hashtag-merged',
      'grp-txt-private-undecodable',
      'txt-msg-encrypted',
      'trace',
    ]) {
      test('detail $name parses bytes, decoded, paths and observations', () async {
        final body = fixture('packet-detail.$name');
        final want = (jsonDecode(body) as Map)['data'] as Map;
        Uri? seen;
        final api = PacketsApi(base, client: MockClient((r) async {
          seen = r.url;
          return json(body);
        }));
        final r = await api.detail((want['hash'] as String).toUpperCase());
        expect(seen!.path, '/v1/packets/${want['hash']}');
        final d = r.detail;
        expect(d.source, PacketSource.v1);
        expect(d.hash, want['hash']);
        expect(d.raw, want['raw']);
        expect(d.rawVerified, isTrue);
        expect(d.bytes.length, (want['bytes'] as List).length);
        expect(d.decodedKind, (want['decoded'] as Map).keys.single);
        expect(d.observations.length, (want['observations'] as List).length);
        expect(d.paths.length, (want['paths'] as List).length);
        expect(d.webLink.toString(), (want['links'] as Map)['web']);
      });
    }

    test('hop confidence comes through as sent: unknown, ambiguous with candidates, likely with score, unique', () async {
      final api = PacketsApi(base, client: MockClient((r) async => json(fixture('packet-detail.grp-txt-outside-ambiguous'))));
      final d = (await api.detail('c4b06ee8fc39b187')).detail;
      final hops = d.paths.first.hops;
      expect([for (final h in hops) h.confidence], [HopConfidence.unknown, HopConfidence.ambiguous, HopConfidence.likely, HopConfidence.unique]);
      expect(hops[1].node, isNull);
      expect([for (final c in hops[1].candidates) c.node.name], ['Riverside RPT', 'Quarry Hill RPT']);
      expect(hops[1].candidatesTotal, 2);
      expect(hops[2].node!.name, 'Old Mill RPT');
      expect(hops[2].score, 0.82);
      expect(hops[2].position!.lat, 39.99655);
      expect(hops[3].node!.name, 'Hilltop RPT');
      expect(d.message!.sender, 'Kestrel-07');
      expect(d.observations.last.observer.id, 'src_31:obs-1142');
      expect(d.paths.last.direction, 'travelled');
    });

    test('more observations page with the cursor', () async {
      Uri? seen;
      final api = PacketsApi(base, client: MockClient((r) async {
        seen = r.url;
        return json(fixture('packet-observations'));
      }));
      final p = await api.observations('c4b06ee8fc39b187', cursor: 'abc');
      expect(seen!.path, '/v1/packets/c4b06ee8fc39b187/observations');
      expect(seen!.queryParameters['cursor'], 'abc');
      expect(p.rows.first.observer.name, 'OVCS Clintonville');
      expect(p.rows[1].observer.kind, 'fixed');
    });

    test('filter catalogue from the server, else the built-in copy', () async {
      final live = PacketsApi(base, client: MockClient((r) async => json(fixture('filter-fields'))));
      final cat = await live.filterFields();
      expect(cat.builtIn, isFalse);
      expect(cat.examples, isNotEmpty);
      resetV1NotLive();
      final dead = PacketsApi(base, client: MockClient((r) async => http.Response('', 404)));
      expect((await dead.filterFields()).builtIn, isTrue);
    });

    test('POST /v1/decode sends the hex and reads the answer; null when not live', () async {
      late http.Request req;
      final api = PacketsApi(base, client: MockClient((r) async {
        req = r;
        return json(fixture('decode'));
      }));
      final r = (await api.decode('1504e2a7'))!;
      expect(req.method, 'POST');
      expect(req.url.path, '/v1/decode');
      expect(jsonDecode(req.body), {'hex': '1504e2a7'});
      expect(r.known, isTrue);
      expect(r.detail.source, PacketSource.serverDecode);
      expect(r.detail.hash, 'c4b06ee8fc39b187');
      resetV1NotLive();
      final dead = PacketsApi(base, client: MockClient((r) async => http.Response('<html>', 404)));
      expect(await dead.decode('15'), isNull);
    });
  });

  group('/v1 not live: today\'s region reads', () {
    test('the list falls back quietly with the reduced field set, says which filters it cannot apply', () async {
      final seen = <Uri>[];
      final api = PacketsApi(base, clock: () => DateTime.utc(2026, 11, 20, 15), client: MockClient((r) async {
        seen.add(r.url);
        if (r.url.path.startsWith('/v1/')) return http.Response('<html>not found</html>', 404);
        return json(jsonEncode(legacyPage));
      }));
      const f = PacketFilter(types: {'GRP_TXT'}, channels: {'public'}, hopsMin: 2);
      final p = await api.list(f, const PacketWindow.named('6h'));
      expect(seen.first.path, '/v1/packets');
      expect(seen.last.path, '/api/cmh/region-packets');
      expect(seen.last.queryParameters, {'type': '5', 'since': '2026-11-20T09:00:00.000Z', 'limit': '100'});
      expect(p.source, NetworkReadSource.legacy);
      expect(p.unapplied, ['channel']);
      expect(p.rows.map((r) => r.hash), ['c4b06ee8fc39b187'], reason: 'hops >= 2 is filtered on the phone');
      expect(p.rows.single.typeName, 'GRP_TXT');
      expect(p.rows.single.route, 'FLOOD');
      expect(p.rows.single.size, isNull, reason: 'the old read has no size: null, never a fake zero');
      expect(p.next, 'legacy-2');
      // Paging stays on the fallback, and /v1 is not asked again (not-live memory).
      seen.clear();
      await api.list(f, const PacketWindow.named('6h'), cursor: p.next, legacyCursor: true);
      expect(seen.single.path, '/api/cmh/region-packets');
      expect(seen.single.queryParameters['cursor'], 'legacy-2');
    });

    test('the detail falls back to region-packet: observations, paths with confidence from the tree, no bytes', () async {
      final api = PacketsApi(base, client: MockClient((r) async {
        if (r.url.path.startsWith('/v1/')) return http.Response('', 404);
        expect(r.url.path, '/api/cmh/region-packet');
        expect(r.url.queryParameters['hash'], 'c4b06ee8fc39b187');
        return json(jsonEncode(legacyDetail));
      }));
      final d = (await api.detail('c4b06ee8fc39b187')).detail;
      expect(d.source, PacketSource.legacy);
      expect(d.hasBytes, isFalse);
      expect(d.missing.single, contains('does not send packet bytes yet'));
      expect(d.observations.length, 2);
      expect(d.observations.last.observer.kind, 'outside');
      expect(d.paths.length, 2);
      final hops = d.paths.first.hops;
      expect([for (final h in hops) h.prefix], ['e2', 'a7', '3c', '4f']);
      expect([for (final h in hops) h.confidence], [HopConfidence.unknown, HopConfidence.ambiguous, HopConfidence.likely, HopConfidence.unique]);
      expect(hops[2].node!.name, 'Old Mill RPT');
      expect(d.observations.first.pathId, d.paths.first.id);
    });

    test('a hash nobody heard is not_found in both states', () async {
      final v1 = PacketsApi(base, client: MockClient((r) async => json(fixture('error'), 404)));
      await expectLater(v1.detail('0000000000000000'), throwsA(isA<V1Error>().having((e) => e.notFound, 'notFound', isTrue)));
      resetV1NotLive();
      final old = PacketsApi(base, client: MockClient((r) async => r.url.path.startsWith('/v1/') ? http.Response('', 404) : json('{"status":{"state":"ready"},"row":null}')));
      await expectLater(old.detail('0000000000000000'), throwsA(isA<V1Error>().having((e) => e.notFound, 'notFound', isTrue)));
    });
  });

  group('offline', () {
    test('no connection and nothing stored: an offline error', () async {
      final api = PacketsApi(base, client: MockClient((r) async => throw const SocketException('down')));
      await expectLater(api.list(PacketFilter.none, PacketWindow.defaultWindow), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
      await expectLater(api.detail('c4b06ee8fc39b187'), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
    });

    test('the stored copy is served with its "as of" time', () async {
      final dir = await Directory.systemTemp.createTemp('pk_cache');
      addTearDown(() => dir.delete(recursive: true));
      var up = true;
      final inner = MockClient((r) async {
        if (!up) throw const SocketException('down');
        return r.url.path == '/v1/packets' ? json(fixture('packets')) : json(fixture('packet-detail.trace'));
      });
      final etag = EtagClient(inner, RegionCache(dir), staleAfter: const Duration(seconds: 2));
      final api = PacketsApi(base, client: etag);
      expect((await api.list(PacketFilter.none, PacketWindow.defaultWindow)).offlineAsOf, isNull);
      await api.detail('50b835a910da5aac');
      up = false;
      final p = await api.list(PacketFilter.none, PacketWindow.defaultWindow);
      expect(p.offlineAsOf, isNotNull);
      expect(p.rows.length, 7);
      final d = (await api.detail('50b835a910da5aac')).detail;
      expect(d.offlineAsOf, isNotNull);
      expect(d.typeName, 'TRACE');
    });
  });

  group('My radio', () {
    test('heard packets decode on the phone and match the network by hash', () {
      final log = RxLog(clock: () => DateTime.utc(2026, 11, 20, 14, 2, 6));
      final raw = (jsonDecode(fixture('packet-detail.grp-txt-outside-ambiguous')) as Map)['data']['raw'] as String;
      log.add(fromHex(raw), snrDb: 4.25, rssiDbm: -101);
      log.add(fromHex((jsonDecode(fixture('packet-detail.trace')) as Map)['data']['raw'] as String), snrDb: 7);
      log.add(fromHex('15'), snrDb: 1); // not a packet: only its length is kept
      final all = myRadioPackets(log);
      expect(all.length, 3);
      expect(all.first.detail, isNull);
      expect(all.first.problem, contains('keeps only its length'));
      final match = radioHeard(log, 'C4B06EE8FC39B187');
      expect(match.length, 1);
      expect(match.single.detail!.source, PacketSource.myRadio);
      expect(match.single.detail!.localSnr, 4.25);
      expect(match.single.detail!.message!.text, 'anyone hearing Hilltop this morning?');
      expect(match.single.detail!.raw, raw, reason: 'the Rx log rebuilds the exact bytes');
      expect(radioHeard(log, '1add53ffce368256'), isEmpty);
      expect(radioHeard(null, 'c4b06ee8fc39b187'), isEmpty);
    });
  });

  group('NetworkRequest carries the list state', () {
    test('a list link round-trips every filter and the window', () {
      const f = PacketFilter(types: {'ADVERT'}, channels: {'public', 'tag:wardriving'}, hopsMin: 2, snrMax: 0, source: PacketSourceFilter.outside, scope: '#cmh', text: 'age < 1h');
      final r = NetworkRequest.packetList(f, region: 'cmh', window: '24h');
      final web = r.toWebUri();
      expect(web.host, 'cmh.meshsonar.com');
      expect(web.path, '/packets');
      expect(web.queryParameters['type'], 'ADVERT');
      expect(web.queryParameters['window'], '24h');
      final back = NetworkRequest.parse(web)!;
      expect(back.listFilter, f);
      expect(back.window, '24h');
      expect(NetworkRequest.parse(r.toAppUri())!.listFilter, f);
      expect(back, r);
    });

    test('single-node links keep the AZ-3.1 fields and merge into the list filter', () {
      const key = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';
      final r = NetworkRequest.parse(Uri.parse('https://cmh.meshsonar.com/packets?node=$key&type=TRACE'))!;
      expect(r.nodeKey, key);
      expect(r.listFilter.nodes, [key]);
      expect(r.listFilter.types, {'TRACE'});
      expect(NetworkRequest.parse(r.toWebUri())!.listFilter, r.listFilter);
      final prefix = NetworkRequest.parse(Uri.parse('https://cmh.meshsonar.com/packets?hash=c4b06ee8'))!;
      expect(prefix.packetHash, isNull);
      expect(prefix.listFilter.hash, 'c4b06ee8');
      expect(prefix.toWebUri().path, '/packets');
      expect(NetworkRequest.parse(Uri.parse('https://cmh.meshsonar.com/packets/c4b06ee8fc39b187'))!.toWebUri().path, '/packets/c4b06ee8fc39b187');
    });
  });
}
