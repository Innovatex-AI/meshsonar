// Network > Nodes (AZ-3.4) widget tests, dark theme: the directory for every role with role / status / last-heard
// filter chips, search, favourites first and the My nodes chip; the node page with every
// section the API supplies and none it does not (hidden, never an empty box); the legacy fallback; star, Watch (sheet,
// saved on the phone, says alerts come later) and Share (region-host link); the observer page with metrics; offline;
// large text without overflow.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/v1/nodes_api.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/repeater_page_link.dart';
import 'package:meshsonar/ui/network/network_context.dart';
import 'package:meshsonar/ui/network/network_share.dart';
import 'package:meshsonar/ui/network/nodes/node_screen.dart';
import 'package:meshsonar/ui/network/nodes/nodes_section.dart';
import 'package:meshsonar/ui/network/nodes/observer_screen.dart';
import 'package:meshsonar/ui/theme.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();
http.Response json(String body, [int status = 200]) => http.Response(body, status, headers: {'content-type': 'application/json'});
const base = 'https://cmh.meshsonar.com';
const hilltop = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';
const kestrel = 'c48e58a12ba6d3040af2806c373e80452ef09c6a06b4d67eb82fa9cd3b69af65';
const westside = 'd1a761a8d6478b879df8a2278225f4fc2c10d2f925f537c6cdd7921c7f147a0f';
const region = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus', url: base);

class Server {
  final List<Uri> seen = [];
  bool v1 = true, offline = false;
  late final MockClient client = MockClient((r) async {
    seen.add(r.url);
    if (offline) throw const SocketException('down');
    final p = r.url.path;
    if (!v1 && p.startsWith('/v1/')) return http.Response('<html>', 404);
    if (p == '/v1/nodes') {
      final role = r.url.queryParameters['role'];
      final j = jsonDecode(fixture('nodes')) as Map<String, dynamic>;
      if (role != null) j['data'] = [for (final n in j['data'] as List) if (role.split(',').contains((n as Map)['role'])) n];
      final q = r.url.queryParameters['q'];
      if (q != null) j['data'] = [for (final n in j['data'] as List) if (((n as Map)['name'] as String).toLowerCase().contains(q)) n];
      return json(jsonEncode(j));
    }
    if (p == '/v1/nodes/$hilltop') return json(fixture('node-detail'));
    if (p == '/v1/nodes/$kestrel') return json(fixture('node-detail.no-location'));
    for (final s in ['activity', 'heard-by', 'neighbors', 'paths', 'reach', 'clock', 'battery']) {
      if (p == '/v1/nodes/$hilltop/$s') return json(fixture('node-$s'));
    }
    if (p == '/v1/observers') return json(fixture('observers'));
    if (p == '/v1/observers/$westside') return json(fixture('observer-detail'));
    if (p == '/v1/observers/$westside/metrics') return json(fixture('observer-metrics'));
    if (p == '/api/cmh/region-repeater') {
      return json(jsonEncode({
        'status': {'state': 'ready'},
        'row': {'key': hilltop, 'hashPrefix': '4f19', 'name': 'Hilltop RPT', 'role': 'repeater', 'lastHeardAt': '2026-11-20T14:05:00Z', 'heardHoursPct': 98, 'status': 'active'},
        'neighbours': [],
        'observers': [
          {'key': westside, 'name': 'MS Westside', 'packets': 412, 'bestSnrDb': 9.5}
        ],
        'packetTypes': [],
        'snrHourly': [],
        'rssiHourly': [],
      }));
    }
    if (p == '/api/cmh/region-repeaters') return json(jsonEncode({'status': {'state': 'ready'}, 'rows': [], 'counts': {}}));
    return json('{"error":{"code":"not_found","message":"Unknown","requestId":"r"}}', 404);
  });
}

Widget app(Widget child, {double scale = 1}) => MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    );

void tall(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 30000);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
  }
}

void main() {
  late Server s;
  late NetworkFavouritesStore store;
  NetworkFavouritesStore networkFavouritesForTest() => store;
  setUp(() {
    resetV1NotLive();
    store = NetworkFavouritesStore();
    debugResetNetworkFavourites(store);
    s = Server();
    nodesApiFactory = (b) => NodesApi(b, client: s.client);
  });
  tearDown(() {
    nodesApiFactory = (b) => NodesApi(b);
    debugNetworkShare = null;
  });

  testWidgets('directory: every role, filter chips go to the server, search, favourites first, My nodes', (t) async {
    tall(t);
    await t.pumpWidget(app(const Scaffold(body: NodeDirectoryView(baseUrl: base, regionSlug: 'cmh'))));
    await settle(t);
    for (final n in ['Hilltop RPT', 'Library Room', 'Creek Gauge', 'Kestrel-07', 'Eastgate RPT']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.textContaining('Companion · Active'), findsOneWidget);
    expect(find.text('Companion 1'), findsOneWidget, reason: 'role chips carry the counts');

    await t.ensureVisible(find.byKey(const Key('nodes-role-room')));
    await t.tap(find.byKey(const Key('nodes-role-room')));
    await settle(t);
    expect(s.seen.last.queryParameters['role'], 'room');
    expect(find.text('Library Room'), findsOneWidget);
    expect(find.text('Hilltop RPT'), findsNothing);
    await t.ensureVisible(find.byKey(const Key('nodes-role-room')));
    await t.tap(find.byKey(const Key('nodes-role-room')));
    await settle(t);

    await t.ensureVisible(find.byKey(const Key('nodes-heard-24h')));
    await t.tap(find.byKey(const Key('nodes-heard-24h')));
    await settle(t);
    expect(s.seen.last.queryParameters['lastHeard'], '24h');
    await t.ensureVisible(find.byKey(const Key('nodes-heard-24h')));
    await t.tap(find.byKey(const Key('nodes-heard-24h')));
    await settle(t);

    await t.enterText(find.byKey(const Key('nodes-search')), 'old');
    await t.pump(const Duration(milliseconds: 400));
    await settle(t);
    expect(s.seen.last.queryParameters['q'], 'old');
    expect(find.text('Old Mill RPT'), findsOneWidget);
    await t.enterText(find.byKey(const Key('nodes-search')), '');
    await t.pump(const Duration(milliseconds: 400));
    await settle(t);

    // Star Eastgate (the last row): it moves first; My nodes shows only it.
    await networkFavouritesForTest().toggleFavourite(FavouriteKind.node, '3c9f4f0d5b8d0d22e81eed085d02372a8b037a8ac1df62a84ced88eed980688f');
    await settle(t);
    final ys = {for (final n in ['Hilltop RPT', 'Eastgate RPT']) n: t.getTopLeft(find.text(n)).dy};
    expect(ys['Eastgate RPT']!, lessThan(ys['Hilltop RPT']!), reason: 'favourites first');
    await t.ensureVisible(find.byKey(const Key('nodes-mine')));
    await t.tap(find.byKey(const Key('nodes-mine')));
    await settle(t);
    expect(find.text('Eastgate RPT'), findsOneWidget);
    expect(find.text('Hilltop RPT'), findsNothing);
    expect(find.byKey(const Key('packets-web-twin')), findsOneWidget);
  });

  testWidgets('node page: every supplied section, star, watch sheet, share link', (t) async {
    tall(t);
    String? shared;
    debugNetworkShare = (text, subject) => shared = text;
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop)));
    await settle(t);
    expect(find.byKey(const Key('node-title')), findsOneWidget);
    for (final id in ['health', 'activity', 'types', 'snr', 'heard-by', 'neighbours', 'paths', 'reach', 'clock', 'battery', 'radio', 'hash', 'adverts']) {
      expect(find.byKey(Key('node-section-$id')), findsOneWidget, reason: id);
    }
    expect(find.text('98%'), findsOneWidget, reason: 'Heard (7 d)');
    expect(find.text('Heard (7 d)'), findsOneWidget);
    expect(find.textContaining('Uptime'), findsNothing);
    expect(find.text('Could be Riverside RPT or Quarry Hill RPT'), findsNothing);
    expect(find.textContaining('could be Riverside RPT or Quarry Hill RPT'), findsOneWidget);

    await t.tap(find.byKey(const Key('fav-node-$hilltop')));
    await settle(t);
    expect(networkFavouritesForTest().isFavourite(FavouriteKind.node, hilltop), isTrue);

    await t.tap(find.byKey(const Key('watch-button')));
    await settle(t);
    expect(find.byKey(const Key('watch-sheet')), findsOneWidget);
    expect(find.text('Alerts arrive in a later update; the watch is kept on this phone.'), findsOneWidget);
    await t.tap(find.byKey(const Key('watch-event-clock_bad')));
    await t.tap(find.byKey(const Key('watch-save')));
    await settle(t);
    final w = networkFavouritesForTest().watchOf('node', hilltop)!;
    expect(w.events, ['silent', 'battery_low']);
    expect(w.region, 'cmh');

    await t.tap(find.byKey(const Key('network-share')));
    await settle(t);
    expect(shared, 'https://cmh.meshsonar.com/nodes/$hilltop');
  });

  testWidgets('node page: the SNR trend is one collapsed header; tapping it shows the 30-day card', (t) async {
    tall(t);
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
    await settle(t);
    expect(find.text('SNR trend'), findsOneWidget);
    expect(find.byKey(const Key('node-snr-latest')), findsOneWidget);
    expect(find.byKey(const Key('repdetail-snr-trend')), findsNothing, reason: 'collapsed by default');
    await t.ensureVisible(find.text('SNR trend'));
    expect(t.getSize(find.byType(ExpansionTile)).height, greaterThanOrEqualTo(44));
    await t.tap(find.text('SNR trend'));
    await settle(t);
    expect(find.byKey(const Key('repdetail-snr-trend')), findsOneWidget);
    expect(find.text('30-day signal trend'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('node page: the drive sections sit on a node with a position and not on one without', (t) async {
    tall(t);
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
    await settle(t);
    expect(find.byKey(const Key('node-your-drives')), findsOneWidget);
    expect(find.byKey(const Key('node-drive-reach')), findsOneWidget);
    await t.pumpWidget(app(const NetworkNodeScreen(key: Key('k'), baseUrl: base, regionSlug: 'cmh', nodeKey: kestrel, mapTiles: false)));
    await settle(t);
    expect(find.byKey(const Key('node-your-drives')), findsNothing);
    expect(find.byKey(const Key('node-drive-reach')), findsNothing);
  });

  testWidgets('"Open repeater page" from a map sheet lands on the /v1 node screen', (t) async {
    t.view.physicalSize = const Size(1125, 2436);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(Builder(
      builder: (c) => Scaffold(
        body: TextButton(
          onPressed: () => openRepeaterPageFromMap(
              c,
              const RepeaterPoint(
                layerId: 'roster',
                source: RepeaterPointSource.roster,
                key: hilltop,
                name: 'Hilltop RPT',
                isRoom: false,
                lat: 40.01,
                lon: -83.01,
                band: 0,
                region: RosterRegion(slug: 'cmh', name: 'CMH', baseUrl: base),
              )),
          child: const Text('open'),
        ),
      ),
    )));
    await t.tap(find.text('open'));
    await settle(t);
    expect(find.byKey(const Key('network-node-screen')), findsOneWidget);
    expect(find.text('Hilltop RPT'), findsWidgets);
    expect(s.seen.any((u) => u.path == '/v1/nodes/$hilltop'), isTrue);
  });

  testWidgets('ObserversDirectoryView stands alone: rows at least 44 pt, tap opens the observer page', (t) async {
    t.view.physicalSize = const Size(1125, 2436); // 375 pt wide
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(const Scaffold(body: ObserversDirectoryView(baseUrl: base, regionSlug: 'cmh'))));
    await settle(t);
    expect(find.byKey(const Key('observers-list')), findsOneWidget);
    expect(find.text('OVCS Clintonville'), findsOneWidget);
    expect(find.textContaining('Phone observer · Online'), findsOneWidget);
    final row = find.byKey(const Key('observer-row-$westside'));
    await t.ensureVisible(row);
    expect(t.getSize(row).height, greaterThanOrEqualTo(44));
    expect(t.takeException(), isNull, reason: 'no overflow at 375 pt');
    await t.tap(row);
    await settle(t);
    expect(find.byType(NetworkObserverScreen), findsOneWidget);
  });

  testWidgets('observers of a region nothing reports to: the server\'s own sentence (old name still works)', (t) async {
    nodesApiFactory = (b) => NodesApi(b,
        client: MockClient((r) async => json(jsonEncode({
              'data': [],
              'page': {'limit': 200, 'next': null, 'approxTotal': 0},
              'meta': {
                'apiVersion': '1.0',
                'region': {'slug': 'phx', 'name': 'Southern Arizona, US', 'kind': 'region'},
                'generatedAt': '2026-11-21T11:27:24.742Z',
                'dataAt': null,
                'status': {'state': 'pending', 'reason': 'No observers report to this region yet. Run an observer: it joins by itself.'},
                'sources': {},
              },
            }))));
    await t.pumpWidget(app(const Scaffold(body: ObserverListView(key: Key('phx'), baseUrl: 'https://phx.meshsonar.com', regionSlug: 'phx'))));
    await settle(t);
    expect(find.textContaining('No observers report to this region yet'), findsOneWidget);
  });

  testWidgets('node page hides the sections the API does not supply', (t) async {
    tall(t);
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: kestrel)));
    await settle(t);
    expect(find.text('Never advertised a position'), findsOneWidget);
    expect(find.byKey(const Key('node-section-health')), findsOneWidget);
    for (final id in ['activity', 'snr', 'heard-by', 'neighbours', 'paths', 'reach', 'clock', 'battery', 'radio']) {
      expect(find.byKey(Key('node-section-$id')), findsNothing, reason: id);
    }
    expect(find.byKey(const Key('node-section-hash')), findsOneWidget);
  });

  testWidgets('node page falls back to the region repeater read when /v1 is not live', (t) async {
    tall(t);
    s.v1 = false;
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop)));
    await settle(t);
    expect(find.byKey(const Key('node-legacy-note')), findsOneWidget);
    expect(find.byKey(const Key('node-section-heard-by')), findsOneWidget);
    expect(find.textContaining('best 9.5 dB'), findsOneWidget);
    expect(find.byKey(const Key('node-section-paths')), findsNothing);
    expect(find.byKey(const Key('node-section-battery')), findsNothing);
  });

  testWidgets('node page offline with nothing stored: the no-connection view', (t) async {
    s.offline = true;
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop)));
    await settle(t);
    expect(find.byKey(const Key('region-offline-empty')), findsOneWidget);
  });

  testWidgets('observer page: metrics charts, neighbour report, star and share', (t) async {
    tall(t);
    String? shared;
    debugNetworkShare = (text, subject) => shared = text;
    await t.pumpWidget(app(const NetworkObserverScreen(baseUrl: base, regionSlug: 'cmh', observerId: westside)));
    await settle(t);
    expect(find.text('MS Westside Observer'), findsWidgets);
    expect(find.byKey(const Key('node-section-observer-metrics')), findsOneWidget);
    expect(find.byKey(const Key('chart-obs-noise')), findsOneWidget);
    expect(find.byKey(const Key('chart-obs-airtime')), findsOneWidget);
    expect(find.byKey(const Key('chart-obs-battery')), findsNothing, reason: 'no battery samples: hidden');
    expect(find.byKey(const Key('node-section-observer-neighbours')), findsOneWidget);
    expect(find.text('RAK4631'), findsOneWidget);
    await t.tap(find.byKey(const Key('fav-observer-$westside')));
    await t.tap(find.byKey(const Key('network-share')));
    await settle(t);
    expect(shared, 'https://cmh.meshsonar.com/observers/$westside');
    expect(networkFavouritesForTest().isFavourite(FavouriteKind.observer, westside), isTrue);
  });

  testWidgets('a 375 pt wide phone: node page, observer page and the directory lay out without overflow', (t) async {
    t.view.physicalSize = const Size(1125, 2436);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
    await settle(t);
    expect(t.takeException(), isNull);
    for (var i = 0; i < 8; i++) {
      await t.drag(find.byKey(const Key('node-page')), const Offset(0, -700));
      await settle(t);
      expect(t.takeException(), isNull);
    }
    await t.pumpWidget(app(const NetworkObserverScreen(baseUrl: base, regionSlug: 'cmh', observerId: westside)));
    await settle(t);
    expect(t.takeException(), isNull);
    await t.pumpWidget(app(const Scaffold(body: NodeDirectoryView(baseUrl: base, regionSlug: 'cmh'))));
    await settle(t);
    expect(t.takeException(), isNull);
  });

  testWidgets('large text: node and observer pages lay out without overflow', (t) async {
    t.view.physicalSize = const Size(1170, 2532);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop), scale: 2.5));
    await settle(t);
    expect(t.takeException(), isNull);
    await t.drag(find.byKey(const Key('node-page')), const Offset(0, -4000));
    await settle(t);
    expect(t.takeException(), isNull);
    await t.pumpWidget(app(const NetworkObserverScreen(baseUrl: base, regionSlug: 'cmh', observerId: westside), scale: 2.5));
    await settle(t);
    expect(t.takeException(), isNull);
    await t.pumpWidget(app(const Scaffold(body: NodeDirectoryView(baseUrl: base, regionSlug: 'cmh')), scale: 2.5));
    await settle(t);
    expect(t.takeException(), isNull);
  });
}
