// Drive report screen: opened from the drive detail screen and the drives list menu; hero numbers, new
// grids/repeaters against an earlier drive, "not on MeshSonar" tags, charts and Share report.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
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
    await tester.scrollUntilVisible(find.byKey(const Key('report-hops')), 200, scrollable: list);
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

    await tester.scrollUntilVisible(find.byKey(const Key('report-share-button')), 200, scrollable: list);
    // The report file is written with real IO, so let it run outside the fake clock.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('report-share-button')));
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
