// Parsers and URLs of the V3 native network screens: flood routes (tool-routes), observer detail, packet detail, findings.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/flood_routes_api.dart';
import 'package:meshsonar/core/region_findings_api.dart';
import 'package:meshsonar/core/region_observer_detail_api.dart';
import 'package:meshsonar/core/region_packet_detail_api.dart';

import 'network_native_fixtures.dart';

void main() {
  group('flood routes', () {
    test('urls match the website: tool-routes with action, hash and hours on the region host', () {
      final api = FloodRoutesApi('https://cmh.meshsonar.com/');
      expect(api.uri({'action': 'recent'}).toString(), 'https://cmh.meshsonar.com/api/cmh/tool-routes?action=recent');
      expect(api.uri({'action': 'trace', 'hash': kHashA}).queryParameters, {'action': 'trace', 'hash': kHashA});
    });

    test('normalizePacketHash: 16 hex, case, spaces and 0x tolerated; anything else is null', () {
      expect(normalizePacketHash('73af46d9fd880617'), kHashA);
      expect(normalizePacketHash('  0x73AF46D9 fd880617\n'), kHashA);
      expect(normalizePacketHash('73af46d9'), isNull);
      expect(normalizePacketHash('zzaf46d9fd880617'), isNull);
      expect(normalizePacketHash(''), isNull);
    });

    test('recent: rows, the unavailable state, and the packet worth showing first', () {
      final r = RecentFloods.parse(recentBody());
      expect(r.packets, hasLength(2));
      expect(r.unavailable, isFalse);
      expect(r.best!.hash, kHashA, reason: 'hops x 10 + observations');
      expect(floodPayloadName(r.packets.first.payloadType), 'Advert');
      expect(floodPayloadName('GRP_TXT'), 'Channel message');
      expect(floodPayloadName('SOMETHING'), 'SOMETHING');
      final none = RecentFloods.parse(recentBody(unavailable: true));
      expect(none.unavailable, isTrue);
      expect(none.best, isNull);
    });

    test('trace: tree, edges, observations and byte ranges parse; an unplaced hop stays unplaced', () {
      final t = FloodTrace.parse(traceBody());
      expect(t.hash, kHashA);
      expect(t.maxDepth, 3);
      expect(t.maxHops, 2);
      expect(t.observerCount, 2);
      expect(t.nodes, hasLength(4));
      expect(t.root!.displayName, 'Alpha');
      final c3 = t.byId['hop:c3']!;
      expect(c3.located, isFalse);
      expect(c3.displayName, 'Unknown c3');
      expect(t.relays.length, 2);
      expect(t.relaysIdentified, 1, reason: 'the unresolved prefix is not identified');
      expect(t.edges.last.toObserver, isTrue);
      expect(t.edges.first.snr, isNull);
      expect(t.observations.first.observer, 'Obs One');
      expect(t.observations.last.observer.length, 8, reason: 'no name: first 8 of the id');
      expect(t.ranges.map((r) => r.length), [1, 2, 7]);
      expect(t.payloadVersion, 1);
    });

    test('aggregate: totals, carry, corridors, histogram median, collisions, and a collision error', () {
      final a = FloodAggregate.parse(aggregateBody());
      expect(a.hashes, 200);
      expect(a.resolvedShare, closeTo(0.5, 1e-9));
      expect(a.carry.first.displayName, 'Bravo');
      expect(a.carry[1].displayName, 'c3c3c3c3');
      expect(a.corridors.first.labels, ['Bravo', 'c3c3c3c3']);
      expect(a.hopHistogram.map((h) => h.$1), [0, 1, 2, 13]);
      expect(a.medianHops, 1, reason: '50 + 60 = 110 >= 100');
      expect(a.ends[1].displayName, 'Unidentified dd');
      expect(a.locations.length, 2);
      expect(a.collisions.single.nodes, hasLength(2));
      expect(a.collisions.single.seenAsOneByteHop, 12);
      final err = FloodAggregate.parse({...aggregateBody(), 'collisions': {'error': 'okimesh down'}});
      expect(err.collisionsError, 'okimesh down');
      expect(err.hasCollisionData, isTrue);
      expect(FloodAggregate.parse({...aggregateBody(), 'collisions': null}).hasCollisionData, isFalse);
    });
  });

  group('observer detail', () {
    test('url is region-observer with the lowercase key', () {
      expect(ObserverDetailApi('https://cmh.meshsonar.com').uriFor('AB12').toString(), 'https://cmh.meshsonar.com/api/cmh/region-observer?key=ab12');
    });

    test('row, hourly series (oldest first, gaps kept as null) and top nodes', () {
      final d = ObserverDetailData.parse(observerBody());
      expect(d.row!.displayName, 'Hilltop Obs');
      expect(d.row!.online, isTrue);
      expect(d.radio, '910.525/62.5/7/5');
      expect(d.noiseFloor, hasLength(6));
      expect(d.noiseFloor[3].a, isNull);
      expect(d.noiseFloor.first.at.isBefore(d.noiseFloor.last.at), isTrue);
      expect(d.airtime.first.a, 1.5);
      expect(d.airtime.first.b, 7.25);
      expect(d.packetTypes, [(4, 700), (5, 300)]);
      expect(d.topNodes.first.displayName, 'Bravo');
      expect(d.topNodes[1].displayName, 'c3c3c3c3…');
      expect(d.health, isNull, reason: 'the server does not send a health state yet');
      expect(d.hasCharts, isTrue);
    });

    test('health slot: a server that sends row.health and healthReason shows up with no code change', () {
      final d = ObserverDetailData.parse(observerBody(withHealth: true));
      expect(d.health!.state, 'deaf');
      expect(d.health!.batteryLow, isTrue);
      final n = d.health!.notice((t) => 'HH:MM')!;
      expect(n.bad, isTrue);
      expect(n.headline, 'Battery low: 3.40 V and falling, the likely cause. Not hearing packets since HH:MM, check the radio');
      expect(const ObserverHealth(state: 'ok').notice((t) => ''), isNull);
      expect(const ObserverHealth(state: 'ok', batteryMv: 3500, batteryLow: true).notice((t) => '')!.bad, isFalse);
    });

    test('a null row (unknown observer answered 200) parses as no row', () {
      final d = ObserverDetailData.parse({'status': {'state': 'not_found'}, 'row': null});
      expect(d.row, isNull);
      expect(d.hasCharts, isFalse);
    });
  });

  group('packet detail', () {
    test('row, observations sorted by time, via name and the tree', () {
      final d = PacketDetailData.parse(packetBody());
      expect(d.hasRow, isTrue);
      expect(d.hash, kHashA);
      expect(d.route, 1);
      expect(d.observations.first.who, 'Obs One');
      expect(d.observations.last.via, 'Outside Feed');
      expect(d.tree!.children, hasLength(2));
      expect(d.tree!.children[0].label, 'Bravo');
      expect(d.tree!.children[1].label, 'Several repeaters share c3');
    });

    test('url', () {
      expect(PacketDetailApi('https://cmh.meshsonar.com').uriFor(kHashA.toUpperCase()).toString(), 'https://cmh.meshsonar.com/api/cmh/region-packet?hash=$kHashA');
    });
  });

  group('findings', () {
    test('parse: severity, evidence numbers formatted, impact labels and values', () {
      final f = RegionFindings.parse(findingsBody());
      expect(f.insights, hasLength(2));
      expect(f.count(FindingSeverity.high), 1);
      expect(f.categories, ['Coverage', 'Health']);
      expect(f.insights.first.evidence.first.value, '12,345');
      expect(f.insights.first.evidence.last.ref, 'link:D2|Oscar');
      expect(f.sites['D2'], 'Dublin Library');
      final r = f.recommendations.single;
      expect(impactLabel('newPeopleWithin3km'), 'people newly within 3 km');
      expect(impactLabel('someNewMetric2'), 'some new metric 2');
      expect(impactValue('newPeopleWithin3km', r.impact['newPeopleWithin3km']!), '+12.3k');
      expect(impactValue('sites', 1), '1');
      expect(fmtFindingNumber(1234567.5), '1,234,567.5');
      expect(fmtFindingNumber(-0.25), '-0.25');
    });

    test('an empty region is pending and empty; an unknown severity is low', () {
      final f = RegionFindings.parse(findingsBody(empty: true));
      expect(f.isEmpty, isTrue);
      expect(f.status.reason, contains('No findings'));
      final odd = RegionFindings.parse({'insights': [{'id': 'X', 'severity': 'bogus'}]});
      expect(odd.insights.single.severity, FindingSeverity.low);
    });
  });
}
