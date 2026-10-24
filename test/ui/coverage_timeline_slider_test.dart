// Coverage-growth slider: honest states, debounced re-query with `until`, play, reset to live, map label.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/coverage_timeline.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/coverage_timeline_slider.dart';

import 'fakes.dart';
import 'network_coverage_layer_test.dart' show twoCells;

RegionTimeline timeline() => RegionTimeline.parse({
  'days': [
    {'day': '2026-10-10', 'newCells': 5, 'totalCells': 5},
    {'day': '2026-10-11', 'newCells': 5, 'totalCells': 10},
  ],
})!;

Future<(Harness, DriveMapModel)> pump(WidgetTester tester, {RegionTimeline? Function()? tl}) async {
  final h = Harness();
  h.client.publicCoverageResult = twoCells();
  await h.state.init();
  final model = DriveMapModel(h.state);
  addTearDown(model.dispose);
  model.timelineFetcher = (_) async => tl == null ? timeline() : tl();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(children: [CoverageTimelineSlider(model: model), CoverageAsOfBadge(model: model)]),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return (h, model);
}

void main() {
  // The harness clock is 2026-10-16 18:00 UTC: first data Oct 10 -> 7 steps, step 6 = live.
  testWidgets('scrubbing re-queries with until after the debounce and labels the map', (tester) async {
    final (h, model) = await pump(tester);
    expect(find.byKey(const Key('timeline-status')), findsOneWidget);
    expect(find.text('Live (first data Oct 10, 2026)'), findsOneWidget);
    expect(find.byKey(const Key('coverage-as-of')), findsNothing);
    final before = h.client.publicCoverageCalls;

    model.timeline.scrubTo(2);
    model.timeline.scrubTo(3); // rapid scrub: only the last position is sent
    await tester.pump();
    expect(h.client.publicCoverageCalls, before, reason: 'debounced');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(h.client.publicCoverageCalls, before + 1);
    expect(h.client.lastCoverageUntil, DateTime.utc(2026, 10, 14));
    expect(find.text('Coverage as of Oct 13, 2026'), findsOneWidget);
    expect(find.text('Showing coverage through Oct 13, 2026 (UTC)'), findsOneWidget);
  });

  testWidgets('empty answer says no coverage yet; reset goes back to live without until', (tester) async {
    final (h, model) = await pump(tester);
    h.client.publicCoverageResult = PublicCoverage(asOf: '2026-10-12T00:00:00Z', grid: const CoverageGrid.square(cellDeg: 0.005), cells: const []);
    model.timeline.scrubTo(0);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('timeline-note-empty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('timeline-live')));
    await tester.pump();
    await tester.pump();
    expect(h.client.lastCoverageUntil, isNull);
    expect(find.byKey(const Key('coverage-as-of')), findsNothing);
    expect(model.coverageQuery.until, isNull);
  });

  testWidgets('a failing request shows the offline note', (tester) async {
    final (h, model) = await pump(tester);
    h.client.publicCoverageResult = null; // fake throws 404
    model.timeline.scrubTo(1);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('timeline-note-offline')), findsOneWidget);
  });

  testWidgets('play steps forward one day per tick and stops at live', (tester) async {
    final (h, model) = await pump(tester);
    model.timeline.scrubTo(4);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('timeline-play')));
    await tester.pump();
    expect(model.timeline.playing, isTrue);
    await tester.pump(const Duration(milliseconds: 1250));
    expect(model.timeline.index, 5);
    await tester.pump(const Duration(milliseconds: 1250));
    expect(model.timeline.isLive, isTrue);
    expect(model.timeline.playing, isFalse);
    await tester.pump();
    expect(h.client.lastCoverageUntil, isNull);
  });

  testWidgets('timeline endpoint missing: honest unavailable note, no slider', (tester) async {
    await pump(tester, tl: () => null);
    expect(find.byKey(const Key('timeline-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('timeline-slider')), findsNothing);
  });
}

