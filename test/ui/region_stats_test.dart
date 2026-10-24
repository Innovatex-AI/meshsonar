import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/region/regions_screen.dart';
import 'package:meshsonar/ui/region/stats_panel.dart';
import 'package:meshsonar/ui/theme.dart';

const _stats = {'km': 533.1, 'pings': 1715, 'drives': 45, 'drivers': 6, 'heardPct': 52.5, 'cellsHeardPct': 49.3, 'repeatersHeard': 67, 'lastDriveAt': '2026-10-23T10:00:00.000Z'};
const _empty = {'km': 0, 'pings': 0, 'drives': 0, 'drivers': 0, 'heardPct': 0, 'cellsHeardPct': null, 'repeatersHeard': 0, 'lastDriveAt': null};

void useClient(Future<http.Response> Function(http.Request) h) {
  regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient(h));
}

http.Response j(Object o, [int code = 200]) => http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json'});

Widget wrap(Widget c) => MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: c));

RegionIndexEntry reg(String code, String name) => RegionIndexEntry(code: code, slug: code.toLowerCase(), name: name, url: 'https://${code.toLowerCase()}.example');

void main() {
  testWidgets('stats panel: figures, live chip, honest empty leaderboard', (t) async {
    useClient((r) async => switch (r.url.path) {
          '/api/cmh/public-stats' => j(_stats),
          '/api/cmh/leaderboard' => j({'period': '30d', 'rows': []}),
          _ => j({'activeDrivers': 2, 'drivers': [{'callsign': 'KE4BFI'}, {'callsign': null}], 'pings15m': 5, 'lastUploadAt': null}),
        });
    await t.pumpWidget(wrap(const StatsPanel(baseUrl: 'https://x.example', regionSlug: 'x')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('stat-Km driven')), findsOneWidget);
    expect(find.text('533'), findsOneWidget);
    expect(find.text('52.5%'), findsOneWidget);
    expect(find.textContaining('2 drivers driving now (KE4BFI)'), findsOneWidget);
    expect(find.text('No one on the leaderboard yet'), findsOneWidget);
  });

  testWidgets('stats panel: a failing read shows an error, the others still render; empty region says so', (t) async {
    useClient((r) async => switch (r.url.path) {
          '/api/cmh/public-stats' => j(_empty),
          '/api/cmh/leaderboard' => j({'error': 'x'}, 500),
          _ => j({'activeDrivers': 0, 'drivers': [], 'pings15m': 0, 'lastUploadAt': null}),
        });
    await t.pumpWidget(wrap(const StatsPanel(baseUrl: 'https://x.example', regionSlug: 'x')));
    await t.pumpAndSettle();
    expect(find.text('No drives here yet'), findsOneWidget);
    expect(find.text('The server answered 500.'), findsOneWidget);
    expect(find.text('No one driving right now'), findsOneWidget);
  });

  test('sortFigures: numbers desc, regions without numbers last', () {
    final a = RegionFigures(reg('AAA', 'Alpha'), RegionPublicStats.fromJson({..._stats, 'km': 10}));
    final b = RegionFigures(reg('BBB', 'Bravo'), RegionPublicStats.fromJson({..._stats, 'km': 99}));
    final c = RegionFigures(reg('CCC', 'Charlie'), RegionPublicStats.fromJson(_empty));
    final d = RegionFigures(reg('DDD', 'Delta'), null);
    expect(sortFigures([d, c, a, b], RegionSort.km).map((f) => f.region.code), ['BBB', 'AAA', 'CCC', 'DDD']);
    expect(sortFigures([d, c, a, b], RegionSort.km, ascending: true).map((f) => f.region.code), ['AAA', 'BBB', 'CCC', 'DDD']);
    expect(sortFigures([b, a], RegionSort.name, ascending: true).first.region.code, 'AAA');
  });

  testWidgets('regions screen: group header, figures, honest empty/unavailable states', (t) async {
    final picked = <RegionIndexEntry>[];
    useClient((r) async {
      if (r.url.host == 'aaa.example') return j(_stats);
      if (r.url.host == 'bbb.example') return j(_empty);
      return j({'e': 1}, 500);
    });
    await t.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: RegionsScreen(
        regions: [reg('AAA', 'Alpha'), reg('BBB', 'Bravo'), reg('CCC', 'Charlie')],
        viewingCode: 'AAA',
        onPick: picked.add,
        loadGroups: () async => const HubRegions(groupOf: {'AAA': 'G', 'BBB': 'G'}, groups: [RegionGroupInfo(code: 'G', name: 'Group One', members: ['AAA', 'BBB'])]),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('regions-group-G')), findsOneWidget);
    expect(find.textContaining('533 km · 45 drives'), findsOneWidget);
    expect(find.textContaining('No drives yet'), findsOneWidget);
    expect(find.textContaining('Numbers unavailable'), findsOneWidget);
    expect(find.byKey(const Key('regions-compare')), findsOneWidget);
    expect(find.text('Viewing'), findsOneWidget);
    await t.tap(find.byKey(const Key('regions-tile-BBB')));
    expect(picked.single.code, 'BBB');
  });
}
