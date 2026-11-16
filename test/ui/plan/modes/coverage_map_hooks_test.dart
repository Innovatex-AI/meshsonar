// The two additive CoverageMap seams the Planner asked for (release 0.38 A9, A7 REQUESTs 1-2): host layers under the plan
// layer (`extraLayers`, the coverage footprint) and dragging plan nodes (`onPlanNodeDrag` / `onPlanNodeDragEnd`). Without
// them the map is as before: no drag handles, a long-press on a node is a PlanNodeHit.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/plan_overlay.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/main_map_focus.dart';

import '../../fakes.dart';

const _here = LatLng(40.0, -83.0);
const _plan = PlanOverlay(planId: 'p1', nodes: [
  PlanOverlayNode(id: 'a', name: 'Hilltop', at: _here),
  PlanOverlayNode(id: 'b', name: 'Water tower', at: LatLng(40.02, -83.0), kind: PlanOverlayNodeKind.installed),
]);

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required PlanOverlayController overlay,
    List<Widget> extraLayers = const [],
    void Function(String, LatLng)? onDrag,
    void Function(String, LatLng)? onDragEnd,
    MapHitHandler<PlanNodeHit>? onPlanNode,
    MapHitHandler<LongPressHit>? onLongPress,
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
            pings: const [],
            position: _here,
            follow: false,
            showTiles: false,
            layerState: kDefaultLayerState.toggle(kPlanLayerId, true),
            planOverlay: overlay,
            extraLayers: extraLayers,
            onPlanNodeDrag: onDrag,
            onPlanNodeDragEnd: onDragEnd,
            onPlanNode: onPlanNode,
            onLongPress: onLongPress,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
  }

  tearDown(() {
    MainMapFocus.overlay.clear();
    MainMapFocus.notifier.value = null;
  });

  testWidgets('extraLayers draw inside the map, under the plan layer', (tester) async {
    await pump(tester, overlay: PlanOverlayController()..showPlan(_plan), extraLayers: const [SizedBox.expand(key: Key('host-layer'))]);
    expect(find.byKey(const Key('host-layer')), findsOneWidget);
    final stackOrder = tester.widgetList(find.byWidgetPredicate((w) => w.key == const Key('host-layer') || w.key == const Key('plan-layer'))).map((w) => w.key).toList();
    expect(stackOrder, [const Key('host-layer'), const Key('plan-layer')], reason: 'the plan markers are drawn over the host layer');
  });

  testWidgets('by default there are no drag handles and a long-press on a node is a PlanNodeHit (the Drive map as before)', (tester) async {
    final nodes = <PlanNodeHit>[];
    await pump(tester, overlay: PlanOverlayController()..showPlan(_plan), onPlanNode: (_, h) async {
      nodes.add(h);
      return true;
    }, onLongPress: (_, _) async => true);
    expect(find.byKey(const Key('plan-drag-layer')), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('plan-node-a')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(nodes.single.nodeId, 'a');
  });

  testWidgets('long-press and drag moves a plan node: every step reported, the end where it was let go; targets get no handle', (tester) async {
    final o = PlanOverlayController()
      ..showPlan(_plan)
      ..showTargets(const [MapFocusTarget(id: 't1', at: LatLng(39.99, -83.0), label: 'Site 1')]);
    final steps = <(String, LatLng)>[];
    (String, LatLng)? end;
    final taps = <PlanNodeHit>[];
    await pump(
      tester,
      overlay: o,
      onDrag: (id, at) => steps.add((id, at)),
      onDragEnd: (id, at) => end = (id, at),
      onPlanNode: (_, h) async {
        taps.add(h);
        return true;
      },
      onLongPress: (_, _) async => true,
    );
    expect(find.byKey(const ValueKey('plan-drag-a')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-drag-b')), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-drag-t1')), findsNothing, reason: 'a target is not the plan\'s to move');

    final start = tester.getCenter(find.byKey(const ValueKey('plan-drag-a')));
    final g = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 700)); // past the long-press deadline
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    await g.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(steps, isNotEmpty);
    expect(steps.every((s) => s.$1 == 'a'), isTrue);
    expect(end, isNotNull);
    expect(end!.$1, 'a');
    expect(end!.$2.longitude, greaterThan(_here.longitude), reason: 'dragged east');
    expect(end!.$2.latitude, closeTo(_here.latitude, 1e-3));
    expect(taps, isEmpty, reason: 'a drag is not a tap');

    // A tap on the handle is still the node's tap; a long-press let go without moving is the long-press on the node.
    await tester.tap(find.byKey(const ValueKey('plan-drag-b')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(taps.single.nodeId, 'b');
    await tester.longPress(find.byKey(const ValueKey('plan-drag-b')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(taps, hasLength(2));
    expect(steps.where((s) => s.$1 == 'b'), isEmpty);
  });
}
