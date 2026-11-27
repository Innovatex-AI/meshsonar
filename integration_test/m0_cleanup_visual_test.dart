// Visual check for the M0 app cleanup (unified map plan, Nov 8 2026): the Plan tab (five tools, no frozen CMH tools), the
// Network tab (Analyze > Region until build 71; Insights > Analysis), the More list (groups, no Developer row until a long-press on
// About MeshSonar), and the rewritten Method page. Prints "SCREEN <name>" lines for scripts/verify_sim.sh to screenshot.
//
//   FLOW_TEST=integration_test/m0_cleanup_visual_test.dart DEVICES="iPhone 17 Pro" scripts/verify_sim.sh <worktree>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

Future<void> _scrollMore(WidgetTester t, String key) async {
  final list = find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first;
  await t.scrollUntilVisible(find.byKey(Key(key)), 200, scrollable: list);
  await pumpFor(t, const Duration(milliseconds: 600));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M0 cleanup screens', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      await t.tap(find.text('Skip'));
    }
    for (var i = 0; i < 14; i++) {
      await pumpFor(t, const Duration(milliseconds: 700));
      final c = find.text('Continue');
      if (c.evaluate().isNotEmpty) {
        await t.tap(c.last, warnIfMissed: false);
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    await pumpFor(t, const Duration(seconds: 3));

    // Plan: Where to drive next + five tools.
    await openShellTab(t, 'Plan');
    await pumpFor(t, const Duration(seconds: 4));
    await shot(t, 'm0-plan-top');
    final planList = find.descendant(of: find.byKey(const Key('planner-sheet-body')), matching: find.byType(Scrollable)).first;
    await t.scrollUntilVisible(find.byKey(const Key('plan-check')), 200, scrollable: planList);
    await shot(t, 'm0-plan-tools');
    await t.tap(find.byKey(const Key('plan-airtime')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'm0-plan-airtime');
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));

    // Network (Analyze until build 71): the region home, then Analytics > Overview (a site page in the app).
    await openShellTab(t, 'Network');
    await pumpFor(t, const Duration(seconds: 5));
    await shot(t, 'm0-analyze-region');
    // Build 71: the old Insights pages are replaced by the site's Analytics tabs, shown inside the app.
    if (await openNetworkSection(t, 'analytics')) {
      await shot(t, 'm0-analyze-tabs-end');
      final overview = find.byKey(const Key('analytics-tab-rf-signal'));
      if (await waitFor(t, overview, timeout: const Duration(seconds: 5))) {
        await t.tap(overview);
        await sitePageProblem(t);
        await shot(t, 'm0-analyze-analysis');
        await popToRoots(t);
      }
    }

    // More: top, middle, bottom (the Developer section and its Drive switch are gone, build 70).
    await openShellTab(t, 'More');
    if (find.byKey(const Key('more-list')).hitTestable().evaluate().isEmpty) await openShellTab(t, 'More');
    await shot(t, 'm0-more-top');
    // Build 71: More is nine rows; Method and the Privacy policy are under Help.
    await _scrollMore(t, 'more-help');
    await shot(t, 'm0-more-middle');
    await t.tap(find.byKey(const Key('more-help')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'm0-more-bottom');

    // Method (coverage v2 text).
    await t.tap(find.byKey(const Key('more-method')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'm0-method-top');
    final method = find.descendant(of: find.byKey(const Key('method-list')), matching: find.byType(Scrollable)).first;
    await t.scrollUntilVisible(find.text('Predicted coverage'), 200, scrollable: method);
    await shot(t, 'm0-method-cells');
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
