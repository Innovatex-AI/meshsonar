// Repeater name labels: the pure placer (zoom budget, priority, collisions, overlays, edges) and the map wiring
// (default on, off in the layers state, persisted switch, one painter).
import 'dart:math' as math;

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
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
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';
import 'repeater_probe.dart';

LabelCandidate cand(String id, double x, double y, {int priority = LabelPriority.rest, double? distance, bool label = true, double r = 10, String? text}) =>
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
      expect(labelBudgetForZoom(15), 80);
      expect([for (final z in [8.9, 9.0, 11.0, 12.0, 13.0, 14.0]) labelBudgetForZoom(z)], [0, 12, 24, 40, 56, 80]);
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
        cand('heard', 100, 108, priority: LabelPriority.heard, distance: 50, text: 'Heard'),
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

  group('grid, priority and cost', () {
    test('the grid gives exactly the same placement as the pairwise test it replaces', () {
      final rnd = math.Random(7);
      final cs = [for (var i = 0; i < 300; i++) cand('r$i', 10 + rnd.nextDouble() * 380, 10 + rnd.nextDouble() * 580, distance: rnd.nextDouble() * 500)];
      final placed = placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 80);
      // Brute force reference of the same greedy rule.
      final order = [...cs]..sort((a, b) {
        final p = a.priority.compareTo(b.priority);
        if (p != 0) return p;
        final d = a.distance.compareTo(b.distance);
        return d != 0 ? d : a.id.compareTo(b.id);
      });
      final ref = <PlacedLabel>[];
      for (final c in order) {
        if (ref.length >= 80) break;
        final s = measure(c.text);
        final a = c.anchor, r = c.markerRadius + 4;
        for (final box in [
          Rect.fromLTWH(a.dx + r, a.dy - s.height / 2, s.width, s.height),
          Rect.fromLTWH(a.dx - r - s.width, a.dy - s.height / 2, s.width, s.height),
          Rect.fromLTWH(a.dx - s.width / 2, a.dy - r - s.height, s.width, s.height),
          Rect.fromLTWH(a.dx - s.width / 2, a.dy + r, s.width, s.height),
        ]) {
          if (box.left < bounds.left || box.right > bounds.right || box.top < bounds.top || box.bottom > bounds.bottom) continue;
          if (cs.any((o) => o.id != c.id && Rect.fromCircle(center: o.anchor, radius: o.markerRadius).overlaps(box))) continue;
          if (ref.any((p) => p.rect.overlaps(box))) continue;
          ref.add(PlacedLabel(c, box));
          break;
        }
      }
      expect([for (final p in placed) (p.candidate.id, p.rect)], [for (final p in ref) (p.candidate.id, p.rect)]);
    });

    test('priority: selected, heard on the last ping, heard, fresh advert, then the rest by distance', () {
      final cs = [
        cand('rest', 100, 100, distance: 1),
        cand('fresh', 100, 104, priority: LabelPriority.freshAdvert, distance: 9),
        cand('heard', 100, 108, priority: LabelPriority.heard, distance: 9),
        cand('last', 100, 112, priority: LabelPriority.heardLast, distance: 9),
        cand('sel', 100, 116, priority: LabelPriority.selected, distance: 99),
      ];
      final order = ids(placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 5));
      // They crowd each other: whatever is placed follows the priority order.
      const rank = ['sel', 'last', 'heard', 'fresh', 'rest'];
      final idx = [for (final i in order) rank.indexOf(i)];
      expect(idx, [...idx]..sort());
      expect(order.first, 'sel');
    });

    test('a label sits badge radius + 4 pt from the marker', () {
      final p = placeRepeaterLabels(candidates: [cand('a', 100, 100, r: 14)], measure: measure, bounds: bounds, budget: 1);
      expect(p.single.rect.left, closeTo(100 + 14 + 4, 0.001));
    });

    test('placement cost: 1,000 candidates and a budget of 80 place in well under a frame budget', () {
      final rnd = math.Random(3);
      final cs = [for (var i = 0; i < 1000; i++) cand('r$i', rnd.nextDouble() * 400, rnd.nextDouble() * 600, distance: rnd.nextDouble() * 500)];
      placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 80); // warm up
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        placeRepeaterLabels(candidates: cs, measure: measure, bounds: bounds, budget: 80);
      }
      final perPlacement = sw.elapsedMicroseconds / 10 / 1000;
      // Generous bound for a loaded CI Mac running debug code; the old pairwise test was O(c^2).
      expect(perPlacement, lessThan(60), reason: '$perPlacement ms per placement');
    });

    test('text measure cache is an LRU: the oldest entry goes, not everything', () {
      final c = TextLru(3);
      var made = 0;
      TextPainter make() {
        made++;
        return TextPainter(text: const TextSpan(text: 'x'), textDirection: TextDirection.ltr);
      }

      for (final k in ['a', 'b', 'c']) {
        c.get(k, make);
      }
      c.get('a', make); // a is now the newest
      c.get('d', make); // evicts b, the least recently used
      expect(c.length, 3);
      made = 0;
      c.get('a', make);
      c.get('c', make);
      c.get('d', make);
      expect(made, 0, reason: 'a, c, d survived');
      c.get('b', make);
      expect(made, 1);
    });

    test('font sizes: 12 below z12, 13 from z12, 14 from z14', () {
      expect([for (final z in [9.0, 11.9, 12.0, 13.9, 14.0, 17.0]) labelFontSizeForZoom(z)], [12, 12, 13, 13, 14, 14]);
    });
  });

  group('hysteresis', () {
    PlacedLabel placed(String id) => PlacedLabel(cand(id, 50, 50), const Rect.fromLTWH(60, 45, 60, 16));
    Duration ms(int v) => Duration(milliseconds: v);

    test('a new label fades in over 120 ms; a dropped one is held 300 ms then fades over 120 ms', () {
      final f = LabelFader();
      var s = f.update([placed('a')], {'a'}, ms(1000));
      expect(s.single.alpha, 0);
      s = f.update(null, {'a'}, ms(1060));
      expect(s.single.alpha, closeTo(0.5, 0.01));
      s = f.update(null, {'a'}, ms(1200));
      expect(s.single.alpha, 1);
      expect(f.animating, isFalse);
      s = f.update(const [], {'a'}, ms(2000)); // no longer fits
      expect(s.single.alpha, 1, reason: 'held');
      s = f.update(null, {'a'}, ms(2299));
      expect(s.single.alpha, 1);
      expect(f.animating, isTrue);
      s = f.update(null, {'a'}, ms(2360));
      expect(s.single.alpha, closeTo(0.5, 0.02));
      s = f.update(null, {'a'}, ms(2421));
      expect(s, isEmpty);
      expect(f.animating, isFalse);
    });

    test('a label that fits again before the hold ends stays at full alpha', () {
      final f = LabelFader();
      f.update([placed('a')], {'a'}, ms(0));
      f.update(null, {'a'}, ms(500));
      f.update(const [], {'a'}, ms(600));
      final s = f.update([placed('a')], {'a'}, ms(800));
      expect(s.single.alpha, 1);
    });

    test('Reduce Motion: no fade, still the 300 ms hold', () {
      final f = LabelFader(reduceMotion: true);
      var s = f.update([placed('a')], {'a'}, ms(0));
      expect(s.single.alpha, 1);
      f.update(const [], {'a'}, ms(100));
      s = f.update(null, {'a'}, ms(399));
      expect(s.single.alpha, 1);
      s = f.update(null, {'a'}, ms(401));
      expect(s, isEmpty);
    });

    test('a held label whose repeater left the screen goes at once', () {
      final f = LabelFader();
      f.update([placed('a')], {'a'}, ms(0));
      f.update(null, {'a'}, ms(500));
      f.update(const [], {'a'}, ms(600));
      expect(f.update(null, <String>{}, ms(650)), isEmpty);
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
              child: CoverageMap(pings: const [], repeaters: const [a, b], position: const LatLng(40.126, -82.93), layerState: state),
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

    testWidgets('placement runs only when the zoom moved > 0.1 or the camera > 24 pt (placements per second stay low)', (tester) async {
      await pump(tester, state: kDefaultLayerState);
      final labels = find.byType(RepeaterNameLabels);
      expect(labels, findsOneWidget);
      RepeaterNameLabelsState st() => tester.state<RepeaterNameLabelsState>(labels);
      final c = MapController.maybeOf(tester.element(labels))!;
      final p0 = st().placements;
      expect(p0, greaterThanOrEqualTo(1));
      // 60 frames of a slow pan (1 pt each): at most two placements (every 24 pt), never one per frame.
      for (var i = 1; i <= 60; i++) {
        final here = c.camera.latLngToScreenOffset(c.camera.center);
        c.move(c.camera.screenOffsetToLatLng(here + const Offset(1, 0)), c.camera.zoom);
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(st().placements - p0, inInclusiveRange(1, 3));
      final p1 = st().placements;
      c.move(c.camera.center, c.camera.zoom + 0.05); // below the 0.1 threshold
      await tester.pump(const Duration(milliseconds: 16));
      expect(st().placements, p1);
      c.move(c.camera.center, c.camera.zoom + 0.2);
      await tester.pump(const Duration(milliseconds: 16));
      expect(st().placements, p1 + 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a marker is spoken with its name', (tester) async {
      final h = tester.ensureSemantics();
      await pump(tester, state: kDefaultLayerState);
      expect(repeaterSemanticLabels(tester).where((l) => l.startsWith('Repeater Westerville Water Tower, ')), hasLength(1));
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
