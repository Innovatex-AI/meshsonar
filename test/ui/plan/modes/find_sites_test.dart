// Find sites, "This view" (release 0.38 A10, plan §4.4, flow C): goal chips rank the view through plan-suggest, numbered
// pins with reasons and the stage-1 estimate, Verify top 5 (plan-verify once per site, one at a time), Add to plan,
// Navigate (Apple Maps), Show on the Drive map, and every state. The server answers are the meshcore-insights fixtures
// (find_sites_fixtures.dart) and test/fixtures/plan_server/plan-verify.site.response.json.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show CmatException;
import 'package:meshsonar/core/plan_contract.dart';
import 'package:meshsonar/ui/map/layers/registry.dart' show kPlanLayerId;
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/plan/modes/find_sites_mode.dart';
import 'package:meshsonar/ui/plan/plan_modes.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';

import '../../fakes.dart';
import '../../shell_test.dart' show phone, drain;
import '../planner_test.dart' show openPlanner, tapIn, settle;
import 'find_sites_fixtures.dart';

PlanSuggestResult suggestFixture() => PlanSuggestResult.parse(jsonDecode(kPlanSuggestResponseJson) as Map<String, dynamic>);
PlanSuggestResult preparingFixture() => PlanSuggestResult.parse(jsonDecode(kPlanSuggestPreparingJson) as Map<String, dynamic>);
PlanVerifyResult verifyFixture() =>
    PlanVerifyResult.parse(jsonDecode(File('test/fixtures/plan_server/plan-verify.site.response.json').readAsStringSync()) as Map<String, dynamic>);

/// A client whose plan-verify takes a moment and records how many run at once; sites at [failLats] fail.
class SlowVerifyClient extends FakeCmatClient {
  SlowVerifyClient(super.u);
  int inFlight = 0, maxInFlight = 0;
  final Set<double> failLats = {};

  @override
  Future<PlanVerifyResult> planVerify(PlanVerifyRequest request) async {
    inFlight++;
    maxInFlight = math.max(maxInFlight, inFlight);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    inFlight--;
    if (failLats.contains(request.site.lat)) {
      planVerifyAsks.add(request);
      throw CmatException('The site is outside the region.', status: 422);
    }
    return super.planVerify(request);
  }
}

class SitesHarness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => SlowVerifyClient(u);
  SlowVerifyClient get slow => client as SlowVerifyClient;
}

Future<PlannerScreenState> openFindSites(WidgetTester tester, Harness h) async {
  final st = await openPlanner(tester, h);
  await tester.ensureVisible(find.byKey(const Key('planner-mode-findSites')));
  await tester.tap(find.byKey(const Key('planner-mode-findSites')));
  await settle(tester);
  return st;
}

void main() {
  group('the contract fixtures', () {
    test('the live server fixture parses: 10 sites with reasons, gains and provenance', () {
      final r = suggestFixture();
      expect(r.sites, hasLength(10));
      expect(r.pool, 83);
      expect(r.sites.first.reason, contains('new coverage'));
      expect(r.sites.first.gain.newLinks.single.name, 'East');
      expect(r.sites[2].gain.redundancy, PlanRedundancyGain.joinsComponents);
      expect(r.provenance.confidence, PlanConfidenceLevel.calibrated);
      expect(preparingFixture().preparing, isTrue);
    });

    test('publicCandidates: never an existing node, never on a hidden-position node, at most 20', () {
      final sites = [
        const PlanSite(id: 'ok', at: PlanPoint(40.0, -83.0), score: 90),
        const PlanSite(id: 'rep', at: PlanPoint(40.1, -83.0), score: 80, kind: 'repeater'),
        const PlanSite(id: 'room', at: PlanPoint(40.1, -83.1), score: 80, kind: 'Room'),
        const PlanSite(id: 'onHidden', at: PlanPoint(40.2, -83.0), score: 70),
        const PlanSite(id: 'nearHidden', at: PlanPoint(40.2005, -83.0), score: 70),
        const PlanSite(id: 'osm', at: PlanPoint(40.3, -83.0), score: 60, kind: 'tower', osmOperator: 'Ham club \u{1F6AB}'),
        for (var i = 0; i < 30; i++) PlanSite(id: 'x$i', at: PlanPoint(41 + i / 10, -83.0), score: 50),
      ];
      final out = publicCandidates(sites, hiddenNodes: const [PlanPoint(40.2, -83.0)]);
      expect(out, hasLength(kMaxSites));
      expect(out.map((s) => s.id), isNot(contains(anyOf('rep', 'room', 'onHidden', 'nearHidden', 'osm'))));
      expect(out.first.id, 'ok');
    });

    test('words: people with separators, stage-1 estimate, redundancy', () {
      expect(peopleWords(1500), '1,500 people');
      expect(peopleWords(1), '1 person');
      expect(peopleWords(1234567), '1,234,567 people');
      final s = suggestFixture().sites;
      expect(redundancyWords(s[2]), 'Joins two separate parts of the mesh.');
      expect(redundancyWords(s[0]), isNull);
    });
  });

  group('This view', () {
    testWidgets('goal chips + Find: up to 20 ranked pins with a reason each, numbered targets on the map', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = suggestFixture();
      final st = await openFindSites(tester, h);
      expect(find.byKey(const Key('plan-mode-sites')), findsOneWidget);
      for (final g in ['coverage', 'links', 'redundancy', 'overall']) {
        expect(find.byKey(Key('sites-goal-$g')), findsOneWidget, reason: g);
      }
      await tapIn(tester, find.byKey(const Key('sites-goal-links')));
      expect(st.controller!.plan.goal, PlanGoal.links);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      final ask = h.client.planSuggestAsks.single;
      expect(ask.goal, PlanGoal.links);
      expect(ask.limit, 20);
      expect(ask.near, isNull, reason: 'the view search sends no location of the person');
      final wire = jsonEncode(ask.toJson());
      expect(wire, isNot(contains('near')));
      expect(find.byKey(const Key('sites-result')), findsOneWidget);
      final sites = suggestFixture().sites;
      expect(find.byKey(Key('site-${sites.first.id}')), findsOneWidget);
      expect(find.text(sites.first.reason), findsOneWidget);
      expect(find.textContaining('Estimate: +'), findsWidgets);
      expect(find.textContaining('reaches East (Likely)'), findsOneWidget);
      expect(find.textContaining('Joins two separate parts of the mesh'), findsOneWidget);
      expect(find.textContaining('from 83 candidates'), findsOneWidget);
      expect(find.textContaining('Calibrated on Columbus'), findsOneWidget);
      expect(st.overlayForTest.targets.map((t) => t.label), [for (var i = 1; i <= 10; i++) '#$i']);
      await drain(tester);
    });

    testWidgets('changing the goal with a list on screen re-ranks at once', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = suggestFixture();
      final st = await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      expect(h.client.planSuggestAsks.single.goal, st.controller!.plan.goal);
      await tapIn(tester, find.byKey(const Key('sites-goal-redundancy')));
      await settle(tester);
      expect(h.client.planSuggestAsks, hasLength(2));
      expect(h.client.planSuggestAsks.last.goal, PlanGoal.redundancy);
      expect(find.textContaining('sites for Redundancy'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('Verify top 5: plan-verify once per site, one at a time, the model next to the estimate', (tester) async {
      phone(tester, h: 1100);
      final h = SitesHarness();
      h.client.planSuggestResult = suggestFixture();
      h.client.planVerifyResult = verifyFixture();
      await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      await tester.ensureVisible(find.byKey(const Key('sites-verify')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byKey(const Key('sites-verify')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.textContaining('Verifying 1 of 5'), findsOneWidget);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      final sites = suggestFixture().sites;
      expect(h.client.planVerifyAsks, hasLength(5));
      expect(h.slow.maxInFlight, 1, reason: 'the server verifies one site at a time');
      expect([for (final a in h.client.planVerifyAsks) a.site], [for (final s in sites.take(5)) s.at], reason: 'in rank order');
      final a = h.client.planVerifyAsks.first;
      expect(a.antennaM, 6, reason: 'the site\'s own mount height');
      expect(a.mount, PlanMount.ground);
      for (final s in sites.take(5)) {
        expect(find.byKey(Key('site-check-${s.id}')), findsOneWidget, reason: s.id);
      }
      expect(find.byKey(Key('site-check-${sites[5].id}')), findsNothing, reason: 'only the top 5');
      expect(find.textContaining('Model (Verify): 39.1 km² covered, +39.0 km² new, heard by 1 live repeater'), findsNWidgets(5));
      expect(find.textContaining('Verify top 5 again'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a site that fails to verify says why and verifies again on its own', (tester) async {
      phone(tester, h: 1100);
      final h = SitesHarness();
      final sites = suggestFixture().sites;
      h.client.planSuggestResult = suggestFixture();
      h.client.planVerifyResult = verifyFixture();
      await openFindSites(tester, h);
      h.slow.failLats.add(sites[1].at.lat);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('sites-verify')));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('Could not verify: The site is outside the region.'), findsOneWidget);
      h.slow.failLats.clear();
      await tapIn(tester, find.text('Verify again'));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(find.textContaining('Could not verify'), findsNothing);
      expect(h.client.planVerifyAsks, hasLength(6));
      await drain(tester);
    });

    testWidgets('Add to plan, tap a pin to add it, Navigate hands off to Apple Maps, Show on the Drive map', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = suggestFixture();
      final st = await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      final sites = suggestFixture().sites;
      await tapIn(tester, find.byKey(Key('site-add-${sites[0].id}')));
      await settle(tester);
      final n = st.controller!.nodes.single;
      expect(n.name, 'Site 1');
      expect((n.lat, n.lon), (sites[0].at.lat, sites[0].at.lon));
      expect(n.heightM, 6);
      expect(n.mount, PlanMount.ground);
      expect(find.text('In the plan'), findsOneWidget);
      // A tap on pin #3 on the map adds it too (and a second tap does not add it twice).
      expect(st.hooksForTest.onNodeTap!('site-${sites[2].id}'), isTrue);
      expect(st.hooksForTest.onNodeTap!('site-${sites[2].id}'), isTrue);
      await settle(tester);
      expect(st.controller!.nodes.map((x) => x.name), ['Site 1', 'Site 3']);
      await tapIn(tester, find.descendant(of: find.byKey(Key('site-nav-${sites[1].id}')), matching: find.byKey(const Key('drive-target-navigate'))));
      await settle(tester);
      final u = h.openedUrls.last;
      expect(u.host, 'maps.apple.com');
      expect(u.queryParameters['daddr'], '${sites[1].at.lat.toStringAsFixed(6)},${sites[1].at.lon.toStringAsFixed(6)}');
      await tapIn(tester, find.byKey(const Key('sites-drive-map')));
      await settle(tester);
      final req = MainMapFocus.notifier.value;
      // The Drive map takes the request when it opens; either way it carried the picks.
      if (req != null) {
        expect(req.showLayers, contains(kPlanLayerId));
        expect(req.targets.map((t) => t.label), [for (var i = 1; i <= 10; i++) '#$i']);
      }
      expect(MainMapFocus.overlay.targets.map((t) => t.label), contains('#1'));
      expect(find.text('Show all on the Drive map'), findsNothing, reason: 'the Drive tab is showing now');
      await drain(tester);
    });

    testWidgets('each result has Navigate and Show on the Drive map (one pin)', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = suggestFixture();
      await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      final sites = suggestFixture().sites;
      expect(find.byKey(const Key('drive-target-navigate')), findsNWidgets(sites.length));
      await tapIn(tester, find.descendant(of: find.byKey(Key('site-nav-${sites[2].id}')), matching: find.byKey(const Key('drive-target-show-map'))));
      await settle(tester);
      expect(MainMapFocus.overlay.targets.map((t) => (t.label, t.at.latitude)), [('#3', sites[2].at.lat)]);
      await drain(tester);
    });

    testWidgets('preparing this region: says so, checks again every 30 s, then shows the list', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = preparingFixture();
      await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      expect(find.byKey(const Key('sites-preparing')), findsOneWidget);
      expect(find.text('Preparing this region'), findsOneWidget);
      expect(find.textContaining('candidate sites are being computed'), findsOneWidget);
      h.client.planSuggestResult = suggestFixture();
      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(h.client.planSuggestAsks, hasLength(2));
      expect(find.byKey(const Key('sites-preparing')), findsNothing);
      expect(find.byKey(const Key('sites-result')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a server without plan-suggest, a refusal and an empty view each have their state with a retry', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      expect(find.byKey(const Key('sites-error')), findsOneWidget);
      expect(find.textContaining('not on this region\'s server yet'), findsOneWidget);
      h.client.planSuggestError = CmatException('The view is outside the region.', status: 422);
      await tapIn(tester, find.text('Try again'));
      await settle(tester);
      expect(find.text('Could not find sites'), findsOneWidget);
      expect(find.textContaining('outside the region'), findsOneWidget);
      h.client.planSuggestError = null;
      h.client.planSuggestResult = const PlanSuggestResult(pool: 12, sites: []);
      await tapIn(tester, find.text('Try again'));
      await settle(tester);
      expect(find.byKey(const Key('sites-empty')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('existing nodes the server might send are never shown as candidates', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = const PlanSuggestResult(sites: [
        PlanSite(id: 'r1', at: PlanPoint(40.1, -82.9), score: 99, kind: 'repeater', reason: 'An existing repeater'),
        PlanSite(id: 's1', at: PlanPoint(40.2, -82.8), score: 80, reason: 'High ground'),
      ]);
      final st = await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      expect(find.byKey(const Key('site-r1')), findsNothing);
      expect(find.byKey(const Key('site-s1')), findsOneWidget);
      expect(st.overlayForTest.targets.map((t) => t.id), ['site-s1']);
      await drain(tester);
    });
  });

  group('VoiceOver and Dynamic Type', () {
    testWidgets('rows read as one item with labelled actions; headers are headers', (tester) async {
      phone(tester, h: 1100);
      final h = Harness();
      h.client.planSuggestResult = suggestFixture();
      await openFindSites(tester, h);
      await tapIn(tester, find.byKey(const Key('sites-run')));
      await settle(tester);
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel('Add pin #1 to the plan'), findsOneWidget);
      expect(find.descendant(of: find.byKey(Key('site-nav-${suggestFixture().sites.first.id}')), matching: find.text('Show on the Drive map')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Pin #1\b')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'^Directions to pin #1\b')), findsOneWidget);
      expect(tester.getSemantics(find.text('Goal')).flagsCollection.isHeader, isTrue);
      handle.dispose();
      await drain(tester);
    });

    for (final scale in [1.0, 2.35]) {
      testWidgets('no overflow at ${scale}x with results, verify and preparing', (tester) async {
        phone(tester, scale: scale, w: 390, h: 844);
        final h = SitesHarness();
        h.client.planSuggestResult = suggestFixture();
        h.client.planVerifyResult = verifyFixture();
        final st = await openFindSites(tester, h);
        await tapIn(tester, find.byKey(const Key('sites-run')));
        await settle(tester);
        expect(tester.takeException(), isNull);
        await tapIn(tester, find.byKey(const Key('sites-verify')));
        for (var i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 200));
        }
        expect(tester.takeException(), isNull);
        h.client.planSuggestResult = preparingFixture();
        await tapIn(tester, find.byKey(const Key('sites-run')));
        await settle(tester);
        expect(find.byKey(const Key('sites-preparing')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'at ${scale}x');
        expect(st.mode, PlanModeId.findSites);
        await drain(tester);
      });
    }
  });
}
