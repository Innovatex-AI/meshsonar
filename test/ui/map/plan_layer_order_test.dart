// The plan layer draws above the repeater clusters (release 0.38 Q1, the A8 note: a ridge flag or relay pin must never hide
// under a cluster at low zoom). The plan's targets and nodes are painted after the clustered repeater painter, the names
// and the host's extra layers, and a tap on a target that sits on a cluster goes to the target.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart' show PlanNodeHit;
import 'package:meshsonar/ui/map/layers/plan_overlay.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_painter_layer.dart';
import 'package:meshsonar/ui/map/main_map_focus.dart' show MapFocusTarget;

RegionRepeater _rep(int i) => RegionRepeater(
      key: i.toRadixString(16).padLeft(2, '0') * 32,
      hashPrefix: i.toRadixString(16).padLeft(2, '0'),
      name: 'R$i',
      lat: 40.0 + (i % 3) * 0.004,
      lon: -83.0 + (i ~/ 3) * 0.004,
      status: RepeaterActivity.active,
    );

/// The order the map paints its layers in: a depth-first walk of the element tree (a Stack paints its children in order).
List<String> _paintOrder(WidgetTester tester, Map<String, Key> keys) {
  final seen = <String>[];
  void visit(Element e) {
    for (final k in keys.entries) {
      if (e.widget.key == k.value && !seen.contains(k.key)) seen.add(k.key);
    }
    e.visitChildren(visit);
  }

  visit(tester.binding.rootElement!);
  return seen;
}

void main() {
  testWidgets('plan targets and nodes are painted above repeater clusters and the host layers; a tap on a target wins', (tester) async {
    final overlay = PlanOverlayController();
    addTearDown(overlay.dispose);
    overlay.showPlan(const PlanOverlay(planId: 'p', nodes: [
      PlanOverlayNode(id: 'n1', name: 'Planned site', at: LatLng(40.03, -83.03), kind: PlanOverlayNodeKind.planned),
    ]));
    // The ridge flag of a link sits right on the clustered repeaters.
    overlay.showTargets(const [MapFocusTarget(id: 'link-ridge', at: LatLng(40.004, -82.996), label: 'Ridge')]);
    final hits = <PlanNodeHit>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 400,
            child: CoverageMap(
              pings: const [],
              showTiles: false,
              fallbackCenter: const LatLng(40.004, -82.996),
              layerState: kDefaultLayerState.toggle(kPlanLayerId, true),
              regionRepeaters: [for (var i = 0; i < 9; i++) _rep(i)],
              planOverlay: overlay,
              extraLayers: const [SizedBox.shrink(key: Key('host-extra-layer'))],
              onPlanNode: (context, hit) async {
                hits.add(hit);
                return true;
              },
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(RepeaterPainterLayer.paintKey), findsOneWidget, reason: 'the clusters are drawn');
    expect(find.byKey(const ValueKey('plan-node-link-ridge')), findsOneWidget, reason: 'the ridge flag is drawn');

    final order = _paintOrder(tester, {
      'clusters': RepeaterPainterLayer.paintKey,
      'extra': const Key('host-extra-layer'),
      'plan': const Key('plan-layer'),
    });
    expect(order, ['clusters', 'extra', 'plan'], reason: 'the plan layer is painted last, over the clusters');

    await tester.tap(find.byKey(const ValueKey('plan-node-link-ridge')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(hits.map((h) => h.nodeId), ['link-ridge'], reason: 'the target, not the cluster under it, takes the tap');
    expect(find.byKey(const Key('repeater-sheet')), findsNothing);
  });
}
