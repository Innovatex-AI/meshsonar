// The Plan tab: the planning engine's tools open native screens (no browser, no external-link icon); the tools not converted yet still
// open the website.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fakes.dart';
import '../shell_test.dart' show phone, drain;

void main() {
  testWidgets('Planner, Recommended build, Site explorer, Scenarios and Build tracker are native; the rest keep the browser icon', (tester) async {
    phone(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tapShellTab(tester, 'Plan');
    await tester.pumpAndSettle();
    final planner = find.byKey(const Key('plan-planner'));
    await tester.ensureVisible(planner);
    await tester.pumpAndSettle();
    await tester.tap(planner);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('planner-form')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    for (final id in const ['planner', 'recommended', 'sites', 'scenarios', 'tracker']) {
      final tile = find.byKey(Key('plan-$id'));
      await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: tile, matching: find.byIcon(Icons.open_in_new)), findsNothing, reason: id);
      expect(find.descendant(of: tile, matching: find.byIcon(Icons.chevron_right)), findsOneWidget, reason: id);
    }
    for (final id in const ['link', 'painter', 'airtime', 'presets', 'check']) {
      final tile = find.byKey(Key('plan-$id'));
      await tester.scrollUntilVisible(tile, 200, scrollable: find.byType(Scrollable).first);
      expect(find.descendant(of: tile, matching: find.byIcon(Icons.open_in_new)), findsOneWidget, reason: id);
    }
    expect(h.openedUrls, isEmpty);
    await drain(tester);
  });
}
