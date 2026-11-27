// MAP slice 5 (app half): the ONE path layer. Solid for certain links, dashed for likely ones, numbered discs, "N · Name" labels,
// a hop with no position is never drawn and the line stops there, light and dark colours from the definition, and with no
// `symbols.path` / `pages` in the definition every map draws what build 73 drew.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/map_preview.dart';
import 'package:meshsonar/ui/map/still/path_layer.dart';
import 'package:meshsonar/ui/theme.dart';
import 'package:meshsonar/ui/tools/tool_kit.dart';

MapDefinition _live() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());

void _useLive(WidgetTester? t) {
  ActiveMapDefinition.notifier.value = _live();
  addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
}

PathHop _h(int n, String name, {double? lat = 40.0, double? lon = -83.0, PathCertainty c = PathCertainty.certain}) =>
    PathHop(n: n, name: name, lat: lat == null ? null : lat + n * 0.01, lon: lon == null ? null : lon + n * 0.01, certainty: c);

Future<void> _pump(WidgetTester tester, PathSpec spec, {bool dark = false}) async {
  final style = MapPathStyle.of(_live())!;
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(dark ? Brightness.dark : Brightness.light),
    home: SizedBox(
      width: 400,
      height: 400,
      child: MapPreview(
        center: const LatLng(40.02, -82.98),
        zoom: 11,
        tiles: false,
        overlays: [PathLayer(spec: spec, style: style, dark: dark)],
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  group('PathSpec', () {
    test('links join consecutive placed hops; certain only when both ends are', () {
      final s = PathSpec(hops: [_h(1, 'A'), _h(2, 'B'), _h(3, 'C', c: PathCertainty.likely)]);
      expect(s.links.map((l) => l.certainty), [PathCertainty.certain, PathCertainty.likely]);
    });

    test('a hop with no position is not drawn and the line stops there', () {
      final s = PathSpec(hops: [_h(1, 'A'), _h(2, 'B', lat: null), _h(3, 'C'), _h(4, 'D')]);
      expect(s.placed.map((h) => h.n), [1, 3, 4]);
      expect(s.unplaced.map((h) => h.n), [2]);
      // 1-2 and 2-3 are broken by the unplaced hop; only 3-4 is drawn
      expect(s.links, hasLength(1));
      expect(s.links.single.a, LatLng(40.03, -82.97));
    });

    test('no chain: no links; the points include the observers', () {
      final s = PathSpec(chain: false, hops: [_h(1, 'A'), _h(2, 'B')], observers: const [PathObserverPoint(lat: 41, lon: -82)]);
      expect(s.links, isEmpty);
      expect(s.points, hasLength(3));
    });
  });

  group('PathLayer', () {
    testWidgets('certain links are solid, likely links dashed; discs are numbered and labelled "N · Name"', (tester) async {
      _useLive(tester);
      await _pump(tester, PathSpec(hops: [_h(1, 'Alpha'), _h(2, 'Bravo'), _h(3, 'Charlie', c: PathCertainty.likely)]));
      final solid = tester.widget<PolylineLayer>(find.byKey(const Key('path-lines-solid')));
      final dashed = tester.widget<PolylineLayer>(find.byKey(const Key('path-lines-dashed')));
      expect(solid.polylines, hasLength(1));
      expect(dashed.polylines, hasLength(1));
      expect(solid.polylines.single.strokeWidth, 3.5);
      expect(solid.polylines.single.pattern.segments, isNull);
      expect(dashed.polylines.single.pattern.segments, [7, 7]);
      for (final n in [1, 2, 3]) {
        expect(find.byKey(Key('path-disc-$n')), findsOneWidget);
      }
      expect(find.text('1 · Alpha'), findsOneWidget);
      expect(find.text('2 · Bravo'), findsOneWidget);
      expect(find.text('3 · Charlie'), findsOneWidget);
      final disc = tester.widget<Container>(find.byKey(const Key('path-disc-1')));
      expect((disc.decoration! as BoxDecoration).color, const Color(0xFF1D4ED8));
    });

    testWidgets('dark theme uses the dark colours', (tester) async {
      _useLive(tester);
      await _pump(tester, PathSpec(hops: [_h(1, 'Alpha'), _h(2, 'Bravo')]), dark: true);
      final solid = tester.widget<PolylineLayer>(find.byKey(const Key('path-lines-solid')));
      expect(solid.polylines.single.color, const Color(0xFF7FB0FF));
      final disc = tester.widget<Container>(find.byKey(const Key('path-disc-1')));
      expect((disc.decoration! as BoxDecoration).color, const Color(0xFF7FB0FF));
    });

    testWidgets('an unplaced hop gets no disc and no label; the line stops there', (tester) async {
      _useLive(tester);
      await _pump(tester, PathSpec(hops: [_h(1, 'Alpha'), _h(2, 'Bravo', lat: null), _h(3, 'Charlie')]));
      expect(find.byKey(const Key('path-disc-2')), findsNothing);
      expect(find.text('2 · Bravo'), findsNothing);
      expect(find.byKey(const Key('path-disc-1')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-3')), findsOneWidget);
      expect(find.byKey(const Key('path-lines-solid')), findsNothing);
      expect(find.byKey(const Key('path-lines-dashed')), findsNothing);
    });

    testWidgets('the hearing observer is drawn with the observer symbol', (tester) async {
      _useLive(tester);
      await _pump(tester, PathSpec(hops: [_h(1, 'Alpha')], observers: const [PathObserverPoint(lat: 40.0, lon: -82.99)]));
      expect(find.byKey(const Key('path-observers')), findsOneWidget);
    });

    testWidgets('unnumbered (a set of repeaters): no number on the disc, the label is the name', (tester) async {
      _useLive(tester);
      await _pump(tester, PathSpec(chain: false, numbered: false, hops: [_h(1, 'Alpha'), _h(2, 'Bravo')]));
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('1'), findsNothing);
      expect(find.byKey(const Key('path-lines-solid')), findsNothing);
    });
  });

  group('PathKey', () {
    testWidgets('says certain, likely, the numbered hop, the observer and the unplaced rule', (tester) async {
      final style = MapPathStyle.of(_live())!;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PathKey(style: style, observers: true))));
      expect(find.text('Hop, numbered in order, named N · Name'), findsOneWidget);
      expect(find.text('Certain: a solid line'), findsOneWidget);
      expect(find.text('Likely: a dashed line'), findsOneWidget);
      expect(find.text('Observer that heard it'), findsOneWidget);
      expect(find.text(style.unplacedNote), findsOneWidget);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PathKey(style: style, unplaced: 2, total: 5))));
      expect(find.text('2 of 5 hops have no position: listed, not drawn.'), findsOneWidget);
      expect(find.text('Observer that heard it'), findsNothing);
    });
  });

  group('MapPreview page presets', () {
    final prefs = MapPrefs();
    tearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);

    test('without a page, or with a definition lacking pages, the caller\'s coverage set decides (build 73)', () {
      const caller = MapPreview(coverage: {'measured', 'predicted'});
      expect(caller.effectiveCoverage(prefs), {'measured', 'predicted'});
      const withPage = MapPreview(page: 'path', coverage: {'measured', 'predicted'});
      expect(ActiveMapDefinition.current.json['pages'], isNull);
      expect(withPage.preset, isNull);
      expect(withPage.effectiveCoverage(prefs), {'measured', 'predicted'});
    });

    test('with the live definition the preset decides: path has no coverage, node has measured', () {
      ActiveMapDefinition.notifier.value = _live();
      expect(const MapPreview(page: 'path', coverage: {'measured', 'predicted'}).effectiveCoverage(prefs), isEmpty);
      expect(const MapPreview(page: 'node', coverage: {'predicted'}).effectiveCoverage(prefs), {'measured'});
      // a page the definition does not preset keeps the caller's set
      expect(const MapPreview(page: 'nope', coverage: {'predicted'}).effectiveCoverage(prefs), {'predicted'});
      // no page: unchanged
      expect(const MapPreview(coverage: {'predicted'}).effectiveCoverage(prefs), {'predicted'});
      expect(MapPreview.presetNames('path'), isTrue);
    });

    testWidgets('the still height comes from the preset word, else the caller\'s snapped to one of the two standard heights (N6)', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      expect(MapPreview.stillHeight(ctx, 'path', fallback: 123), MapPreview.compactHeight);
      ActiveMapDefinition.notifier.value = _live();
      // the path preset says no height word: still the caller's, snapped
      expect(MapPreview.stillHeight(ctx, 'path', fallback: 123), MapPreview.compactHeight);
      expect(MapPreview.stillHeight(ctx, null, fallback: 300), MapPreview.tallHeight);
    });
  });

  group('ToolMap', () {
    testWidgets('without symbols.path it draws its pins and lines exactly as build 73 (no path key)', (tester) async {
      ToolMap.tilesEnabled = false;
      addTearDown(() => ToolMap.tilesEnabled = true);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ToolMap(
            pins: const [MapPin(point: LatLng(40.1, -82.9), label: 'A'), MapPin(point: LatLng(40.2, -82.8), label: 'B')],
            lines: const [MapLine([LatLng(40.1, -82.9), LatLng(40.2, -82.8)], Colors.orange)],
            path: PathSpec(hops: [_h(1, 'A'), _h(2, 'B')]),
            semanticLabel: 'Two repeaters.',
          ),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const Key('tool-map')), findsOneWidget);
      expect(find.byKey(const Key('path-key')), findsNothing);
      expect(find.byKey(const Key('path-disc-1')), findsNothing);
    });

    testWidgets('with symbols.path it draws the numbered path and its key', (tester) async {
      _useLive(tester);
      ToolMap.tilesEnabled = false;
      addTearDown(() => ToolMap.tilesEnabled = true);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ToolMap(
            pins: const [],
            path: PathSpec(hops: [_h(1, 'A'), _h(2, 'B', lat: null)]),
            semanticLabel: 'Two repeaters.',
          ),
        ),
      ));
      await tester.pump();
      expect(find.byKey(const Key('path-disc-1')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-2')), findsNothing);
      expect(find.text('1 of 2 hops have no position: listed, not drawn.'), findsOneWidget);
    });
  });
}
