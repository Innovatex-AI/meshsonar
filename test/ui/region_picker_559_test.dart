// The region picker and the All regions screen at 559 regions: built lazily, searchable (accents), nearest first,
// country headings, figures read only for rows on screen and politely (429 pauses).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/region/region_switcher.dart';
import 'package:meshsonar/ui/region/regions_screen.dart';
import 'package:meshsonar/ui/region/stats_panel.dart';
import 'package:meshsonar/ui/theme.dart';

import '../support/regions_559.dart';
import 'fakes.dart';

const _stats = {'km': 533.1, 'pings': 1715, 'drives': 45, 'drivers': 6, 'heardPct': 52.5, 'cellsHeardPct': 49.3, 'repeatersHeard': 67, 'lastDriveAt': '2026-10-23T10:00:00.000Z'};

http.Response j(Object o, [int code = 200]) => http.Response(jsonEncode(o), code, headers: {'content-type': 'application/json'});

Future<Harness> pumpSheet(WidgetTester tester, {List<RegionIndexEntry>? regions}) async {
  useTallScreen(tester);
  final h = Harness();
  h.client.regionsIndexResult = regions ?? syntheticIndex559();
  await h.state.init();
  await tester.pumpAndSettle();
  await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: RegionSwitcherSheet(state: h.state))));
  await tester.pumpAndSettle();
  return h;
}

void main() {
  group('the picker sheet', () {
    testWidgets('559 regions: only the rows near the top are built, "Near you" and the country headings are there', (tester) async {
      final h = await pumpSheet(tester);
      expect(h.state.regionIndex.length, 559);
      final built = find.byType(ListTile).evaluate().length;
      expect(built, lessThan(40), reason: 'a lazily built list builds a screenful, not 559 radio tiles');
      expect(find.byKey(const Key('region-all')), findsOneWidget);
      expect(find.byKey(const Key('region-follow')), findsOneWidget);
      expect(find.byKey(const Key('regions-near')), findsOneWidget);
      expect(find.byKey(const Key('region-search')), findsOneWidget);
      expect(find.text('Search 559 regions'), findsOneWidget);
    });

    testWidgets('the nearest regions to the phone are listed first (the fix is known, the order is by distance)', (tester) async {
      final h = await pumpSheet(tester);
      final near = h.state.switcherRegions.take(regionNearCount).map((r) => r.code).toList();
      for (final c in near) {
        expect(find.byKey(Key('region-near-$c')), findsOneWidget, reason: c);
      }
    });

    testWidgets('searching "dusseldorf" finds the accented names; the list shrinks to the matches; clear brings it back', (tester) async {
      final h = await pumpSheet(tester);
      final want = h.state.regionIndex.where((r) => r.name.startsWith('Düsseldorf')).length;
      expect(want, greaterThan(10));
      await tester.enterText(find.byKey(const Key('region-search')), 'dusseldorf');
      await tester.pumpAndSettle();
      final tiles = find.byWidgetPredicate((w) => w is ListTile && w.key is Key && (w.key as ValueKey).value.toString().startsWith('region-option-'));
      expect(tiles, findsWidgets);
      for (final t in tiles.evaluate()) {
        final title = ((t.widget as ListTile).title as Text).data!;
        expect(title, startsWith('Düsseldorf'));
      }
      expect(find.byKey(const Key('region-all')), findsNothing, reason: 'search results are results only');
      await tester.tap(find.byKey(const Key('region-search-clear')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('region-all')), findsOneWidget);
    });

    testWidgets('searching by country name, by code, and a miss', (tester) async {
      await pumpSheet(tester);
      await tester.enterText(find.byKey(const Key('region-search')), 'moldova');
      await tester.pumpAndSettle();
      expect(find.textContaining(', MD'), findsWidgets);
      await tester.enterText(find.byKey(const Key('region-search')), 'chisinau');
      await tester.pumpAndSettle();
      expect(find.textContaining('Chișinău'), findsWidgets);
      await tester.enterText(find.byKey(const Key('region-search')), 'zzzzqq');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('region-switcher-empty')), findsOneWidget);
      expect(find.textContaining('No region matches "zzzzqq"'), findsOneWidget);
    });

    testWidgets('picking a search result views that region (a manual pick) and closes; "Follow my location" goes back to GPS', (tester) async {
      final h = await pumpSheet(tester);
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: Scaffold(body: Builder(builder: (c) => TextButton(key: const Key('open'), onPressed: () => showModalBottomSheet<void>(context: c, isScrollControlled: true, builder: (_) => RegionSwitcherSheet(state: h.state)), child: const Text('open')))),
      ));
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('region-search')), 'sao paulo 7');
      await tester.pumpAndSettle();
      final first = find.byWidgetPredicate((w) => w is ListTile && w.key.toString().contains('region-option-')).first;
      final title = ((tester.widget<ListTile>(first)).title as Text).data!;
      await tester.tap(first);
      await tester.pumpAndSettle();
      expect(find.byType(RegionSwitcherSheet), findsNothing);
      expect(h.state.viewingIsManual, isTrue);
      expect(h.state.viewingRegion!.name, title);

      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(tester.widget<ListTile>(find.byKey(const Key('region-follow'))).selected, isFalse);
      await tester.tap(find.byKey(const Key('region-follow')));
      await tester.pumpAndSettle();
      expect(h.state.viewingIsManual, isFalse);
    });

    testWidgets('building the sheet with 559 regions takes a frame or two, not seconds', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      h.client.regionsIndexResult = syntheticIndex559();
      await h.state.init();
      await tester.pumpAndSettle();
      final sw = Stopwatch()..start();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: RegionSwitcherSheet(state: h.state))));
      await tester.pump();
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000), reason: '${sw.elapsedMilliseconds} ms (debug build, includes search index and grouping)');
    });

    testWidgets('a short list needs no country headings; an empty one says to connect once', (tester) async {
      await pumpSheet(tester, regions: [syntheticRegion(1), syntheticRegion(2), syntheticRegion(3)]);
      expect(find.byKey(const Key('region-search')), findsNothing, reason: 'three regions need no search box');
      expect(find.byKey(const Key('regions-near')), findsNothing);
      await pumpSheet(tester, regions: const []);
      expect(find.textContaining('No regions loaded yet'), findsOneWidget);
    });
  });

  group('All regions screen', () {
    late List<String> hits;
    late bool limit;
    void useClient() {
      hits = [];
      regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async {
            hits.add(r.url.host);
            if (limit) return j({'error': 'slow down'}, 429);
            return j(_stats);
          }));
    }

    setUp(() => limit = false);
    tearDown(() => regionStatsApiFactory = (b) => RegionStatsApi(b));

    Future<void> pump(WidgetTester tester, {Duration gap = const Duration(milliseconds: 450), Duration pause = const Duration(seconds: 45)}) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      useClient();
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: RegionsScreen(regions: syntheticIndex559(), viewingCode: 'AAA', loadGroups: () async => const HubRegions(), gap: gap, pause: pause),
      ));
      await tester.pump();
    }

    testWidgets('only the rows on screen are read, a few at a time: nowhere near 559 requests', (tester) async {
      await pump(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(hits.length, greaterThan(0));
      expect(hits.length, lessThan(40), reason: 'one screenful, not one request per region (that was 559 at once)');
      expect(hits.toSet().length, hits.length, reason: 'each region is read once');
      final before = hits.length;
      await tester.drag(find.byKey(const Key('regions-screen')), const Offset(0, -3000));
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(hits.length, greaterThan(before), reason: 'scrolling reads the rows that come on screen');
      expect(hits.length, lessThan(150));
    });

    testWidgets('lanes: at most three reads are in flight at once', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      var inFlight = 0, peak = 0;
      regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) async {
            inFlight++;
            if (inFlight > peak) peak = inFlight;
            await Future<void>.delayed(const Duration(milliseconds: 200));
            inFlight--;
            return j(_stats);
          }));
      await tester.pumpWidget(MaterialApp(home: RegionsScreen(regions: syntheticIndex559(), viewingCode: 'AAA', loadGroups: () async => const HubRegions())));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 700)));
      await tester.pump(const Duration(seconds: 3));
      expect(peak, lessThanOrEqualTo(regionFigureLanes));
      expect(peak, greaterThan(0));
    });

    testWidgets('a 429 pauses the reads, says so, and goes on after the pause', (tester) async {
      limit = true;
      await pump(tester, pause: const Duration(seconds: 30));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byKey(const Key('regions-paused')), findsOneWidget);
      final during = hits.length;
      await tester.pump(const Duration(seconds: 20));
      expect(hits.length, during, reason: 'nothing is asked while paused');
      limit = false;
      await tester.pump(const Duration(seconds: 11));
      await tester.pump(const Duration(seconds: 3));
      expect(find.byKey(const Key('regions-paused')), findsNothing);
      expect(hits.length, greaterThan(during));
    });

    testWidgets('country headings, a search box over 559 regions, ranked results, and the compare table only among regions read', (tester) async {
      await pump(tester);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const Key('regions-search')), findsOneWidget);
      expect(find.byKey(const Key('regions-country-AU')), findsOneWidget);
      expect(find.byKey(const Key('regions-compare-scope')), findsOneWidget);
      expect(find.textContaining('of 559 regions read so far'), findsOneWidget);
      expect(find.byKey(const Key('regions-compare')), findsNothing, reason: 'collapsed until opened');
      await tester.tap(find.byKey(const Key('regions-compare-tile')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('regions-compare')), findsOneWidget);
      final rows = tester.widget<DataTable>(find.byKey(const Key('regions-compare'))).rows.length;
      expect(rows, inInclusiveRange(1, regionCompareRows));
      await tester.tap(find.text('Compare regions'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('regions-search')), 'lubeck');
      await tester.pump();
      expect(find.textContaining('Lübeck'), findsWidgets);
      await tester.enterText(find.byKey(const Key('regions-search')), 'qqqqq');
      await tester.pump();
      expect(find.byKey(const Key('regions-no-match')), findsOneWidget);
    });

    testWidgets('leaving the screen cancels what is queued: nothing is read after dispose', (tester) async {
      await pump(tester);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      final n = hits.length;
      await tester.pump(const Duration(seconds: 10));
      expect(hits.length, n);
    });
  });
}
