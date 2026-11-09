// The Plan tab after M0 (Nov 8 2026): Where to drive next plus five native tools. The Oct 15 planning-engine screens
// (Planner, Recommended build, Site explorer, Scenarios, Build tracker) and Field data are gone, and no row opens the browser.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes.dart';
import '../shell_test.dart' show phone, drain;

void main() {
  testWidgets('only the working tools are listed, all native; the frozen CMH tools and Field data are gone', (tester) async {
    phone(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tapShellTab(tester, 'Plan');
    await tester.pumpAndSettle();
    for (final id in const ['link', 'painter', 'airtime', 'presets', 'check']) {
      final tile = find.byKey(Key('plan-$id'));
      await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: tile, matching: find.byIcon(Icons.open_in_new)), findsNothing, reason: id);
      expect(find.descendant(of: tile, matching: find.byIcon(Icons.chevron_right)), findsOneWidget, reason: id);
    }
    for (final id in const ['planner', 'recommended', 'sites', 'scenarios', 'tracker', 'field']) {
      expect(find.byKey(Key('plan-$id')), findsNothing, reason: id);
    }
    expect(find.textContaining('okimesh'), findsNothing);
    expect(h.openedUrls, isEmpty);
    await drain(tester);
  });
}
