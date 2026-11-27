// Drive report screen: opened from the drive detail screen and the drives list menu; hero numbers, new
// grids/repeaters against an earlier drive, "not on MeshSonar" tags, charts and Share report.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import '../support/tool_definition.dart';
import 'package:meshsonar/ui/report/drive_report_screen.dart';

import 'fakes.dart';

final t0 = DateTime.utc(2026, 10, 16, 18);
DrivePing at(String id, int sec, double lat, double lon, [List<Echo> echoes = const []]) =>
    DrivePing(id: id, ts: t0.add(Duration(seconds: sec)), lat: lat, lon: lon, echoes: echoes);

Harness seeded() {
  final h = Harness();
  h.cache.items = const [RepeaterRef(key: 'a1b2c3d4', name: 'Westerville North', lat: 40.13, lon: -82.93)];
  // Earlier drive: one cell, heard a1b2 only.
  h.store.seed(
    DriveSession(id: 'old', startedAt: t0.subtract(const Duration(days: 1)), endedAt: t0.subtract(const Duration(hours: 23))),
    [at('o1', -86400, 40.1001, -82.9301, const [Echo(repeater: 'a1b2', snrDb: 3, hops: 1)])],
  );
  // This drive: the old cell plus two new ones, a new repeater (e5f6) that isn't on CMAT's list.
  h.store.seed(DriveSession(id: 'new', startedAt: t0, endedAt: t0.add(const Duration(minutes: 3))), [
    at('n1', 0, 40.1001, -82.9301, const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]),
    at('n2', 60, 40.1031, -82.9301, const [Echo(repeater: 'a1b2', snrDb: 1, hops: 1), Echo(repeater: 'e5f6', snrDb: -4, hops: 2)]),
    at('n3', 120, 40.1061, -82.9301),
    at('n4', 150, 40.1065, -82.9301),
  ]);
  return h;
}

void main() {
  Future<void> openReport(WidgetTester tester, {required MapDefinition def, required List<PrivacyZone> zones}) async {
    useTallScreen(tester);
    ActiveMapDefinition.notifier.value = def;
    addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
    final h = seeded();
    await h.pumpApp(tester);
    await h.state.privacyZones.setZones(zones);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-report')));
    await tester.pumpAndSettle();
  }

  List<Polygon> dashedPolygons(WidgetTester tester) =>
      [for (final l in tester.widgetList<PolygonLayer>(find.byType(PolygonLayer))) ...l.polygons.where((p) => p.pattern.segments != null)];

  testWidgets('report map: a zone on the drive is drawn from the definition and named in the key; the squares stay', (tester) async {
    await openReport(tester, def: liveToolDefinition(), zones: const [PrivacyZone(lat: 40.1031, lon: -82.9301, radiusM: 200), PrivacyZone(lat: 41.5, lon: -80, radiusM: 200)]);
    expect(dashedPolygons(tester), hasLength(1), reason: 'only the zone that reaches the map; the far one is neither drawn nor counted');
    expect(find.text('Privacy zone'), findsOneWidget);
    expect(find.byKey(const Key('drive-key-bands')), findsNothing, reason: 'the report keeps its own heard scale');
    final squares = [for (final l in tester.widgetList<PolygonLayer>(find.byType(PolygonLayer))) ...l.polygons.where((p) => p.pattern.segments == null && p.points.length == 4)];
    expect(squares, hasLength(3), reason: 'the three cells are still squares');
  });

  testWidgets('report map: without tool style (the bundled definition) no zone and no key, as in build 73', (tester) async {
    await openReport(tester, def: MapDefinition.bundled, zones: const [PrivacyZone(lat: 40.1031, lon: -82.9301, radiusM: 200)]);
    expect(dashedPolygons(tester), isEmpty);
    expect(find.byKey(const Key('drive-key')), findsNothing);
    expect(find.byType(CircleLayer), findsNothing);
  });

  testWidgets('report opens from drive detail and shows hero numbers, new grids and repeaters', (tester) async {
    useTallScreen(tester);
    final h = seeded();
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('session-new')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-report')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('drive-report')), findsOneWidget);
    // Round 5 D-1: the verdict is the headline; distance is in the stat row.
    expect(tester.widget<Text>(find.byKey(const Key('report-verdict'))).data, startsWith('Patchy: heard on 2 of 4 pings'));
    // D-10: the report no longer repeats the Pings and Heard tiles.
    expect(find.byKey(const Key('report-pings')), findsNothing);
    expect(find.byKey(const Key('report-heard-count')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('report-grids'))).data, '3');
    expect(find.text('+2 new'), findsOneWidget); // grids
    expect(tester.widget<Text>(find.byKey(const Key('report-heard'))).data, '50%');
    expect(tester.widget<Text>(find.byKey(const Key('report-repeaters'))).data, '2');
    expect(find.text('+1 new'), findsOneWidget); // repeaters
    expect(tester.widget<Text>(find.byKey(const Key('report-distance'))).data, '712 m');
    expect(find.textContaining('New repeater heard: E5F6'), findsOneWidget);
    expect(find.textContaining('isn\'t on MeshSonar\'s list'), findsOneWidget);
    expect(find.byKey(const Key('report-map')), findsOneWidget);
    expect(find.textContaining('3 cells'), findsOneWidget);

    final list = find.descendant(of: find.byKey(const Key('report-list')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('report-snr-chart')), 200, scrollable: list);
    // D-11: the radio charts are one group of one-line readings; a row opens its chart.
    await tester.scrollUntilVisible(find.byKey(const Key('radio-row-hops')), 200, scrollable: list);
    expect(find.byKey(const Key('report-hops')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const Key('radio-reading-hops'))).data, startsWith('Echoes: '));
    await tester.ensureVisible(find.byKey(const Key('radio-row-hops')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('radio-row-hops')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('report-hops')), findsOneWidget);
    expect(find.textContaining('Direct'), findsWidgets);
    await tester.scrollUntilVisible(find.byKey(const ValueKey('report-rep-e5f6')), 200, scrollable: list);
    expect(find.text('Westerville North'), findsWidgets);
    expect(tester.widget<Text>(find.byKey(const ValueKey('report-rep-count-a1b2'))).data, '2×');
    expect(find.byKey(const ValueKey('report-new-e5f6')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-new-a1b2')), findsNothing);
    expect(find.byKey(const ValueKey('report-unknown-e5f6')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-unknown-a1b2')), findsNothing);
    await tester.scrollUntilVisible(find.byKey(const Key('report-worst-spot')), 200, scrollable: list);
    expect(find.byKey(const Key('report-best-spot')), findsOneWidget);
    // D-8: Show on map instead of raw coordinates.
    expect(find.byKey(const Key('report-best-spot-map')), findsOneWidget);
    expect(find.byKey(const Key('report-worst-spot-map')), findsOneWidget);
    expect(find.textContaining('40.10'), findsNothing);

    await tester.scrollUntilVisible(find.byKey(const Key('report-share-button')), 200, scrollable: list);
    // The report file is written with real IO, so let it run outside the fake clock.
    // D-6: the button opens the one Share sheet; Summary (text) is the old Share report.
    await tester.tap(find.byKey(const Key('report-share-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('report-csv-button')), findsNothing);
    expect(find.text('Report (PDF)'), findsOneWidget);
    expect(find.text('Drive file (for re-upload)'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('report-export-text')));
      for (var i = 0; i < 20 && h.shared.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pumpAndSettle();
    expect(h.shared, hasLength(1));
    expect(h.shared.single.path, endsWith('.txt'));
    final text = await tester.runAsync(() => h.shared.single.readAsString());
    expect(text, contains('3 grid cells mapped (2 with coverage, 2 new)'));
    expect(text, contains('Westerville North: 2×'));
  });

  testWidgets('first drive: everything is new, nothing tagged NEW, report from the drives menu', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.store.seed(DriveSession(id: 'only', startedAt: t0, endedAt: t0.add(const Duration(minutes: 1))), [
      at('a', 0, 40.1001, -82.9301, const [Echo(repeater: 'a1b2', snrDb: 2, hops: 1)]),
      at('b', 30, 40.1001, -82.9311),
    ]);
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-only')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-report-only')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drive-report')), findsOneWidget);
    expect(find.textContaining('First drive on this phone'), findsOneWidget);
    expect(find.byKey(const ValueKey('report-new-a1b2')), findsNothing);
    // CMAT list not loaded: nothing is flagged unknown to CMAT.
    expect(find.textContaining('MeshSonar\'s list'), findsNothing);
  });

  testWidgets('DriveReportScreen can be pushed directly (Drive screen card)', (tester) async {
    useTallScreen(tester);
    final h = seeded();
    await h.pumpApp(tester);
    final ctx = tester.element(find.byType(Scaffold).first);
    openDriveReport(ctx, 'new');
    await tester.pumpAndSettle();
    expect(find.byType(DriveReportScreen), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('report-grids'))).data, '3');
  });
}
