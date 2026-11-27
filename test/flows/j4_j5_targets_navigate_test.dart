// J4 and J5 (plan 4.5 item 5): a Find-sites result or a planned site can be driven to (Navigate = the Apple Maps hand-off
// DriveNextCard already uses) and shown as targets on the Drive map; the Where-to-drive card lives in the Planner's fourth
// mode and opens the Drive map with its targets. One set of coordinates all the way: the card's row, the Navigate link, the
// target on the Drive map and its sheet agree.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/ui/map/layers/plan_node_sheet.dart';
import 'package:meshsonar/ui/map/layers/plan_overlay.dart';
import 'package:meshsonar/ui/map/layers/registry.dart' show kPlanLayerId;
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/plan/node_list.dart' show planDriveOverlay;
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/shell/drive_next_card.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import 'flow_kit.dart';

CoverageCell _cell(double lat, double lon) =>
    CoverageCell(lat: lat, lon: lon, pings: 6, heard: 0, bestSnr: null, medianSnr: null, repeaters: 0, lastAt: '2026-10-30T12:00:00Z');

/// What the Drive map holds or has been asked to hold (it takes the request when it is built).
List<MapFocusTarget> _driveTargets() =>
    MainMapFocus.overlay.targets.isNotEmpty ? MainMapFocus.overlay.targets : (MainMapFocus.notifier.value?.targets ?? const <MapFocusTarget>[]);

void _clearMap() {
  MainMapFocus.overlay.clear();
  MainMapFocus.notifier.value = null;
}

void main() {
  setUp(_clearMap);
  tearDown(_clearMap);

  group('J4 targets from the plan', () {
    test('Find-sites results become numbered targets in rank order; only planned plan nodes are targets', () {
      const sites = [
        PlanSite(id: 's1', at: PlanPoint(40.2, -82.8), score: 88, reason: 'a'),
        PlanSite(id: 's2', at: PlanPoint(40.0, -83.0), score: 61, reason: 'b'),
      ];
      expect([for (final t in focusTargetsFromSites(sites)) (t.id, t.label, t.at)],
          [('s1', '#1', const LatLng(40.2, -82.8)), ('s2', '#2', const LatLng(40.0, -83.0))]);
      final nodes = [
        PlanNode(id: 'p', name: 'Planned hill', lat: 40.3, lon: -82.7, status: PlanNodeStatus.planned),
        PlanNode(id: 'i', name: 'Built tower', lat: 40.4, lon: -82.6, status: PlanNodeStatus.installed),
        PlanNode(id: 'e', name: 'Network repeater', lat: 40.5, lon: -82.5, status: PlanNodeStatus.existing, existingKey: 'ab' * 32),
      ];
      expect([for (final t in focusTargetsFromPlanNodes(nodes)) t.label], ['Planned hill']);
      expect(focusTargetsFromSites(const []), isEmpty);
    });

    testWidgets('Find sites in the planner, then the same results on the Drive map (plan layer, camera on the first)', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      const sites = [
        PlanSite(id: 's1', at: PlanPoint(40.2, -82.8), score: 88, reason: '+14 km² of new coverage', heightAboveM: 35),
        PlanSite(id: 's2', at: PlanPoint(40.0, -83.0), score: 61, reason: 'Second path for Delaware'),
      ];
      h.client.planSuggestResult = const PlanSuggestResult(pool: 40, sites: sites);
      final st = await openPlanner(tester, h);
      await tester.tap(find.byKey(const Key('planner-mode-findSites')));
      await settle(tester);
      await tapKey(tester, 'sites-run');
      await settle(tester);
      expect(st.overlayForTest.targets.map((t) => t.at), [const LatLng(40.2, -82.8), const LatLng(40.0, -83.0)], reason: 'the planner map draws them');

      // The planner's targets go to the Drive map as they are.
      final ctx = tester.element(find.byType(PlannerScreen));
      expect(showTargetsOnDriveMap(ctx, st.overlayForTest.targets), isTrue);
      await settle(tester);
      expect(shellOf(tester).tab, AppTab.drive);
      expect(_driveTargets().map((t) => t.at), [const LatLng(40.2, -82.8), const LatLng(40.0, -83.0)]);
      expect(MainMapFocus.overlay.requestedLayers.contains(kPlanLayerId) || (MainMapFocus.notifier.value?.showLayers.contains(kPlanLayerId) ?? false), isTrue);
      await finish(tester);
    });

    testWidgets('the target sheet of the Drive map: distance and Navigate (Apple Maps directions to that spot)', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      final target = MapFocusTarget(id: 's1', at: const LatLng(40.2, -82.8), label: '#1');
      final node = PlanOverlayNode(id: target.id, name: 'Site #1', at: target.at, kind: PlanOverlayNodeKind.target);
      await pushOnRoot(tester, PlanNodeSheet(node: node, here: const LatLng(40.126, -82.93), openUrl: (u) async {
        h.openedUrls.add(u);
        return true;
      }));
      expect(find.byKey(const Key('plan-node-sheet-distance')), findsOneWidget);
      await tapKey(tester, 'plan-node-sheet-navigate');
      final u = h.openedUrls.last;
      expect(u.host, 'maps.apple.com');
      expect(u.queryParameters['daddr'], '40.200000,-82.800000');
      expect(u.queryParameters['dirflg'], 'd');
      await finish(tester);
    });

    testWidgets('DriveTargetActions for a planned site: Navigate opens Maps; Show on the Drive map opens the Drive tab with that target', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      final site = PlanNode(id: 'p', name: 'Planned hill', lat: 40.3, lon: -82.7, status: PlanNodeStatus.planned);
      await pushOnRoot(tester, DriveTargetActions(name: site.name, lat: site.lat, lon: site.lon, targets: focusTargetsFromPlanNodes([site])));
      await tapKey(tester, 'drive-target-navigate');
      final u = h.openedUrls.single;
      expect(u.queryParameters['daddr'], '40.300000,-82.700000');
      expect(u.queryParameters['q'], 'MeshSonar: Planned hill');
      await tapKey(tester, 'drive-target-show-map');
      expect(shellOf(tester).tab, AppTab.drive);
      await settle(tester);
      expect(find.byKey(const Key('drive-target-navigate')), findsNothing, reason: 'the screen above the tabs closed');
      expect(_driveTargets().single.label, 'Planned hill');
      await finish(tester);
    });

    testWidgets('Maps failing to open says so; with no targets or no shell nothing happens', (tester) async {
      phone(tester);
      final h = Harness()..browserWorks = false;
      await h.pumpApp(tester);
      await pushOnRoot(tester, const DriveTargetActions(name: 'Spot', lat: 40.3, lon: -82.7));
      await tapKey(tester, 'drive-target-navigate');
      expect(find.text('Could not open Maps.'), findsOneWidget);
      final ctx = tester.element(find.byKey(const Key('drive-target-navigate')));
      expect(showTargetsOnDriveMap(ctx, const []), isFalse);
      expect(find.byKey(const Key('drive-target-navigate')), findsOneWidget, reason: 'nothing to show: the screen stays');
      await finish(tester);
    });
  });

  group('J4 the plan\'s own nodes reach the Drive map', () {
    testWidgets('the selected planned spot: its editor has Navigate (opens Maps) and Show on the Drive map (that spot as the target)', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final n = st.controller!.addNode(name: 'Hill site', lat: 40.31, lon: -82.71);
      st.selectNodeForTest(n.id);
      await settle(tester);
      // Build 77 (round 4 P-V1): the selected spot is one line (name, Edit, close); Navigate is in Edit.
      expect(find.descendant(of: find.byKey(const Key('plan-selected')), matching: find.byKey(const Key('plan-node-drive'))), findsNothing);
      await tapKey(tester, 'plan-selected-edit');
      await settle(tester);
      final card = find.byKey(const Key('node-editor'));
      expect(tester.widget(find.descendant(of: card, matching: find.byKey(const Key('drive-target-navigate')))), isA<OutlinedButton>(),
          reason: 'Navigate is outlined: amber only for warnings');
      expect(find.descendant(of: card, matching: find.byKey(const Key('plan-node-drive'))), findsOneWidget);
      await tester.tap(find.descendant(of: card, matching: find.byKey(const Key('drive-target-navigate'))));
      await settle(tester);
      expect(h.openedUrls.last.queryParameters['daddr'], '40.310000,-82.710000');
      await tester.tap(find.descendant(of: card, matching: find.byKey(const Key('drive-target-show-map'))));
      await settle(tester);
      expect(shellOf(tester).tab, AppTab.drive);
      final t = _driveTargets();
      expect([for (final x in t) (x.id, x.label, x.at)], [(n.id, 'Hill site', const LatLng(40.31, -82.71))]);
      await finish(tester);
    });

    testWidgets('an installed node gets Navigate only; a node whose position is hidden offers nothing', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      final built = c.addNode(name: 'Built tower', lat: 40.4, lon: -82.6);
      c.updateNode(built.id, (x) => x.copyWith(status: PlanNodeStatus.installed));
      st.selectNodeForTest(built.id);
      await settle(tester);
      await tapKey(tester, 'plan-selected-edit');
      await settle(tester);
      expect(find.byKey(const Key('drive-target-navigate')), findsOneWidget);
      expect(find.byKey(const Key('drive-target-show-map')), findsNothing);
      Navigator.of(tester.element(find.byKey(const Key('node-editor')))).pop();
      await settle(tester);

      final hidden = c.addNode(name: 'Secret \u{1F6AB}', lat: 40.5, lon: -82.5);
      st.selectNodeForTest(hidden.id);
      await settle(tester);
      expect(find.byKey(const Key('plan-selected')), findsOneWidget);
      await tapKey(tester, 'plan-selected-edit');
      await settle(tester);
      expect(find.byKey(const Key('node-editor')), findsOneWidget);
      expect(find.byKey(const Key('plan-node-drive')), findsNothing);
      expect(find.byKey(const Key('drive-target-navigate')), findsNothing);
      expect(find.byKey(const Key('drive-target-show-map')), findsNothing);
      expect(MainMapFocus.notifier.value, isNull, reason: 'nothing was sent to the Drive map');
      await finish(tester);
    });

    testWidgets('the plan menu: Show plan on the Drive map sends every planned site (not hidden ones) and the saved plan id', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      final st = await openPlanner(tester, h);
      final c = st.controller!;
      final a = c.addNode(name: 'Site A', lat: 40.2, lon: -82.8);
      final b = c.addNode(name: 'Site B', lat: 40.0, lon: -83.0);
      c.addNode(name: 'Hidden \u{1F6AB}', lat: 40.1, lon: -82.9);
      final built = c.addNode(name: 'Built', lat: 40.3, lon: -82.7);
      c.updateNode(built.id, (x) => x.copyWith(status: PlanNodeStatus.installed));
      await settle(tester);
      await tapKey(tester, 'plan-menu');
      await settle(tester);
      await tapKey(tester, 'plan-menu-drive-map');
      await settle(tester);
      expect(shellOf(tester).tab, AppTab.drive);
      expect(_driveTargets().map((t) => t.id), [a.id, b.id]);
      // The saved plan resolves for the Drive map: its installed node is drawn, its planned and hidden ones are not doubled.
      final drawn = await MainMapFocus.overlay.resolvePlan!(c.plan.id);
      expect(drawn!.nodes.map((n) => n.id), [built.id]);
      expect(planDriveOverlay(c.plan).nodes.map((n) => n.id), [built.id]);
      await finish(tester);
    });

    testWidgets('a plan with only hidden or built nodes has no Show plan on the Drive map entry', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      final st = await openPlanner(tester, h);
      st.controller!.addNode(name: 'Hidden \u{1F6AB}', lat: 40.1, lon: -82.9);
      await settle(tester);
      await tapKey(tester, 'plan-menu');
      await settle(tester);
      expect(find.byKey(const Key('plan-menu-sheet')), findsOneWidget);
      expect(find.byKey(const Key('plan-menu-drive-map')), findsNothing);
      await finish(tester);
    });
  });

  group('J5 Where to drive in Plan mode', () {
    testWidgets('the card is the planner\'s fourth mode; its rows, the Navigate link and the Drive map targets are the same places', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.publicCoverageResult = PublicCoverage(
        asOf: '2026-10-31T00:00:00Z',
        grid: const CoverageGrid.square(cellDeg: 0.005),
        // The fake phone is at 40.126, -82.93: one silent cell 1.1 km north.
        cells: [_cell(40.136, -82.93)],
      );
      final st = await openPlanner(tester, h);
      expect(shellOf(tester).tab, AppTab.plan);
      await tester.tap(find.byKey(const Key('planner-mode-whereToDrive')));
      await settle(tester);
      expect(find.byKey(const Key('plan-drive-next')), findsOneWidget);
      expect(find.byKey(const Key('plan-target-0')), findsOneWidget);
      expect(st.overlayForTest.targets, isNotEmpty);
      // Round 4 P-V3: no small map in the panel; a tap on a row centres the big map on that place.
      expect(find.byKey(const Key('plan-drive-next-map')), findsNothing);
      await tapKey(tester, 'plan-target-0');
      await settle(tester);
      final centre = st.mapCentreForTest!;
      expect(centre.latitude, closeTo(40.136, 0.002));
      expect(centre.longitude, closeTo(-82.93, 0.002));

      await tapKey(tester, 'plan-navigate-0');
      final nav = h.openedUrls.last;
      expect(nav.queryParameters['daddr'], '40.136000,-82.930000');

      await tapKey(tester, 'drive-next-show-map');
      await settle(tester);
      expect(shellOf(tester).tab, AppTab.drive);
      final t = _driveTargets();
      expect(t, isNotEmpty);
      expect('${t.first.at.latitude.toStringAsFixed(6)},${t.first.at.longitude.toStringAsFixed(6)}', nav.queryParameters['daddr'],
          reason: 'the Drive map target is the place Navigate goes to');
      await finish(tester);
    });

    testWidgets('no position fix: the card says what to do and offers no Drive-map button', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.location.permission = false;
      h.location.currentFix = () => null;
      await openPlanner(tester, h);
      await tester.tap(find.byKey(const Key('planner-mode-whereToDrive')));
      await settle(tester);
      expect(find.byKey(const Key('plan-drive-next')), findsOneWidget);
      expect(find.byKey(const Key('drive-next-show-map')), findsNothing);
      await finish(tester);
    });
  });
}
