// The V3 native network screens: flood routes (one packet / all floods), packet detail, observer detail (incl. the health slot),
// findings, and the How it works / Method pages. HTTP is faked; no tiles are loaded.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/ui/info/method_screens.dart';
import 'package:meshsonar/ui/region/findings_panel.dart';
import 'package:meshsonar/ui/region/observer_detail_screen.dart';
import 'package:meshsonar/ui/region/observers_panel.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/ui/region/packet_detail_screen.dart';
import 'package:meshsonar/ui/region/routes_panel.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../core/network_native_fixtures.dart';

Widget _app(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: child));

/// Answers by `fn` (path tail) and, for tool-routes, by `action`.
http.Client _server({
  Map<String, dynamic>? recent,
  Map<String, dynamic>? trace,
  Map<String, dynamic>? aggregate,
  Map<String, dynamic>? observer,
  Map<String, dynamic>? packet,
  Map<String, dynamic>? findings,
  int traceCode = 200,
  List<Uri>? seen,
}) =>
    MockClient((req) async {
      seen?.add(req.url);
      final fn = req.url.pathSegments.last;
      Map<String, dynamic>? body;
      var code = 200;
      switch (fn) {
        case 'tool-routes':
          switch (req.url.queryParameters['action']) {
            case 'recent':
              body = recent ?? recentBody();
            case 'trace':
              body = trace ?? traceBody();
              code = traceCode;
            case 'aggregate':
              body = aggregate ?? aggregateBody(hours: int.parse(req.url.queryParameters['hours']!));
          }
        case 'region-observer':
          body = observer ?? observerBody();
        case 'region-packet':
          body = packet ?? packetBody();
        case 'region-findings':
          body = findings ?? findingsBody();
      }
      return http.Response(jsonEncode(body ?? {}), body == null ? 404 : code);
    });

void main() {
  group('flood routes', () {
    testWidgets('opens on the best recent flood and draws its trace: figures, map, steps, tree, bytes', (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final seen = <Uri>[];
      await tester.pumpWidget(_app(RoutesPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _server(seen: seen), tiles: false)));
      await tester.pumpAndSettle();
      expect(seen.any((u) => u.queryParameters['action'] == 'trace' && u.queryParameters['hash'] == kHashA), isTrue, reason: 'auto-picked the well-travelled flood');
      expect(find.byKey(const Key('trace-title')), findsOneWidget);
      expect(find.text('Advert from Alpha'), findsOneWidget);
      expect(find.byKey(const Key('trace-map')), findsOneWidget);
      expect(find.text('Step 3 of 3'), findsOneWidget);
      expect(find.text('1 of 2'), findsOneWidget, reason: 'relays identified');
      expect(find.byKey(const Key('trace-tree')), findsOneWidget);
      expect(find.textContaining('Hop 2, unresolved prefix'), findsOneWidget);
      expect(find.textContaining('Observer, after 2 hops'), findsOneWidget);
      expect(find.byKey(const Key('trace-bytes')), findsOneWidget);
      expect(find.text('What the 10 bytes are'), findsOneWidget);
      expect(find.textContaining('1 hop with no known position is not drawn'), findsOneWidget);
      // step slider moves the step
      final slider = tester.widget<Slider>(find.byKey(const Key('trace-step')));
      slider.onChanged!(1);
      await tester.pump();
      expect(find.text('Step 1 of 3'), findsOneWidget);
    });

    testWidgets('a pasted hash that is not 16 hex is refused in words, a good one traces; a 404 says so', (tester) async {
      final seen = <Uri>[];
      await tester.pumpWidget(_app(RoutesPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _server(recent: recentBody(unavailable: true), seen: seen, traceCode: 404), tiles: false)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('routes-nofeed')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('routes-hash')), '1234');
      await tester.tap(find.byKey(const Key('routes-trace')));
      await tester.pump();
      expect(find.textContaining('16 hex characters'), findsWidgets);
      expect(seen.where((u) => u.queryParameters['action'] == 'trace'), isEmpty);
      await tester.enterText(find.byKey(const Key('routes-hash')), '0x$kHashA');
      await tester.tap(find.byKey(const Key('routes-trace')));
      await tester.pumpAndSettle();
      expect(seen.where((u) => u.queryParameters['action'] == 'trace').single.queryParameters['hash'], kHashA);
      expect(find.byKey(const Key('routes-trace-notfound')), findsOneWidget, reason: '404 means no such packet or no feed');
    });

    testWidgets('all floods: figures, warning below 70% resolved, carry share, corridors, hop chart, ends, collisions; 7 days refetches', (tester) async {
      tester.view.physicalSize = const Size(900, 6000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final seen = <Uri>[];
      await tester.pumpWidget(_app(RoutesPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _server(seen: seen), tiles: false)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All floods'));
      await tester.pumpAndSettle();
      expect(seen.last.queryParameters, {'action': 'aggregate', 'hours': '24'});
      expect(find.byKey(const Key('routes-agg-figures')), findsOneWidget);
      expect(find.text('200'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget, reason: '150 of 200 relayed');
      expect(find.byKey(const Key('routes-agg-warn')), findsOneWidget);
      expect(find.textContaining('50% of hops cannot be pinned'), findsOneWidget);
      expect(find.text('Bravo'), findsWidgets);
      expect(find.text('40.0%'), findsOneWidget);
      expect(find.text('Bravo  →  c3c3c3c3'), findsOneWidget);
      expect(find.byKey(const Key('routes-links-map')), findsOneWidget);
      expect(find.text('Unidentified dd'), findsOneWidget);
      expect(find.textContaining('b2 shared by 2 repeaters; seen as a 1-byte hop 12 times'), findsOneWidget);
      await tester.tap(find.text('7 days'));
      await tester.pumpAndSettle();
      expect(seen.last.queryParameters, {'action': 'aggregate', 'hours': '168'});
    });

    testWidgets('all floods with no feed (404): says so, no Retry', (tester) async {
      final c = MockClient((req) async => req.url.queryParameters['action'] == 'recent' ? http.Response(jsonEncode(recentBody(unavailable: true)), 200) : http.Response('{}', 404));
      await tester.pumpWidget(_app(RoutesPanel(baseUrl: 'https://day.meshsonar.com', regionSlug: 'day', client: c, tiles: false)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All floods'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('routes-agg-nofeed')), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('observer detail', () {
    Widget screen({Map<String, dynamic>? body}) => MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          home: ObserverDetailScreen(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', observerKey: 'ab' * 32, title: 'Hilltop Obs', client: _server(observer: body)),
        );

    testWidgets('header chips, figures, hardware, charts with tables, packet types, nodes it hears', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(screen());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('obsdetail-online')), findsOneWidget);
      expect(find.byKey(const Key('obsdetail-health')), findsNothing, reason: 'no health state from the server yet');
      expect(find.text('1,234'), findsOneWidget);
      expect(find.text('-104.5 dBm'), findsOneWidget);
      expect(find.text('4.01 V'), findsOneWidget);
      expect(find.text('Heltec V3'), findsOneWidget);
      expect(find.textContaining('Public: the operator chose to share it'), findsNothing);
      expect(find.textContaining('(public: the operator chose to share it)'), findsOneWidget);
      expect(find.text('Noise floor (dBm)'), findsOneWidget);
      expect(find.text('Packet types'), findsOneWidget);
      expect(find.text('Advert'), findsOneWidget);
      expect(find.text('70%'), findsNothing); // bar shows "700 · 70%" in one text
      expect(find.textContaining('700 · 70%'), findsOneWidget);
      expect(find.byKey(Key('obsdetail-node-${'b2' * 32}')), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
    });

    testWidgets('HEALTH SLOT: when the server sends row.health the chip and reason appear', (tester) async {
      await tester.pumpWidget(screen(body: observerBody(withHealth: true)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('obsdetail-health')), findsOneWidget);
      expect(find.text('Deaf'), findsOneWidget);
      expect(find.textContaining('Battery low: 3.40 V and falling'), findsOneWidget);
      expect(find.byKey(const Key('obsdetail-health-reason')), findsOneWidget);
    });

    testWidgets('an unknown observer (404) is "not published", not a crash', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: ObserverDetailScreen(
            baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', observerKey: 'ff', title: 'x', client: MockClient((_) async => http.Response('{}', 404))),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('obsdetail-notfound')), findsOneWidget);
    });

    testWidgets('tapping an observer in the list opens its detail', (tester) async {
      final data = RegionObservers.fromJson({
        'status': {'state': 'ready'},
        'rows': [observerBody()['row']],
      });
      await tester.pumpWidget(_app(SingleChildScrollView(child: ObserversContent(data: data, baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh'))));
      await tester.tap(find.byKey(Key('observer-${'ab' * 32}')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(ObserverDetailScreen), findsOneWidget);
    });
  });

  group('packet detail', () {
    testWidgets('observations, tree with an ambiguous hop not named, and a button to the flood route', (tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: PacketDetailScreen(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', hash: kHashA, client: _server()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Advert from Alpha'), findsOneWidget);
      expect(find.text('Who heard it (2)'), findsOneWidget);
      expect(find.textContaining('(via Outside Feed)'), findsOneWidget);
      expect(find.text('Several repeaters share c3'), findsOneWidget);
      expect(find.byKey(const Key('pktdetail-trace')), findsOneWidget);
    });

    testWidgets('a direct packet has no flood button', (tester) async {
      final body = packetBody();
      (body['row'] as Map)['route'] = 2;
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: PacketDetailScreen(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', hash: kHashA, client: _server(packet: body)),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pktdetail-trace')), findsNothing);
    });
  });

  group('findings', () {
    testWidgets('lead, severity filter with counts, evidence with site names, recommendations with impact', (tester) async {
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(FindingsPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _server())));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 findings from the 2026-10-01 baseline'), findsOneWidget);
      expect(find.text('All 2'), findsOneWidget);
      expect(find.text('High 1'), findsOneWidget);
      await tester.tap(find.byKey(const Key('findings-sev-low')));
      await tester.pump();
      expect(find.text('I1  East side has no repeater'), findsNothing);
      expect(find.text('I2  One quiet repeater'), findsOneWidget);
      await tester.tap(find.byKey(const Key('findings-sev-all')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('finding-I1')));
      await tester.pumpAndSettle();
      expect(find.textContaining('12,345  (D2 (Dublin Library))'), findsOneWidget);
      expect(find.textContaining('33%  (D2 to Oscar)'), findsOneWidget);
      expect(find.text('Add a repeater at D2.'), findsOneWidget);
      expect(find.text('+12.3k people newly within 3 km'), findsOneWidget);
      expect(find.textContaining('Sites: D2 (Dublin Library)'), findsOneWidget);
    });

    testWidgets('pending region shows the server reason and the empty text', (tester) async {
      await tester.pumpWidget(_app(FindingsPanel(baseUrl: 'https://day.meshsonar.com', regionSlug: 'day', client: _server(findings: findingsBody(empty: true)))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('findings-empty')), findsOneWidget);
      // The server sends the same sentence as its reason: it is said once, not twice.
      expect(find.text('No findings have been written for this region yet.'), findsOneWidget);
    });

    test('findingRefText writes site ids and links out', () {
      expect(findingRefText('D2, P1', {'D2': 'Library'}), 'D2 (Library), P1');
      expect(findingRefText("link:D2|Oscar's", const {}), "D2 to Oscar's");
    });
  });

  group('info pages', () {
    testWidgets('How it works: four numbered steps, regions, replay button calls back', (tester) async {
      var replayed = 0;
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: HowItWorksScreen(onReplayTour: () => replayed++)));
      expect(find.text('From a phone in a car to a square on a map, in four steps.'), findsOneWidget);
      expect(find.textContaining('Your phone pings.', findRichText: true), findsOneWidget);
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Regions'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('howitworks-tour')), 200);
      await tester.tap(find.byKey(const Key('howitworks-tour')));
      expect(replayed, 1);
    });

    testWidgets('Method: the limits and the privacy rules are there', (tester) async {
      tester.view.physicalSize = const Size(900, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: const MethodScreen()));
      expect(find.text('What it cannot say'), findsOneWidget);
      expect(find.text('Privacy rules applied before anything is public'), findsOneWidget);
      expect(find.textContaining('MS: and ten random characters'), findsOneWidget);
    });
  });
}
