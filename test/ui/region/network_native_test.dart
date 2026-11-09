// The V3 native network screens: packet detail, observer detail (incl. the health slot), and the How it works / Method
// pages. HTTP is faked; no tiles are loaded.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/ui/info/method_screens.dart';
import 'package:meshsonar/ui/region/observer_detail_screen.dart';
import 'package:meshsonar/ui/region/observers_panel.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/ui/region/packet_detail_screen.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../core/network_native_fixtures.dart';

Widget _app(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: child));

/// Answers by `fn` (path tail).
http.Client _server({
  Map<String, dynamic>? observer,
  Map<String, dynamic>? packet,
  List<Uri>? seen,
}) =>
    MockClient((req) async {
      seen?.add(req.url);
      final fn = req.url.pathSegments.last;
      Map<String, dynamic>? body;
      switch (fn) {
        case 'region-observer':
          body = observer ?? observerBody();
        case 'region-packet':
          body = packet ?? packetBody();
      }
      return http.Response(jsonEncode(body ?? {}), body == null ? 404 : 200);
    });

void main() {
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
    testWidgets('observations, tree with an ambiguous hop not named, and no flood route button', (tester) async {
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
      expect(find.byKey(const Key('pktdetail-trace')), findsNothing, reason: 'flood routes were removed (M0)');
    });

  });

  group('info pages', () {
    testWidgets('How it works: four numbered steps, regions, replay button calls back', (tester) async {
      var replayed = 0;
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: HowItWorksScreen(onReplayTour: () => replayed++)));
      expect(find.text('From a phone in a car to a coloured hexagon on the map, in four steps.'), findsOneWidget);
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
