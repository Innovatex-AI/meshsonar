// Shared helpers for the cross-feature flow tests (release 0.38 A12, J1-J7): the real app (AppScope, the shell, the
// Planner) in a harness, a way to put a sheet-like screen on the root navigator (where repeater sheets and contact profiles
// live: beside the shell, not under it), and short pumps that let the planner and its toasts finish.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/plan/plan_api.dart';
import 'package:meshsonar/core/plan/plan_store.dart';
import 'package:meshsonar/core/plan_contract.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import '../ui/fakes.dart';
import '../ui/shell_test.dart' show drain;

export '../ui/fakes.dart' show Harness, tapShellTab;
export '../ui/shell_test.dart' show drain, phone;

const PlanVerifyResult flowVerify = PlanVerifyResult(
  coveredKm2: 42.5,
  bands: [PlanBandArea('fringe', 'Fringe', 10), PlanBandArea('usable', 'Usable', 20), PlanBandArea('solid', 'Solid', 12.5)],
  links: [PlanPredictedLink(publicKey: 'ab', name: 'North Ridge', km: 6.2, marginDb: 7.1)],
  newAreaKm2: 18,
  newPeople: 4200,
  provenance: PlanProvenance(terrain: 'AWS Terrain Tiles (test)'),
);

/// Opens the app on the Plan tab with the planner API answered by the harness's fake client.
Future<PlannerScreenState> openPlanner(WidgetTester tester, Harness h, {Future<void> Function()? afterPump}) async {
  PlannerScreen.testApi = (s) => PlanApi(h.client, PlanStore(), clock: () => h.clockNow);
  addTearDown(() => PlannerScreen.testApi = null);
  await h.pumpApp(tester);
  await afterPump?.call();
  await tapShellTab(tester, 'Plan');
  await tester.pump(const Duration(milliseconds: 100));
  final st = tester.state<PlannerScreenState>(find.byType(PlannerScreen));
  for (var i = 0; i < 5 && st.controller == null; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(st.controller, isNotNull, reason: 'the planner opened a plan');
  return st;
}

/// The shell controller of the running app.
ShellController shellOf(WidgetTester tester) => ShellScope.maybeRead(tester.element(find.byKey(const Key('shell-tabs'), skipOffstage: false)))!;

/// Pushes [screen] on the root navigator (as a sheet or a pushed screen is: not under the shell) and shows it.
Future<void> pushOnRoot(WidgetTester tester, Widget screen) async {
  final ctx = tester.element(find.byKey(const Key('shell-tabs'), skipOffstage: false));
  unawaited(Navigator.of(ctx, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: SafeArea(child: screen)))));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

/// Lets the planner finish a request (its async open, a Find sites run, toasts).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(f);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> finish(WidgetTester tester) => drain(tester);

/// A harness whose server answers `my-radios` with [claimed] (the person's claimed radios).
class ClaimedHarness extends Harness {
  final List<NodeClaim> claimed = [];
  @override
  FakeCmatClient newClient(Uri u) => _ClaimedClient(u, claimed);

  /// Turns claims on for the app and loads the list (call after the app is pumped).
  Future<void> loadClaims() async {
    client.siteConfigResult = const SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'nodeClaims'});
    await state.refreshSiteConfig();
    await state.refreshUploadSiteConfig(force: true);
    await state.claims.refresh();
  }
}

class _ClaimedClient extends FakeCmatClient {
  final List<NodeClaim> claimed;
  _ClaimedClient(super.baseUrl, this.claimed);
  @override
  Future<List<NodeClaim>> myRadios(String driverKey) async => List.of(claimed);
}
