// AZ-3.5: search on /v1/search with the local fallback, share links in the region-host form, and link parsing for
// region subdomains (the links `applinks:*.meshsonar.com` now opens in the app).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/network_request.dart';
import 'package:meshsonar/core/v1/search_api.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name').readAsStringSync();

const hilltop = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';
const quarry = 'a70e50d47a757afc624567a35e00bc93baf97509844ea9f01b34942bc0d21027';
const riverside = 'a7b21db75893e8c8665e5060b05d5e03c68c963d5a3a6e7e0dba6b5e0b9cde85';

const ix = LocalSearchIndex(
  region: 'cmh',
  nodes: [
    (key: hilltop, name: 'Hilltop RPT', role: 'repeater'),
    (key: quarry, name: 'Quarry Hill RPT', role: 'repeater'),
    (key: riverside, name: 'Riverside RPT', role: 'repeater'),
  ],
  regions: [(slug: 'cmh', name: 'Columbus, US'), (slug: 'day', name: 'Dayton, US'), (slug: 'hil', name: 'Hilo, US')],
  observers: [(id: 'src_31:obs-1142', name: 'Scioto North'), (id: 'd1a761a8d6478b879df8a2278225f4fc2c10d2f925f537c6cdd7921c7f147a0f', name: 'MS Westside Observer')],
);

void main() {
  setUp(resetV1NotLive);

  group('search', () {
    test('/v1/search: hits open the node page, a message opens its packet', () async {
      Uri? seen;
      final api = SearchApi('https://cmh.meshsonar.com', client: MockClient((r) async {
        seen = r.url;
        return http.Response(fixture('search.json'), 200, headers: {'content-type': 'application/json'});
      }));
      final r = await api.search('hill');
      expect(seen!.path, '/v1/search');
      expect(seen!.queryParameters['q'], 'hill');
      expect(r.local, isFalse);
      expect(r.hits.map((h) => h.title), ['Hilltop RPT', 'Quarry Hill RPT', 'anyone hearing Hilltop this morning?']);
      expect(r.hits.first.request, NetworkRequest.node(hilltop, region: 'cmh'));
      expect(r.hits.last.request, NetworkRequest.packet('c4b06ee8fc39b187', region: 'cmh'));
      expect(r.truncated, {SearchKind.message});
    });

    test('falls back to the local index while /v1 is not live', () async {
      final api = SearchApi('https://cmh.meshsonar.com', client: MockClient((r) async => http.Response('<html>', 404)));
      final r = await api.search('hill', local: ix);
      expect(r.local, isTrue);
      expect(r.localReason, 'not_live');
      // starts-with before contains; "Hilo" does not contain "hill".
      expect(r.hits.where((h) => h.kind == SearchKind.node).map((h) => h.title), ['Hilltop RPT', 'Quarry Hill RPT']);
      expect(r.hits.where((h) => h.kind == SearchKind.region), isEmpty);
      expect((await api.search('hil', local: ix)).hits.where((h) => h.kind == SearchKind.region).map((h) => h.region), ['hil'],
          reason: 'the exact slug first');
    });

    test('falls back to the local index offline', () async {
      final api = SearchApi('https://cmh.meshsonar.com', client: MockClient((r) async => throw const SocketException('no route')));
      final r = await api.search('scioto', local: ix);
      expect(r.localReason, 'offline');
      expect(r.hits.single.request, const NetworkRequest.observer('src_31:obs-1142', region: 'cmh'));
    });

    test('local rules: key prefix, hop prefix, packet hash and prefix, region slug', () {
      final a7 = localSearch('a7', ix);
      expect(a7.where((h) => h.kind == SearchKind.node).map((h) => h.title), ['Quarry Hill RPT', 'Riverside RPT']);
      expect(a7.any((h) => h.title == 'Packets through hop a7' && h.request!.listFilter.prefix == 'a7'), isTrue);
      final full = localSearch('C4B06EE8FC39B187', ix);
      expect(full.first.request, NetworkRequest.packet('c4b06ee8fc39b187', region: 'cmh'));
      final pre = localSearch('c4b06ee8', ix);
      expect(pre.first.request!.listFilter.hash, 'c4b06ee8');
      expect(localSearch('day', ix).single.request, const NetworkRequest.section(NetworkSection.home, region: 'day'));
      expect(localSearch('x', ix), isEmpty, reason: 'two characters at least');
      expect(localSearch('zzzz', ix), isEmpty);
    });
  });

  group('share links (region-host form)', () {
    test('node, packet, observer and region views', () {
      expect(NetworkRequest.node(hilltop, region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/nodes/$hilltop');
      expect(NetworkRequest.packet('c4b06ee8fc39b187', region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/packets/c4b06ee8fc39b187');
      expect(const NetworkRequest.observer('src_31:obs-1142', region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/observers/src_31%3Aobs-1142');
      expect(const NetworkRequest.section(NetworkSection.nodes, region: 'day').toWebUri().toString(), 'https://day.meshsonar.com/nodes');
      expect(const NetworkRequest.section(NetworkSection.home, region: 'day').toWebUri().toString(), 'https://day.meshsonar.com/');
      expect(const NetworkRequest.section(NetworkSection.live, region: 'cmh').toWebUri().toString(), 'https://cmh.meshsonar.com/live');
    });
  });

  group('link parsing: region subdomains', () {
    NetworkRequest? p(String s) => NetworkRequest.parse(Uri.parse(s));

    test('every route on a region host carries that region', () {
      expect(p('https://cmh.meshsonar.com/nodes/$hilltop'), NetworkRequest.node(hilltop, region: 'cmh'));
      expect(p('https://day.meshsonar.com/packets/C4B06EE8FC39B187'), NetworkRequest.packet('c4b06ee8fc39b187', region: 'day'));
      expect(p('https://cmh.meshsonar.com/observers/src_31%3Aobs-1142'), const NetworkRequest.observer('src_31:obs-1142', region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/'), const NetworkRequest.section(NetworkSection.home, region: 'cmh'));
      expect(p('https://cmh.meshsonar.com/repeaters/$hilltop')!.nodeKey, hilltop, reason: 'old /repeaters links still open the node');
      expect(p('https://swoh.meshsonar.com/map?panel=live')!.region, 'swoh');
      expect(p('https://CMH.MeshSonar.com/nodes')!.region, 'cmh', reason: 'host case does not matter');
    });

    test('?region= wins over the host (a region host may show another region)', () {
      expect(p('https://cmh.meshsonar.com/nodes?region=day')!.region, 'day');
    });

    test('hosts that are not regions, other domains and deeper subdomains are not Network links', () {
      for (final s in [
        'https://www.meshsonar.com/nodes',
        'https://api.meshsonar.com/nodes',
        'https://tiles.meshsonar.com/manifest.json',
        'https://a.b.meshsonar.com/nodes',
        'https://cmh.meshsonar.com.evil.example/nodes',
        'https://evilmeshsonar.com/nodes',
        'https://cmh.meshsonar.com/nodes/not-a-key',
        'https://cmh.meshsonar.com/share/plan',
      ]) {
        expect(p(s), isNull, reason: s);
      }
    });

    test('a shared link round-trips to the same view', () {
      for (final r in [
        NetworkRequest.node(hilltop, region: 'cmh'),
        NetworkRequest.packet('c4b06ee8fc39b187', region: 'day'),
        const NetworkRequest.observer('src_31:obs-1142', region: 'cmh'),
        const NetworkRequest.section(NetworkSection.analytics, region: 'cmh'),
        NetworkRequest.mapPacket('c4b06ee8fc39b187', region: 'cmh', at: DateTime.utc(2026, 11, 20, 14, 2, 5)),
      ]) {
        expect(NetworkRequest.parse(r.toWebUri()), r, reason: '${r.toWebUri()}');
      }
    });
  });
}
