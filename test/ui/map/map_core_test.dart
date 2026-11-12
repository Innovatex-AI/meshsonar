// Drive WP2: the map core. Credit on every base style at every state, one FlutterMap and one camera, hit priority, insets.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/satellite_layers.dart';
import 'package:meshsonar/ui/map/core/map_hit_resolver.dart';
import 'package:meshsonar/ui/map/core/map_insets.dart';
import 'package:meshsonar/ui/map/core/map_view_controller.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/overlays/map_overlay_host.dart';
import 'package:meshsonar/ui/theme.dart';

Widget _app(Widget child, {double textScale = 1, Size size = const Size(402, 500)}) => MaterialApp(
  theme: meshSonarTheme(Brightness.light),
  home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SizedBox(width: size.width, height: size.height, child: child)),
  ),
);

void main() {
  group('credit (AttributionLine)', () {
    // The WP2 states: tiles on, tiles off (tests/offline), SIMULATED tag, host slots filled, 2x text.
    final states = <String, Widget Function(BaseMapStyle)>{
      'tiles on': (s) => CoverageMap(pings: const [], showTiles: true, baseStyle: s, fallbackCenter: const LatLng(39.96, -83.0)),
      'tiles off': (s) => CoverageMap(pings: const [], showTiles: false, baseStyle: s, fallbackCenter: const LatLng(39.96, -83.0)),
      'simulated + bottom': (s) => CoverageMap(
        pings: const [],
        showTiles: true,
        simulated: true,
        baseStyle: s,
        fallbackCenter: const LatLng(39.96, -83.0),
        bottom: const SizedBox(height: 90, width: 300, child: Text('hint')),
        topTrailing: const SizedBox(width: 46, height: 300),
        banner: const SizedBox(height: 56, width: double.infinity, child: Text('gps banner')),
      ),
    };
    // Satellite's credit is the definition's imagery credits (Esri, USGS NAIP) plus ours; the others carry their own line.
    String creditOf(BaseMapStyle s) => s.isSatellite ? satelliteCredit(ActiveMapDefinition.current) : s.attribution;
    for (final style in BaseMapStyle.values) {
      for (final e in states.entries) {
        for (final scale in [1.0, 2.0]) {
          testWidgets('${style.id} / ${e.key} / x$scale shows ${creditOf(style).split(',').first} bottom-right', (tester) async {
            await tester.pumpWidget(_app(e.value(style), textScale: scale));
            await tester.pump();
            final text = find.text(creditOf(style));
            expect(text, findsOneWidget);
            final handle = tester.ensureSemantics();
            expect(tester.getSemantics(text).label, contains('OpenStreetMap'));
            handle.dispose();
            final r = tester.getRect(find.byKey(const Key('map-attribution')));
            expect(r.right, closeTo(402 - kOverlayMargin, 1), reason: 'right-aligned, also when it wraps');
            expect(r.bottom, closeTo(500 - kOverlayMargin, 1));
            expect(r.right, greaterThan(201), reason: 'right-aligned: nothing parked bottom-left');
            expect(find.byKey(const Key('map-attribution-info')), findsOneWidget);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }

    testWidgets('Satellite carries the Esri and USGS NAIP credit in the corner line itself, not only in the sheet', (tester) async {
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: true, baseStyle: BaseMapStyle.satellite)));
      await tester.pump();
      expect(find.textContaining('Powered by Esri'), findsOneWidget);
      expect(find.textContaining('USGS National Map (NAIP)'), findsOneWidget);
      expect(find.textContaining('OpenStreetMap contributors'), findsOneWidget, reason: 'our names are drawn over the imagery');
    });

    testWidgets('Topo is our own map: no OpenTopoMap credit any more', (tester) async {
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: true, baseStyle: BaseMapStyle.topo)));
      await tester.pump();
      expect(find.textContaining('OpenTopoMap'), findsNothing);
      expect(find.textContaining('OpenStreetMap contributors'), findsOneWidget);
    });

    testWidgets('the (i) has a 44 x 44 hit area and opens the Credits sheet', (tester) async {
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: true, baseStyle: BaseMapStyle.topo)));
      await tester.pump();
      final c = tester.getCenter(find.byKey(const Key('map-attribution-info')));
      await tester.tapAt(c + const Offset(10, 10)); // 10 pt off the glyph centre, inside the 44 x 44 target
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('credits-sheet')), findsOneWidget);
      expect(find.byKey(const Key('credits-topo')), findsOneWidget);
      expect(find.byKey(const Key('credits-osm')), findsOneWidget);
    });

    testWidgets('the Credits sheet names the Esri and USGS imagery on Satellite', (tester) async {
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: true, baseStyle: BaseMapStyle.satellite)));
      await tester.pump();
      await tester.tap(find.byKey(const Key('map-attribution-info')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('credits-satellite')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('credits-satellite')), matching: find.textContaining('Esri')), findsWidgets);
      expect(find.descendant(of: find.byKey(const Key('credits-satellite')), matching: find.textContaining('USGS')), findsWidgets);
    });
  });

  group('single map instance and one camera', () {
    testWidgets('the camera survives the map being rebuilt in a different layout (the expanded toggle)', (tester) async {
      final vc = MapViewController();
      addTearDown(vc.dispose);
      var expanded = false;
      late StateSetter set;
      await tester.pumpWidget(_app(StatefulBuilder(builder: (context, setState) {
        set = setState;
        final map = CoverageMap(pings: const [], showTiles: false, viewController: vc, fallbackCenter: const LatLng(39.96, -83.0));
        // Two different tree shapes: the map is a new element after the toggle, as when the footer collapses.
        return expanded
            ? Column(children: [Expanded(child: Padding(padding: EdgeInsets.zero, child: map))])
            : Column(children: [Expanded(child: map), const SizedBox(height: 120)]);
      })));
      await tester.pump();
      expect(find.byType(FlutterMap), findsOneWidget);
      vc.map.move(const LatLng(40.1, -82.9), 12.5);
      await tester.pump();
      set(() => expanded = true);
      await tester.pump();
      await tester.pump();
      expect(find.byType(FlutterMap), findsOneWidget, reason: 'never two maps');
      expect(vc.map.camera.zoom, closeTo(12.5, 0.01));
      expect(vc.map.camera.center.latitude, closeTo(40.1, 0.001));
      expect(vc.map.camera.center.longitude, closeTo(-82.9, 0.001));
      set(() => expanded = false);
      await tester.pump();
      await tester.pump();
      expect(vc.map.camera.zoom, closeTo(12.5, 0.01));
    });

    testWidgets('a map given a controller does not dispose it; a map without one makes and disposes its own', (tester) async {
      final vc = MapViewController();
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: false, viewController: vc)));
      await tester.pumpWidget(_app(const SizedBox()));
      expect(vc.disposed, isFalse);
      vc.dispose();
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: false)));
      await tester.pumpWidget(_app(const SizedBox()));
      expect(tester.takeException(), isNull);
    });
  });

  group('MapHitResolver', () {
    MapHitCandidate c(MapHitKind k, List<String> log, String name, {double d = 0, double a = 0}) => MapHitCandidate(k, () => log.add(name), distance: d, area: a);

    test('priority is ping > repeater > observer > cell, whatever order they arrive in', () {
      final log = <String>[];
      final r = MapHitResolver();
      r.submit(c(MapHitKind.cell, log, 'cell'));
      r.submit(c(MapHitKind.observer, log, 'observer'));
      r.submit(c(MapHitKind.repeater, log, 'repeater'));
      r.submit(c(MapHitKind.ping, log, 'ping'));
      r.resolveNow();
      expect(log, ['ping']);
      for (final order in [
        [MapHitKind.observer, MapHitKind.cell],
        [MapHitKind.cell, MapHitKind.observer],
      ]) {
        log.clear();
        for (final k in order) {
          r.submit(c(k, log, k.name));
        }
        r.resolveNow();
        expect(log, ['observer']);
      }
      r.dispose();
    });

    test('within a kind the nearest wins, then the smallest cell', () {
      final log = <String>[];
      final r = MapHitResolver();
      r.submit(c(MapHitKind.repeater, log, 'far', d: 20));
      r.submit(c(MapHitKind.repeater, log, 'near', d: 4));
      r.resolveNow();
      expect(log, ['near']);
      log.clear();
      r.submit(c(MapHitKind.cell, log, 'big', a: 100));
      r.submit(c(MapHitKind.cell, log, 'small', a: 10));
      r.resolveNow();
      expect(log, ['small']);
    });

    test('a tap that only reached the map clears; exactly one action runs per tap', () {
      var nothing = 0;
      final log = <String>[];
      final r = MapHitResolver()..onNothing = () => nothing++;
      r.tapReachedMap();
      r.resolveNow();
      expect(nothing, 1);
      r.tapReachedMap();
      r.submit(c(MapHitKind.repeater, log, 'rep'));
      r.resolveNow();
      expect(nothing, 1, reason: 'a claimed tap does not also clear');
      expect(log, ['rep']);
    });

    testWidgets('decided in the same event-loop turn: no 90 ms wait', (tester) async {
      final log = <String>[];
      final r = MapHitResolver();
      r.submit(c(MapHitKind.ping, log, 'ping'));
      await tester.pump(Duration.zero);
      expect(log, ['ping']);
      r.dispose();
    });
  });

  group('MapInsets', () {
    testWidgets('published once per settled layout, not per frame, and again only when the layout changes', (tester) async {
      final n = MapInsetsNotifier();
      addTearDown(n.dispose);
      var bannerH = 0.0;
      late StateSetter set;
      await tester.pumpWidget(_app(StatefulBuilder(builder: (context, setState) {
        set = setState;
        return MapOverlayHost(
          insets: n,
          map: const ColoredBox(color: Colors.grey),
          banner: bannerH == 0 ? null : SizedBox(height: bannerH, width: double.infinity),
          bottom: const SizedBox(height: 90, width: 200),
          attribution: const SizedBox(width: 120, height: 18),
        );
      })));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(n.publishCount, 1);
      final first = n.value;
      expect(first.top, 0);
      expect(first.bottom, greaterThan(90 + 18));
      set(() => bannerH = 56);
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(n.publishCount, 2);
      expect(n.value.top, 56);
      expect(n.value.bottom, first.bottom);
    });
  });
}
