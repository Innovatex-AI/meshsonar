// Build 77 (redesign Round 1): F9 compass whenever rotated, F10 stale and estimated repeaters, F14 the Predicted hatch on a light
// map, N5 the status pill, N6 small maps that match the main map, N7 feedback moments, N8 one-time tips and the map actions
// button.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/core/time_format.dart' as tf;
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/core/map_view_controller.dart';
import 'package:meshsonar/ui/map/coverage_tiles_layer.dart' show CoverageViewStatus;
import 'package:meshsonar/ui/map/layers/repeater_sprites.dart';
import 'package:meshsonar/ui/map/map_layers.dart' show HeardView, HeardPhase;
import 'package:meshsonar/ui/map/map_preview.dart';
import 'package:meshsonar/ui/map/overlays/map_controls.dart';
import 'package:meshsonar/ui/map/parts/map_feedback.dart';
import 'package:meshsonar/ui/map/parts/map_status_pill.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;

Widget _app(Widget child, {Brightness b = Brightness.dark}) => MaterialApp(
  theme: meshSonarTheme(b),
  home: Scaffold(body: SizedBox(width: 400, height: 560, child: child)),
);

void main() {
  group('F10: stale and estimated repeaters', () {
    Future<List<int>> pixels(RepeaterSpriteSpec spec, Brightness b) async {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawRect(const Rect.fromLTWH(0, 0, 40, 40), Paint()..color = const Color(0xFF0D1117));
      paintRepeaterSprite(canvas, const Offset(20, 20), spec, RepeaterSpriteTheme(brightness: b, accent: Colors.teal, ok: Colors.green, highContrast: false));
      final img = await rec.endRecording().toImage(40, 40);
      final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      return data.buffer.asUint8List();
    }

    test('a stale repeater keeps its outline at full strength on a dark map (only the glyph fades)', () async {
      final fresh = await pixels(const RepeaterSpriteSpec(RepeaterFreshness.fresh, false, SpriteVariant.badge), Brightness.dark);
      final stale = await pixels(const RepeaterSpriteSpec(RepeaterFreshness.stale, false, SpriteVariant.badge), Brightness.dark);
      int brightest(List<int> px) {
        var m = 0;
        for (var i = 0; i < px.length; i += 4) {
          final v = px[i] + px[i + 1] + px[i + 2];
          if (v > m) m = v;
        }
        return m;
      }
      // Before build 77 the whole stale sprite was drawn at 45 %: its brightest pixel was under half the fresh one's.
      expect(brightest(stale), greaterThan(brightest(fresh) * 0.8), reason: 'the outline is not faded');
    });

    test('an estimated position is its own look (a dotted outline), never the stale one', () {
      const a = RepeaterSpriteSpec(RepeaterFreshness.stale, false, SpriteVariant.badgeLarge, estimated: true);
      const b = RepeaterSpriteSpec(RepeaterFreshness.stale, false, SpriteVariant.badgeLarge);
      expect(a == b, isFalse);
    });
  });

  test('F14: the Predicted hatch is finer on a light map; colours and opacities stay the definition\'s', () {
    expect(predictedHatchWidth(CoverageBandColors.of(ColourPalette.standard, Brightness.light)), lessThan(2));
    expect(predictedHatchWidth(CoverageBandColors.of(ColourPalette.standard, Brightness.dark)), 2);
  });

  group('N5: the status pill', () {
    test('most important first: failed, loading, nothing measured, then names waiting for a zoom', () {
      expect(mapStatusFor(coverage: CoverageViewStatus.failed, namesHiddenByZoom: true), MapStatus.failed);
      expect(mapStatusFor(coverage: CoverageViewStatus.loading), MapStatus.loading);
      expect(mapStatusFor(coverage: CoverageViewStatus.empty), MapStatus.nothingHere);
      expect(mapStatusFor(coverage: CoverageViewStatus.shown, namesHiddenByZoom: true), MapStatus.zoomForNames);
      expect(mapStatusFor(coverage: CoverageViewStatus.shown), isNull);
      expect(mapStatusText(MapStatus.loading), 'Loading coverage');
    });

    testWidgets('names switched on but the map is zoomed out: "Zoom in to see names" beside the legend chip', (t) async {
      await t.pumpWidget(_app(CoverageMap(pings: const [], showTiles: false, fallbackCenter: const LatLng(39.96, -83.0), legend: const SizedBox(width: 40, height: 36), onLayers: () {})));
      await t.pump();
      await t.pump();
      expect(find.text('Zoom in to see names'), findsOneWidget);
    });

    testWidgets('a failed coverage read says so with Retry', (t) async {
      await t.pumpWidget(_app(const Center(child: MapStatusPill(status: MapStatus.failed, onRetry: _noop))));
      expect(find.text("Couldn't load coverage"), findsOneWidget);
      expect(find.byKey(const Key('map-status-retry')), findsOneWidget);
    });
  });

  group('N6: small maps', () {
    testWidgets('follow the chosen base map (one layer, names inside), its background, one credit pill, one mini legend', (t) async {
      final h = Harness();
      await h.state.init();
      await h.state.updateSettings(h.state.settings.copyWith(baseMapStyle: 'dark'));
      await t.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          home: const Scaffold(body: SizedBox(height: MapPreview.compactHeight, child: MapPreview(center: LatLng(39.96, -83.0), coverage: {'measured'}))),
        ),
      ));
      await t.pump();
      final r = MapPreview.resolvedFor(t.element(find.byType(MapPreview)), coverageOn: false);
      expect(r.choice, BaseMapStyle.dark, reason: 'the person\'s choice, not the theme\'s Road');
      expect(r.labels, isNull, reason: 'a small map keeps one vector layer');
      expect(find.byKey(const Key('mini-map-credit')), findsOneWidget);
      expect(find.text('© OpenStreetMap'), findsOneWidget);
      expect(MapPreview.tallHeight, greaterThan(MapPreview.compactHeight));
    });

    testWidgets('the mini legend shows whenever coverage is drawn, in the main map\'s words', (t) async {
      await t.pumpWidget(_app(const MiniMapLegend()));
      expect(find.text('Weak → strong'), findsOneWidget);
    });
  });

  group('N7: feedback moments', () {
    testWidgets('a repeater heard for the first time on a drive: a ring and a success tap, once', (t) async {
      const ref = RepeaterRef(key: 'aa11', name: 'Hilltop', lat: 39.97, lon: -83.0);
      HeardView hv() => HeardView(id: 'aa11', label: 'Hilltop', ref: ref, timesHeard: 1, phase: HeardPhase.fresh, snrDb: 3);
      debugFirstHeardTaps = 0;
      Widget map(List<HeardView> heard) => _app(CoverageMap(pings: const [], heard: heard, showTiles: false, fallbackCenter: const LatLng(39.96, -83.0)));
      await t.pumpWidget(map(const []));
      await t.pumpWidget(map([hv()]));
      expect(debugFirstHeardTaps, 1);
      expect(find.byKey(const ValueKey('first-heard-aa11')), findsOneWidget);
      await t.pumpWidget(map([hv()]));
      expect(debugFirstHeardTaps, 1, reason: 'once per drive');
      await t.pump(const Duration(seconds: 2));
      expect(find.byKey(const ValueKey('first-heard-aa11')), findsNothing);
    });

    testWidgets('a switched-on layer fades in; under Reduce Motion it appears at once', (t) async {
      await t.pumpWidget(_app(const MapFadeIn(child: SizedBox(key: Key('x'), width: 10, height: 10))));
      expect(t.widget<Opacity>(find.ancestor(of: find.byKey(const Key('x')), matching: find.byType(Opacity))).opacity, lessThan(1));
      await t.pump(kMapFadeIn);
      expect(t.widget<Opacity>(find.ancestor(of: find.byKey(const Key('x')), matching: find.byType(Opacity))).opacity, 1);
      await t.pumpWidget(MaterialApp(home: MediaQuery(data: const MediaQueryData(disableAnimations: true), child: const MapFadeIn(child: SizedBox(key: Key('y'))))));
      expect(find.ancestor(of: find.byKey(const Key('y')), matching: find.byType(Opacity)), findsNothing);
    });
  });

  group('N8: one-time tips and the map actions button', () {
    setUp(() => CoverageMap.showTips = true);
    tearDown(() => CoverageMap.showTips = false);

    testWidgets('one tip at a time, gone for good once closed; press-and-hold actions have a button', (t) async {
      final prefs = MapPrefs.shared;
      for (final id in ['cell', 'repeater', 'longpress']) {
        expect(prefs.tipSeen(id), isFalse);
      }
      LatLng? held;
      await t.pumpWidget(_app(CoverageMap(
        pings: const [],
        showTiles: false,
        fallbackCenter: const LatLng(39.96, -83.0),
        onLayers: () {},
        onLongPress: (context, hit) async {
          held = LatLng(hit.lat, hit.lon);
          return true;
        },
      )));
      await t.pump();
      final tip = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('map-tip-'));
      expect(tip, findsOneWidget);
      await t.tap(find.byKey(const Key('map-tip-close')));
      await t.pump();
      expect(prefs.tipSeen('repeater') || prefs.tipSeen('cell') || prefs.tipSeen('longpress'), isTrue);
      await t.tap(find.byKey(const Key('map-more')));
      await t.pump();
      expect(held, isNotNull, reason: 'Meet here and the other press-and-hold actions, at the middle of the map');
    });
  });

  group('F9: the compass', () {
    testWidgets('shows whenever the map is rotated, rotatable or not (heading up turns it at any panel position)', (t) async {
      final view = MapViewController();
      await t.pumpWidget(_app(CoverageMap(viewController: view, pings: const [], showTiles: false, fallbackCenter: const LatLng(39.96, -83.0), onLayers: () {}, rotatable: false)));
      await t.pump();
      view.map.rotate(30);
      await t.pump();
      expect(t.widget<MapControlButton>(find.byKey(const Key('map-compass'))).visible, isTrue);
    });
  });

  test('W1-B: the repeater sheet\'s advert line uses the one time formatter', () {
    final now = DateTime.utc(2026, 11, 27, 15);
    expect(advertText(now.subtract(const Duration(hours: 3)), now), 'Last advert 3 h ago (${tf.dateOnly(now.subtract(const Duration(hours: 3)))})');
  });
}

void _noop() {}
