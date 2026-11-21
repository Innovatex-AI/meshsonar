// The Planner (release 0.38 A7): the Plan tab's root is one map with the planner sheet and the four mode chips, acting on
// one Plan. These tests drive the real app (AppScope, the shell, the CoverageMap) with the fake CmatClient answering the
// planner endpoints.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/plan_api.dart';
import 'package:meshsonar/core/plan/plan_codec.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan/plan_store.dart';
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/map/coverage_map.dart' show CoverageMap;
import 'package:meshsonar/ui/map/layers/map_layer.dart' show LongPressHit;
import 'package:meshsonar/ui/map/layers/registry.dart' show kPlanLayerId;
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/plan/plan_modes.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/plan/planner_sheet.dart';
import 'package:meshsonar/ui/shell/drive_next_card.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import '../fakes.dart';
import '../shell_test.dart' show phone, drain;

const _profile = PlanProfile(distanceKm: [0, 1, 2, 3], groundM: [200, 210, 205, 200]);

PlanLinkResult _link({PlanVerdict verdict = PlanVerdict.likely, PlanMeasured? measured}) => PlanLinkResult(
      km: 3.1,
      profile: _profile,
      fresnelClearancePct: 72,
      tightest: const PlanTightestPoint(km: 1.2, raiseM: 4),
      ridge: const PlanRidge(km: 1.2),
      odds: 0.81,
      verdict: verdict,
      marginDb: 9.5,
      measured: measured,
      provenance: const PlanProvenance(terrain: 'AWS Terrain Tiles (test)'),
    );

const _verify = PlanVerifyResult(
  coveredKm2: 42.5,
  bands: [PlanBandArea('fringe', 'Fringe', 10), PlanBandArea('usable', 'Usable', 20), PlanBandArea('solid', 'Solid', 12.5)],
  links: [PlanPredictedLink(publicKey: 'ab', name: 'North Ridge', km: 6.2, marginDb: 7.1)],
  newAreaKm2: 18,
  newPeople: 4200,
  provenance: PlanProvenance(terrain: 'AWS Terrain Tiles (test)'),
);

/// Opens the Plan tab with the planner API answered by [h]'s fake client (no network).
Future<PlannerScreenState> openPlanner(WidgetTester tester, Harness h) async {
  PlannerScreen.testApi = (s) => PlanApi(h.client, PlanStore(), clock: () => h.clockNow);
  addTearDown(() => PlannerScreen.testApi = null);
  await h.pumpApp(tester);
  await tapShellTab(tester, 'Plan');
  await tester.pump(const Duration(milliseconds: 100));
  final st = tester.state<PlannerScreenState>(find.byType(PlannerScreen));
  for (var i = 0; i < 5 && st.controller == null; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(st.controller, isNotNull, reason: 'the planner opened a plan');
  return st;
}

Future<void> tapIn(WidgetTester tester, Finder f) async {
  await tester.ensureVisible(f);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(f);
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  group('shell', () {
    testWidgets('opens on the map with the sheet at Medium, Link picked, the empty plan offering one-tap starts', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      expect(find.byKey(const Key('planner-map')), findsOneWidget);
      expect(st.mode, PlanModeId.link);
      expect(st.detent, PlannerDetent.medium);
      expect(find.byKey(const Key('planner-title')), findsOneWidget);
      expect(find.byKey(const Key('plan-quick-here')), findsOneWidget, reason: 'the phone has a fix: one tap to a result');
      expect(find.byKey(const Key('plan-quick-network')), findsOneWidget);
      expect(find.byKey(const Key('plan-mode-link')), findsOneWidget);
      expect(st.controller!.plan.radio, PlanRadio.usDefault, reason: 'no region preset in the harness');
      await drain(tester);
    });

    testWidgets('first useful result in one tap: Coverage from my location adds my spot and runs the Estimate', (tester) async {
      phone(tester);
      final h = Harness();
      h.client.planVerifyResult = _verify;
      final st = await openPlanner(tester, h);
      await tapIn(tester, find.byKey(const Key('plan-quick-here')));
      await settle(tester);
      expect(st.mode, PlanModeId.coverage);
      final n = st.controller!.nodes.single;
      expect(n.name, 'My location');
      expect(n.mine, isTrue);
      expect(h.client.planVerifyAsks, hasLength(1));
      final ask = h.client.planVerifyAsks.single;
      expect(ask.site.lat, closeTo(40.126, 1e-6));
      // Only the site and the model settings go out (privacy): the request carries no name, key or id.
      expect(jsonEncode(ask.toJson()), isNot(contains('My location')));
      expect(find.byKey(const Key('coverage-result')), findsOneWidget);
      expect(find.byKey(const Key('coverage-area')), findsOneWidget);
      expect(find.textContaining('North Ridge'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('one open panel on the Plan map: the sheet and the map share a group; a map panel opening collapses the sheet', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      await settle(tester);
      final group = MapPanelScope.maybeRead(tester.element(find.byType(PlannerSheet)))!;
      expect(identical(group, MapPanelScope.maybeRead(tester.element(find.byType(CoverageMap)))), isTrue, reason: 'the map inspector joins the same group');
      expect(st.detent, PlannerDetent.medium);
      expect(group.openId, kPlannerPanelId, reason: 'the open sheet is the map\'s open panel');
      // What the map's transient panel does when the person opens it (MapPanel claims the group).
      group.claim('drive.inspect');
      await settle(tester);
      expect(st.detent, PlannerDetent.dock, reason: 'one open panel per map');
      expect(group.openId, 'drive.inspect');
      // The person opens the sheet again: it takes the group back (the map panel collapses to its header).
      await tester.tap(find.byKey(const Key('planner-sheet-handle')));
      await settle(tester);
      expect(st.detent, PlannerDetent.medium);
      expect(group.openId, kPlannerPanelId);
      // Picking a mode opens the sheet from the screen, not the handle: the group still follows.
      group.claim('drive.inspect');
      await settle(tester);
      expect(st.detent, PlannerDetent.dock);
      await tester.tap(find.byKey(Key('planner-mode-${PlanModeId.coverage.name}')));
      await settle(tester);
      if (st.detent != PlannerDetent.dock) expect(group.openId, kPlannerPanelId);
      await drain(tester);
    });

    testWidgets('the four chips switch modes; the sheet snaps between Dock, Medium and Full', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      for (final (id, body) in [
        (PlanModeId.coverage, 'plan-mode-coverage'),
        (PlanModeId.findSites, 'plan-mode-sites'),
        (PlanModeId.whereToDrive, 'plan-mode-drive'),
        (PlanModeId.link, 'plan-mode-link'),
      ]) {
        await tester.tap(find.byKey(Key('planner-mode-${id.name}')));
        await settle(tester);
        expect(st.mode, id);
        expect(find.byKey(Key(body)), findsOneWidget, reason: id.name);
      }
      final handle = find.byKey(const Key('planner-sheet-handle'));
      final medium = tester.getSize(find.byKey(const Key('planner-sheet'))).height;
      await tester.fling(handle, const Offset(0, 300), 1500);
      await settle(tester);
      expect(st.detent, PlannerDetent.dock);
      expect(tester.getSize(find.byKey(const Key('planner-sheet'))).height, lessThan(medium));
      expect(tester.getSize(find.byKey(const Key('planner-sheet-body'))).height, 0, reason: 'the dock shows the chips only');
      expect(find.byKey(const Key('planner-mode-link')), findsOneWidget);
      await tester.fling(handle, const Offset(0, -60), 1500);
      await settle(tester);
      expect(st.detent, PlannerDetent.medium, reason: 'a flick goes one detent up');
      await tester.fling(handle, const Offset(0, -60), 1500);
      await settle(tester);
      expect(st.detent, PlannerDetent.full);
      await drain(tester);
    });

    testWidgets('VoiceOver: the handle is a button with increase / decrease; chips are buttons with their state', (tester) async {
      phone(tester);
      final h = Harness();
      final sem = tester.ensureSemantics();
      final st = await openPlanner(tester, h);
      final handle = find.byKey(const Key('planner-sheet-handle'));
      expect(tester.getSemantics(handle), isSemantics(label: 'Plan sheet, Open', isButton: true, hasTapAction: true, hasIncreaseAction: true, hasDecreaseAction: true));
      tester.semantics.performAction(find.semantics.byLabel('Plan sheet, Open'), SemanticsAction.increase);
      await settle(tester);
      expect(st.detent, PlannerDetent.full);
      tester.semantics.performAction(find.semantics.byLabel('Plan sheet, Full'), SemanticsAction.decrease);
      await settle(tester);
      expect(st.detent, PlannerDetent.medium);
      expect(find.bySemanticsLabel('Coverage mode'), findsOneWidget);
      expect(find.bySemanticsLabel('Where to drive mode'), findsOneWidget);
      sem.dispose();
      await drain(tester);
    });
  });

  group('nodes', () {
    testWidgets('a long-press on the map drops a planned node (Undo takes it back); it shows on the plan layer', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      await tester.longPressAt(const Offset(200, 220));
      await settle(tester);
      final c = st.controller!;
      // A long-press on the bare map: one planned node (the map may resolve the long-press anywhere on screen).
      expect(c.nodes, hasLength(1));
      expect(c.nodes.single.status, PlanNodeStatus.planned);
      expect(c.nodes.single.name, 'Site 1');
      expect(st.selectedNodeId, c.nodes.single.id);
      expect(find.byKey(const Key('plan-selected')), findsOneWidget);
      expect(find.byKey(Key('plan-list-node-${c.nodes.single.id}')), findsOneWidget);
      expect(find.byKey(Key('plan-node-${c.nodes.single.id}')), findsOneWidget, reason: 'the marker on the plan layer');
      expect(find.text('Dropped Site 1.'), findsOneWidget);
      c.undo();
      await settle(tester);
      expect(c.nodes, isEmpty);
      await drain(tester);
    });

    testWidgets('node editor: rename, height, status; delete with Undo', (tester) async {
      phone(tester, h: 1000);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      final n = c.addNode(name: 'Water tower', lat: 40.1, lon: -82.9);
      await settle(tester);
      await tapIn(tester, find.byKey(Key('plan-node-edit-${n.id}')));
      await settle(tester);
      expect(find.byKey(const Key('node-editor')), findsOneWidget);
      await tester.tap(find.text('Installed'));
      await settle(tester);
      expect(c.plan.node(n.id)!.status, PlanNodeStatus.installed);
      await tester.enterText(find.byKey(const Key('node-name')), 'Tower 2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(c.plan.node(n.id)!.name, 'Tower 2');
      final slider = find.byKey(const Key('node-height-slider'));
      await tester.scrollUntilVisible(slider, 120, scrollable: find.descendant(of: find.byKey(const Key('node-editor')), matching: find.byType(Scrollable)).first);
      await settle(tester);
      await tester.drag(slider, const Offset(400, 0));
      await settle(tester);
      expect(c.plan.node(n.id)!.heightM, isNotNull);
      expect(c.plan.node(n.id)!.heightM, greaterThan(plannedHeightM));
      await tester.tap(find.byKey(const Key('node-delete')));
      await settle(tester);
      expect(c.nodes, isEmpty);
      expect(find.text('Deleted Tower 2.'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await settle(tester);
      expect(c.nodes.single.name, 'Tower 2');
      await drain(tester);
    });

    testWidgets('move on the map: the crosshair and Set here put the node where the map is centred', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      final n = c.addNode(name: 'Mast', lat: 40.1, lon: -82.9);
      await settle(tester);
      st.selectNodeForTest(n.id);
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('plan-selected-edit')));
      await settle(tester);
      await tester.tap(find.byKey(const Key('node-move')));
      await settle(tester);
      expect(find.byKey(const Key('planner-move-bar')), findsOneWidget);
      expect(find.byKey(const Key('planner-crosshair')), findsOneWidget);
      expect(st.detent, PlannerDetent.dock);
      // Pan the map under the crosshair, then set.
      await tester.drag(find.byKey(const Key('planner-map')), const Offset(-120, 60), warnIfMissed: false);
      await settle(tester);
      await tester.tap(find.byKey(const Key('planner-move-set')));
      await settle(tester);
      final moved = c.plan.node(n.id)!;
      expect(moved.lat == 40.1 && moved.lon == -82.9, isFalse, reason: 'the node moved to the crosshair');
      expect(find.byKey(const Key('planner-move-bar')), findsNothing);
      c.undo();
      expect(c.plan.node(n.id)!.lat, 40.1);
      await drain(tester);
    });

    testWidgets('existing-node picker: my radios first, then the network nearest first; a pick joins as an existing node', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      await tapIn(tester, find.byKey(const Key('plan-quick-network')));
      await settle(tester);
      expect(find.byKey(const Key('node-picker')), findsOneWidget);
      // No repeater sync in this harness: the honest empty state, with the way forward.
      expect(find.byKey(const Key('node-picker-empty')), findsOneWidget);
      expect(st.controller!.nodes, isEmpty);
      await drain(tester);
    });
  });

  group('modes', () {
    testWidgets('Link: two nodes are checked through plan-link (coordinates, heights and the radio only); verdict, raise, ridge, measured', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planLinkResult = _link(measured: PlanMeasured(echoes: 12, meanSnr: 4.5, lastAt: DateTime.utc(2026, 11, 1), source: 'drives'));
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      c.addNode(name: 'Hill', lat: 40.10, lon: -82.90, heightM: 12);
      c.addNode(name: 'Barn', lat: 40.12, lon: -82.87);
      await settle(tester);
      expect(h.client.planLinkAsks, hasLength(1), reason: 'two ends: checked at once');
      final ask = h.client.planLinkAsks.single.toJson();
      expect(ask.keys.toSet(), {'a', 'b', 'haM', 'hbM', 'radio', 'clutter', 'direction'});
      expect(ask['haM'], 12);
      expect(find.byKey(const Key('link-result')), findsOneWidget);
      expect(find.text('Works (Estimate)'), findsOneWidget);
      expect(find.byKey(const Key('link-raise')), findsOneWidget);
      expect(find.byKey(const Key('link-ridge')), findsOneWidget);
      expect(find.byKey(const Key('link-measured')), findsOneWidget);
      // The pair is drawn on the plan layer coloured by its verdict.
      expect(st.overlayForTest.plan.links.single.verdict.name, 'likely');
      // Tapping a node on the map while Link is open makes it an end (B first, then A): a new check runs.
      final third = c.addNode(name: 'Silo', lat: 40.13, lon: -82.86);
      await settle(tester);
      expect(st.hooksForTest.onNodeTap!(third.id), isTrue);
      await settle(tester);
      expect(h.client.planLinkAsks, hasLength(2));
      expect(h.client.planLinkAsks.last.b.lat, 40.13);
      expect(st.overlayForTest.plan.links.single.toId, third.id);
      await drain(tester);
    });

    testWidgets('Link: the server refusing shows the error with a retry, never an endless spinner', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planLinkError = CmatException('The ends are outside the region.', status: 422);
      final st = await openPlanner(tester, h);
      st.controller!.addNode(name: 'A', lat: 40.10, lon: -82.90);
      st.controller!.addNode(name: 'B', lat: 40.12, lon: -82.87);
      await settle(tester);
      expect(find.byKey(const Key('link-error')), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('Find sites: ranks the view, draws numbered targets, Add puts a site in the plan', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = const PlanSuggestResult(pool: 40, sites: [
        PlanSite(id: 's1', at: PlanPoint(40.2, -82.8), score: 88, reason: '+14 km² of new coverage; reaches 3 repeaters', heightAboveM: 35),
        PlanSite(id: 's2', at: PlanPoint(40.0, -83.0), score: 61, reason: 'Second path for Delaware'),
      ]);
      final st = await openPlanner(tester, h);
      await tester.tap(find.byKey(const Key('planner-mode-findSites')));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('sites-goal-coverage')));
      expect(st.controller!.plan.goal, PlanGoal.coverage);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      final ask = h.client.planSuggestAsks.single;
      expect(ask.goal, PlanGoal.coverage);
      expect(ask.bounds.north, greaterThan(ask.bounds.south));
      expect(find.byKey(const Key('site-s1')), findsOneWidget);
      expect(st.overlayForTest.targets.map((t) => t.label), ['#1', '#2']);
      await tapIn(tester, find.byKey(const Key('site-add-s1')));
      await settle(tester);
      final n = st.controller!.nodes.single;
      expect(n.name, 'Site 1');
      expect(n.lat, 40.2);
      await drain(tester);
    });

    testWidgets('Find sites: a region still building its table says so', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = const PlanSuggestResult(preparing: true);
      await openPlanner(tester, h);
      await tester.tap(find.byKey(const Key('planner-mode-findSites')));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      expect(find.byKey(const Key('sites-preparing')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('Where to drive hosts the card and opens the Drive map with the targets on its plan layer', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      DriveNextCard.testMap = (c, me, t) => SizedBox(key: const Key('fake-map'), height: 10, child: Text('${t.length} targets'));
      addTearDown(() => DriveNextCard.testMap = null);
      h.client.publicCoverageResult = PublicCoverage(
        asOf: '2026-10-31T00:00:00Z',
        grid: const CoverageGrid.square(cellDeg: 0.005),
        cells: [CoverageCell(lat: 40.136, lon: -82.93, pings: 6, heard: 0, bestSnr: null, medianSnr: null, repeaters: 0, lastAt: '2026-10-30T12:00:00Z')],
      );
      final st = await openPlanner(tester, h);
      await tester.tap(find.byKey(const Key('planner-mode-whereToDrive')));
      await settle(tester);
      expect(find.byKey(const Key('plan-drive-next')), findsOneWidget);
      expect(st.overlayForTest.targets, isNotEmpty, reason: 'the targets show on the planner map too');
      await tapIn(tester, find.byKey(const Key('drive-next-show-map')));
      await settle(tester);
      final shell = ShellScope.maybeRead(tester.element(find.byType(PlannerScreen, skipOffstage: false)))!;
      expect(shell.tab, AppTab.drive);
      final req = MainMapFocus.notifier.value ?? MainMapFocus.overlay.targets;
      expect(req, isNotNull);
      expect(MainMapFocus.overlay.targets.isNotEmpty || (MainMapFocus.notifier.value?.targets.isNotEmpty ?? false), isTrue);
      expect(MainMapFocus.overlay.requestedLayers.contains(kPlanLayerId) || (MainMapFocus.notifier.value?.showLayers.contains(kPlanLayerId) ?? false), isTrue);
      MainMapFocus.overlay.clear();
      MainMapFocus.notifier.value = null;
      await drain(tester);
    });

    testWidgets('radio and clutter: the plan takes a preset and the sliders; every Estimate uses them', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      final st = await openPlanner(tester, h);
      await tapIn(tester, find.byKey(const Key('plan-radio-summary')));
      await settle(tester);
      expect(find.byKey(const Key('plan-settings')), findsOneWidget);
      await tester.tap(find.byKey(const Key('plan-radio-eu')));
      await settle(tester);
      expect(st.controller!.plan.radio.freqMHz, 869.618);
      expect(st.controller!.plan.radio.sf, 8);
      await drain(tester);
    });
  });

  group('requests', () {
    testWidgets('Add to plan, Link to…, a point and Plan from here all land in the planner', (tester) async {
      phone(tester);
      final h = Harness();
      h.client.planVerifyResult = _verify;
      final st = await openPlanner(tester, h);
      final shell = ShellScope.maybeRead(tester.element(find.byType(PlannerScreen)))!;
      const key = 'aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44';
      shell.openPlan(const PlanRequest.addNode(PlanNodeSeed(key: key, name: 'North Ridge', lat: 40.2, lon: -82.95, source: 'repeater')));
      await settle(tester);
      final c = st.controller!;
      expect(c.nodes.single.existingKey, key);
      expect(c.nodes.single.status, PlanNodeStatus.existing);
      shell.openPlan(const PlanRequest.linkTo(PlanNodeSeed(name: 'Alex', lat: 40.15, lon: -82.91, source: 'contact')));
      await settle(tester);
      expect(st.mode, PlanModeId.link);
      expect(c.nodes.last.role, PlanNodeRole.handheld);
      shell.openPlan(const PlanRequest.point(PlanNodeSeed(name: 'From chat', lat: 40.11, lon: -82.99, source: 'chat')));
      await settle(tester);
      expect(c.nodes.last.name, 'From chat');
      expect(c.nodes.last.status, PlanNodeStatus.planned);
      final before = c.plan.id;
      shell.openPlan(const PlanRequest.planFrom(PlanNodeSeed(key: key, name: 'North Ridge', lat: 40.2, lon: -82.95, source: 'repeater')));
      await settle(tester);
      expect(c.plan.id, isNot(before), reason: 'Plan from here starts a new plan');
      expect(c.plan.name, 'From North Ridge');
      expect(st.mode, PlanModeId.coverage);
      expect(h.client.planVerifyAsks, isNotEmpty, reason: 'and runs its coverage');
      await drain(tester);
    });

    testWidgets('a request sent before the tab was ever built is taken when the planner opens', (tester) async {
      phone(tester);
      final h = Harness();
      PlannerScreen.testApi = (s) => PlanApi(h.client, PlanStore());
      addTearDown(() => PlannerScreen.testApi = null);
      await h.pumpApp(tester);
      final shell = ShellScope.maybeRead(tester.element(find.byKey(const Key('shell-tabs'))))!;
      shell.openPlan(const PlanRequest.addNode(PlanNodeSeed(name: 'Pin 7', lat: 40.3, lon: -82.7, source: 'pin')));
      await settle(tester);
      final st = tester.state<PlannerScreenState>(find.byType(PlannerScreen));
      expect(st.controller!.nodes.single.name, 'Pin 7');
      expect(shell.pendingPlan, isNull);
      await drain(tester);
    });

    testWidgets('a shared plan link opens as a new saved plan; a bad link says so', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final shell = ShellScope.maybeRead(tester.element(find.byType(PlannerScreen)))!;
      final shared = Plan(
        id: 'p_shared',
        name: 'Club plan',
        nodes: const [PlanNode(id: 'n1', name: 'Tower', lat: 40.2, lon: -82.9), PlanNode(id: 'n2', name: 'Mine', lat: 40.1, lon: -82.8, mine: true)],
        createdAt: DateTime.utc(2026, 11, 1),
      );
      final uri = planShareUri(encodePlanShare(shared).code);
      shell.openPlan(PlanRequest.openLink(uri));
      await settle(tester);
      expect(st.controller!.plan.name, 'Club plan');
      expect(st.controller!.plan.id, isNot('p_shared'), reason: 'kept under a fresh id');
      expect(st.controller!.nodes, hasLength(2));
      expect(find.textContaining('Opened the shared plan'), findsOneWidget);
      expect(await h.planRepository.read(st.controller!.plan.id), isNotNull);
      shell.openPlan(PlanRequest.openLink(Uri.parse('https://meshsonar.com/share/plan#notaplan')));
      await settle(tester);
      expect(find.textContaining('could not be read'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the plan is saved as it changes and reopens next time; open a saved plan by id', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      final first = c.plan.id;
      c.addNode(name: 'Kept', lat: 40.0, lon: -83.0);
      await tester.pump(const Duration(seconds: 1));
      expect(await h.planRepository.read(first), contains('Kept'));
      final other = Plan(id: 'p_other', name: 'Other plan', createdAt: DateTime.utc(2026, 1, 1));
      await h.planRepository.write(other.id, jsonEncode(other.toJson()));
      final shell = ShellScope.maybeRead(tester.element(find.byType(PlannerScreen)))!;
      shell.openPlan(const PlanRequest.openSaved('p_other'));
      await settle(tester);
      expect(c.plan.name, 'Other plan');
      shell.openPlan(const PlanRequest.openSaved('p_missing'));
      await settle(tester);
      expect(find.textContaining('no longer on this phone'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a long-press while another mode takes map points goes to that mode first', (tester) async {
      phone(tester);
      final h = Harness();
      final st = await openPlanner(tester, h);
      var got = 0;
      st.hooksForTest.onMapPoint = (_) {
        got++;
        return true;
      };
      final ok = await st.longPressForTest(const LongPressHit(lat: 40.5, lon: -82.5));
      expect(ok, isTrue);
      expect(got, 1);
      expect(st.controller!.nodes, isEmpty);
      await drain(tester);
    });
  });

  group('Dynamic Type', () {
    for (final scale in [1.0, 2.35]) {
      testWidgets('no overflow at ${scale}x text in every mode, with nodes and a result', (tester) async {
        phone(tester, scale: scale, w: 390, h: 844);
        final h = Harness();
        h.client.planLinkResult = _link();
        h.client.planVerifyResult = _verify;
        final st = await openPlanner(tester, h);
        st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: 40.10, lon: -82.90);
        st.controller!.addNode(name: 'Barn', lat: 40.12, lon: -82.87);
        await settle(tester);
        for (final id in PlanModeId.values) {
          await tester.ensureVisible(find.byKey(Key('planner-mode-${id.name}')));
          await tester.tap(find.byKey(Key('planner-mode-${id.name}')));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '${id.name} at ${scale}x');
        }
        expect(PlannerSheetMetrics.compactModes(tester.element(find.byType(PlannerScreen))), scale >= 1.35);
        await drain(tester);
      });

      testWidgets('no overflow at ${scale}x text in the node editor, the picker and the radio settings', (tester) async {
        phone(tester, scale: scale, w: 390, h: 844);
        final h = Harness();
        final st = await openPlanner(tester, h);
        final n = st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: 40.10, lon: -82.90);
        await settle(tester);
        await tapIn(tester, find.byKey(Key('plan-node-edit-${n.id}')));
        await settle(tester);
        expect(find.byKey(const Key('node-editor')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'editor at ${scale}x');
        await tester.tapAt(const Offset(4, 60));
        await settle(tester);
        await tapIn(tester, find.byKey(const Key('plan-node-add')));
        await settle(tester);
        expect(find.byKey(const Key('node-picker')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'picker at ${scale}x');
        await tester.tapAt(const Offset(4, 60));
        await settle(tester);
        await tapIn(tester, find.byKey(const Key('plan-radio-summary')));
        await settle(tester);
        expect(find.byKey(const Key('plan-settings')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'settings at ${scale}x');
        await drain(tester);
      });
    }
  });
}
