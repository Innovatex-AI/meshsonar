// The Nodes reads (AZ-3.4) in the three server states: `/v1` live (contract fixtures for the directory, node detail
// and every sub-resource, observers, observer detail and metrics), `/v1` not live (today's region-repeaters?roles=all
// filtered on the phone, region-repeater, region-observers, region-observer), and offline (stored copy with its "as of"
// time, or a plain offline error). Absent sub-resources come back null so the page hides them.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/etag_client.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/v1/nodes_api.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();
http.Response json(String body, [int status = 200]) => http.Response(body, status, headers: {'content-type': 'application/json'});
const base = 'https://cmh.meshsonar.com';
const hilltop = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';
const kestrel = 'c48e58a12ba6d3040af2806c373e80452ef09c6a06b4d67eb82fa9cd3b69af65';
const westside = 'd1a761a8d6478b879df8a2278225f4fc2c10d2f925f537c6cdd7921c7f147a0f';

http.Response v1Fixtures(http.Request r) {
  final p = r.url.path;
  if (p == '/v1/nodes') return json(fixture('nodes'));
  if (p == '/v1/nodes/$hilltop') return json(fixture('node-detail'));
  if (p == '/v1/nodes/$kestrel') return json(fixture('node-detail.no-location'));
  for (final s in ['activity', 'heard-by', 'neighbors', 'paths', 'reach', 'clock', 'battery']) {
    if (p == '/v1/nodes/$hilltop/$s') return json(fixture('node-$s'));
  }
  if (p.startsWith('/v1/nodes/$kestrel/')) return json('{"error":{"code":"not_found","message":"none","requestId":"r"}}', 404);
  if (p == '/v1/observers') return json(fixture('observers'));
  if (p == '/v1/observers/$westside') return json(fixture('observer-detail'));
  if (p == '/v1/observers/$westside/metrics') return json(fixture('observer-metrics'));
  return json('{"error":{"code":"not_found","message":"Unknown","requestId":"r"}}', 404);
}

const legacyRoster = {
  'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-11-20T14:00:00Z'},
  'rows': [
    {'key': hilltop, 'hashPrefix': '4f19', 'name': 'Hilltop RPT', 'role': 'repeater', 'lat': 40.01, 'lon': -83.01, 'lastHeardAt': '2026-11-20T14:05:00Z', 'relays24h': 1843, 'status': 'active'},
    {'key': kestrel, 'hashPrefix': 'c4', 'name': 'Kestrel-07', 'role': 'companion', 'lastHeardAt': '2026-11-20T10:00:00Z', 'status': 'quiet'},
    {'key': 'a7b21db75893e8c8665e5060b05d5e03c68c963d5a3a6e7e0dba6b5e0b9cde85', 'hashPrefix': 'a7', 'name': 'Riverside RPT', 'role': 'repeater', 'lastHeardAt': '2026-11-10T10:00:00Z', 'status': 'stale'},
  ],
  'counts': {'active': 1, 'quiet': 1, 'new': 0, 'stale': 1},
};

const legacyRepeater = {
  'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-11-20T14:00:00Z'},
  'row': {'key': hilltop, 'hashPrefix': '4f19', 'name': 'Hilltop RPT', 'role': 'repeater', 'lat': 40.01, 'lon': -83.01, 'lastHeardAt': '2026-11-20T14:05:00Z', 'relays24h': 1843, 'heardHoursPct': 98, 'snrMeanDb': 5.4, 'status': 'active'},
  'neighbours': [
    {'key': '3cd0c95448b8566d21060bfec77f420446b1122cb903ec140fe946603dbdfbd4', 'name': 'Old Mill RPT', 'kind': 'observed', 'snrDb': 4.75, 'distanceKm': 7.9, 'packets': 640}
  ],
  'heatmap': null,
  'snrHourly': [],
  'rssiHourly': [],
  'snrDaily': [
    {'day': '2026-11-19', 'meanDb': 5.0, 'n': 47},
    {'day': '2026-11-20', 'meanDb': 5.4, 'n': 22}
  ],
  'packetTypes': [
    {'type': 5, 'n': 812},
    {'type': 4, 'n': 4}
  ],
  'observers': [
    {'key': westside, 'name': 'MS Westside', 'packets': 412, 'bestSnrDb': 9.5, 'lastAt': '2026-11-20T14:05:00Z'}
  ],
  'adverts': [],
  'events': [],
};

const legacyObservers = {
  'status': {'state': 'ready', 'reason': null},
  'rows': [
    {'key': westside, 'name': 'MS Westside', 'online': true, 'source': 'meshsonar', 'lat': 39.97, 'lon': -83.07, 'packetsPerHour': 640, 'noiseFloorDbm': -112},
    {'key': '08af2aa59175566e72f3b7157a9956104cea0983fa320d658f9c9fb39bfa7d50', 'name': 'Phone 08f3', 'online': true, 'phone': true, 'lat': 39.9, 'lon': -83.0},
    {'key': 'obs-9', 'name': 'Scioto North', 'online': false, 'source': 'corescope'},
  ],
};

const legacyObserver = {
  'status': {'state': 'ready', 'reason': null},
  'row': {'key': westside, 'name': 'MS Westside', 'online': true, 'source': 'meshsonar', 'model': 'RAK4631', 'trusted': true, 'packetsPerHour': 640},
  'noiseFloor': [
    {'at': '2026-11-20T13:00:00Z', 'dbm': -112},
    {'at': '2026-11-20T14:00:00Z', 'dbm': -111}
  ],
  'airtime': [
    {'at': '2026-11-20T14:00:00Z', 'txPct': 1.9, 'rxPct': 14.2}
  ],
  'battery': [],
  'packetsPerHour': [
    {'at': '2026-11-20T14:00:00Z', 'n': 640}
  ],
  'packetTypes': [],
  'topNodes': [
    {'key': hilltop, 'name': 'Hilltop RPT', 'packets': 412}
  ],
};

http.Response legacy(http.Request r) {
  final p = r.url.path;
  if (p.startsWith('/v1/')) return http.Response('<html>not here</html>', 404);
  if (p == '/api/cmh/region-repeaters') {
    expect(r.url.queryParameters['roles'], 'all');
    return json(jsonEncode(legacyRoster));
  }
  if (p == '/api/cmh/region-repeater') return r.url.queryParameters['key'] == hilltop ? json(jsonEncode(legacyRepeater)) : json('{"status":{"state":"not_found"}}', 404);
  if (p == '/api/cmh/region-observers') return json(jsonEncode(legacyObservers));
  if (p == '/api/cmh/region-observer') return json(jsonEncode(legacyObserver));
  return http.Response('nope', 404);
}

void main() {
  setUp(resetV1NotLive);

  group('/v1 live', () {
    test('directory: every role, counts, and the filters go to the server', () async {
      final seen = <Uri>[];
      final api = NodesApi(base, client: MockClient((r) async {
        seen.add(r.url);
        return v1Fixtures(r);
      }));
      final p = await api.nodes(const NodeQuery(roles: {'repeater', 'room'}, statuses: {'active'}, lastHeard: '24h', q: 'hill'));
      expect(p.source, NetworkReadSource.v1);
      expect(p.rows.map((r) => r.role).toSet(), containsAll(['repeater', 'room', 'sensor', 'companion']));
      expect(p.roleCounts['companion'], 1);
      expect(p.statusCounts['silent'], 1);
      final q = seen.single.queryParameters;
      expect(q['role'], 'repeater,room');
      expect(q['status'], 'active');
      expect(q['lastHeard'], '24h');
      expect(q['q'], 'hill');
      final kes = p.rows.firstWhere((r) => r.name == 'Kestrel-07');
      expect(kes.position, isNull);
      expect(kes.positionReason, 'not_advertised');
      final hill = p.rows.firstWhere((r) => r.key == hilltop);
      expect(hill.usefulnessGrade, 'A');
      expect(hill.clockSeverity, 'ok');
    });

    test('node page with every sub-resource', () async {
      final api = NodesApi(base, client: MockClient((r) async => v1Fixtures(r)));
      final p = await api.node(hilltop);
      expect(p.detail.label, 'Hilltop RPT');
      expect(p.detail.prefixes['2'], '4f19');
      expect(p.detail.health!.heard7d, 0.98);
      expect(p.detail.radio!.model, 'Heltec V3');
      expect(p.detail.claimed, isTrue);
      expect(p.activity!.timeline.length, 6);
      expect(p.activity!.timeline.first.$3, 73);
      expect(p.activity!.snrTrend.where((s) => s.$2 == null).length, 1);
      expect(p.activity!.heatmap!.length, 7);
      expect(p.heardBy!.length, 3);
      expect(p.relayOnlyObservers, 3);
      expect(p.neighbours!.any((n) => n.node == null && n.confidence == 'ambiguous' && n.candidates.length == 2), isTrue);
      expect(p.paths!.first.hops.first.confidence, HopConfidence.unknown);
      expect(p.totalPaths, 2);
      expect(p.reach!.links.length, 2);
      expect(p.clock!.severity, 'critical');
      expect(p.battery!.latestMv, 3712);
    });

    test('sub-resources the server does not supply are null (hidden), not empty', () async {
      final api = NodesApi(base, client: MockClient((r) async => v1Fixtures(r)));
      final p = await api.node(kestrel);
      expect(p.detail.role, 'companion');
      expect(p.detail.position, isNull);
      expect(p.detail.health!.heard7d, isNull);
      expect(p.detail.radio, isNull);
      expect(p.activity, isNull);
      expect(p.heardBy, isNull);
      expect(p.neighbours, isNull);
      expect(p.paths, isNull);
      expect(p.reach, isNull);
      expect(p.clock, isNull);
      expect(p.battery, isNull);
    });

    test('an unknown node is a not_found error', () async {
      final api = NodesApi(base, client: MockClient((r) async => v1Fixtures(r)));
      await expectLater(api.node('00' * 32), throwsA(isA<V1Error>().having((e) => e.notFound, 'notFound', isTrue)));
    });

    test('observers, observer page and metrics', () async {
      final api = NodesApi(base, client: MockClient((r) async => v1Fixtures(r)));
      final l = await api.observers();
      expect(l.rows.length, 4);
      expect(l.rows.firstWhere((r) => r.kind == 'phone').position, isNull);
      final p = await api.observer(westside);
      expect(p.detail.model, 'RAK4631');
      expect(p.detail.radio, contains('SF7'));
      expect(p.detail.neighbours.length, 2);
      expect(p.detail.topNodes.first.$2, 412);
      final m = p.metrics!;
      expect(m.samples.length, 4);
      expect(m.samples[2].noiseFloorDbm, isNull, reason: 'a missing sample is nulls, never zeros');
      expect(m.samples[3].rebooted, isTrue);
      expect(m.gaps.length, 1);
      expect(m.dutyCycleWarnPct, 10);
    });
  });

  group('/v1 not live: today\'s region reads', () {
    test('directory from the roster, filtered on the phone', () async {
      final api = NodesApi(base, client: MockClient((r) async => legacy(r)), clock: () => DateTime.utc(2026, 11, 20, 14, 10));
      final all = await api.nodes(NodeQuery.all);
      expect(all.source, NetworkReadSource.legacy);
      expect(all.rows.length, 3);
      expect(all.rows.first.key, hilltop, reason: 'newest heard first');
      expect({for (final r in all.rows) r.name: r.status}, {'Hilltop RPT': 'active', 'Kestrel-07': 'degraded', 'Riverside RPT': 'silent'});
      expect(all.roleCounts, {'repeater': 2, 'companion': 1});

      expect((await api.nodes(const NodeQuery(roles: {'companion'}))).rows.single.name, 'Kestrel-07');
      expect((await api.nodes(const NodeQuery(statuses: {'silent'}))).rows.single.name, 'Riverside RPT');
      expect((await api.nodes(const NodeQuery(lastHeard: '1h'))).rows.single.name, 'Hilltop RPT');
      expect((await api.nodes(const NodeQuery(silentFor: '7d'))).rows.single.name, 'Riverside RPT');
      expect((await api.nodes(const NodeQuery(q: 'kest'))).rows.single.key, kestrel);
      expect((await api.nodes(const NodeQuery(q: 'C48E'))).rows.single.key, kestrel, reason: 'key prefix');
      expect((await api.nodes(const NodeQuery(hasLocation: true))).rows.single.key, hilltop);
    });

    test('node page from region-repeater: mapped sections, the rest hidden', () async {
      final api = NodesApi(base, client: MockClient((r) async => legacy(r)));
      final p = await api.node(hilltop);
      expect(p.source, NetworkReadSource.legacy);
      expect(p.detail.label, 'Hilltop RPT');
      expect(p.detail.health!.heard7d, 0.98);
      expect(p.detail.health!.avgSnr, 5.4);
      expect(p.heardBy!.single.bestSnr, 9.5);
      expect(p.heardBy!.single.avgSnr, isNull);
      expect(p.neighbours!.single.label, 'Old Mill RPT');
      expect(p.activity!.types, {'GRP_TXT': 812, 'ADVERT': 4});
      expect(p.activity!.snrTrend.length, 2);
      expect(p.paths, isNull);
      expect(p.reach, isNull);
      expect(p.clock, isNull);
      expect(p.battery, isNull);
      await expectLater(api.node(kestrel), throwsA(isA<V1Error>().having((e) => e.notFound, 'notFound', isTrue)));
    });

    test('observers and observer page from the region reads', () async {
      final api = NodesApi(base, client: MockClient((r) async => legacy(r)));
      final l = await api.observers();
      expect(l.source, NetworkReadSource.legacy);
      expect({for (final r in l.rows) r.name: r.kind}, {'MS Westside': 'fixed', 'Phone 08f3': 'phone', 'Scioto North': 'outside'});
      expect(l.rows.firstWhere((r) => r.kind == 'phone').position, isNull, reason: 'phones never get a position');
      expect(l.rows.firstWhere((r) => r.name == 'Scioto North').status, 'offline');
      expect((await api.observers(kinds: {'fixed'})).rows.single.name, 'MS Westside');
      final p = await api.observer(westside);
      expect(p.source, NetworkReadSource.legacy);
      expect(p.detail.model, 'RAK4631');
      expect(p.detail.topNodes.single.$1.name, 'Hilltop RPT');
      final m = p.metrics!;
      expect(m.resolution, '1h');
      expect(m.samples.length, 2);
      expect(m.samples.last.airtimeTxPct, 1.9);
      expect(m.samples.last.packetsRx, 640);
      expect(m.samples.first.airtimeTxPct, isNull);
    });
  });

  group('offline', () {
    test('no connection and nothing stored: an offline error', () async {
      final api = NodesApi(base, client: MockClient((r) async => throw const SocketException('down')));
      await expectLater(api.nodes(NodeQuery.all), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
      await expectLater(api.node(hilltop), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
      await expectLater(api.observers(), throwsA(isA<V1Error>().having((e) => e.offline, 'offline', isTrue)));
    });

    test('the stored copy is served with its "as of" time', () async {
      final dir = await Directory.systemTemp.createTemp('nodes_cache');
      addTearDown(() => dir.delete(recursive: true));
      var up = true;
      final inner = MockClient((r) async {
        if (!up) throw const SocketException('down');
        return v1Fixtures(r);
      });
      final api = NodesApi(base, client: EtagClient(inner, RegionCache(dir), staleAfter: const Duration(seconds: 2)));
      expect((await api.nodes(NodeQuery.all)).offlineAsOf, isNull);
      await api.node(hilltop);
      await api.observers();
      up = false;
      final p = await api.nodes(NodeQuery.all);
      expect(p.offlineAsOf, isNotNull);
      expect(p.rows.length, 7);
      final n = await api.node(hilltop);
      expect(n.offlineAsOf, isNotNull);
      expect(n.detail.label, 'Hilltop RPT');
      expect((await api.observers()).offlineAsOf, isNotNull);
    });
  });
}
