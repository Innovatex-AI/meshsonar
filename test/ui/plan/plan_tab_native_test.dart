// The Plan tab is native (release 0.38): its root is the Planner, nothing on it opens the browser, and the frozen CMH
// planning tools of Oct 15 (Planner page, Recommended build, Site explorer, Scenarios, Build tracker, Field data) and the
// old Link / Painter tool rows are gone. planToolUri stays for the one website page the app still links (observer setup).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/shell/plan_tab.dart';

import '../fakes.dart';
import '../shell_test.dart' show phone, drain;

void main() {
  testWidgets('the Plan tab is the Planner: native, no tool list, no browser, no frozen CMH tools', (tester) async {
    phone(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tapShellTab(tester, 'Plan');
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(PlanTab), findsOneWidget);
    expect(find.byType(PlannerScreen), findsOneWidget);
    for (final id in const ['link', 'painter', 'planner', 'recommended', 'sites', 'scenarios', 'tracker', 'field']) {
      expect(find.byKey(Key('plan-$id')), findsNothing, reason: id);
    }
    expect(find.textContaining('okimesh'), findsNothing);
    expect(h.openedUrls, isEmpty);
    await drain(tester);
  });

  test('planToolUri: the region host when it is a URL, else meshsonar.com', () {
    final region = planToolUri('https://cmh.meshsonar.com/?x=1', '/observers/setup');
    expect((region.host, region.path, region.query), ('cmh.meshsonar.com', '/observers/setup', ''));
    expect(planToolUri('not a url', '/observers/setup').toString(), 'https://meshsonar.com/observers/setup');
  });
}
