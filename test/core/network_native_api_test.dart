// Parsers and URLs of the V3 native network screens: observer detail and packet detail.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_observer_detail_api.dart';
import 'package:meshsonar/core/region_packet_detail_api.dart';

import 'network_native_fixtures.dart';

void main() {
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

}
