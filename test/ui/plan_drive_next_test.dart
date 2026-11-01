// Plan tab, "Where to drive next": gaps near the phone from the network coverage the app already loaded, with Navigate into
// Apple Maps. Honest states without a fix or without data.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/ui/shell/drive_next_card.dart';

import 'fakes.dart';
import 'shell_test.dart' show phone, drain;

CoverageCell cell(double lat, double lon, {int pings = 6, int heard = 0}) => CoverageCell(
    lat: lat, lon: lon, pings: pings, heard: heard, bestSnr: null, medianSnr: null, repeaters: 0, lastAt: '2026-10-30T12:00:00Z');

void main() {
  setUp(() => DriveNextCard.testMap = (c, me, t) => SizedBox(key: const Key('fake-map'), height: 10, child: Text('${t.length} targets')));
  tearDown(() => DriveNextCard.testMap = null);

  testWidgets('lists silent areas with distance and direction; Navigate opens Apple Maps', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.publicCoverageResult = PublicCoverage(
      asOf: '2026-10-31T00:00:00Z',
      grid: const CoverageGrid.square(cellDeg: 0.005),
      // The fake phone is at 40.126, -82.93: one silent cell 1.1 km north, one measured cell right here.
      cells: [cell(40.136, -82.93), cell(40.126, -82.93, heard: 3)],
    );
    await h.pumpApp(tester);
    await tapShellTab(tester, 'Plan');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plan-drive-next')), findsOneWidget);
    expect(find.text('Where to drive next'), findsOneWidget);
    expect(find.byKey(const Key('fake-map')), findsOneWidget);
    expect(find.textContaining('Silent area'), findsOneWidget);
    expect(find.textContaining('N'), findsWidgets);
    await tester.tap(find.byKey(const Key('plan-navigate-0')));
    await tester.pump();
    final u = h.openedUrls.last;
    expect(u.host, 'maps.apple.com');
    expect(u.queryParameters['daddr'], '40.136000,-82.930000');
    await drain(tester);
  });

  testWidgets('no gaps in range says so; no coverage yet says loading or failed with a retry', (tester) async {
    phone(tester);
    final h = Harness();
    h.client.publicCoverageResult = PublicCoverage(
        asOf: 'x', grid: const CoverageGrid.square(cellDeg: 0.005), cells: [cell(40.126, -82.93, heard: 3)]);
    await h.pumpApp(tester);
    await tapShellTab(tester, 'Plan');
    await tester.pumpAndSettle();
    expect(find.textContaining('No silent or unmapped areas'), findsOneWidget);
    expect(find.byKey(const Key('plan-navigate-0')), findsNothing);
    await drain(tester);
  });

  testWidgets('no location fix: explains and offers the permission action, never an empty card', (tester) async {
    phone(tester);
    final h = Harness();
    h.location.currentFix = () => null;
    h.location.permission = false;
    await h.pumpApp(tester);
    await tapShellTab(tester, 'Plan');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plan-drive-next')), findsOneWidget);
    expect(find.textContaining('location'), findsWidgets);
    await drain(tester);
  });
}
