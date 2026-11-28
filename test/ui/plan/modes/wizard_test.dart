// The Find sites wizard ("Guide me", release 0.38 A10, plan §4.4): Personal - Balanced - Mesh, a ZIP code / address
// looked up on the phone or a point on the map, rounded to about 1 km before anything is sent, and the two lists
// "For your coverage" / "To extend the mesh". Server answers are the meshcore-insights plan-suggest fixtures.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan_contract.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart' show LongPressHit;
import 'package:meshsonar/ui/plan/modes/wizard.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';

import '../../fakes.dart';
import '../../shell_test.dart' show phone, drain;
import '../planner_test.dart' show openPlanner, tapIn, settle;
import 'find_sites_test.dart' show suggestFixture, preparingFixture, verifyFixture;

/// Answers plan-suggest by goal: Coverage gets the fixture's sites 0-5, any other goal sites 3-9 (3-5 overlap).
class GoalClient extends FakeCmatClient {
  GoalClient(super.u);
  bool preparing = false;

  @override
  Future<PlanSuggestResult> planSuggest(PlanSuggestRequest request) async {
    planSuggestAsks.add(request);
    if (preparing) return preparingFixture();
    final all = suggestFixture();
    final sites = request.goal == PlanGoal.coverage ? all.sites.sublist(0, 6) : all.sites.sublist(3);
    return PlanSuggestResult(pool: all.pool, sites: sites, notes: all.notes, provenance: all.provenance);
  }
}

class WizardHarness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => GoalClient(u);
  GoalClient get goal => client as GoalClient;
}

class FakePlaceFinder implements PlaceFinder {
  final List<String> asked = [];
  PlaceResult answer = const PlaceResult.found(PlanPoint(39.96118, -82.99879), label: 'Columbus, OH 43215');
  @override
  Future<PlaceResult> find(String query) async {
    asked.add(query);
    return answer;
  }
}

Future<PlannerScreenState> openWizard(WidgetTester tester, Harness h) async {
  final st = await openPlanner(tester, h);
  await tester.ensureVisible(find.byKey(const Key('planner-mode-findSites')));
  await tester.tap(find.byKey(const Key('planner-mode-findSites')));
  await settle(tester);
  await tapIn(tester, find.byKey(const Key('sites-tab-wizard')));
  await settle(tester);
  return st;
}

Future<void> lookUp(WidgetTester tester, String text) async {
  await tester.ensureVisible(find.byKey(const Key('wizard-address')));
  await tester.enterText(find.byKey(const Key('wizard-address')), text);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await settle(tester);
}

/// Every number in [json] (recursively).
Iterable<num> numbersIn(Object? json) sync* {
  if (json is num) yield json;
  if (json is Map) {
    for (final v in json.values) {
      yield* numbersIn(v);
    }
  }
  if (json is List) {
    for (final v in json) {
      yield* numbersIn(v);
    }
  }
}

bool twoDecimals(num v) => (v * 100 - (v * 100).roundToDouble()).abs() < 1e-6;

void main() {
  late FakePlaceFinder finder;
  setUp(() {
    finder = FakePlaceFinder();
    WizardModel.testPlaceFinder = () => finder;
  });
  tearDown(() => WizardModel.testPlaceFinder = null);

  group('rounding (privacy)', () {
    test('the point is rounded to 2 decimals and the box is built from the rounded point', () {
      final p = approximatePoint(const PlanPoint(40.12645, -82.93051));
      expect(p, const PlanPoint(40.13, -82.93));
      final b = approximateBounds(p);
      for (final v in [b.south, b.north, b.west, b.east]) {
        expect(twoDecimals(v), isTrue, reason: '$v');
      }
      expect(b.south, lessThan(p.lat));
      expect(b.north, greaterThan(p.lat));
      expect(b.north - b.south, closeTo(0.36, 0.02), reason: 'about 20 km each way');
      expect(approximateBounds(approximatePoint(const PlanPoint(40.12999, -82.93001))).toJson(), b.toJson(), reason: 'nearby precise points give the same box');
    });

    test('the slider: goals, list sizes and order', () {
      expect(meshGoalFor(WizardLean.personal), PlanGoal.links);
      expect(meshGoalFor(WizardLean.balanced), PlanGoal.overall);
      expect(meshGoalFor(WizardLean.mesh), PlanGoal.redundancy);
      expect(listSizesFor(WizardLean.personal), (10, 5));
      expect(listSizesFor(WizardLean.mesh), (5, 10));
    });
  });

  group('Guide me', () {
    testWidgets('a ZIP code is looked up on the phone; only the rounded point and its box are sent; two lists come back', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      final st = await openWizard(tester, h);
      expect(find.byKey(const Key('sites-wizard')), findsOneWidget);
      expect(find.byKey(const Key('sites-goal-coverage')), findsNothing, reason: 'the wizard picks its own goals');
      expect(find.byKey(const Key('wizard-lean')), findsOneWidget);
      expect(find.text('Balanced'), findsWidgets);
      await lookUp(tester, '43215');
      expect(finder.asked, ['43215'], reason: 'the platform geocoder got the ZIP code, on the phone');
      expect(find.byKey(const Key('wizard-point')), findsOneWidget);
      expect(find.textContaining('Around 39.96, -83.00 (Columbus, OH 43215), rounded to about 1 km'), findsOneWidget);
      final asks = h.client.planSuggestAsks;
      expect(asks, hasLength(2), reason: 'one request per list, one after the other');
      expect(asks[0].goal, PlanGoal.coverage, reason: 'Balanced: For your coverage first');
      expect(asks[1].goal, PlanGoal.overall);
      expect((asks[0].limit, asks[1].limit), (8, 8));
      for (final a in asks) {
        expect(a.near, const PlanPoint(39.96, -83.0));
        final wire = jsonEncode(a.toJson());
        expect(wire, isNot(contains('43215')));
        expect(wire, isNot(contains('Columbus')));
        expect(wire, isNot(contains('39.961')));
        final j = a.toJson();
        for (final v in [...numbersIn(j['near']), ...numbersIn(j['bounds'])]) {
          expect(twoDecimals(v), isTrue, reason: 'never more precise than about 1 km: $v');
        }
      }
      expect(find.byKey(const Key('wizard-list-coverage')), findsOneWidget);
      expect(find.byKey(const Key('wizard-list-mesh')), findsOneWidget);
      expect(find.text('For your coverage'), findsOneWidget);
      expect(find.text('To extend the mesh'), findsOneWidget);
      final sites = suggestFixture().sites;
      expect(find.byKey(Key('wiz-c-${sites[0].id}')), findsOneWidget);
      expect(find.byKey(Key('wiz-m-${sites[3].id}')), findsNothing, reason: 'a site in the first list is not repeated');
      expect(find.byKey(Key('wiz-m-${sites[6].id}')), findsOneWidget);
      final labels = st.overlayForTest.targets.map((t) => t.label).toList();
      expect(labels.take(6), ['C1', 'C2', 'C3', 'C4', 'C5', 'C6']);
      expect(labels.skip(6), ['M1', 'M2', 'M3', 'M4']);
      await drain(tester);
    });

    testWidgets('the slider: Personal ranks Links, Mesh puts the mesh list first, ranks Redundancy across the box', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      await openWizard(tester, h);
      await lookUp(tester, '43215');
      h.client.planSuggestAsks.clear();
      final slider = find.descendant(of: find.byKey(const Key('wizard-lean')), matching: find.byType(Slider));
      final target = slider.evaluate().isEmpty ? find.byKey(const Key('wizard-lean')) : slider;
      await tester.ensureVisible(target);
      await tester.pump(const Duration(milliseconds: 300));
      final r = tester.getRect(target);
      await tester.tapAt(Offset(r.left + 4, r.center.dy));
      await settle(tester);
      var asks = h.client.planSuggestAsks;
      expect(asks.map((a) => a.goal), [PlanGoal.coverage, PlanGoal.links], reason: 'Personal');
      expect((asks[0].limit, asks[1].limit), (10, 5));
      h.client.planSuggestAsks.clear();
      await tester.tapAt(Offset(r.right - 4, r.center.dy));
      await settle(tester);
      asks = h.client.planSuggestAsks;
      expect(asks.map((a) => a.goal), [PlanGoal.redundancy, PlanGoal.coverage], reason: 'Mesh: the mesh list first');
      expect(asks[0].near, isNull);
      expect(asks[1].near, const PlanPoint(39.96, -83.0));
      final mesh = tester.getTopLeft(find.byKey(const Key('wizard-list-mesh'))).dy;
      final cov = tester.getTopLeft(find.byKey(const Key('wizard-list-coverage'))).dy;
      expect(mesh, lessThan(cov));
      await drain(tester);
    });

    testWidgets('a point on the map (touch and hold) is taken by the wizard, rounded, and drops no node', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      final st = await openWizard(tester, h);
      await tapIn(tester, find.byKey(const Key('wizard-pick-map')));
      expect(find.byKey(const Key('wizard-picking')), findsOneWidget);
      expect(st.hooksForTest.onMapPoint, isNotNull);
      expect(await st.longPressForTest(const LongPressHit(lat: 40.04567, lon: -83.01234)), isTrue);
      await settle(tester);
      expect(st.controller!.nodes, isEmpty, reason: 'the long-press went to the wizard');
      expect(st.hooksForTest.onMapPoint, isNull, reason: 'one point, then the map is the planner\'s again');
      expect(h.client.planSuggestAsks.first.near, const PlanPoint(40.05, -83.01));
      expect(find.textContaining('Around 40.05, -83.01, rounded'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('use my location sends it rounded; Clear forgets it', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      await openWizard(tester, h);
      await tapIn(tester, find.byKey(const Key('wizard-use-here')));
      await settle(tester);
      expect(h.client.planSuggestAsks.first.near, const PlanPoint(40.13, -82.93));
      await tapIn(tester, find.byKey(const Key('wizard-clear-point')));
      await settle(tester);
      expect(find.byKey(const Key('wizard-point')), findsNothing);
      expect(find.byKey(const Key('wizard-list-coverage')), findsNothing);
      expect(tester.widget<FilledButton>(find.byKey(const Key('wizard-run'))).onPressed, isNull, reason: 'nothing to rank without a place');
      await drain(tester);
    });

    testWidgets('lookup failures: nothing found, and a phone without the geocoder channel', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      await openWizard(tester, h);
      finder.answer = const PlaceResult.failed('Nothing found for "zzz". Check the ZIP code or address.');
      await lookUp(tester, 'zzz');
      expect(find.byKey(const Key('wizard-lookup-error')), findsOneWidget);
      expect(find.textContaining('Nothing found'), findsOneWidget);
      expect(h.client.planSuggestAsks, isEmpty);
      // The real platform finder, with no native side in the test: an honest sentence pointing at the map.
      WizardModel.testPlaceFinder = null;
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      // No native handler: the engine answers with no reply at all.
      messenger.setMockMessageHandler('app.meshsonar/geocoder', (_) async => null);
      addTearDown(() => messenger.setMockMessageHandler('app.meshsonar/geocoder', null));
      await lookUp(tester, '43215');
      expect(find.textContaining('cannot look up addresses on this phone'), findsOneWidget);
      expect(h.client.planSuggestAsks, isEmpty);
      // The Look up button does the same as the keyboard's search key.
      await tester.enterText(find.byKey(const Key('wizard-address')), '');
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(find.byKey(const Key('wizard-find-address')));
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(find.byKey(const Key('wizard-find-address')));
      await settle(tester);
      expect(find.textContaining('Type a ZIP code'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the platform finder reads the channel answer', (tester) async {
      const channel = 'app.meshsonar/geocoder';
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      String? got;
      messenger.setMockMethodCallHandler(const MethodChannel(channel), (call) async {
        got = (call.arguments as Map)['query'] as String;
        return {'lat': 39.96118, 'lon': -82.99879, 'label': 'Columbus'};
      });
      addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel(channel), null));
      final r = await const PlatformPlaceFinder().find('43215');
      expect(got, '43215');
      expect(r.at, const PlanPoint(39.96118, -82.99879));
      expect(r.label, 'Columbus');
      messenger.setMockMethodCallHandler(const MethodChannel(channel), (call) async => null);
      expect((await const PlatformPlaceFinder().find('nowhere')).error, contains('Nothing found'));
    });

    testWidgets('tap a pin to add it, Verify a list\'s top 5, preparing this region', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      h.client.planVerifyResult = verifyFixture();
      final st = await openWizard(tester, h);
      await lookUp(tester, '43215');
      final sites = suggestFixture().sites;
      expect(st.hooksForTest.onNodeTap!('wiz-c-${sites[1].id}'), isTrue);
      await settle(tester);
      expect(st.controller!.nodes.single.name, 'Coverage pick 2');
      await tapIn(tester, find.byKey(const Key('wizard-verify-coverage')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      expect(h.client.planVerifyAsks.map((a) => a.site), [for (final s in sites.take(5)) s.at]);
      expect(find.textContaining('Double-checked: '), findsNWidgets(5));
      h.goal.preparing = true;
      await tapIn(tester, find.byKey(const Key('wizard-run')));
      await settle(tester);
      expect(find.byKey(const Key('wizard-preparing')), findsOneWidget);
      expect(find.text('Preparing this region'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('switching to This view and back keeps the wizard\'s place and lists', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      final st = await openWizard(tester, h);
      await lookUp(tester, '43215');
      await tapIn(tester, find.byKey(const Key('sites-tab-view')));
      await settle(tester);
      expect(st.overlayForTest.targets, isEmpty, reason: 'This view has no results yet');
      await tapIn(tester, find.byKey(const Key('sites-tab-wizard')));
      await settle(tester);
      expect(find.byKey(const Key('wizard-point')), findsOneWidget);
      expect(find.byKey(const Key('wizard-list-coverage')), findsOneWidget);
      expect(st.overlayForTest.targets, isNotEmpty);
      await drain(tester);
    });
  });

  group('VoiceOver and Dynamic Type', () {
    testWidgets('steps are headers; the slider and the buttons are labelled', (tester) async {
      phone(tester, h: 1100);
      final h = WizardHarness();
      await openWizard(tester, h);
      final handle = tester.ensureSemantics();
      for (final s in ['1. What matters most', '2. About where', '3. Your picks']) {
        expect(tester.getSemantics(find.text(s)).flagsCollection.isHeader, isTrue, reason: s);
      }
      expect(find.bySemanticsLabel('Pick about where you are on the map'), findsOneWidget);
      expect(find.bySemanticsLabel('Use my location, rounded to about 1 kilometre'), findsOneWidget);
      handle.dispose();
      await drain(tester);
    });

    for (final scale in [1.0, 2.35]) {
      testWidgets('no overflow at ${scale}x with both lists and an error', (tester) async {
        phone(tester, scale: scale, w: 390, h: 844);
        final h = WizardHarness();
        await openWizard(tester, h);
        expect(tester.takeException(), isNull);
        await lookUp(tester, '43215');
        expect(find.byKey(const Key('wizard-list-mesh')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'lists at ${scale}x');
        finder.answer = const PlaceResult.failed('Nothing found for "zzz". Check the ZIP code or address.');
        await lookUp(tester, 'zzz');
        expect(tester.takeException(), isNull, reason: 'error at ${scale}x');
        await drain(tester);
      });
    }
  });
}
