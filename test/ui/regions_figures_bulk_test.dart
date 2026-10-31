// All regions: ONE regions-figures read fills the list (no per-region requests); per-region reads only when the server has
// no such read; a 429 waits and asks the same single question again. Plus the API class and the machine-derived note.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/region/region_hub_screen.dart';
import 'package:meshsonar/ui/region/regions_screen.dart';
import 'package:meshsonar/ui/region/stats_panel.dart';
import 'package:meshsonar/ui/theme.dart';

import 'fakes.dart';

const _stats = {'km': 533.1, 'pings': 1715, 'drives': 45, 'drivers': 6, 'heardPct': 52.5, 'cellsHeardPct': 49.3, 'repeatersHeard': 67, 'lastDriveAt': '2026-10-23T10:00:00.000Z'};

http.Response j(Object o, [int code = 200]) => http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json'});
RegionIndexEntry reg(String code, String name) => RegionIndexEntry(code: code, slug: code.toLowerCase(), name: name, url: 'https://${code.toLowerCase()}.example');

Widget screen({required Future<RegionsFigures> Function() loadFigures, Duration pause = const Duration(milliseconds: 50)}) => MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: RegionsScreen(
        regions: [reg('AAA', 'Alpha'), reg('BBB', 'Bravo'), reg('CCC', 'Charlie'), reg('DDD', 'Delta')],
        viewingCode: 'AAA',
        onPick: (_) {},
        loadGroups: () async => const HubRegions(),
        loadFigures: loadFigures,
        pause: pause,
      ),
    );

void main() {
  tearDown(() => regionStatsApiFactory = (b) => RegionStatsApi(b));

  group('RegionsFigures / RegionStatsApi.regionsFigures', () {
    test('ok rows carry the public-stats fields, empty is drives 0, unavailable (and an unknown state) is null', () {
      final f = RegionsFigures.tryParse({
        'asOf': '2026-10-28T20:00:00.000Z',
        'regions': [
          {'code': 'AAA', 'slug': 'aaa', 'state': 'ok', ..._stats},
          {'code': 'BBB', 'slug': 'bbb', 'state': 'empty', 'drives': 0},
          {'code': 'CCC', 'slug': 'ccc', 'state': 'unavailable'},
          {'code': 'DDD', 'slug': 'ddd', 'state': 'from-the-future'},
          {'slug': 'no-code', 'state': 'ok'},
        ],
      })!;
      expect(f.byCode.keys, ['AAA', 'BBB', 'CCC', 'DDD']);
      expect(f.byCode['AAA']!.km, 533.1);
      expect(f.byCode['AAA']!.drives, 45);
      expect(f.byCode['AAA']!.lastDriveAt, DateTime.utc(2026, 10, 23, 10));
      expect(f.byCode['BBB']!.isEmpty, isTrue);
      expect(f.byCode['CCC'], isNull);
      expect(f.byCode['DDD'], isNull);
      expect(f.asOf, DateTime.utc(2026, 10, 28, 20));
      expect(RegionsFigures.tryParse({'nope': 1}), isNull);
    });

    test('one GET to /api/cmh/regions-figures; a 404 carries its status, junk is unreadable', () async {
      final seen = <String>[];
      var mode = 'ok';
      final api = RegionStatsApi('https://hub.example', client: MockClient((r) async {
        seen.add(r.url.toString());
        return switch (mode) {
          'ok' => j({'regions': [{'code': 'AAA', 'state': 'empty', 'drives': 0}], 'asOf': '2026-10-28T20:00:00Z'}),
          '404' => j({'error': 'not available'}, 404),
          _ => http.Response('<html>', 200),
        };
      }));
      expect((await api.regionsFigures()).byCode['AAA']!.isEmpty, isTrue);
      expect(seen, ['https://hub.example/api/cmh/regions-figures']);
      mode = '404';
      await expectLater(api.regionsFigures(), throwsA(isA<RegionStatsException>().having((e) => e.status, 'status', 404)));
      mode = 'junk';
      await expectLater(api.regionsFigures(), throwsA(isA<RegionStatsException>()));
    });
  });

  testWidgets('one read fills every row: no per-region request, honest states, "as of" line, compare card counts all', (t) async {
    final hosts = <String>[];
    regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async {
          hosts.add(r.url.host);
          return j({'e': 1}, 500);
        }));
    var reads = 0;
    await t.pumpWidget(screen(loadFigures: () async {
      reads++;
      return RegionsFigures({
        'AAA': RegionPublicStats.fromJson(_stats),
        'BBB': const RegionPublicStats(drives: 0),
        'CCC': null,
        // DDD is not in the answer
      }, asOf: DateTime.utc(2026, 10, 28, 20));
    }));
    await t.pumpAndSettle();
    expect(reads, 1);
    expect(hosts, isEmpty, reason: 'not one per-region request');
    expect(find.textContaining('533 km · 45 drives'), findsOneWidget);
    expect(find.textContaining('No drives yet'), findsOneWidget);
    expect(find.textContaining('Numbers unavailable'), findsNWidgets(2)); // CCC (server: unavailable) and DDD (not in the answer)
    expect(find.byKey(const Key('regions-figures-asof')), findsOneWidget);
    expect(find.byKey(const Key('regions-loading')), findsNothing);
    expect(find.text('1 of 4 regions have drives.'), findsOneWidget);
    await t.tap(find.byKey(const Key('regions-refresh')));
    await t.pumpAndSettle();
    expect(reads, 2, reason: 'refresh asks the one question again');
    expect(hosts, isEmpty);
  });

  testWidgets('a server without regions-figures (404) or any other failure: the per-region reads of before', (t) async {
    final hosts = <String>[];
    regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async {
          hosts.add(r.url.host);
          return r.url.host == 'aaa.example' ? j(_stats) : j({'e': 1}, 500);
        }));
    await t.pumpWidget(screen(loadFigures: () async => throw const RegionStatsException('The server answered 404.', status: 404)));
    await t.pumpAndSettle();
    expect(hosts, contains('aaa.example'));
    expect(find.textContaining('533 km · 45 drives'), findsOneWidget);
    expect(find.textContaining('Numbers unavailable'), findsNWidgets(3));
    expect(find.textContaining('read so far'), findsOneWidget);
  });

  testWidgets('a 429 on the one read waits and asks the same single question again; never per-region requests', (t) async {
    final hosts = <String>[];
    regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async {
          hosts.add(r.url.host);
          return j({'e': 1}, 500);
        }));
    var reads = 0;
    await t.pumpWidget(screen(loadFigures: () async {
      reads++;
      if (reads == 1) throw const RegionStatsException('The server answered 429.', status: 429);
      return RegionsFigures({'AAA': RegionPublicStats.fromJson(_stats)});
    }));
    await t.pump();
    await t.pump();
    expect(find.byKey(const Key('regions-paused')), findsOneWidget);
    expect(hosts, isEmpty);
    await t.pump(const Duration(milliseconds: 80));
    await t.pumpAndSettle();
    expect(reads, 2);
    expect(find.byKey(const Key('regions-paused')), findsNothing);
    expect(find.textContaining('533 km · 45 drives'), findsOneWidget);
    expect(hosts, isEmpty);
  });

  group('machine-derived outline note on the region detail', () {
    const derived = RegionIndexEntry(
        code: 'BTS', slug: 'bts', name: 'Bratislava, SK', url: 'https://bts.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65], country: 'Slovakia', countryCode: 'SK', machineDerived: true);
    const reviewed = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);

    testWidgets('shown for a machine-derived region, quiet and absent otherwise', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.client.regionsIndexResult = const [derived];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openRegionTab(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('region-machine-derived-note')), findsOneWidget);
      expect(find.textContaining('Machine-derived outline'), findsOneWidget);
      expect(find.textContaining('Bratislava, SK'), findsWidgets);
    });

    testWidgets('not shown for a reviewed region', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.client.regionsIndexResult = const [reviewed];
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openRegionTab(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('region-machine-derived-note')), findsNothing);
    });

    testWidgets('the note widget on its own', (tester) async {
      await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const Scaffold(body: MachineDerivedNote(regionName: 'Bratislava, SK'))));
      expect(find.textContaining('approximate near the edge'), findsOneWidget);
    });
  });
}
