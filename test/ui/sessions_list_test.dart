import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/drive_stats.dart';

import 'fakes.dart';

DrivePing at(String id, double lat, double lon, int sec, List<Echo> echoes) => DrivePing(
    id: id, ts: DateTime.utc(2026, 10, 16, 18, 0, sec), lat: lat, lon: lon, echoes: echoes);

void main() {
  test('stats: haversine distance, heard %, SNR, repeaters, multi-hop', () {
    // ~0.01 deg of latitude = ~1112 m per step.
    final pings = [
      at('a', 40.00, -82.9, 0, const [Echo(repeater: 'AA', snrDb: 4, hops: 1), Echo(repeater: 'bb', snrDb: -3, hops: 2)]),
      at('b', 40.01, -82.9, 30, const []),
      at('c', 40.02, -82.9, 60, const [Echo(repeater: 'aa', snrDb: 9.5, hops: 1)]),
      at('d', 40.03, -82.9, 90, const [Echo(repeater: 'cc', snrDb: -1, hops: 3)]),
    ];
    final s = DriveSession(id: 's', startedAt: DateTime.utc(2026, 10, 16, 18), endedAt: DateTime.utc(2026, 10, 16, 18, 25));
    final st = DriveStats.of(s, pings);
    expect(st.distanceM, closeTo(3 * 1111.95, 5));
    expect(st.heardPercent, 75);
    expect(st.bestSnr, 9.5);
    expect(st.medianSnr, 4); // per-ping best: 4, 9.5, -1
    expect(st.multiHopEchoes, 2);
    expect(st.repeaters.first.repeater, 'aa');
    expect(st.repeaters.first.pings, 2);
    expect(st.repeaters.map((r) => r.repeater), ['aa', 'bb', 'cc']);
    expect(st.timeline, [true, false, true, true]);
    expect(st.duration, const Duration(minutes: 25));
    expect(Units.metric.distance(st.distanceM), '3.3 km');
    expect(formatDuration(st.duration), '25 min');
    expect(formatDuration(const Duration(hours: 1, minutes: 5)), '1 h 05 min');
  });

  test('stats: empty drive has no numbers it did not measure', () {
    final st = DriveStats.of(DriveSession(id: 's', startedAt: DateTime.utc(2026)), const []);
    expect(st.heardPercent, isNull);
    expect(st.bestSnr, isNull);
    expect(st.medianSnr, isNull);
    expect(st.distanceM, 0);
  });

  testWidgets('an all-rx (discovery) drive card shows "Heard —", not a misleading "Heard 0%"', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.store.seed(
      DriveSession(id: 'rx1', startedAt: DateTime.utc(2026, 10, 19, 10), endedAt: DateTime.utc(2026, 10, 19, 10, 20)),
      [
        DrivePing(id: 'r1', ts: DateTime.utc(2026, 10, 19, 10, 1), lat: 40, lon: -82.9, kind: PingKind.rx, echoes: const [Echo(repeater: 'aa', snrDb: 3)]),
        DrivePing(id: 'r2', ts: DateTime.utc(2026, 10, 19, 10, 2), lat: 40.01, lon: -82.9, kind: PingKind.rx, echoes: const [Echo(repeater: 'bb', snrDb: 1)]),
      ],
    );
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();

    expect(find.text('2 pings'), findsOneWidget);
    expect(find.text('Heard —'), findsOneWidget);
    expect(find.text('Heard 0%'), findsNothing);
  });

  testWidgets('drive card shows duration, distance, heard strip and sync badge; Sync all', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.store.seed(
      DriveSession(
          id: 'd1',
          startedAt: DateTime.utc(2026, 10, 15, 14),
          endedAt: DateTime.utc(2026, 10, 15, 14, 42),
          label: 'Polaris loop',
          channel: '#wardriving'),
      [
        at('p1', 40.00, -82.9, 0, const [Echo(repeater: 'aa', snrDb: 3)]),
        at('p2', 40.01, -82.9, 30, const []),
      ],
    );
    h.store.seed(DriveSession(id: 'd2', startedAt: DateTime.utc(2026, 10, 14, 14), endedAt: DateTime.utc(2026, 10, 14, 15)),
        [at('q1', 40, -82.9, 0, const [])],
        syncedFirst: 1);
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();

    expect(find.text('Polaris loop'), findsOneWidget);
    expect(find.text('42 min'), findsOneWidget);
    expect(find.text('1.1 km'), findsOneWidget);
    expect(find.byKey(const ValueKey('strip-d1')), findsOneWidget);
    expect(find.text('2 not synced'), findsOneWidget);
    expect(find.text('All synced'), findsOneWidget);
    expect(find.text('2 pings waiting to upload'), findsOneWidget);

    await tester.tap(find.byKey(const Key('sync-all')));
    await tester.pumpAndSettle();
    expect(h.sync.syncAllCalls, 1);
    expect(find.text('All synced'), findsNWidgets(2));
    expect(find.byKey(const Key('sync-all')), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('sync failure shows a Sync failed badge', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.sync.failWith = 'network error';
    h.store.seed(DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 15, 14)), [at('p', 40, -82, 0, const [])]);
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sync-d1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sync-failed-d1')), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('rename from the card menu; swipe to delete asks first', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.store.seed(DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 15, 14)), [at('p', 40, -82, 0, const [])]);
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('menu-d1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rename-d1')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rename-field')), 'Route 3 north');
    await tester.tap(find.byKey(const Key('rename-save')));
    await tester.pumpAndSettle();
    expect(find.text('Route 3 north'), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey('session-d1')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Delete this drive?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.store.sessionsById.containsKey('d1'), isTrue);
    expect(find.byKey(const ValueKey('session-d1')), findsOneWidget);

    await tester.drag(find.byKey(const ValueKey('session-d1')), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(h.store.sessionsById.containsKey('d1'), isFalse);
    expect(find.byKey(const ValueKey('session-d1')), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('pull to refresh reloads drives', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    expect(find.text('No drives yet'), findsOneWidget);
    h.store.seed(DriveSession(id: 'late', startedAt: DateTime.utc(2026, 10, 15)), [at('p', 40, -82, 0, const [])]);
    await tester.fling(find.text('No drives yet'), const Offset(0, 400), 1000);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('session-late')), findsOneWidget);
  });
}
