// Repeater name labels: the pure placer (zoom budget, priority, collisions, overlays, edges) and the map wiring
// (default on, off in the layers state, persisted switch, one painter).
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/layers_sheet.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/layers/repeater_name_labels.dart';
import 'package:meshsonar/ui/map/map_layers.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';

LabelCandidate cand(String id, double x, double y, {int priority = 1, double? distance, bool label = true, double r = 10, String? text}) =>
    LabelCandidate(id: id, text: text ?? 'Repeater $id', anchor: Offset(x, y), markerRadius: r, priority: priority, distance: distance ?? x, label: label);

Size measure(String t) => Size(t.length * 6.0 + 6, 16);
const bounds = Rect.fromLTWH(0, 0, 400, 600);

List<String> ids(List<PlacedLabel> l) => [for (final p in l) p.candidate.id];

void main() {
  group('zoom budget', () {
    test('nothing below the lowest zoom, then more labels as you zoom in', () {
      expect(labelBudgetForZoom(kLabelMinZoomHeard - 0.1), 0);
      var last = 0;
      for (var z = 0.0; z <= 20; z += 0.25) {
        final b = labelBudgetForZoom(z);
        expect(b, greaterThanOrEqualTo(last));
        last = b;
      }
      expect(labelBudgetForZoom(9), lessThan(labelBudgetForZoom(12)));
      expect(labelBudgetForZoom(15), 60);
    });
  });

  group('placement', () {
    test('a lone repeater is labelled to its right', () {
      final p = placeRepeaterLabels(candidates: [cand('a', 100, 100)], measure: measure, bounds: bounds, budget: 10);
      expect(p, hasLength(1));
      expect(p.single.rect.left, greaterThan(100));
      expect(p.single.rect.center.dy, closeTo(100, 0.01));
    });

    test('budget 0 draws nothing; the budget caps the count', () {
      final cs = [for (var i = 0; i < 20; i++) cand('r$i', 20.0, 20.0 + i * 25)];
      expect(placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 0), isEmpty);
      expect(placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 5), hasLength(5));
    });

    test('heard this drive wins over nearer repeaters; then nearest first', () {
      // Two markers so close that only one label fits between them.
      final cs = [
        cand('near', 100, 100, distance: 1, text: 'Near'),
        cand('heard', 100, 108, priority: 0, distance: 50, text: 'Heard'),
        cand('far', 100, 116, distance: 5, text: 'Far'),
      ];
      final p = placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 1);
      expect(ids(p), ['heard']);
      final two = placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 3);
      expect(ids(two).first, 'heard');
    });

    test('labels never overlap each other or any marker', () {
      final cs = [for (var i = 0; i < 60; i++) cand('r$i', 20.0 + (i % 10) * 36, 20.0 + (i ~/ 10) * 40, distance: i.toDouble())];
      final p = placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 100);
      expect(p, isNotEmpty);
      for (var i = 0; i < p.length; i++) {
        for (var j = i + 1; j < p.length; j++) {
          expect(p[i].rect.overlaps(p[j].rect), isFalse, reason: '${p[i].candidate.id} vs ${p[j].candidate.id}');
        }
        for (final c in cs) {
          if (c.id == p[i].candidate.id) continue;
          expect(p[i].rect.overlaps(Rect.fromCircle(center: c.anchor, radius: c.markerRadius)), isFalse, reason: '${p[i].candidate.id} covers ${c.id}');
        }
      }
    });

    test('falls back to the left near the right edge, and drops a label that fits nowhere', () {
      final edge = placeRepeaterLabels(candidates: [cand('e', 380, 100)], measure: measure, bounds: bounds, budget: 5);
      expect(edge.single.rect.right, lessThanOrEqualTo(380));
      final none = placeRepeaterLabels(candidates: [cand('x', 200, 100, text: 'A very long repeater name that cannot fit anywhere in the box')], measure: measure, bounds: const Rect.fromLTWH(190, 90, 30, 30), budget: 5);
      expect(none, isEmpty);
    });

    test('overlay rectangles (heard box, report card, buttons) are kept clear', () {
      const box = Rect.fromLTWH(0, 0, 400, 130);
      final p = placeRepeaterLabels(
        candidates: [cand('under', 100, 60), cand('clear', 100, 300)],
        measure: measure,
        bounds: bounds,
        obstacles: const [box],
        budget: 5,
      );
      expect(ids(p), ['clear']);
    });

    test('markers that are not labelled (selected, own tag) still block others', () {
      final p = placeRepeaterLabels(
        candidates: [cand('sel', 100, 100, label: false, r: 30), cand('b', 60, 100, r: 6)],
        measure: measure,
        bounds: const Rect.fromLTWH(0, 0, 200, 200),
        budget: 5,
      );
      // 'sel' is not labelled and its footprint is in the way of b's right side; b goes elsewhere (or nowhere), never on it.
      for (final l in p) {
        expect(l.rect.overlaps(Rect.fromCircle(center: const Offset(100, 100), radius: 30)), isFalse);
      }
      expect(ids(p), isNot(contains('sel')));
    });

    test('deterministic: same input, same output', () {
      final cs = [for (var i = 0; i < 30; i++) cand('r$i', 15.0 + (i * 37) % 360, 20.0 + (i * 53) % 560, distance: (i * 7 % 11).toDouble())];
      final a = placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 40);
      final b = placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 40);
      expect([for (final p in a) (p.candidate.id, p.rect)], [for (final p in b) (p.candidate.id, p.rect)]);
    });
  });

  group('registry and settings', () {
    test('Repeater names is a registered app-only layer, default on, listed in the sheet', () {
      final spec = layerSpec(kLabelsLayerId)!;
      expect(spec.defaultOn, isTrue);
      expect(spec.onWebsite, isFalse);
      expect(kDrawnLayerIds, contains(kLabelsLayerId));
      expect(kDefaultLayerState.isOn(kLabelsLayerId), isTrue);
    });

    test('the choice persists in Settings (written only when off)', () {
      expect(const Settings().mapRepeaterLabels, isTrue);
      expect(const Settings().toJson().containsKey('map_repeater_labels'), isFalse);
      final off = const Settings().copyWith(mapRepeaterLabels: false);
      expect(off.toJson()['map_repeater_labels'], false);
      expect(Settings.fromJson(off.toJson()).mapRepeaterLabels, isFalse);
      expect(Settings.fromJson({'map_repeater_labels': 'nope'}).mapRepeaterLabels, isTrue);
    });

    test('the model starts from the saved choice and saves a switch', () async {
      final h = Harness();
      await h.state.init();
      final model = DriveMapModel(h.state);
      addTearDown(model.dispose);
      expect(model.layerState.isOn(kLabelsLayerId), isTrue);
      model.setLayer(kLabelsLayerId, false);
      await Future<void>.delayed(Duration.zero);
      expect(h.state.settings.mapRepeaterLabels, isFalse);
      // A fresh model (next app start) comes up with it off.
      final next = DriveMapModel(h.state);
      addTearDown(next.dispose);
      expect(next.layerState.isOn(kLabelsLayerId), isFalse);
      // The bool-bag setter used by older callers keeps the choice.
      next.layers = next.layers.copyWith(rings: false);
      expect(next.layerState.isOn(kLabelsLayerId), isFalse);
    });
  });

  group('on the map', () {
    const a = RepeaterRef(key: 'a1b2c3d4e5', name: 'Westerville Water Tower', lat: 40.13, lon: -82.925);
    const b = RepeaterRef(key: 'ff09aa11', name: 'Otterbein Hill', lat: 40.12, lon: -82.95);

    Future<void> pump(WidgetTester tester, {required MapLayerState state, double? width}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          home: Scaffold(
            body: SizedBox(
              width: width ?? 600,
              height: 600,
              child: CoverageMap(pings: const [], repeaters: const [a, b], position: const LatLng(40.126, -82.93), layerState: state, layers: const MapLayers()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('labels are drawn by default and gone when the layer is off', (tester) async {
      await pump(tester, state: kDefaultLayerState);
      expect(find.byKey(const ValueKey('repeater-name-labels-paint')), findsOneWidget);
      await pump(tester, state: kDefaultLayerState.toggle(kLabelsLayerId, false));
      expect(find.byKey(const ValueKey('repeater-name-labels-paint')), findsNothing);
    });

    testWidgets('a marker is spoken with its name', (tester) async {
      final h = tester.ensureSemantics();
      await pump(tester, state: kDefaultLayerState);
      expect(find.bySemanticsLabel('Repeater Westerville Water Tower'), findsOneWidget);
      h.dispose();
    });

    testWidgets('huge Dynamic Type still lays out', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pump(tester, state: kDefaultLayerState);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('repeater-name-labels-paint')), findsOneWidget);
    });
  });
}
