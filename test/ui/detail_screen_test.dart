import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';

import 'fakes.dart';

DrivePing at(String id, double lat, int sec, List<Echo> echoes) =>
    DrivePing(id: id, ts: DateTime.utc(2026, 10, 16, 18, 0, sec), lat: lat, lon: -82.93, echoes: echoes);

void main() {
  Future<Harness> openDetail(WidgetTester tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    h.cache.items = const [RepeaterRef(key: 'a1b2c3d4', name: 'Polaris Water Tower', lat: 40.1, lon: -82.9)];
    h.store.seed(
      DriveSession(
          id: 'd1',
          startedAt: DateTime.utc(2026, 10, 16, 18),
          endedAt: DateTime.utc(2026, 10, 16, 18, 10),
          label: 'Evening loop',
          channel: '#wardriving'),
      [
        at('p1', 40.10, 0, const [Echo(repeater: 'a1', snrDb: 6.5, hops: 1), Echo(repeater: 'ee', snrDb: -4, hops: 2)]),
        at('p2', 40.11, 30, const []),
        at('p3', 40.12, 59, const [Echo(repeater: 'a1', snrDb: 2.0, hops: 1)]),
      ],
      syncedFirst: 1,
    );
    await h.pumpApp(tester);
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-d1')));
    await tester.pumpAndSettle();
    return h;
  }

  String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

  testWidgets('detail: map, stats, repeaters with names and counts, ping list', (tester) async {
    await openDetail(tester);
    expect(find.byKey(const Key('drive-detail')), findsOneWidget);
    expect(find.byKey(const Key('detail-map')), findsOneWidget);
    for (final id in ['p1', 'p2', 'p3']) {
      expect(find.byKey(ValueKey('map-ping-$id')), findsOneWidget, reason: 'ping $id on the map');
    }
    expect(textOf(tester, 'stat-pings'), '3');
    expect(textOf(tester, 'stat-heard-pct'), '67%');
    expect(textOf(tester, 'stat-best-snr'), '6.5 dB');
    expect(textOf(tester, 'stat-median-snr'), '4.3 dB'); // per-ping best: 6.5 and 2.0
    expect(textOf(tester, 'stat-repeaters'), '2');
    expect(textOf(tester, 'stat-multihop'), '1');
    expect(textOf(tester, 'stat-duration'), '10 min');
    expect(textOf(tester, 'stat-distance'), '2.2 km');

    // Repeater name comes from the cache; count of pings that heard it.
    expect(find.text('Polaris Water Tower'), findsWidgets);
    expect(textOf(tester, 'repeater-count-a1'), '2×');
    expect(textOf(tester, 'repeater-count-ee'), '1×');

    final scroll = find.descendant(of: find.byKey(const Key('detail-scroll')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('detail-ping-p1')), 200, scrollable: scroll);
    expect(find.text('Heard nothing'), findsOneWidget);
    expect(find.textContaining('2 repeaters'), findsOneWidget);
    expect(find.text('SNR -4.0 dB · 2 hops'), findsOneWidget);
  });

  testWidgets('detail: sync and export & share', (tester) async {
    final h = await openDetail(tester);
    expect(find.text('Sync 2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail-sync')));
    await tester.pumpAndSettle();
    expect(h.sync.syncedSessions, ['d1']);
    expect(find.text('Synced'), findsOneWidget);

    await tester.tap(find.byKey(const Key('detail-export')));
    await tester.pumpAndSettle();
    expect(h.shared.single.path, endsWith('drive-d1.json'));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('detail: delete returns to the list', (tester) async {
    final h = await openDetail(tester);
    await tester.tap(find.byKey(const Key('detail-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete')));
    await tester.pumpAndSettle();
    expect(h.store.sessionsById, isEmpty);
    expect(find.byKey(const Key('drive-detail')), findsNothing);
    expect(find.text('No drives yet'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });
}
