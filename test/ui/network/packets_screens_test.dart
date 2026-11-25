// Network > Packets (AZ-3.2) widget tests, dark theme: the list (grouping, paging with infinite scroll, expand to the
// observations, window chips, active filter chips, filter sheet, live pause/resume and the battery rules), the three
// server states (v1, fallback with the unapplied-filter banner, offline), My radio with matching by hash, the packet
// detail for every contract fixture, the byte inspector's two-way highlighting, Decode a packet, and large text.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/network_request.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/tools/rx_log.dart';
import 'package:meshsonar/ui/network/packets/byte_inspector.dart';
import 'package:meshsonar/ui/network/packets/decode_packet_screen.dart';
import 'package:meshsonar/ui/network/packets/packet_detail_body.dart' show packetObserversShown;
import 'package:meshsonar/ui/network/packets/packet_detail_screen.dart';
import 'package:meshsonar/ui/network/packets/packet_list_view.dart';
import 'package:meshsonar/ui/theme.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();
Map<String, dynamic> data(String name) => (jsonDecode(fixture(name)) as Map)['data'] as Map<String, dynamic>;
http.Response json(String body, [int status = 200]) => http.Response(body, status, headers: {'content-type': 'application/json'});
const base = 'https://cmh.meshsonar.com';
final now = DateTime.utc(2026, 11, 20, 14, 15);

/// A second page of the list: the fixture's rows with other hashes, and no next cursor.
String page2() {
  final j = jsonDecode(fixture('packets')) as Map<String, dynamic>;
  j['data'] = [
    for (final (i, r) in (j['data'] as List).indexed) {...(r as Map), 'hash': 'ffff00000000000$i', 'summary': 'Older packet $i'}
  ];
  j['page'] = {'limit': 50, 'next': null};
  return jsonEncode(j);
}

class Server {
  final List<Uri> seen = [];
  bool v1 = true;
  bool offline = false;

  /// Adds this many observations to a packet detail (a busy packet).
  int extraObservers = 0;

  /// The live answer of a region no feed covers (phx, swoh).
  bool noFeed = false;
  late final MockClient client = MockClient((r) async {
    seen.add(r.url);
    if (offline) throw const SocketException('down');
    final p = r.url.path;
    if (!v1 && p.startsWith('/v1/')) return http.Response('<html>', 404);
    if (noFeed && p == '/v1/packets') {
      return json(jsonEncode({
        'data': [],
        'page': {'limit': 100, 'next': null},
        'meta': {
          'apiVersion': '1.0',
          'region': {'slug': 'phx', 'name': 'Southern Arizona, US', 'kind': 'region'},
          'generatedAt': '2026-11-21T11:27:24.566Z',
          'dataAt': null,
          'status': {'state': 'unavailable', 'code': 'no_packet_feed', 'reason': 'No packet feed covers Southern Arizona, US yet: no outside feed delivers packets here and no MeshSonar observer or phone reports to it.'},
          'sources': {},
        },
      }));
    }
    if (p == '/v1/packets') return json(r.url.queryParameters['cursor'] == 'eyJ0IjoiMjAyNi0xMS0yMFQxNDowMDo0MC4xMjBaIiwiaCI6IjAwIn0' ? page2() : fixture('packets'));
    if (p.endsWith('/observations')) return json(fixture('packet-observations'));
    if (p == '/v1/filters/fields') return json(fixture('filter-fields'));
    if (p == '/v1/decode') return json(fixture('decode'));
    if (p.startsWith('/v1/packets/')) {
      final h = p.split('/').last;
      for (final n in ['advert-first-party', 'grp-txt-outside-ambiguous', 'grp-txt-hashtag-merged', 'grp-txt-private-undecodable', 'txt-msg-encrypted', 'trace']) {
        if (data('packet-detail.$n')['hash'] == h) {
          if (extraObservers == 0) return json(fixture('packet-detail.$n'));
          final j = jsonDecode(fixture('packet-detail.$n')) as Map<String, dynamic>;
          final d = j['data'] as Map<String, dynamic>;
          final obs = d['observations'] as List;
          final first = obs.first as Map;
          for (var i = 0; i < extraObservers; i++) {
            obs.add({
              ...first,
              'id': 'x$i',
              'observer': {...(first['observer'] as Map), 'id': 'extra-$i', 'name': 'Extra observer $i'},
              'path': [for (var k = 0; k < 9; k++) 'a$k'],
            });
          }
          d['observationCount'] = obs.length;
          d['observerCount'] = obs.length;
          return json(jsonEncode(j));
        }
      }
      return json(notFound, 404);
    }
    if (p == '/api/cmh/region-packets') {
      return json(jsonEncode({
        'status': {'state': 'ready'},
        'rows': [
          {'hash': 'c4b06ee8fc39b187', 'type': 5, 'route': 1, 'firstAt': '2026-11-20T14:02:05.120Z', 'observers': 2, 'minHops': 4, 'bestSnrDb': 1.75},
        ],
        'nextCursor': null,
      }));
    }
    if (p == '/api/cmh/region-packet') {
      return json(jsonEncode({
        'status': {'state': 'ready'},
        'row': {'hash': 'c4b06ee8fc39b187', 'type': 5, 'route': 1, 'firstAt': '2026-11-20T14:02:05.120Z', 'observers': 2, 'minHops': 4},
        'observations': [
          {'observer': 'd1a761a8', 'observerName': 'MS Westside', 'at': '2026-11-20T14:02:05.120Z', 'snrDb': 1.75, 'path': ['e2', 'a7', '3c', '4f']}
        ],
        'tree': null,
      }));
    }
    return http.Response('', 404);
  });
  PacketsApi get api => PacketsApi(base, client: client, clock: () => now);
  int count(String path) => seen.where((u) => u.path == path).length;
}

Widget app(Widget child, {double scale = 1}) => MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)), child: w!),
      home: child,
    );

Widget list(Server s, {NetworkRequest? request, RxLog? log, Duration poll = const Duration(seconds: 15), bool visible = true}) => app(Scaffold(
      body: TickerMode(
        enabled: visible,
        child: PacketListView(baseUrl: base, regionSlug: 'cmh', request: request, api: s.api, radioLog: log, clock: () => now, pollEvery: poll),
      ),
    ));

/// A tall phone (390 x 2400 pt) so a whole detail is built (ListView builds only what is near the screen).
void tall(WidgetTester t) {
  t.view.physicalSize = const Size(1170, 7200);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
}

const notFound = '{"error":{"code":"not_found","message":"No packet with hash 0000000000000000 in the last 90 days.","param":"hash","requestId":"r"}}';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUp(() {
    resetV1NotLive();
    packetShareOverride = null;
  });

  group('list', () {
    testWidgets('rows grouped by hash with observer count and best SNR; infinite scroll pages with the cursor, no cap', (t) async {
      t.view.physicalSize = const Size(1170, 2532); // an iPhone: the first page is longer than the screen
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final s = Server();
      await t.pumpWidget(list(s));
      await settle(t);
      expect(find.text('Public: Kestrel-07: anyone hearing Hilltop this morning?'), findsOneWidget);
      expect(find.textContaining('4 hops · heard by 2 observers'), findsOneWidget);
      expect(find.byKey(const ValueKey('packet-row-snr-c4b06ee8fc39b187')), findsOneWidget);
      expect(find.text('1.75 dB'), findsOneWidget);
      expect(s.seen.first.queryParameters['window'], '1h');
      await t.drag(find.byKey(const Key('packets-list')), const Offset(0, -3000));
      await settle(t);
      expect(s.seen.where((u) => u.path == '/v1/packets' && u.queryParameters['cursor'] != null).length, 1);
      await t.drag(find.byKey(const Key('packets-list')), const Offset(0, -3000));
      await settle(t);
      expect(find.text('Older packet 6'), findsOneWidget, reason: '14 rows: the second page is appended, nothing dropped');
      expect(find.text('No older packets in this window.'), findsOneWidget);
      expect(find.byKey(const Key('packets-web-twin')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a row expands to its observations', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(list(s));
      await settle(t);
      await t.tap(find.byKey(const Key('packet-row-expand-50b835a910da5aac')));
      await settle(t);
      expect(s.count('/v1/packets/50b835a910da5aac/observations'), 1);
      expect(find.byKey(const ValueKey('packet-row-obs-50b835a910da5aac')), findsOneWidget);
      expect(find.textContaining('OVCS Clintonville'), findsWidgets);
      await t.tap(find.byKey(const Key('packet-row-expand-50b835a910da5aac')));
      await settle(t);
      expect(find.byKey(const ValueKey('packet-row-obs-50b835a910da5aac')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('filter sheet: a channel typed but not added with + is still applied by Show packets', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(list(s));
      await settle(t);
      await t.tap(find.byKey(const Key('packets-filters')));
      await t.pumpAndSettle();
      expect(find.text('Show packets'), findsOneWidget);
      await t.scrollUntilVisible(find.byKey(const Key('filter-channel')), 200, scrollable: find.descendant(of: find.byKey(const Key('packet-filter-sheet')), matching: find.byType(Scrollable)).first);
      await t.enterText(find.byKey(const Key('filter-channel')), '#test');
      await t.tap(find.byKey(const Key('filter-apply')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('packet-filter-sheet')), findsNothing);
      expect(s.seen.last.queryParameters['channel'], 'tag:test');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('window chips re-ask; 30d and 90d need a narrowing filter', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(list(s));
      await settle(t);
      await t.tap(find.byKey(const Key('packets-window-24h')));
      await settle(t);
      expect(s.seen.last.queryParameters['window'], '24h');
      // Build 76: a tap on 30d without a narrowing filter asks nothing and says why, with a way to the filters.
      final asked = s.seen.length;
      await t.ensureVisible(find.byKey(const Key('packets-window-30d')));
      await t.tap(find.byKey(const Key('packets-window-30d')));
      await settle(t);
      expect(s.seen.length, asked, reason: 'the long window is not asked for without a filter');
      expect(find.byKey(const Key('packets-long-hint')), findsOneWidget);
      expect(find.byKey(const Key('packets-long-hint-filters')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      final s2 = Server();
      await t.pumpWidget(list(s2, request: NetworkRequest.packetList(const PacketFilter(channels: {'public'}), region: 'cmh')));
      await settle(t);
      expect(t.widget<ChoiceChip>(find.byKey(const Key('packets-window-30d'))).onSelected, isNotNull);
      expect(find.byKey(const Key('packets-long-hint')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a link opens the list with its filters as chips; removing a chip re-asks without it', (t) async {
      tall(t);
      final s = Server();
      final req = NetworkRequest.parse(Uri.parse('https://cmh.meshsonar.com/packets?type=ADVERT&channel=public&filter=hops%20%3E%3D%202&window=6h'))!;
      await t.pumpWidget(list(s, request: req));
      await settle(t);
      final q = s.seen.first.queryParameters;
      expect(q['type'], 'ADVERT');
      expect(q['channel'], 'public');
      expect(q['filter'], 'hops >= 2');
      expect(q['window'], '6h');
      expect(find.byKey(const ValueKey('packets-chip-type:ADVERT')), findsOneWidget);
      expect(find.byKey(const ValueKey('packets-chip-hops')), findsOneWidget);
      await t.tap(find.byTooltip('Remove Advert'));
      await settle(t);
      expect(s.seen.last.queryParameters.containsKey('type'), isFalse);
      expect(s.seen.last.queryParameters['channel'], 'public');
      // Share: the list state as a link.
      String? shared;
      packetShareOverride = (x) async => shared = x;
      await t.tap(find.byKey(const Key('packets-share')));
      await t.pump();
      final back = NetworkRequest.parse(Uri.parse(shared!))!;
      expect(back.listFilter, const PacketFilter(channels: {'public'}, hopsMin: 2));
      expect(back.window, '6h');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the filter sheet: chips, sliders, the text field with its mistake and suggestions, Apply', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(list(s));
      await settle(t);
      await t.tap(find.byKey(const Key('packets-filters')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('packet-filter-sheet')), findsOneWidget);
      expect(s.count('/v1/filters/fields'), 1);
      await t.tap(find.byKey(const Key('filter-type-TRACE')));
      await t.pump();
      await t.tap(find.text('Ours'));
      await t.pump();
      // Build 76: the less-used filters are behind "More filters".
      expect(find.byKey(const Key('filter-text'), skipOffstage: false), findsNothing);
      await t.scrollUntilVisible(find.byKey(const Key('filter-more')), 300, scrollable: find.descendant(of: find.byKey(const Key('packet-filter-sheet')), matching: find.byType(Scrollable)).first);
      await t.tap(find.byKey(const Key('filter-more')));
      await t.pump();
      await t.scrollUntilVisible(find.byKey(const Key('filter-text')), 300, scrollable: find.descendant(of: find.byKey(const Key('packet-filter-sheet')), matching: find.byType(Scrollable)).first);
      await t.enterText(find.byKey(const Key('filter-text')), 'tpye = ADVERT');
      await t.pump();
      expect(find.textContaining('Did you mean "type"?'), findsOneWidget);
      await t.tap(find.byKey(const Key('filter-apply')));
      await t.pump();
      expect(find.byKey(const Key('packet-filter-sheet')), findsOneWidget, reason: 'a mistake keeps the sheet open');
      await t.enterText(find.byKey(const Key('filter-text')), 'hop ~ a7 and pay');
      await t.pump();
      expect(find.byKey(const ValueKey('filter-suggest-payload.name')), findsOneWidget);
      await t.enterText(find.byKey(const Key('filter-text')), 'snr > -5');
      await t.pump();
      // Save it on the phone under a name; it shows at the top of the sheet.
      await t.scrollUntilVisible(find.byKey(const Key('filter-save-name')), 300, scrollable: find.descendant(of: find.byKey(const Key('packet-filter-sheet')), matching: find.byType(Scrollable)).first);
      await t.enterText(find.byKey(const Key('filter-save-name')), 'Traces');
      await t.tap(find.byKey(const Key('filter-save-name-add')));
      await t.pump();
      await t.pump();
      expect(find.byKey(const ValueKey('saved-filter-Traces'), skipOffstage: false), findsOneWidget);
      await t.tap(find.byKey(const Key('filter-apply')));
      await t.pumpAndSettle();
      final q = s.seen.last.queryParameters;
      expect(q['type'], 'TRACE');
      expect(q['source'], 'meshsonar,meshsonar-phone');
      expect(q['filter'], 'snr > -5');
      expect(find.byKey(const ValueKey('packets-chip-text')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('live: polls newer rows while on screen; pause stops it; hidden, background or Saver never polls', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(list(s, poll: const Duration(seconds: 1)));
      await settle(t);
      final first = s.count('/v1/packets');
      await t.pump(const Duration(milliseconds: 1100));
      await settle(t);
      expect(s.count('/v1/packets'), first + 1);
      expect(s.seen.last.queryParameters['cursor'], 'eyJ0IjoiMjAyNi0xMS0yMFQxNDowNTozMC4xMjBaIiwiZCI6Im5ld2VyIn0', reason: 'catch-up uses page.prev');
      await t.tap(find.byKey(const Key('packets-live-toggle')));
      await t.pump();
      final paused = s.count('/v1/packets');
      await t.pump(const Duration(seconds: 3));
      expect(s.count('/v1/packets'), paused);
      await t.tap(find.byKey(const Key('packets-live-toggle')));
      await settle(t);
      await PowerProfile.set(PowerSettings.saver);
      addTearDown(() => PowerProfile.set(PowerSettings.balanced));
      await t.pump();
      final saver = s.count('/v1/packets');
      await t.pump(const Duration(seconds: 3));
      expect(s.count('/v1/packets'), saver, reason: 'no polling in Saver');
      expect(find.textContaining('paused in Saver'), findsOneWidget);
      await PowerProfile.set(PowerSettings.balanced);
      await t.pumpWidget(const SizedBox());
      final hidden = Server();
      await t.pumpWidget(list(hidden, poll: const Duration(seconds: 1), visible: false));
      await settle(t);
      final n = hidden.count('/v1/packets');
      await t.pump(const Duration(seconds: 3));
      expect(hidden.count('/v1/packets'), n, reason: 'a hidden list never polls');
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await t.pump(const Duration(seconds: 2));
      expect(hidden.count('/v1/packets'), n);
      t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('not live: today\'s read, with the filters it cannot apply named', (t) async {
      tall(t);
      final s = Server()..v1 = false;
      await t.pumpWidget(list(s, request: NetworkRequest.packetList(const PacketFilter(channels: {'public'}, scope: '#cmh'), region: 'cmh')));
      await settle(t);
      expect(s.count('/api/cmh/region-packets'), 1);
      expect(find.byKey(const Key('packets-unapplied')), findsOneWidget);
      expect(find.textContaining('channel, scope'), findsOneWidget);
      expect(find.textContaining('Channel message'), findsOneWidget, reason: 'the row title is built from the fields the old read has');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a region with no packet feed says so plainly, not an empty list or an error', (t) async {
      t.view.physicalSize = const Size(1125, 2436); // 375 pt wide
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final s = Server()..noFeed = true;
      await t.pumpWidget(list(s));
      await settle(t);
      expect(find.byKey(const Key('no-packet-feed')), findsOneWidget);
      expect(find.text('No packet feed for cmh yet'), findsOneWidget);
      expect(find.textContaining('No packet feed covers Southern Arizona, US yet'), findsOneWidget, reason: 'the server\'s sentence, once');
      expect(find.byKey(const Key('packets-empty')), findsNothing);
      expect(find.byKey(const Key('packets-status')), findsNothing);
      expect(find.byKey(const Key('packets-error')), findsNothing);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('offline with nothing stored: a no-connection view with Retry', (t) async {
      tall(t);
      final s = Server()..offline = true;
      await t.pumpWidget(list(s));
      await settle(t);
      expect(find.byKey(const Key('region-offline-empty')), findsOneWidget);
      s.offline = false;
      await t.tap(find.byKey(const Key('region-offline-retry')));
      await settle(t);
      expect(find.textContaining('Kestrel-07'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('My radio: the switch shows with a radio; heard packets decode; the detail says the network heard it too', (t) async {
      tall(t);
      final s = Server();
      final log = RxLog(clock: () => now.subtract(const Duration(minutes: 1)));
      log.add(fromHex(data('packet-detail.grp-txt-outside-ambiguous')['raw'] as String), snrDb: 4.25, rssiDbm: -101);
      await t.pumpWidget(list(s, log: log));
      await settle(t);
      expect(find.byKey(const Key('packets-source-switch')), findsOneWidget);
      await t.tap(find.byKey(const Key('packets-source-mine')));
      await settle(t);
      expect(find.byKey(const Key('myradio-note')), findsOneWidget);
      expect(find.text('Channel message on Public'), findsOneWidget);
      await t.tap(find.text('Channel message on Public'));
      await settle(t);
      expect(find.byType(NetworkPacketScreen), findsOneWidget);
      expect(find.text('Packet (your radio)'), findsOneWidget);
      expect(find.byKey(const Key('packet-network-heard')), findsOneWidget);
      expect(find.textContaining('Also heard by the network: 2 observers'), findsOneWidget);
      // the bytes are one tap away, behind their header
      await t.ensureVisible(find.byKey(const Key('packet-fold-bytes')));
      await t.tap(find.byKey(const Key('packet-fold-bytes')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('byte-inspector')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      // No radio: no switch.
      await t.pumpWidget(list(Server()));
      await settle(t);
      expect(find.byKey(const Key('packets-source-switch')), findsNothing);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('detail', () {
    Future<void> open(WidgetTester t, Server s, String hash, {RxLog? log, double scale = 1, bool expand = true}) async {
      await t.pumpWidget(app(NetworkPacketScreen(baseUrl: base, regionSlug: 'cmh', hash: hash, api: s.api, radioLog: log, clock: () => now, expandSections: expand), scale: scale));
      await settle(t);
    }

    Future<void> scrollTo(WidgetTester t, Finder f) =>
        t.scrollUntilVisible(f, 300, scrollable: find.descendant(of: find.byKey(const Key('packet-detail-body')), matching: find.byType(Scrollable)).first);

    testWidgets('advert: header, decoded fields, unique hop, observers, inspector, sources', (t) async {
      tall(t);
      final s = Server();
      await open(t, s, '1add53ffce368256');
      expect(find.text('Advert: Library Room'), findsOneWidget);
      expect(find.text('room'), findsOneWidget);
      expect(find.text('Valid'), findsWidgets);
      await scrollTo(t, find.byKey(const ValueKey('packet-hop-p1-0')));
      expect(find.text('Unique'), findsOneWidget);
      expect(find.text('Hilltop RPT'), findsOneWidget);
      await scrollTo(t, find.byKey(const Key('byte-inspector')));
      expect(find.byKey(const Key('inspector-field-advert.signature')), findsOneWidget);
      await scrollTo(t, find.byKey(const Key('packets-web-twin')));
      expect(find.text('On the website: cmh.meshsonar.com/packets/1add53ffce368256'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('small screen: who heard it comes first (5, then Show all); Paths and Bytes are closed until tapped', (t) async {
      t.view.physicalSize = const Size(1206, 2622); // 402 x 874 pt
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      final s = Server()..extraObservers = 6; // 8 observations
      await open(t, s, 'c4b06ee8fc39b187', expand: false);
      // the first screen: what, when, how far, who heard it
      expect(find.byKey(const Key('packet-detail-title')), findsOneWidget);
      expect(find.text('Hops'), findsOneWidget);
      expect(find.text('Who heard it (8)'), findsOneWidget);
      expect(t.getTopLeft(find.text('Who heard it (8)')).dy, lessThan(874), reason: 'on the first screen, no scrolling');
      expect(find.byWidgetPredicate((w) => w is Container && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('packet-obs-'), skipOffstage: false), findsNWidgets(packetObserversShown));
      // a long path is a hop count in the row, not a line of codes
      expect(find.textContaining('after 9 hops', skipOffstage: false), findsWidgets);

      // closed: no hop rows and no byte inspector are built
      final body = find.descendant(of: find.byKey(const Key('packet-detail-body')), matching: find.byType(Scrollable)).first;
      await t.scrollUntilVisible(find.byKey(const Key('packet-fold-paths')), 200, scrollable: body);
      expect(find.byKey(const Key('packet-fold-paths-summary')), findsOneWidget);
      expect(find.text('Up to 4 hops · 3 of 7 named'), findsOneWidget);
      expect(find.byKey(const ValueKey('packet-hop-p1-0'), skipOffstage: false), findsNothing);
      expect(find.byKey(const Key('byte-inspector'), skipOffstage: false), findsNothing);
      expect(t.getSize(find.byKey(const Key('packet-fold-paths'))).height, greaterThanOrEqualTo(48));

      await t.tap(find.byKey(const Key('packet-fold-paths')));
      await t.pumpAndSettle();
      expect(find.byKey(const ValueKey('packet-hop-p1-0'), skipOffstage: false), findsOneWidget);

      await t.scrollUntilVisible(find.byKey(const Key('packet-fold-bytes')), 200, scrollable: body);
      await t.ensureVisible(find.byKey(const Key('packet-fold-bytes')));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('packet-fold-bytes')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('byte-inspector'), skipOffstage: false), findsOneWidget);

      await t.scrollUntilVisible(find.byKey(const Key('packet-obs-all')), -200, scrollable: body);
      expect(find.text('Show all 8 listed'), findsOneWidget);
      await t.tap(find.byKey(const Key('packet-obs-all')));
      await t.pumpAndSettle();
      expect(find.byWidgetPredicate((w) => w is Container && w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('packet-obs-'), skipOffstage: false), findsNWidgets(8));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('public message with ambiguous path: the text, says-it-is sender, candidates, likely score, unknown', (t) async {
      tall(t);
      final s = Server();
      await open(t, s, 'c4b06ee8fc39b187');
      expect(find.text('anyone hearing Hilltop this morning?'), findsOneWidget);
      expect(find.text('Says it is Kestrel-07'), findsOneWidget);
      await scrollTo(t, find.byKey(const ValueKey('packet-hop-p1-3')));
      expect(find.text('Ambiguous'), findsWidgets);
      expect(find.text('Riverside RPT, 41% likely, 6.2 km away'), findsWidgets);
      expect(find.text('Old Mill RPT (82% likely)'), findsWidgets);
      expect(find.text('No known node has this code'), findsWidgets);
      expect(find.byKey(const Key('packet-show-on-map')), findsOneWidget, reason: 'the likely hop has a position');
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('hashtag, private channel, encrypted DM, trace each render their decoded fields', (t) async {
      tall(t);
      final s = Server();
      await open(t, s, 'a03aaeaf864003ae');
      expect(find.text('drive loop 3 done, 41 pings, Old Mill answered 38'), findsOneWidget);
      expect(find.text('Hashtag channel key (from its name)'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await open(t, s, '1c26c203910896f0');
      expect(find.text('Encrypted: the key is not known'), findsWidgets);
      expect(find.byKey(const Key('packet-message')), findsNothing);
      expect(find.text('#cmh'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await open(t, s, '3d729e68c935af6f');
      expect(find.text('Encrypted end to end'), findsWidgets);
      expect(find.textContaining('could be N0CALL Mobile'), findsOneWidget);
      await scrollTo(t, find.byKey(const ValueKey('packet-path-p1')));
      expect(find.textContaining('Route still ahead'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await open(t, s, '50b835a910da5aac');
      expect(find.text('Trace hops'), findsOneWidget);
      expect(find.text('10 dB, 6.5 dB, -2.5 dB'), findsOneWidget);
      expect(find.byKey(const Key('packet-map-note')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the radio heard it too: shown with the local SNR', (t) async {
      tall(t);
      final s = Server();
      final log = RxLog(clock: () => now);
      log.add(fromHex(data('packet-detail.trace')['raw'] as String), snrDb: 6.5);
      await open(t, s, '50b835a910da5aac', log: log);
      expect(find.byKey(const Key('packet-radio-heard')), findsOneWidget);
      expect(find.textContaining('Your radio heard this too: 6.5 dB'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('not live: no bytes from the server, the radio\'s bytes fill the inspector, and the screen says so', (t) async {
      tall(t);
      final s = Server()..v1 = false;
      final log = RxLog(clock: () => now);
      log.add(fromHex(data('packet-detail.grp-txt-outside-ambiguous')['raw'] as String), snrDb: 2);
      await open(t, s, 'c4b06ee8fc39b187', log: log);
      expect(s.count('/api/cmh/region-packet'), 1);
      expect(find.textContaining('does not send packet bytes yet'), findsWidgets);
      await scrollTo(t, find.byKey(const Key('packet-bytes-from-radio')));
      expect(find.byKey(const Key('byte-inspector')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      resetV1NotLive();
      await open(t, Server()..v1 = false, 'c4b06ee8fc39b187');
      await scrollTo(t, find.byKey(const Key('packet-no-bytes')));
      expect(find.byKey(const Key('packet-no-bytes')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('not found and offline states; share and copy hex', (t) async {
      tall(t);
      await open(t, Server(), '0000000000000000');
      expect(find.byKey(const Key('packet-not-found')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await open(t, Server()..offline = true, '50b835a910da5aac');
      expect(find.byKey(const Key('region-offline-empty')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      String? shared;
      packetShareOverride = (x) async => shared = x;
      await open(t, Server(), '50b835a910da5aac');
      await t.tap(find.byKey(const Key('packet-share')));
      await t.pump();
      expect(shared, 'https://cmh.meshsonar.com/packets/50b835a910da5aac');
      expect(find.byKey(const Key('packet-copy-hex')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('large text does not clip or overflow', (t) async {
      tall(t);
      await open(t, Server(), 'c4b06ee8fc39b187', scale: 2.0);
      expect(t.takeException(), isNull);
      await scrollTo(t, find.byKey(const Key('byte-inspector')));
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(app(Scaffold(body: PacketListView(baseUrl: base, regionSlug: 'cmh', api: Server().api, clock: () => now)), scale: 2.0));
      await settle(t);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a 375 pt wide phone: the detail and the list lay out without overflow, the source switch is 44 pt', (t) async {
      t.view.physicalSize = const Size(1125, 7200); // 375 x 2400 pt
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      for (final h in ['1add53ffce368256', 'c4b06ee8fc39b187']) {
        await open(t, Server(), h);
        expect(t.takeException(), isNull, reason: h);
        await scrollTo(t, find.byKey(const Key('byte-inspector')));
        expect(t.takeException(), isNull, reason: h);
        await t.pumpWidget(const SizedBox());
      }
      await t.pumpWidget(list(Server(), log: RxLog(clock: () => now)));
      await settle(t);
      expect(t.takeException(), isNull);
      expect(t.getSize(find.byKey(const Key('packets-source-switch'))).height, greaterThanOrEqualTo(44));
      // Share sits in the action row, not on a row of its own
      expect(t.getCenter(find.byKey(const Key('packets-share'))).dy, closeTo(t.getCenter(find.byKey(const Key('packets-filters'))).dy, 1));
      expect(find.descendant(of: find.byKey(const Key('packets-toolbar')), matching: find.byKey(const Key('packets-share'))), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('byte inspector', () {
    testWidgets('tap a field lights its bytes; tap a byte lights its field; every byte is labelled', (t) async {
      tall(t);
      final sem = t.ensureSemantics();
      final d = data('packet-detail.grp-txt-outside-ambiguous');
      final ranges = [for (final b in d['bytes'] as List) ByteRange.tryParse(b)!];
      await t.pumpWidget(app(Scaffold(body: SingleChildScrollView(child: ByteInspector(raw: d['raw'] as String, ranges: ranges)))));
      await t.pump();
      bool selected(Finder f) => t.getSemantics(f).flagsCollection.isSelected.name == 'isTrue';
      expect(find.byKey(const Key('inspector-byte-72')), findsOneWidget, reason: 'all 73 bytes, 8 a row');
      expect(t.getSemantics(find.byKey(const Key('inspector-byte-7'))).label, 'Byte 8 of 73, hex 79, MAC (HMAC-SHA256, 2 bytes)');
      await t.tap(find.byKey(const Key('inspector-field-grp.mac')));
      await t.pump();
      expect(selected(find.byKey(const Key('inspector-byte-7'))), isTrue);
      expect(selected(find.byKey(const Key('inspector-byte-8'))), isTrue);
      expect(selected(find.byKey(const Key('inspector-byte-9'))), isFalse);
      await t.tap(find.byKey(const Key('inspector-byte-3')));
      await t.pump();
      expect(selected(find.byKey(const Key('inspector-field-path[1]'))), isTrue);
      expect(selected(find.byKey(const Key('inspector-field-grp.mac'))), isFalse);
      expect(selected(find.byKey(const Key('inspector-byte-7'))), isFalse);
      // Ciphertext is bytes with its status word.
      expect(find.text('Decrypted (text shown above)'), findsOneWidget);
      sem.dispose();
    });
  });

  group('decode a packet', () {
    testWidgets('pasted hex decodes on the phone with no request; an unknown type asks POST /v1/decode', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(app(DecodePacketScreen(baseUrl: base, regionSlug: 'cmh', api: s.api)));
      // Build 76: an empty field offers one step, Paste and decode, and says what the screen is for.
      expect(find.text('Paste and decode'), findsOneWidget);
      expect(find.byKey(const Key('decode-intro')), findsOneWidget);
      expect(find.byKey(const Key('decode-run')), findsNothing);
      await t.enterText(find.byKey(const Key('decode-hex')), data('packet-detail.grp-txt-outside-ambiguous')['raw'] as String);
      await t.pump();
      await t.tap(find.byKey(const Key('decode-run')));
      await settle(t);
      expect(s.seen, isEmpty, reason: 'decoded locally, no network');
      expect(find.text('anyone hearing Hilltop this morning?'), findsOneWidget);
      expect(find.text('Pasted, decoded on this phone'), findsOneWidget);
      await t.enterText(find.byKey(const Key('decode-hex')), '3d00090807'); // RAW_CUSTOM: no local field decoder
      await t.tap(find.byKey(const Key('decode-run')));
      await settle(t);
      expect(s.count('/v1/decode'), 1);
      expect(find.text('Pasted, decoded by the MeshSonar server'), findsOneWidget);
      expect(find.byKey(const Key('decode-open-known')), findsOneWidget);
      await t.enterText(find.byKey(const Key('decode-hex')), 'nothex');
      await t.tap(find.byKey(const Key('decode-run')));
      await settle(t);
      expect(find.textContaining('That is not hex'), findsOneWidget);
      // A private channel packet: the phone has no key; the person may ask the server's hashtag list.
      await t.enterText(find.byKey(const Key('decode-hex')), data('packet-detail.grp-txt-private-undecodable')['raw'] as String);
      await t.tap(find.byKey(const Key('decode-run')));
      await settle(t);
      expect(find.byKey(const Key('decode-ask-server')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });
}
