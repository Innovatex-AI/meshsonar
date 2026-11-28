// The More list. M0 (Nov 8 2026, unified map plan §5): no Developer switch, even after a long-press on the version row
// (About MeshSonar). Build 71: nine rows, no group headers; the help rows (My reports among them) sit under Help.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'shell_test.dart' show drain;

Finder _inMore(String key) => find.byKey(Key(key));

Future<void> _scrollTo(WidgetTester tester, Finder f) => tester.scrollUntilVisible(f, 150,
    scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);

void main() {
  testWidgets('no Developer section or "New Drive screen" switch, even after a long-press on the version row (build 70)', (tester) async {
    useTallScreen(tester);
    await Harness().pumpApp(tester);
    await tapShellTab(tester, 'More');
    await tester.pumpAndSettle();
    await _scrollTo(tester, _inMore('more-about'));
    await tester.longPress(_inMore('more-about'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-drive-redesign')), findsNothing);
    expect(find.text('Developer'), findsNothing);
    expect(find.text('New Drive screen'), findsNothing);
    await drain(tester);
  });

  testWidgets('build 77: More is seven rows with no group headers; My reports, the legend and the terms sit under Help', (tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await Harness().pumpApp(tester);
    await tapShellTab(tester, 'More');
    await tester.pumpAndSettle();
    // Build 76 order: what people open most first (Drives, Radio, Settings), then the rest.
    // Build 77 (round 5 M1, decision 2): Chat settings is in Settings > Messages, Devices and keys in Settings > Account.
    const rows = ['more-drives', 'more-radio', 'more-settings', 'more-leaderboard', 'more-observerJoin', 'more-help', 'more-about'];
    final list = find.byKey(const Key('more-list'));
    expect(find.descendant(of: list, matching: find.byType(ListTile)), findsNWidgets(rows.length));
    var lastY = double.negativeInfinity;
    for (final k in rows) {
      expect(_inMore(k), findsOneWidget, reason: k);
      final y = tester.getTopLeft(_inMore(k)).dy;
      expect(y, greaterThan(lastY), reason: '$k is in order');
      lastY = y;
    }
    for (final h in ['Your drives', 'Your radio', 'Radios and tools', 'Community', 'App', 'Help and about']) {
      expect(find.descendant(of: list, matching: find.text(h)), findsNothing, reason: 'no group header "$h"');
    }
    // Rows that only jumped into a Settings section are gone from the list.
    for (final k in ['more-myRadios', 'more-observer', 'more-wardriving', 'more-notifications', 'more-privacy', 'more-network', 'more-chat', 'more-devices']) {
      expect(_inMore(k), findsNothing, reason: k);
    }
    expect(_inMore('more-myReports'), findsNothing);
    await tester.tap(_inMore('more-help'));
    await tester.pumpAndSettle();
    for (final k in ['more-howItWorks', 'more-method', 'more-legend', 'more-report', 'more-myReports', 'more-privacy-policy', 'more-terms']) {
      expect(_inMore(k), findsOneWidget, reason: '$k is under Help');
    }
    // One name per thing (round 5 S7): the legend is "Map legend" here as in Settings.
    expect(find.descendant(of: _inMore('more-legend'), matching: find.text('Map legend')), findsOneWidget);
    expect(find.text('Colour legend'), findsNothing);
    expect(tester.getTopLeft(_inMore('more-terms')).dy, greaterThan(tester.getTopLeft(_inMore('more-privacy-policy')).dy),
        reason: 'the terms beside the privacy policy');
    expect(_inMore('more-tour'), findsOneWidget, reason: 'build 76: the intro is one tap away under Help');
    expect(find.textContaining('square'), findsNothing, reason: 'cells are hexagons (coverage v2)');
    await drain(tester);
  });
}
