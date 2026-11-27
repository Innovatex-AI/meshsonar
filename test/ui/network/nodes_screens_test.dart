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
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_overview_api.dart' show RegionDataState;
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/core/v1/nodes_api.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/repeater_page_link.dart';
import 'package:meshsonar/ui/charts/time_line_chart.dart';
import 'package:meshsonar/ui/network/network_context.dart';
import 'package:meshsonar/ui/network/nodes/node_ui.dart';
import 'package:meshsonar/ui/network/packets/packet_ui.dart' show plainServerText;
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

/// Opens a closed section of a node or observer page (build 76: one row each, a tap opens it).
Future<void> openSection(WidgetTester t, String id) async {
  final head = find.descendant(of: find.byKey(Key('node-section-$id')), matching: find.byType(ListTile)).first;
  await t.ensureVisible(head);
  await t.pumpAndSettle();
  await t.tap(head);
  await t.pumpAndSettle();
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
    expect(find.textContaining('Companion\u00A0· Active'), findsOneWidget, reason: 'a separator is tied to the word before it');
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

    // Build 76: a plain hint, a clear button in the field, one Clear chip while a filter is on, a chevron on every row.
    expect(find.text('Search nodes by name or ID'), findsOneWidget);
    expect(find.byKey(const Key('nodes-clear-filters')), findsNothing);
    await t.ensureVisible(find.byKey(const Key('nodes-role-room')));
    await t.tap(find.byKey(const Key('nodes-role-room')));
    await settle(t);
    await t.ensureVisible(find.byKey(const Key('nodes-clear-filters')));
    await t.tap(find.byKey(const Key('nodes-clear-filters')));
    await settle(t);
    expect(s.seen.last.queryParameters['role'], isNull);
    expect(find.text('Hilltop RPT'), findsOneWidget);
    await t.enterText(find.byKey(const Key('nodes-search')), 'old');
    await t.pump();
    await t.tap(find.byKey(const Key('nodes-search-clear')));
    await settle(t);
    expect(find.text('Hilltop RPT'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('nodes-list')), matching: find.byIcon(Icons.chevron_right)), findsWidgets);

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

  testWidgets('node page: every supplied section, star, no bell, share link', (t) async {
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
    // Build 76: what people look for comes first (name, kind and state, last heard, position, actions, key on one line);
    // nothing is said twice; every other part is one closed row that a tap opens.
    expect(find.byKey(const Key('node-name')), findsOneWidget);
    expect(find.byKey(const Key('node-heard')), findsOneWidget);
    expect(find.text('Status'), findsNothing, reason: 'the state is in the header, not again under Health');
    expect(find.text('Last heard'), findsNothing);
    expect(t.widget<Text>(find.byKey(const Key('node-key'))).data, '${hilltop.substring(0, 8)}…${hilltop.substring(58)}');
    expect(t.getSize(find.byKey(const Key('node-key-copy'))).height, greaterThanOrEqualTo(44));
    expect(t.getTopLeft(find.byKey(const Key('node-actions'))).dy, lessThan(t.getTopLeft(find.byKey(const Key('node-section-health'))).dy));
    for (final id in ['activity', 'types', 'snr', 'heard-by', 'neighbours', 'paths', 'reach', 'clock', 'battery', 'radio', 'hash', 'adverts']) {
      expect(find.descendant(of: find.byKey(Key('node-section-$id')), matching: find.byType(ExpansionTile)), findsOneWidget, reason: '$id is a closed row');
    }
    expect(find.textContaining('could be Riverside RPT or Quarry Hill RPT'), findsNothing, reason: 'Neighbours starts closed');
    await openSection(t, 'neighbours');
    expect(find.text('Could be Riverside RPT or Quarry Hill RPT'), findsNothing);
    expect(find.textContaining('could be Riverside RPT or Quarry Hill RPT'), findsOneWidget);
    await openSection(t, 'hash');
    expect(find.text('Short ID in packets'), findsOneWidget);
    expect(find.text('First seen'), findsOneWidget);
    await t.drag(find.byKey(const Key('node-page')), const Offset(0, 3000));
    await settle(t);

    await t.tap(find.byKey(const Key('fav-node-$hilltop')));
    await settle(t);
    expect(networkFavouritesForTest().isFavourite(FavouriteKind.node, hilltop), isTrue);

    // Build 77 (Round 2 N-U9): no bell; the star stays.
    expect(find.byKey(const Key('watch-button')), findsNothing);
    expect(find.byKey(Key('fav-node-$hilltop')), findsOneWidget);
    // Round 2 N-U3: "See who shares this ID" sits on the short ID row.
    expect(find.byKey(const Key('link-node-shares-id')), findsOneWidget);

    await t.tap(find.byKey(const Key('network-share')));
    await settle(t);
    expect(shared, 'https://cmh.meshsonar.com/nodes/$hilltop');
  });

  testWidgets('node page: a long list shows five rows and one "Show all" button; a huge clock drift is said in words', (t) async {
    tall(t);
    Widget row(int i) => ListTile(title: Text('row $i'));
    await t.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: NodeMoreList(id: 'x', children: [for (var i = 0; i < 12; i++) row(i)])))));
    expect(find.text('row 4'), findsOneWidget);
    expect(find.text('row 5'), findsNothing);
    expect(find.text('Show all 12'), findsOneWidget);
    expect(t.getSize(find.byKey(const Key('node-more-x'))).height, greaterThanOrEqualTo(44));
    await t.tap(find.byKey(const Key('node-more-x')));
    await t.pump();
    expect(find.text('row 11'), findsOneWidget);
    expect(find.byKey(const Key('node-more-x')), findsNothing);
    expect(driftText(-67263900.0), 'Jumps around (not a steady drift)');
    expect(driftText(2.34), '2.3 s per day fast');
    expect(readableName('212de2caebe743a1e2eb1d298f4a959616ad8806877839418478eb40e30e4ca4'), 'Unnamed 212de2ca…');
    expect(readableName('Hilltop RPT'), 'Hilltop RPT');
  });

  testWidgets('node page: the SNR trend is one collapsed header; tapping it shows the 30-day card', (t) async {
    tall(t);
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
    await settle(t);
    expect(find.text('Signal trend'), findsOneWidget);
    expect(find.byKey(const Key('node-snr-latest')), findsOneWidget);
    expect(find.byKey(const Key('repdetail-snr-trend')), findsNothing, reason: 'collapsed by default');
    await t.ensureVisible(find.text('Signal trend'));
    expect(t.getSize(find.descendant(of: find.byKey(const Key('node-section-snr')), matching: find.byType(ExpansionTile))).height, greaterThanOrEqualTo(44));
    await t.tap(find.text('Signal trend'));
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
    expect(find.textContaining('Phone observer\u00A0· Online'), findsOneWidget);
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

  test('shareText never shows over 100%; radioText reads the raw and the labelled forms; server text drops internal codes', () {
    expect(shareText(1.042), '100%');
    expect(shareText(0.98), '98%');
    expect(shareText(-0.1), '0%');
    expect(radioText('910.525024,62.5,7,5'), '910.525 MHz · BW 62.5 kHz · SF 7 · CR 5');
    expect(radioText('910.525 MHz · 62.5 kHz · SF7 · CR5'), '910.525 MHz · BW 62.5 kHz · SF 7 · CR 5');
    expect(radioText('869.618,250.0,11,5'), '869.618 MHz · BW 250 kHz · SF 11 · CR 5');
    expect(radioText('LongFast preset'), 'LongFast preset');
    expect(
        plainServerText('Some figures are missing: relay figures and hop-based activity (the node list is incomplete, so hop codes cannot be tied to this node). '
            'Radio, scope, usefulness, battery, clock, claim and recent adverts arrive with AZ-1.5 to AZ-1.8.'),
        'Some figures are missing: relay figures and hop-based activity (the node list is incomplete, so hop codes cannot be tied to this node).');
    expect(plainServerText('Comes with AZ-3.11.'), isNull);
    expect(plainServerText('No observers report to this region yet.'), 'No observers report to this region yet.');
  });

  testWidgets('node page: a 24 h share the server sends over 1 shows as 100%, and its note carries no internal code', (t) async {
    tall(t);
    final j = jsonDecode(fixture('node-detail')) as Map<String, dynamic>;
    (((j['data'] as Map)['health'] as Map)['uptime'] as Map)['h24'] = 1.042; // 25 hourly buckets over a 24 h base
    // A note shows only while data is really missing (pending or failed); a "partial" footer is not printed (Round 2 W7).
    (j['meta'] as Map)['status'] = {'state': 'pending', 'reason': 'Some figures are missing: relay figures. Radio and clock arrive with AZ-1.5 to AZ-1.8.'};
    nodesApiFactory = (b) => NodesApi(b,
        client: MockClient((r) async => r.url.path == '/v1/nodes/$hilltop' ? json(jsonEncode(j)) : json('{"error":{"code":"not_found","message":"none","requestId":"r"}}', 404)));
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
    await settle(t);
    expect(find.text('Heard (24 h)'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.textContaining('104%'), findsNothing);
    expect(t.widget<Text>(find.byKey(const Key('node-status-note'))).data, 'Some figures are missing: relay figures.');
    expect(find.textContaining('AZ-'), findsNothing);
  });

  testWidgets('node page (Round 2 W7): the server\'s "not on this page yet" footer of a partial answer is not printed', (t) async {
    tall(t);
    final j = jsonDecode(fixture('node-detail')) as Map<String, dynamic>;
    (j['meta'] as Map)['status'] = {'state': 'partial', 'reason': 'Radio settings, scopes, usefulness, battery, clock, claim and recent adverts are not on this page yet.'};
    nodesApiFactory = (b) => NodesApi(b,
        client: MockClient((r) async => r.url.path == '/v1/nodes/$hilltop' ? json(jsonEncode(j)) : json('{"error":{"code":"not_found","message":"none","requestId":"r"}}', 404)));
    await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
    await settle(t);
    expect(find.byKey(const Key('node-status-note')), findsNothing);
    expect(find.textContaining('not on this page yet'), findsNothing);
    expect(nodeStatusNoteShown(RegionDataState.partial), isFalse);
    expect(nodeStatusNoteShown(RegionDataState.stale), isFalse);
    expect(nodeStatusNoteShown(RegionDataState.pending), isTrue);
    expect(nodeStatusNoteShown(RegionDataState.unavailable), isTrue);
  });

  testWidgets('observer page: radio settings are spelled out and the dashed line is named under the chart', (t) async {
    tall(t);
    final j = jsonDecode(fixture('observer-detail')) as Map<String, dynamic>;
    (j['data'] as Map)['radio'] = '910.525024,62.5,7,5';
    final inner = s.client;
    nodesApiFactory = (b) => NodesApi(b, client: MockClient((r) async => r.url.path == '/v1/observers/$westside' ? json(jsonEncode(j)) : inner.get(r.url)));
    await t.pumpWidget(app(const NetworkObserverScreen(baseUrl: base, regionSlug: 'cmh', observerId: westside)));
    await settle(t);
    await openSection(t, 'observer-hardware');
    expect(t.widget<Text>(find.byKey(const Key('observer-radio'))).data, '910.525 MHz · BW 62.5 kHz · SF 7 · CR 5');
    expect(find.textContaining('910.525024'), findsNothing);
    expect(find.textContaining('Dashed line: interference above this (-100 dBm).', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Dashed line: duty limit', skipOffstage: false), findsOneWidget);
    for (final c in t.widgetList<TimeLineChart>(find.byType(TimeLineChart, skipOffstage: false))) {
      expect(c.refLabel, isNull, reason: 'no label drawn on top of the data line');
    }
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
    await openSection(t, 'heard-by');
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
    expect(find.byKey(const Key('observer-name')), findsOneWidget);
    expect(find.byKey(const Key('observer-seen')), findsOneWidget);
    expect(find.text('RAK4631'), findsNothing, reason: 'Hardware starts closed; its row says the model');
    expect(find.textContaining('RAK4631'), findsOneWidget);
    await openSection(t, 'observer-hardware');
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

  testWidgets('Round 2 N-U4, N-U11: Observers chips with counts, online first, the kind in words, "Updated X ago"', (t) async {
    tall(t);
    final now = DateTime.utc(2026, 11, 20, 14, 20);
    var clock = now;
    await t.pumpWidget(app(Scaffold(body: ObserversDirectoryView(baseUrl: base, regionSlug: 'cmh', clock: () => clock))));
    await settle(t);
    for (final (chip, label) in [('all', 'All 4'), ('online', 'Online 3'), ('meshsonar', 'MeshSonar 1'), ('phone', 'Phone 1'), ('outside', 'Outside 2')]) {
      expect(find.descendant(of: find.byKey(Key('observers-chip-$chip')), matching: find.text(label)), findsOneWidget, reason: chip);
    }
    expect(find.text('Updated just now \u00B7 pull to refresh'), findsOneWidget);
    clock = now.add(const Duration(minutes: 5));
    await t.pump(const Duration(seconds: 31));
    expect(find.text('Updated 5 min ago \u00B7 pull to refresh'), findsOneWidget, reason: 'the line ticks on its own');
    // Online first: the stale outside feed is the last row.
    final rows = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('observer-row-') && !(w.key as ValueKey<String>).value.contains('-what-') && !(w.key as ValueKey<String>).value.contains('-figures-'));
    final ids = [for (final e in rows.evaluate()) ((e.widget.key as ValueKey<String>).value)];
    expect(ids.last, startsWith('observer-row-src_31:'), reason: 'stale after online');
    await t.ensureVisible(find.byKey(const Key('observers-chip-outside')));
    await t.tap(find.byKey(const Key('observers-chip-outside')));
    await settle(t);
    expect(find.byKey(const Key('observer-row-$westside')), findsNothing, reason: 'a MeshSonar observer is not an outside feed');
    expect(rows.evaluate().length, 2);
    await t.ensureVisible(find.byKey(const Key('observers-chip-phone')));
    await t.tap(find.byKey(const Key('observers-chip-phone')));
    await settle(t);
    expect(rows.evaluate().length, 1);
  });

  test('Round 2 N-U4: the Observers order is online, stale, offline, newest report first; the kind words', () {
    ObserverRow r(String id, String status, int? min, {String kind = 'fixed', String? phoneKind, bool? ours}) => ObserverRow(
        id: id, name: id, kind: kind, status: status, lastSeen: min == null ? null : DateTime.utc(2026, 11, 20, 14, min), phoneKind: phoneKind, operatedByMeshsonar: ours);
    final order = observersInListOrder([r('a', 'offline', 50), r('b', 'online', 1), r('c', 'stale', 40), r('d', 'online', 9), r('e', 'online', null)]);
    expect([for (final o in order) o.id], ['d', 'b', 'e', 'c', 'a']);
    expect(observerKindWords(r('p', 'online', 1, kind: 'phone', phoneKind: 'mobile')), 'Phone observer, moving');
    expect(observerKindWords(r('p', 'online', 1, kind: 'phone')), 'Phone observer');
    expect(observerKindWords(r('f', 'online', 1, ours: true)), 'MeshSonar observer, run by MeshSonar');
    expect(observerKindWords(r('f', 'online', 1, ours: false)), 'MeshSonar observer');
    expect(observerKindWords(r('o', 'online', 1, kind: 'outside')), 'Outside feed');
  });

  testWidgets('Round 2 N-U4: the observer page has a Stats block with its links, no bell, the star', (t) async {
    tall(t);
    await t.pumpWidget(app(const NetworkObserverScreen(baseUrl: base, regionSlug: 'cmh', observerId: westside)));
    await settle(t);
    expect(find.byKey(const Key('node-section-observer-stats')), findsOneWidget);
    expect(find.byKey(const Key('observer-stat-last')), findsOneWidget);
    for (final id in ['observer-packets', 'observer-compare', 'observer-rf-health', 'observer-live']) {
      expect(find.byKey(Key('link-$id')), findsOneWidget, reason: id);
    }
    expect(find.byKey(const Key('watch-button')), findsNothing);
    expect(find.byKey(const Key('fav-observer-$westside')), findsOneWidget);
    // Stats comes before the charts.
    expect(t.getTopLeft(find.byKey(const Key('node-section-observer-stats'))).dy, lessThan(t.getTopLeft(find.byKey(const Key('node-section-observer-metrics'))).dy));
  });

  test('Round 2 N-V4: 0 dBm is "no reading", never a noise level', () {
    expect(ObserverSample(DateTime.utc(2026), noiseFloorDbm: 0).noiseReading, isNull);
    expect(ObserverSample(DateTime.utc(2026), noiseFloorDbm: -93.5).noiseReading, -93.5);
    expect(const ObserverRow(id: 'x', name: 'x', kind: 'fixed', status: 'online', noiseFloorDbm: 0).noiseReading, isNull);
  });

  testWidgets('Round 2 N-V5, N-U11: a node row keeps its line whole, relays on their own line, "Updated X ago"', (t) async {
    tall(t);
    await t.pumpWidget(app(const Scaffold(body: NodeDirectoryView(baseUrl: base, regionSlug: 'cmh'))));
    await settle(t);
    expect(find.byKey(const Key('nodes-updated')), findsOneWidget);
    expect(find.textContaining('pull to refresh'), findsOneWidget);
    expect(find.byKey(const Key('node-row-relayed-$hilltop')), findsOneWidget);
    expect(t.widget<Text>(find.byKey(const Key('node-row-relayed-$hilltop'))).data, 'relayed 1843 today');
    expect(t.widget<Text>(find.byKey(const Key('node-row-line-$hilltop'))).data, isNot(contains('relayed')));
    expect(t.widget<Text>(find.byKey(const Key('node-row-line-$hilltop'))).data, isNot(contains(' · ')), reason: 'no breakable separator');
  });

  group('MAP slice 5: the small maps on the node and observer pages', () {
    void useLive() {
      ActiveMapDefinition.notifier.value = MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
      addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
    }

    testWidgets('node page: a map on a node with a position when the definition presets `node`; none without a position', (t) async {
      useLive();
      tall(t);
      await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
      await settle(t);
      expect(find.byKey(const Key('node-map')), findsOneWidget);
      expect(find.byKey(const Key('still-node-map')), findsOneWidget);
      expect(find.byKey(const Key('still-place-name')), findsOneWidget);
      await t.pumpWidget(app(const NetworkNodeScreen(key: Key('k'), baseUrl: base, regionSlug: 'cmh', nodeKey: kestrel, mapTiles: false)));
      await settle(t);
      expect(find.byKey(const Key('node-map')), findsNothing);
    });

    testWidgets('node page: with the bundled definition (no pages) there is no small map, as in build 73', (t) async {
      tall(t);
      await t.pumpWidget(app(const NetworkNodeScreen(baseUrl: base, regionSlug: 'cmh', nodeKey: hilltop, mapTiles: false)));
      await settle(t);
      expect(find.byKey(const Key('node-map')), findsNothing);
    });

    testWidgets('observer page: a map for a fixed observer with a position; none without the preset', (t) async {
      useLive();
      tall(t);
      await t.pumpWidget(app(const NetworkObserverScreen(baseUrl: base, regionSlug: 'cmh', observerId: westside)));
      await settle(t);
      expect(find.byKey(const Key('observer-map')), findsOneWidget);
      expect(find.byKey(const Key('still-observer-map')), findsOneWidget);
      ActiveMapDefinition.notifier.value = MapDefinition.bundled;
      await t.pumpWidget(app(const NetworkObserverScreen(key: Key('k'), baseUrl: base, regionSlug: 'cmh', observerId: westside)));
      await settle(t);
      expect(find.byKey(const Key('observer-map')), findsNothing);
    });
  });
}
