// The More list after M0 (Nov 8 2026, unified map plan §5): the Developer switch is not in the normal list and appears only
// after a long-press on the version row (About MeshSonar); Leaderboard sits under Community and My reports under Help and
// about, not under Your radio.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'shell_test.dart' show drain;

Finder _inMore(String key) => find.byKey(Key(key));

Future<void> _scrollTo(WidgetTester tester, Finder f) => tester.scrollUntilVisible(f, 150,
    scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);

/// The header text a row sits under: the nearest header above it in list order.
String _headerOf(WidgetTester tester, String rowKey, List<String> headers) {
  final rowY = tester.getTopLeft(_inMore(rowKey)).dy;
  String? best;
  double bestY = double.negativeInfinity;
  for (final h in headers) {
    final f = find.text(h);
    if (f.evaluate().isEmpty) continue;
    final y = tester.getTopLeft(f.first).dy;
    if (y < rowY && y > bestY) {
      bestY = y;
      best = h;
    }
  }
  return best ?? '';
}

void main() {
  testWidgets('no Developer switch until a long-press on the version row; a second long-press hides it again', (tester) async {
    useTallScreen(tester);
    await Harness().pumpApp(tester);
    await tapShellTab(tester, 'More');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-drive-redesign')), findsNothing);
    expect(find.text('Developer'), findsNothing);
    await _scrollTo(tester, _inMore('more-about'));
    await tester.longPress(_inMore('more-about'));
    await tester.pumpAndSettle();
    await _scrollTo(tester, find.byKey(const Key('more-drive-redesign')));
    expect(find.byKey(const Key('more-drive-redesign')), findsOneWidget);
    expect(find.text('Developer'), findsOneWidget);
    await _scrollTo(tester, _inMore('more-about'));
    await tester.longPress(_inMore('more-about'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-drive-redesign')), findsNothing);
    await drain(tester);
  });

  testWidgets('Leaderboard is under Community and My reports under Help and about, not under Your radio', (tester) async {
    tester.view.physicalSize = const Size(1200, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await Harness().pumpApp(tester);
    await tapShellTab(tester, 'More');
    await tester.pumpAndSettle();
    const headers = ['Your radio', 'Radios and tools', 'Community', 'App', 'Help and about'];
    expect(_headerOf(tester, 'more-leaderboard', headers), 'Community');
    expect(_headerOf(tester, 'more-myReports', headers), 'Help and about');
    expect(_headerOf(tester, 'more-devices', headers), 'Your radio');
    expect(find.textContaining('square'), findsNothing, reason: 'cells are hexagons (coverage v2)');
    await drain(tester);
  });
}
