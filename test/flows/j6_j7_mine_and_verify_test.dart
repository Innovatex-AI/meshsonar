// J6 and J7 (plan 4.5 item 5).
// J6: a plan node whose key is one of the person's claimed radios (`my-radios`) is `mine`; the planner resolves it when a node
//     joins and whenever a plan opens, and an ended claim stops counting.
// J7: after an install the Verify loop compares measured drive data with the prediction. The display is A9's; here is the data
//     path that exists today: an installed plan node, the measured coverage the app holds (network coverage cells, the
//     `coverage_attempt` rollup) and calibrationConfidence turning them into "N drive cells within 2 km" for that node.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/plan/plan_analysis.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import 'flow_kit.dart';

String k(String c) => c * 64;

NodeClaim claim(String c, {bool ended = false, ClaimNodeType type = ClaimNodeType.repeater, String? name}) =>
    NodeClaim(pubkey: k(c), nodeType: type, method: ClaimMethod.advert, displayName: name, ended: ended);

CoverageCell cell(double lat, double lon, {int heard = 1}) =>
    CoverageCell(lat: lat, lon: lon, pings: 8, heard: heard, bestSnr: 4, medianSnr: 3, repeaters: 1, lastAt: '2026-11-10T12:00:00Z');

void main() {
  group('J6 mine from claimed radios', () {
    test('resolveMine: a claimed key becomes mine, an unclaimed or ended one is not, a keyless site keeps what the person set', () {
      final plan = Plan(id: 'p', createdAt: DateTime.utc(2026, 11, 15), nodes: [
        PlanNode(id: 'a', name: 'Mine', lat: 40.1, lon: -82.9, status: PlanNodeStatus.existing, existingKey: k('a')),
        PlanNode(id: 'b', name: 'Not mine', lat: 40.2, lon: -82.9, status: PlanNodeStatus.existing, existingKey: k('b')),
        PlanNode(id: 'c', name: 'Was mine', lat: 40.3, lon: -82.9, status: PlanNodeStatus.existing, existingKey: k('c'), mine: true),
        PlanNode(id: 'd', name: 'Pin', lat: 40.4, lon: -82.9, mine: true),
      ]);
      final out = resolveMine(plan, [claim('a'), claim('c', ended: true)]);
      expect({for (final n in out.nodes) n.id: n.mine}, {'a': true, 'b': false, 'c': false, 'd': true});
      expect(identical(resolveMine(out, [claim('a'), claim('c', ended: true)]), out), isTrue, reason: 'nothing to change: the same plan');
    });

    testWidgets('a repeater added to the plan from anywhere is mine when claimed, and only then', (tester) async {
      phone(tester);
      final h = ClaimedHarness()..approveKey();
      h.claimed.addAll([claim('a'), claim('c', ended: true)]);
      final st = await openPlanner(tester, h, afterPump: h.loadClaims);
      expect(h.state.claims.claims, hasLength(2), reason: 'my-radios loaded');
      final shell = shellOf(tester);
      for (final (key, name) in [(k('a'), 'My hill'), (k('b'), 'Somebody else'), (k('c'), 'Released')]) {
        shell.openPlan(PlanRequest.addNode(PlanNodeSeed(key: key, name: name, lat: 40.2, lon: -82.95, source: 'repeater')));
        await settle(tester);
      }
      final mine = {for (final n in st.controller!.nodes) n.name: n.mine};
      expect(mine, {'My hill': true, 'Somebody else': false, 'Released': false});
      await finish(tester);
    });

    testWidgets('a claim made after the node joined: a saved plan reopened picks the claim up', (tester) async {
      phone(tester);
      final h = ClaimedHarness()..approveKey();
      final st = await openPlanner(tester, h, afterPump: h.loadClaims);
      final shell = shellOf(tester);
      shell.openPlan(PlanRequest.addNode(PlanNodeSeed(key: k('a'), name: 'North Ridge', lat: 40.2, lon: -82.95, source: 'repeater')));
      await settle(tester);
      expect(st.controller!.nodes.single.mine, isFalse);
      final id = st.controller!.plan.id;
      await st.controller!.save();
      h.claimed.add(claim('a'));
      await h.state.claims.refresh();
      shell.openPlan(PlanRequest.openSaved(id));
      await settle(tester);
      expect(st.controller!.plan.id, id);
      expect(st.controller!.nodes.single.mine, isTrue);
      await finish(tester);
    });

    test('mineNodes: claimed radios with a known position are offered, repeaters and companions as the right roles, observers never', () {
      final plan = Plan(id: 'p', createdAt: DateTime.utc(2026, 11, 15));
      final nodes = mineNodes(
        plan,
        [claim('a', name: 'Hill'), claim('b', type: ClaimNodeType.companion), claim('c', type: ClaimNodeType.observer), claim('d')],
        {k('a'): const PlanPoint(40.1, -82.9), k('b'): const PlanPoint(40.2, -82.8), k('c'): const PlanPoint(40.3, -82.7)},
      );
      expect([for (final n in nodes) (n.existingKey, n.role, n.mine)], [(k('a'), PlanNodeRole.repeater, true), (k('b'), PlanNodeRole.handheld, true)]);
    });
  });

  group('J7 verify after an install: the data path', () {
    testWidgets('an installed node reads the measured drive cells around it from the app\'s network coverage; a planned one far from any drive says "unobserved"', (tester) async {
      phone(tester);
      final h = Harness();
      h.client.publicCoverageResult = PublicCoverage(
        asOf: '2026-11-14T00:00:00Z',
        grid: const CoverageGrid.square(cellDeg: 0.005),
        // Three measured cells within 2 km of the install (40.20, -82.95); one 30 km away.
        cells: [cell(40.201, -82.951), cell(40.205, -82.945), cell(40.195, -82.955), cell(40.5, -82.5)],
      );
      await openPlanner(tester, h);
      final s = AppScope.read(tester.element(find.byType(PlannerScreen)));
      await s.refreshNetworkCoverage();
      await settle(tester);
      final cov = s.networkCoverage;
      expect(cov, isNotNull, reason: 'measured coverage loaded through the app state');
      final centres = [for (final c in cov!.cells) PlanPoint(c.lat, c.lon)];

      final installed = PlanNode(id: 'i', name: 'Hilltop', lat: 40.20, lon: -82.95, status: PlanNodeStatus.installed, mine: true);
      final planned = PlanNode(id: 'p', name: 'Next site', lat: 41.0, lon: -83.5);
      final near = calibrationConfidence(installed.point, centres);
      expect(near.driveCells, 3);
      expect(near.observed, isTrue);
      expect(near.text, '3 drive cells within 2 km');
      final far = calibrationConfidence(planned.point, centres);
      expect(far.observed, isFalse);
      expect(far.text, 'unobserved, estimate');
      expect(installed.sensitivePosition, isTrue, reason: 'an installed node shares at ~1 km only');
      await finish(tester);
    });
  });
}
