// Release 0.38 A4 (plan §4.5 item 1): the map extension points. The `plan` layer drawn from an overlay provider (planned,
// installed and target markers, links), plan-node taps as PlanNodeHit (wins over a ping), long-press as LongPressHit, the main
// map applying "open the map with this overlay" requests, the default plan node sheet (Navigate, Remove plan from map), and
// the Drive map model keeping the plan layer off by default and never remembering it.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_definition.dart' show MapDefinition;
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/plan_layer.dart';
import 'package:meshsonar/ui/map/layers/plan_overlay.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart' show kRosterLayerId;
import 'package:meshsonar/ui/map/main_map_focus.dart';
import 'package:meshsonar/ui/ping_detail_sheet.dart' show PingDetailSheet;

import '../fakes.dart';

const _here = LatLng(40.0, -83.0);
const _a = PlanOverlayNode(id: 'a', name: 'Hilltop', at: _here);
const _b = PlanOverlayNode(id: 'b', name: 'Water tower', at: LatLng(40.02, -83.0), kind: PlanOverlayNodeKind.installed);
const _plan = PlanOverlay(planId: 'p1', nodes: [_a, _b], links: [PlanOverlayLink(fromId: 'a', toId: 'b', verdict: PlanLinkVerdict.likely)]);

MapLayerState _withPlan(bool on) => kDefaultLayerState.toggle(kPlanLayerId, on);

void main() {
  tearDown(() {
    MainMapFocus.overlay.clear();
    MainMapFocus.overlay.resolvePlan = null;
    MainMapFocus.notifier.value = null;
  });

  group('PlanOverlayController', () {
    test('a request with targets draws them; a plan id goes through resolvePlan; a plain request changes nothing', () async {
      final c = PlanOverlayController();
      var changes = 0;
      c.addListener(() => changes++);
      await c.applyFocus(MapFocusRequest(_here, 12, 1));
      expect(changes, 0);
      expect(c.isActive, isFalse);

      c.resolvePlan = (id) async => id == 'p1' ? _plan : null;
      await c.applyFocus(MapFocusRequest(_here, 12, 2,
          showLayers: const {kPlanLayerId}, planId: 'p1', targets: const [MapFocusTarget(id: 't1', at: LatLng(40.1, -83.1), label: 'Site 1')]));
      expect(c.isActive, isTrue);
      expect(c.requestedLayers, {kPlanLayerId});
      expect(c.requestSeq, 1);
      expect([for (final n in c.drawnNodes) n.id], ['a', 'b', 't1']);
      expect(c.nodeById('t1')!.kind, PlanOverlayNodeKind.target);
      expect(c.plan.links.single.verdict, PlanLinkVerdict.likely);

      c.clear();
      expect(c.isActive, isFalse);
      expect(c.requestedLayers, isEmpty);
      expect(c.drawnNodes, isEmpty);
    });

    test('a slow resolve of an older request never overwrites a newer plan; a failing resolve draws nothing', () async {
      final c = PlanOverlayController();
      c.resolvePlan = (id) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (id == 'bad') throw StateError('unreadable');
        return PlanOverlay(planId: id, nodes: [PlanOverlayNode(id: id, name: id, at: _here)]);
      };
      final old = c.applyFocus(MapFocusRequest(_here, 12, 1, planId: 'old'));
      c.showPlan(_plan);
      await old;
      expect(c.plan.planId, 'p1');
      await c.applyFocus(MapFocusRequest(_here, 12, 2, planId: 'bad'));
      expect(c.plan.planId, 'p1');
    });
  });

  test('plan symbol style reads the Map Definition (symbols.plan): purple, dashed links, verdict bands', () {
    final s = PlanSymbolStyle.of(MapDefinition.bundled, dark: true);
    expect(s.disc, const Color(0xFFCE93D8));
    expect(s.linkDash, [6, 4]);
    expect(s.verdictBand['likely'], 5);
    final l = PlanSymbolStyle.of(MapDefinition.bundled, dark: false);
    expect(l.disc, const Color(0xFF6A1B9A));
  });

  group('CoverageMap plan layer, plan-node hits, long-press', () {
    Future<Harness> pump(
      WidgetTester tester, {
      required PlanOverlayController overlay,
      bool planOn = true,
      List<DrivePing> pings = const [],
      MapHitHandler<PlanNodeHit>? onPlanNode,
      MapHitHandler<LongPressHit>? onLongPress,
      bool takesFocusRequests = false,
      bool passOverlay = true,
    }) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.dark),
          home: Scaffold(
            body: CoverageMap(
              pings: pings,
              position: _here,
              follow: false,
              showTiles: false,
              layerState: _withPlan(planOn),
              planOverlay: passOverlay ? overlay : null,
              takesFocusRequests: takesFocusRequests,
              onPlanNode: onPlanNode,
              onLongPress: onLongPress,
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      return h;
    }

    testWidgets('draws planned, installed and target markers and the link while the plan layer is on; nothing when off', (tester) async {
      final o = PlanOverlayController()
        ..showPlan(_plan)
        ..showTargets(const [MapFocusTarget(id: 't1', at: LatLng(39.99, -83.0), label: 'Site 1')]);
      await pump(tester, overlay: o);
      expect(find.byKey(const Key('plan-layer')), findsOneWidget);
      expect(find.byKey(const Key('plan-links-layer')), findsOneWidget);
      for (final id in ['a', 'b', 't1']) {
        expect(find.byKey(ValueKey('plan-node-$id')), findsOneWidget);
      }
      expect(find.bySemanticsLabel('Planned site: Hilltop'), findsOneWidget);
      expect(find.bySemanticsLabel('Installed: Water tower'), findsOneWidget);
      expect(find.bySemanticsLabel('Target: Site 1'), findsOneWidget);

      // The provider hook: a change redraws.
      o.clear();
      await tester.pump();
      expect(find.byKey(const ValueKey('plan-node-a')), findsNothing);

      await pump(tester, overlay: PlanOverlayController()..showPlan(_plan), planOn: false);
      expect(find.byKey(const Key('plan-layer')), findsNothing);
      expect(find.byKey(const ValueKey('plan-node-a')), findsNothing);
    });

    testWidgets('a tap on a plan node is a PlanNodeHit for the host, and it wins over a ping under it', (tester) async {
      final hits = <PlanNodeHit>[];
      final ping = DrivePing(id: 'p1', ts: DateTime.utc(2026, 11, 15, 12), lat: _here.latitude, lon: _here.longitude);
      await pump(tester, overlay: PlanOverlayController()..showPlan(_plan), pings: [ping], onPlanNode: (_, h) async {
        hits.add(h);
        return true;
      });
      expect(find.byKey(const ValueKey('map-ping-tap-p1')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('plan-node-a')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(hits.single.nodeId, 'a');
      expect(hits.single.name, 'Hilltop');
      expect(hits.single.lat, closeTo(40.0, 1e-9));
      expect(find.byType(PingDetailSheet), findsNothing);
    });

    testWidgets('long-press on bare map is a LongPressHit at that spot; on a plan node it is that node', (tester) async {
      final presses = <LongPressHit>[];
      final nodes = <PlanNodeHit>[];
      await pump(
        tester,
        overlay: PlanOverlayController()..showPlan(_plan),
        onPlanNode: (_, h) async {
          nodes.add(h);
          return true;
        },
        onLongPress: (_, h) async {
          presses.add(h);
          return true;
        },
      );
      final map = tester.getRect(find.byType(CoverageMap));
      await tester.longPressAt(map.center + const Offset(120, 200));
      await tester.pump(const Duration(milliseconds: 200));
      expect(presses, hasLength(1));
      expect(presses.single.lat, lessThan(40.0)); // below the centre = south
      expect(presses.single.lon, greaterThan(-83.0)); // right of the centre = east
      expect(nodes, isEmpty);

      await tester.longPress(find.byKey(const ValueKey('plan-node-a')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(nodes.single.nodeId, 'a');
      expect(presses, hasLength(1));
    });

    testWidgets('no long-press handler: a long-press opens nothing (the map as before)', (tester) async {
      await pump(tester, overlay: PlanOverlayController());
      final map = tester.getRect(find.byType(CoverageMap));
      await tester.longPressAt(map.center + const Offset(80, 120));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const Key('plan-node-sheet')), findsNothing);
    });

    testWidgets('main map: takes an overlay request into MainMapFocus.overlay; the default sheet navigates and removes the plan', (tester) async {
      final h = await pump(tester, overlay: MainMapFocus.overlay, takesFocusRequests: true, passOverlay: false);
      MainMapFocus.request(_here, 13, showLayers: const {kPlanLayerId}, targets: const [MapFocusTarget(id: 't1', at: _here, label: 'Site 1')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(MainMapFocus.notifier.value, isNull); // taken
      expect(MainMapFocus.overlay.targets.single.id, 't1');
      expect(find.byKey(const ValueKey('plan-node-t1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('plan-node-t1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('plan-node-sheet')), findsOneWidget);
      expect(find.text('Site 1'), findsWidgets);
      expect(find.byKey(const Key('plan-node-sheet-kind')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('plan-node-sheet-kind'))).data, 'Target');

      await tester.tap(find.byKey(const Key('plan-node-sheet-navigate')));
      await tester.pump();
      expect(h.openedUrls.single.host, 'maps.apple.com');
      expect(h.openedUrls.single.queryParameters['daddr'], '40.000000,-83.000000');

      await tester.tap(find.byKey(const Key('plan-node-sheet-remove')));
      await tester.pumpAndSettle();
      expect(MainMapFocus.overlay.isActive, isFalse);
      expect(find.byKey(const ValueKey('plan-node-t1')), findsNothing);
    });

    testWidgets('a secondary map (takesFocusRequests false) leaves the request for the main map', (tester) async {
      await pump(tester, overlay: PlanOverlayController());
      MainMapFocus.request(_here, 13, targets: const [MapFocusTarget(id: 't1', at: _here, label: 'Site 1')]);
      await tester.pump(const Duration(milliseconds: 200));
      expect(MainMapFocus.notifier.value, isNotNull);
      expect(MainMapFocus.overlay.isActive, isFalse);
    });
  });

  group('Drive map model: the plan layer', () {
    testWidgets('off by default; on while the main overlay draws something; never remembered; off again on Remove', (tester) async {
      final h = Harness();
      await h.pumpApp(tester);
      final prefs = MapPrefs();
      final model = DriveMapModel(h.state, prefs: prefs);
      addTearDown(model.dispose);
      expect(model.layerState.isOn(kPlanLayerId), isFalse);

      await MainMapFocus.overlay.applyFocus(MapFocusRequest(_here, 13, 1,
          showLayers: const {kPlanLayerId, kRosterLayerId}, targets: const [MapFocusTarget(id: 't1', at: _here, label: 'Site 1')]));
      expect(model.layerState.isOn(kPlanLayerId), isTrue);
      expect(model.layerState.isOn(kRosterLayerId), isTrue); // asked for by the request, like the person switched it on
      expect(prefs.layerPrefs(kDriveLayerPage).toggles.containsKey(kPlanLayerId), isFalse);

      MainMapFocus.overlay.clear();
      expect(model.layerState.isOn(kPlanLayerId), isFalse);
      expect(prefs.layerPrefs(kDriveLayerPage).toggles.containsKey(kPlanLayerId), isFalse);
    });

    testWidgets('a saved plan choice from an older file is ignored', (tester) async {
      final h = Harness();
      await h.pumpApp(tester);
      final prefs = MapPrefs()..setLayerPrefs(kDriveLayerPage, const LayerPrefs(toggles: {kPlanLayerId: true}));
      final model = DriveMapModel(h.state, prefs: prefs);
      addTearDown(model.dispose);
      expect(model.layerState.isOn(kPlanLayerId), isFalse);
    });
  });
}
