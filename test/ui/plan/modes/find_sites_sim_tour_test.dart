// The Find sites simulator tour (release 0.38 A10). Under `flutter test` it is one more walk through every state; run on
// the iPhone 17 Pro simulator with
//   flutter run -d <sim> -t test/ui/plan/modes/find_sites_sim_tour_test.dart
// (LiveTestWidgetsFlutterBinding draws it on the device) it prints `SIMSHOT <name>` and holds each state for a few
// seconds so a script can take `xcrun simctl io booted screenshot`. The planner endpoints answer from the fixtures (the
// live CMH server does not have plan-suggest deployed yet): the meshcore-insights plan-suggest fixtures and
// test/fixtures/plan_server/plan-verify.site.response.json.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/plan/modes/wizard.dart';

import '../../shell_test.dart' show drain;
import '../planner_test.dart' show settle, tapIn;
import 'find_sites_test.dart';
import 'wizard_test.dart' show FakePlaceFinder, WizardHarness, lookUp;

bool get _live => WidgetsBinding.instance is LiveTestWidgetsFlutterBinding;

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester);
  expect(tester.takeException(), isNull, reason: name);
  if (!_live) return;
  // ignore: avoid_print
  print('SIMSHOT $name');
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
}

void size(WidgetTester tester, {double scale = 1.0}) {
  // iPhone 17 Pro: 402 x 874 points at 3x.
  if (!_live) {
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

Future<void> fullSheet(WidgetTester tester) async {
  await tester.fling(find.byKey(const Key('planner-sheet-handle')), const Offset(0, -500), 1500);
  await settle(tester);
}

void main() {
  testWidgets('tour: This view', (tester) async {
    size(tester);
    final h = SitesHarness();
    h.client.planSuggestResult = suggestFixture();
    h.client.planVerifyResult = verifyFixture();
    await openFindSites(tester, h);
    await shot(tester, '01-find-sites-start');
    await tapIn(tester, find.byKey(const Key('sites-run')));
    await shot(tester, '02-ranked-pins-medium');
    await fullSheet(tester);
    await shot(tester, '03-ranked-list-full');
    await tapIn(tester, find.byKey(const Key('sites-verify')));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.ensureVisible(find.byKey(Key('site-${suggestFixture().sites.first.id}')));
    await shot(tester, '04-verified-top5-vs-estimate');
    h.client.planSuggestResult = preparingFixture();
    await tapIn(tester, find.byKey(const Key('sites-run')));
    await shot(tester, '05-preparing-this-region');
    h.client.planSuggestResult = null;
    await tapIn(tester, find.text('Check now'));
    await shot(tester, '06-server-without-plan-suggest');
    await drain(tester);
  });

  testWidgets('tour: Guide me', (tester) async {
    size(tester);
    final h = WizardHarness();
    h.client.planVerifyResult = verifyFixture();
    WizardModel.testPlaceFinder = FakePlaceFinder.new;
    addTearDown(() => WizardModel.testPlaceFinder = null);
    await openFindSites(tester, h);
    await tapIn(tester, find.byKey(const Key('sites-tab-wizard')));
    await fullSheet(tester);
    await shot(tester, '07-wizard-start');
    await lookUp(tester, '43215');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.ensureVisible(find.byKey(const Key('wizard-point')));
    await shot(tester, '08-wizard-rounded-point');
    await tester.ensureVisible(find.byKey(const Key('wizard-list-coverage')));
    await shot(tester, '09-wizard-for-your-coverage');
    await tester.ensureVisible(find.byKey(const Key('wizard-list-mesh')));
    await shot(tester, '10-wizard-to-extend-the-mesh');
    await drain(tester);
  });

  testWidgets('tour: AX3 text', (tester) async {
    size(tester, scale: 2.35);
    final h = WizardHarness();
    h.client.planSuggestResult = suggestFixture();
    WizardModel.testPlaceFinder = FakePlaceFinder.new;
    addTearDown(() => WizardModel.testPlaceFinder = null);
    await openFindSites(tester, h);
    await fullSheet(tester);
    await tapIn(tester, find.byKey(const Key('sites-run')));
    await settle(tester);
    // GoalClient answers Best overall with the fixture's sites 3-9.
    await tester.ensureVisible(find.byKey(Key('site-${suggestFixture().sites[3].id}')));
    await shot(tester, '11-ax3-ranked-row');
    await tapIn(tester, find.byKey(const Key('sites-tab-wizard')));
    await shot(tester, '12-ax3-wizard');
    await drain(tester);
  });
}
