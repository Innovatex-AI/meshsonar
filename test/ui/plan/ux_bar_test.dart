// The UX bar for the 0.38 screens (build plan §4.5 item 8, Q1): Dynamic Type at 3.1x on a 390 dp phone without overflow
// (the Planner in every mode with nodes and results, the node editor / picker / radio settings, the share, import and
// saved-plans sheets, the Find sites wizard, the node action bar, Settings > Observer's join guide), VoiceOver labels and
// headers, 44 pt targets, and the first useful result within one tap of opening Plan (with and without a phone position).
// The 1.0x and 2.35x runs of the same screens live next to each feature's own tests.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/saved_plans.dart';
import 'package:meshsonar/core/network_repeaters.dart' show NetworkRepeater;
import 'package:meshsonar/ui/nodes/node_actions.dart';
import 'package:meshsonar/ui/nodes/node_ref.dart';
import 'package:meshsonar/ui/plan/node_list.dart' show pickableNodes;
import 'package:meshsonar/ui/plan/plan_modes.dart';
import 'package:meshsonar/ui/plan/plan_share.dart' show showPlanImport, showPlanShare;
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/plan/saved_plans.dart' show showSavedPlans;
import 'package:meshsonar/ui/radios/observer_join_screen.dart';

import '../claims_ui_test.dart' show open, openScreen;
import '../fakes.dart';
import '../shell_test.dart' show phone, drain;
import 'planner_test.dart' show openPlanner, settle, tapIn;

const double ax3 = 3.1;

const _profile = PlanProfile(distanceKm: [0, 1, 2, 3], groundM: [200, 210, 205, 200]);
const _link = PlanLinkResult(
  km: 3.1,
  profile: _profile,
  fresnelClearancePct: 72,
  tightest: PlanTightestPoint(km: 1.2, raiseM: 4),
  ridge: PlanRidge(km: 1.2),
  odds: 0.81,
  verdict: PlanVerdict.likely,
  marginDb: 9.5,
  provenance: PlanProvenance(terrain: 'AWS Terrain Tiles (test)'),
);
const _verify = PlanVerifyResult(
  coveredKm2: 42.5,
  bands: [PlanBandArea('fringe', 'Fringe', 10), PlanBandArea('usable', 'Usable', 20), PlanBandArea('solid', 'Solid', 12.5)],
  links: [PlanPredictedLink(publicKey: 'ab', name: 'North Ridge with a long name', km: 6.2, marginDb: 7.1)],
  newAreaKm2: 18,
  newPeople: 4200,
  provenance: PlanProvenance(terrain: 'AWS Terrain Tiles (test)'),
);

final List<String> _details = [];

/// Keeps the framework's own report of each error (it names the widget that overflowed); the test handler still runs.
void _recordErrors() {
  final before = FlutterError.onError;
  _details.clear();
  FlutterError.onError = (d) {
    if (d.exception is TestFailure) return before?.call(d);
    final lines = d.toString().split('\n');
    final at = lines.indexWhere((l) => l.contains('relevant error-causing widget'));
    _details.add(at < 0 ? d.exceptionAsString() : '${d.exceptionAsString()} at ${lines.skip(at + 1).take(2).join(' ').trim()}');
    before?.call(d);
  };
  addTearDown(() => FlutterError.onError = before);
}

/// Every overflow / layout error since the last call, with the widget that caused it (null when none).
String? _errors(WidgetTester tester) {
  var any = false;
  while (tester.takeException() != null) {
    any = true;
  }
  final got = [..._details];
  _details.clear();
  if (!any && got.isEmpty) return null;
  return got.join('\n');
}

Future<void> _scrollSheet(WidgetTester tester) async {
  // Walk the whole sheet so every row is built and laid out at least once.
  final body = find.byKey(const Key('planner-sheet-body'));
  if (body.evaluate().isEmpty) return;
  for (var i = 0; i < 8; i++) {
    await tester.drag(body, const Offset(0, -400));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  pickerPrivacy();
  group('Dynamic Type AX3 (3.1x) on a 390 dp phone', () {
    testWidgets('the empty Planner: quick starts and every mode body', (tester) async {
      phone(tester, scale: ax3, w: 390, h: 844);
      _recordErrors();
      await openPlanner(tester, Harness());
      await settle(tester);
      expect(_errors(tester), isNull, reason: 'empty plan');
      // Medium opens as Full at this size: the map's credit and controls stay at the Medium line, never up in the status bar.
      final credit = tester.getRect(find.byKey(const Key('map-attribution')));
      expect(credit.bottom, greaterThan(844 * 0.4), reason: 'the credit sits at the Medium line ($credit)');
      for (final id in PlanModeId.values) {
        await tester.ensureVisible(find.byKey(Key('planner-mode-${id.name}')));
        await tester.tap(find.byKey(Key('planner-mode-${id.name}')));
        await settle(tester);
        await _scrollSheet(tester);
        expect(_errors(tester), isNull, reason: 'empty ${id.name}');
      }
      await drain(tester);
    });

    testWidgets('the Planner with nodes and a result in every mode', (tester) async {
      phone(tester, scale: ax3, w: 390, h: 844);
      _recordErrors();
      final h = Harness();
      h.client.planLinkResult = _link;
      h.client.planVerifyResult = _verify;
      final st = await openPlanner(tester, h);
      st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: 40.10, lon: -82.90, mine: true);
      st.controller!.addNode(name: 'Barn', lat: 40.12, lon: -82.87);
      await settle(tester);
      st.selectNodeForTest(st.controller!.nodes.first.id);
      await settle(tester);
      for (final id in PlanModeId.values) {
        await tester.ensureVisible(find.byKey(Key('planner-mode-${id.name}')));
        await tester.tap(find.byKey(Key('planner-mode-${id.name}')));
        await settle(tester);
        await _scrollSheet(tester);
        expect(_errors(tester), isNull, reason: id.name);
      }
      await drain(tester);
    });

    testWidgets('the node editor, the picker and the radio settings', (tester) async {
      phone(tester, scale: ax3, w: 390, h: 844);
      _recordErrors();
      final st = await openPlanner(tester, Harness());
      final n = st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: 40.10, lon: -82.90);
      await settle(tester);
      await tapIn(tester, find.byKey(Key('plan-node-edit-${n.id}')));
      await settle(tester);
      expect(find.byKey(const Key('node-editor')), findsOneWidget);
      expect(_errors(tester), isNull, reason: 'editor');
      await tester.tapAt(const Offset(4, 60));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('plan-node-add')));
      await settle(tester);
      expect(find.byKey(const Key('node-picker')), findsOneWidget);
      expect(_errors(tester), isNull, reason: 'picker');
      await tester.tapAt(const Offset(4, 60));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('plan-radio-summary')));
      await settle(tester);
      expect(find.byKey(const Key('plan-settings')), findsOneWidget);
      expect(_errors(tester), isNull, reason: 'radio settings');
      await drain(tester);
    });

    testWidgets('the share, import and saved-plans sheets and the plan menu', (tester) async {
      phone(tester, scale: ax3, w: 390, h: 844);
      _recordErrors();
      final h = Harness();
      final st = await openPlanner(tester, h);
      st.controller!.addNode(name: 'A very long site name on the ridge above the river', lat: 40.1, lon: -82.9, mine: true);
      st.controller!.rename('A long plan name for the north side of the county');
      await settle(tester);
      final ctx = tester.element(find.byType(PlannerScreen));
      unawaited(showPlanShare(ctx, st.controller!.plan));
      await settle(tester);
      expect(find.byKey(const Key('plan-share')), findsOneWidget);
      expect(_errors(tester), isNull, reason: 'share');
      await tester.tapAt(const Offset(4, 60));
      await settle(tester);
      unawaited(showPlanImport(ctx, controller: st.controller!, near: const PlanPoint(40, -83)));
      await settle(tester);
      expect(_errors(tester), isNull, reason: 'import');
      await tester.tapAt(const Offset(4, 60));
      await settle(tester);
      unawaited(showSavedPlans(ctx, saved: SavedPlans(h.planRepository), current: st.controller));
      await settle(tester);
      expect(find.byKey(const Key('saved-plans')), findsOneWidget);
      expect(_errors(tester), isNull, reason: 'saved plans');
      await tester.tapAt(const Offset(4, 60));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('plan-menu')));
      await settle(tester);
      expect(find.byKey(const Key('plan-menu-sheet')), findsOneWidget);
      expect(_errors(tester), isNull, reason: 'plan menu');
      await tapIn(tester, find.byKey(const Key('plan-menu-rename')));
      await settle(tester);
      expect(find.byKey(const Key('saved-plan-name-field')), findsOneWidget, reason: 'Rename is the shared plan-name sheet');
      expect(_errors(tester), isNull, reason: 'rename');
      await drain(tester);
    });

    testWidgets('the Find sites wizard', (tester) async {
      phone(tester, scale: ax3, w: 390, h: 844);
      _recordErrors();
      await openPlanner(tester, Harness());
      await tester.ensureVisible(find.byKey(const Key('planner-mode-findSites')));
      await tester.tap(find.byKey(const Key('planner-mode-findSites')));
      await settle(tester);
      await tapIn(tester, find.byKey(const Key('sites-tab-wizard')));
      await settle(tester);
      await _scrollSheet(tester);
      expect(_errors(tester), isNull, reason: 'wizard');
      await drain(tester);
    });

    testWidgets('the node action bar', (tester) async {
      phone(tester, scale: ax3, w: 390, h: 844);
      _recordErrors();
      final n = NodeRef(key: List.filled(32, 'ab').join(), name: 'A repeater with a long name on the hill', kind: NodeKind.repeater, lat: 40.1, lon: -83.2, source: NodeSource.network);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: NodeActionBar(node: n, env: const NodeActionEnv(radioConnected: true, canOpenPage: true, hostPing: true, claimAvailable: true)),
          ),
        ),
      ));
      await tester.pump();
      expect(_errors(tester), isNull);
      for (final id in [NodeActionId.planFrom, NodeActionId.addToPlan, NodeActionId.linkTo, NodeActionId.ping]) {
        expect(tester.getSize(find.byKey(Key('node-action-${id.name}'))).height, greaterThanOrEqualTo(44), reason: id.name);
      }
    });

    testWidgets('the repeater observer guide', (tester) async {
      await open(tester);
      phone(tester, scale: ax3, w: 390, h: 844);
      _recordErrors();
      await openScreen(tester, const ObserverJoinScreen());
      await tester.pump();
      final states = <String>{};
      void seeStates() {
        for (final k in ['connect', 'claim-radio', 'claim-repeater', 'report', 'check']) {
          if (find.byKey(Key('observer-step-$k-state')).evaluate().isNotEmpty) states.add(k);
        }
      }

      seeStates();
      final scroll = find.descendant(of: find.byKey(const Key('observer-join-screen')), matching: find.byType(Scrollable)).first;
      for (final k in ['connect', 'claim-radio', 'claim-repeater', 'report', 'check']) {
        await tester.scrollUntilVisible(find.byKey(Key('observer-step-$k-state')), 200, scrollable: scroll);
        await tester.pump(const Duration(milliseconds: 100));
        seeStates();
      }
      expect(states, hasLength(5), reason: 'every step says its state in words (Done / Next / Waiting)');
      expect(_errors(tester), isNull);
    });
  });

  group('first useful result within one tap', () {
    testWidgets('no phone position yet: Coverage from the map centre adds a node there and runs the Estimate', (tester) async {
      phone(tester);
      final h = Harness();
      h.location.currentFix = () => null;
      h.client.planVerifyResult = _verify;
      final st = await openPlanner(tester, h);
      expect(find.byKey(const Key('plan-quick-here')), findsNothing);
      expect(find.byKey(const Key('plan-quick-no-location')), findsOneWidget, reason: 'icon and words say why');
      await tapIn(tester, find.byKey(const Key('plan-quick-centre')));
      await settle(tester);
      expect(st.mode, PlanModeId.coverage);
      expect(st.controller!.nodes, hasLength(1));
      expect(h.client.planVerifyAsks, hasLength(1));
      expect(find.byKey(const Key('coverage-result')), findsOneWidget);
      await drain(tester);
    });
  });

  group('VoiceOver', () {
    testWidgets('the Planner: the title is a header, the chips say their mode, the quick starts and menu are labelled', (tester) async {
      phone(tester);
      final sem = tester.ensureSemantics();
      await openPlanner(tester, Harness());
      await settle(tester);
      final title = tester.getSemantics(find.byKey(const Key('planner-title')));
      expect(title.flagsCollection.isHeader || _ancestorIsHeader(tester, find.byKey(const Key('planner-title'))), isTrue);
      for (final m in planModes) {
        expect(find.bySemanticsLabel('${m.label} mode'), findsOneWidget, reason: m.label);
      }
      expect(find.bySemanticsLabel(RegExp('How far would a radio here reach')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Will two places connect')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Where should I drive next')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('Opens Saved plans')), findsOneWidget, reason: 'the name chip says what it does');
      expect(find.byTooltip('Plan options'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Plan map')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('plan-menu'))).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.byKey(const Key('plan-quick-here'))).height, greaterThanOrEqualTo(44));
      sem.dispose();
      await drain(tester);
    });
  });
}

bool _ancestorIsHeader(WidgetTester tester, Finder f) =>
    find.ancestor(of: f, matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.header == true)).evaluate().isNotEmpty;


/// The existing-node picker never offers a node whose owner hides its position (V1 review, privacy).
void pickerPrivacy() {
  test('pickableNodes skips nodes whose name carries the no-position mark', () {
    final rows = [
      NetworkRepeater(key: 'aa' * 32, lat: 40.1, lon: -83.0, name: 'Open hilltop'),
      NetworkRepeater(key: 'bb' * 32, lat: 40.2, lon: -83.1, name: 'Hidden $kNoPositionMark'),
    ];
    final got = pickableNodes(region: rows, global: const [], claimed: {'bb' * 32}, near: const PlanPoint(40.1, -83.0));
    expect(got.map((p) => p.name), ['Open hilltop'], reason: 'hidden even when it is your own claimed node');
  });
}
