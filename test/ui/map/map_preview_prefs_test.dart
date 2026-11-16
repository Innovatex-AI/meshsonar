// Release 0.38 A4 (plan §4.5: "MapPreview ignores the user's layer prefs"): previews read the person's LayerPrefs under the
// new page ids `detail` and `plan`, falling back to the Drive map's choice; they never add a layer the page did not ask for.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/ui/map/layers/plan_overlay.dart';
import 'package:meshsonar/ui/map/layers/registry.dart' show kHeardCellsLayerId, kPlanLayerId;
import 'package:meshsonar/ui/map/map_preview.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  group('MapPrefs page ids', () {
    test('plan and detail are their own pages next to drive, and round-trip through the file', () {
      expect(kMapLayerPages, [kDriveLayerPage, kPlanLayerPage, kDetailLayerPage]);
      expect(kPlanLayerPage, 'plan');
      expect(kDetailLayerPage, 'detail');
      final p = MapPrefs()
        ..setLayerPrefs(kPlanLayerPage, const LayerPrefs(toggles: {'measured': false}))
        ..setLayerPrefs(kDetailLayerPage, const LayerPrefs(toggles: {'predicted': false}));
      final back = MapPrefs()..applyJson(jsonDecode(jsonEncode(p.toJson())));
      expect(back.layerPrefs(kPlanLayerPage).toggles, {'measured': false});
      expect(back.layerPrefs(kDetailLayerPage).toggles, {'predicted': false});
      expect(back.layerPrefs(kDriveLayerPage), LayerPrefs.empty);
    });

    test('previewLayerOn: the page wins, then the Drive map, then the fallback', () {
      final p = MapPrefs();
      expect(p.previewLayerOn(kDetailLayerPage, 'measured', fallback: true), isTrue);
      p.setLayerPrefs(kDriveLayerPage, const LayerPrefs(toggles: {'measured': false}));
      expect(p.previewLayerOn(kDetailLayerPage, 'measured', fallback: true), isFalse);
      p.setLayerPrefs(kDetailLayerPage, const LayerPrefs(toggles: {'measured': true}));
      expect(p.previewLayerOn(kDetailLayerPage, 'measured', fallback: true), isTrue);
      expect(p.previewLayerOn(kDriveLayerPage, 'measured', fallback: true), isFalse);
      expect(p.previewLayerOn(kPlanLayerPage, 'predicted', fallback: false), isFalse);
    });
  });

  group('MapPreview reads the prefs', () {
    test('a layer switched off (page or Drive) is dropped; nothing the page did not ask for is added', () {
      final p = MapPrefs();
      const preview = MapPreview(coverage: {'measured', 'predicted'});
      expect(preview.effectiveCoverage(p), {'measured', 'predicted'});
      p.setLayerPrefs(kDriveLayerPage, const LayerPrefs(toggles: {'predicted': false, kHeardCellsLayerId: true}));
      expect(preview.effectiveCoverage(p), {'measured'});
      p.setLayerPrefs(kDetailLayerPage, const LayerPrefs(toggles: {'predicted': true, 'measured': false}));
      expect(preview.effectiveCoverage(p), {'predicted'});
      // The plan page keeps its own choice.
      const plan = MapPreview(coverage: {'measured', 'predicted'}, layerPage: kPlanLayerPage);
      expect(plan.effectiveCoverage(p), {'measured'});
      expect(const MapPreview().effectiveCoverage(p), isEmpty);
    });

    testWidgets('draws the plan overlay on top; the page switching the plan layer off hides it, live', (tester) async {
      final prefs = MapPrefs();
      final overlay = PlanOverlayController()..showPlan(const PlanOverlay(nodes: [PlanOverlayNode(id: 'a', name: 'Hilltop', at: LatLng(40, -83))]));
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: SizedBox(
          width: 300,
          height: 200,
          child: MapPreview(center: const LatLng(40, -83), tiles: false, layerPage: kPlanLayerPage, prefs: prefs, planOverlay: overlay),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const ValueKey('plan-node-a')), findsOneWidget);
      prefs.setLayerPrefs(kPlanLayerPage, const LayerPrefs(toggles: {kPlanLayerId: false}));
      await tester.pump();
      expect(find.byKey(const ValueKey('plan-node-a')), findsNothing);
    });
  });
}
