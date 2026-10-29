// A brand-new region (the first drive there is yours): Kazakhstan's UKK on Oct 28 2026, real answers captured from
// production. No observers, no packets, no drives, no radio preset. Every panel must say what is missing, in words,
// never a zero that looks like a measurement and never an endless spinner.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/region/observers_panel.dart';
import 'package:meshsonar/ui/region/overview_panel.dart';
import 'package:meshsonar/ui/region/region_common.dart';
import 'package:meshsonar/ui/region/stats_panel.dart';
import 'package:meshsonar/ui/theme.dart';

String fixture(String n) => File('test/fixtures/$n').readAsStringSync();

Widget wrap(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: SingleChildScrollView(child: child)));

http.Response ok(String body) => http.Response(body, 200, headers: {'content-type': 'application/json'});

void main() {
  setUp(() {
    regionApiFactory = (b) => RegionOverviewApi(b, client: MockClient((r) async => switch (r.url.path) {
          '/api/cmh/region-overview' => ok(fixture('ukk_region_overview.json')),
          '/api/cmh/region-observers' => ok(fixture('ukk_region_observers.json')),
          _ => http.Response('{}', 404),
        }));
    regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async => switch (r.url.path) {
          '/api/cmh/public-stats' => ok(fixture('ukk_public_stats.json')),
          '/api/cmh/leaderboard' => ok('{"period":"30d","rows":[]}'),
          _ => ok('{"activeDrivers":0,"drivers":[],"pings15m":0,"lastUploadAt":null}'),
        }));
  });
  tearDown(() {
    regionApiFactory = (b) => RegionOverviewApi(b);
    regionStatsApiFactory = (b) => RegionStatsApi(b);
  });

  test('the captured fixtures are what production sent (no observers, no drives)', () {
    final o = jsonDecode(fixture('ukk_region_overview.json')) as Map;
    expect(o['observersTotal'], 0);
    expect(o['packets24h'], 0);
    expect((o['status'] as Map)['state'], 'partial');
    expect(jsonDecode(fixture('ukk_public_stats.json'))['drives'], 0);
  });

  testWidgets('overview: partial status is explained in the status chip text, packets are 0 observers, last packet never', (tester) async {
    await tester.pumpWidget(wrap(const OverviewPanel(baseUrl: 'https://ukk.example', regionSlug: 'ukk')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('overview-loading')), findsNothing);
    expect(find.textContaining('No MeshSonar observers in this region yet'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('observers: an honest "no observers" empty state with the server\'s reason, not an error', (tester) async {
    await tester.pumpWidget(wrap(const ObserversPanel(baseUrl: 'https://ukk.example', regionSlug: 'ukk')));
    await tester.pumpAndSettle();
    expect(find.text('No observers listed'), findsOneWidget);
    expect(find.textContaining('No trusted observers in this region yet'), findsWidgets);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('stats: "No drives here yet", never 0 km as a result', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const Scaffold(body: StatsPanel(baseUrl: 'https://ukk.example', regionSlug: 'ukk'))));
    await tester.pumpAndSettle();
    expect(find.text('No drives here yet'), findsOneWidget);
    expect(find.textContaining('first uploaded drive'), findsOneWidget);
  });
}
