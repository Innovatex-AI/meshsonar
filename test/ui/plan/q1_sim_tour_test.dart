// The Q1 UX tour of the 0.38 screens (build plan §4.5 item 8): the Planner (empty, Link, Coverage, Find sites wizard, the
// node editor, the radio settings, share / import / saved plans, AX3 text), the plan layer over repeater clusters, Settings
// > Observer with an MQTT feed, the preset picker and the repeater observer guide. Under `flutter test` it is one more walk
// with an overflow check at every stop; on a simulator,
//   flutter run -d <sim> -t test/ui/plan/q1_sim_tour_test.dart [--dart-define=Q1_THEME=light]
// draws it on the device, prints `SIMSHOT <name>` and holds each state so a script can take `xcrun simctl io screenshot`.
// The main matrix is iPhone 17 Pro dark; the iPad and light runs are the allowed one-off passes on these new screens.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/mqtt_presets.dart';
import 'package:meshsonar/core/plan/saved_plans.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/plan_overlay.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/main_map_focus.dart' show MapFocusTarget;
import 'package:meshsonar/ui/plan/plan_share.dart' show showPlanImport, showPlanShare;
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/plan/saved_plans.dart' show showSavedPlans;
import 'package:meshsonar/ui/radios/observer_join_screen.dart';
import 'package:meshsonar/ui/settings/observer_section.dart';

import '../claims_ui_test.dart' show openScreen;
import '../fakes.dart';
import '../settings_test_kit.dart';
import '../shell_test.dart' show drain;
import 'planner_test.dart' show openPlanner, settle, tapIn;

bool get _live => WidgetsBinding.instance is LiveTestWidgetsFlutterBinding;
const String _theme = String.fromEnvironment('Q1_THEME', defaultValue: 'dark');

const _profile = PlanProfile(distanceKm: [0, 1, 2, 3, 4, 5], groundM: [250, 262, 281, 270, 248, 251]);
const _link = PlanLinkResult(
  km: 5.2,
  profile: _profile,
  fresnelClearancePct: 64,
  tightest: PlanTightestPoint(km: 2.1, raiseM: 4),
  ridge: PlanRidge(km: 2.1),
  odds: 0.78,
  verdict: PlanVerdict.likely,
  marginDb: 8.5,
  provenance: PlanProvenance(terrain: 'AWS Terrain Tiles'),
);
const _verify = PlanVerifyResult(
  coveredKm2: 42.5,
  bands: [PlanBandArea('fringe', 'Fringe', 10), PlanBandArea('usable', 'Usable', 20), PlanBandArea('solid', 'Solid', 12.5)],
  links: [PlanPredictedLink(publicKey: 'ab', name: 'North Ridge', km: 6.2, marginDb: 7.1)],
  newAreaKm2: 18,
  newPeople: 4200,
  provenance: PlanProvenance(terrain: 'AWS Terrain Tiles'),
);

Future<void> shot(WidgetTester tester, String name) async {
  await settle(tester);
  final e = tester.takeException();
  if (!_live) expect(e, isNull, reason: name);
  if (!_live) return;
  // ignore: avoid_print
  print('SIMSHOT $name');
  await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 4)));
}

Future<void> size(WidgetTester tester, {double scale = 1.0}) async {
  final tiles = CoverageMap.tilesByDefault;
  CoverageMap.tilesByDefault = false;
  addTearDown(() => CoverageMap.tilesByDefault = tiles);
  if (!_live) {
    tester.view.physicalSize = const Size(402 * 3, 874 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  } else {
    // The live binding draws an 800 x 600 test surface letterboxed in the middle of the screen: use the whole screen.
    final d = tester.view.display;
    await tester.binding.setSurfaceSize(d.size / d.devicePixelRatio);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.platformDispatcher.platformBrightnessTestValue = _theme == 'light' ? Brightness.light : Brightness.dark;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

Future<void> _dismiss(WidgetTester tester) async {
  await tester.tapAt(const Offset(4, 70));
  await settle(tester);
}

RegionRepeater _rep(int i) => RegionRepeater(
      key: i.toRadixString(16).padLeft(2, '0') * 32,
      hashPrefix: i.toRadixString(16).padLeft(2, '0'),
      name: 'R$i',
      lat: 40.0 + (i % 4) * 0.01,
      lon: -83.0 + (i ~/ 4) * 0.01,
      status: RepeaterActivity.active,
    );

void main() {
  testWidgets('tour: the Planner', (tester) async {
    await size(tester);
    final h = Harness();
    h.client.planLinkResult = _link;
    h.client.planVerifyResult = _verify;
    final st = await openPlanner(tester, h);
    await shot(tester, '01-planner-empty-one-tap-start');
    final c = st.controller!;
    c.addNode(name: 'Water tower', lat: 40.11, lon: -82.95, mine: true);
    c.addNode(name: 'Ridge site', lat: 40.15, lon: -82.90);
    await settle(tester);
    st.selectNodeForTest(c.nodes.first.id);
    await shot(tester, '02-planner-link-result');
    await tapIn(tester, find.byKey(const Key('planner-mode-coverage')));
    await tapIn(tester, find.byKey(const Key('coverage-run')));
    await shot(tester, '03-planner-coverage');
    await tapIn(tester, find.byKey(const Key('planner-mode-findSites')));
    await tapIn(tester, find.byKey(const Key('sites-tab-wizard')));
    await shot(tester, '04-find-sites-wizard');
    await tapIn(tester, find.byKey(const Key('planner-mode-link')));
    st.selectNodeForTest(c.nodes.first.id);
    await settle(tester);
    await tapIn(tester, find.byKey(const Key('plan-selected-edit')));
    await shot(tester, '05-node-editor');
    await _dismiss(tester);
    await tapIn(tester, find.byKey(const Key('plan-radio-summary')));
    await shot(tester, '06-radio-and-clutter');
    await _dismiss(tester);
    final ctx = tester.element(find.byType(PlannerScreen));
    unawaited(showPlanShare(ctx, c.plan));
    await shot(tester, '07-share-sheet');
    await _dismiss(tester);
    unawaited(showPlanImport(ctx, controller: c, near: const PlanPoint(40.1, -82.9)));
    await shot(tester, '08-import-sheet');
    await _dismiss(tester);
    unawaited(showSavedPlans(ctx, saved: SavedPlans(h.planRepository), current: c));
    await shot(tester, '09-saved-plans');
    await _dismiss(tester);
    await drain(tester);
  });

  testWidgets('tour: the Planner at AX3 text', (tester) async {
    await size(tester, scale: 3.1);
    final h = Harness();
    h.client.planLinkResult = _link;
    final st = await openPlanner(tester, h);
    await shot(tester, '10-ax3-planner-empty');
    final c = st.controller!;
    c.addNode(name: 'Water tower', lat: 40.11, lon: -82.95);
    c.addNode(name: 'Ridge site', lat: 40.15, lon: -82.90);
    await settle(tester);
    st.selectNodeForTest(c.nodes.first.id);
    await shot(tester, '11-ax3-selected-node-and-link');
    await drain(tester);
  });

  testWidgets('tour: plan targets above repeater clusters', (tester) async {
    await size(tester);
    final overlay = PlanOverlayController();
    addTearDown(overlay.dispose);
    overlay.showPlan(const PlanOverlay(planId: 'p', nodes: [
      PlanOverlayNode(id: 'a', name: 'Water tower', at: LatLng(39.75, -83.35), kind: PlanOverlayNodeKind.planned),
      PlanOverlayNode(id: 'b', name: 'Barn', at: LatLng(40.28, -82.62), kind: PlanOverlayNodeKind.installed),
    ], links: [PlanOverlayLink(fromId: 'a', toId: 'b', verdict: PlanLinkVerdict.likely)]));
    overlay.showTargets(const [
      MapFocusTarget(id: 'link-ridge', at: LatLng(40.015, -82.985), label: 'Ridge'),
      MapFocusTarget(id: 'link-relay-0', at: LatLng(40.25, -83.2), label: 'R1'),
    ]);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: _theme == 'light' ? Brightness.light : Brightness.dark),
      home: Scaffold(
        body: CoverageMap(
          pings: const [],
          showTiles: false,
          fallbackCenter: const LatLng(40.015, -82.99),
          layerState: kDefaultLayerState.toggle(kPlanLayerId, true),
          regionRepeaters: [for (var i = 0; i < 16; i++) _rep(i)],
          planOverlay: overlay,
        ),
      ),
    ));
    await shot(tester, '12-plan-targets-over-clusters');
  });

  testWidgets('tour: Settings > Observer and the feed sheets', (tester) async {
    await size(tester);
    final h = Harness();
    h.settings.saved = const Settings(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved, display: 'KD8XYZ', mqttSlots: [
      MqttSlotSettings(id: 'slot-1', presetId: 'corecomms', name: 'CoreComms', host: 'mqtt.corecomms.net', wsPath: '/mqtt'),
    ]);
    h.observerEngineFactory = FakeObserverEngine.new;
    ObserverPresets.debugStore = MqttPresetStore(loadBundled: () => rootBundle.loadString(ObserverPresets.asset), fetcher: () => h.client.mqttPresets);
    addTearDown(() => ObserverPresets.debugStore = null);
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await showSetting(tester, 'observer-share-toggle');
    await shot(tester, '13-settings-observer');
    await showSetting(tester, 'mqtt-add-feed');
    await shot(tester, '14-mqtt-feeds');
    await showSetting(tester, 'mqtt-slot-slot-1');
    await tester.tap(find.byKey(const Key('mqtt-slot-slot-1')));
    await settleIo(tester);
    await shot(tester, '15-mqtt-feed-sheet');
    await drain(tester);
  });

  testWidgets('tour: the repeater observer guide', (tester) async {
    await size(tester);
    await Harness().pumpApp(tester);
    await openScreen(tester, const ObserverJoinScreen());
    await shot(tester, '16-observer-guide');
  });
}
