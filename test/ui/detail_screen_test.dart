import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart' show dismissAppToast;

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

  testWidgets('detail: verdict, map, four tiles, repeaters with names and counts, one-line pings that open', (tester) async {
    await openDetail(tester);
    expect(find.byKey(const Key('drive-detail')), findsOneWidget);
    expect(find.byKey(const Key('detail-map')), findsOneWidget);
    for (final id in ['p1', 'p2', 'p3']) {
      expect(find.byKey(ValueKey('map-ping-$id')), findsOneWidget, reason: 'ping $id on the map');
    }
    // Round 5 D-1: the verdict (2 of 3 heard = 67%, Patchy; median best reply 4.25 dB = good). D-17: the name once.
    expect(textOf(tester, 'detail-verdict'), 'Patchy: heard on 2 of 3 pings, mostly good');
    expect(textOf(tester, 'detail-title'), 'Evening loop');
    expect(find.text('Evening loop'), findsOneWidget);
    // D-10: four tiles; signal, hops and the charts are the report's.
    expect(textOf(tester, 'stat-pings'), '3');
    expect(textOf(tester, 'stat-heard-pct'), '67%');
    expect(textOf(tester, 'stat-duration'), '10 min');
    expect(textOf(tester, 'stat-distance'), '2.2 km');
    for (final k in ['stat-best-snr', 'stat-median-snr', 'stat-repeaters', 'stat-multihop']) {
      expect(find.byKey(Key(k)), findsNothing, reason: k);
    }
    // D-12: the separate Ping log button is gone ("All N pings" replaces it).
    expect(find.byKey(const Key('detail-ping-log')), findsNothing);

    // Repeater name comes from the cache; count of pings that heard it. Drives open inside More since build 71 (the tab
    // area, not the whole screen), so the list is scrolled to the repeaters first.
    final scroll = find.descendant(of: find.byKey(const Key('detail-scroll')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const ValueKey('repeater-count-ee')), 200, scrollable: scroll);
    expect(find.text('Polaris Water Tower'), findsWidgets);
    expect(textOf(tester, 'repeater-count-a1'), '2×');
    expect(textOf(tester, 'repeater-count-ee'), '1×');
    // D-17: a short id is upper case, as on the report.
    expect(find.text('EE'), findsOneWidget);
    expect(find.text('ee'), findsNothing);

    await tester.scrollUntilVisible(find.byKey(const ValueKey('detail-ping-p1')), 200, scrollable: scroll);
    expect(find.text('Heard nothing'), findsOneWidget);
    expect(find.text('2 repeaters · Strong'), findsOneWidget);
    expect(find.text('1 repeater · Good'), findsOneWidget);
    // One line per ping: the echoes are in the ping's own sheet, which a tap opens.
    expect(find.text('SNR -4.0 dB · 2 hops'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('detail-ping-p1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ping-detail')), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(find.byKey(const Key('show-all-pings')), 200, scrollable: scroll);
    expect(find.text('All 3 pings'), findsOneWidget);
    await tester.tap(find.byKey(const Key('show-all-pings')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ping-log')), findsOneWidget);
  });

  testWidgets('detail: upload line shown once, then a quiet Uploaded; Share opens the one Share sheet', (tester) async {
    final h = await openDetail(tester);
    expect(textOf(tester, 'unsynced-d1'), '1 of 3 uploaded');
    expect(find.text('Upload 2'), findsOneWidget);
    await tester.tap(find.byKey(const Key('detail-sync')));
    await tester.pumpAndSettle();
    expect(h.sync.syncedSessions, ['d1']);
    expect(textOf(tester, 'unsynced-d1'), 'Uploaded');
    expect(find.byKey(const Key('detail-sync')), findsNothing);

    // The upload toast sits over the bottom of the share sheet: close it first.
    dismissAppToast();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('detail-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('share-drive-file')));
    await tester.pumpAndSettle();
    expect(h.shared.single.path, endsWith('drive-d1.json'));
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('detail: delete returns to the list', (tester) async {
    final h = await openDetail(tester);
    // Build 76: Delete lives in the More menu (the app bar holds Report and the menu only).
    await tester.tap(find.byKey(const Key('detail-more')));
    await tester.pumpAndSettle();
    // Round 5 D-7: the drive card's menu.
    for (final k in ['detail-menu-report', 'detail-menu-share', 'detail-rename', 'detail-more-report', 'detail-diagnostics', 'detail-delete']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
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
