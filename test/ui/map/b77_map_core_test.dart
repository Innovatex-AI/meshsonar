// Build 77 (redesign Round 1): the map core changes of package W2-A. Credit pill at one fixed spot (decision 5), names and
// clusters keep clear of it (F3), the base map resolved with names above the coverage (F2), the picker's real thumbnails (N3),
// and basemap recovery that no longer empties the whole image cache (F12).
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/core/hex_cells.dart' show HexPoint;
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/ui/map/basemap_layer.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/overlays/map_overlay_host.dart';
import 'package:meshsonar/ui/map/satellite_layers.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/theme.dart';

Widget _app(Widget child, {Brightness b = Brightness.light, Size size = const Size(402, 560)}) => MaterialApp(
  theme: meshSonarTheme(b),
  home: MediaQuery(
    data: MediaQueryData(size: size),
    child: Scaffold(body: SizedBox(width: size.width, height: size.height, child: child)),
  ),
);

void main() {
  group('decision 5: the credit pill', () {
    testWidgets('"© OpenStreetMap (i)" on a pill, dark on a dark map and light on a light one', (tester) async {
      for (final (style, b, dark) in [
        (BaseMapStyle.chart, Brightness.light, false),
        (BaseMapStyle.chart, Brightness.dark, true),
        (BaseMapStyle.street, Brightness.dark, false),
        (BaseMapStyle.dark, Brightness.light, true),
      ]) {
        await tester.pumpWidget(_app(CoverageMap(key: ValueKey((style, b)), pings: const [], showTiles: true, baseStyle: style, fallbackCenter: const LatLng(39.96, -83.0)), b: b));
        await tester.pump(const Duration(milliseconds: 400)); // the theme change animates
        expect(find.text('© OpenStreetMap'), findsOneWidget, reason: '${style.id} $b');
        expect(find.byKey(const Key('map-attribution-info')), findsOneWidget);
        final box = tester.widget<Container>(find.byKey(const Key('map-attribution')));
        final fill = (box.decoration! as BoxDecoration).color!;
        expect(fill.computeLuminance() < 0.2, dark, reason: '${style.id} in $b: ${dark ? 'dark' : 'light'} pill, got $fill');
      }
    });

    testWidgets('Satellite: the longer imagery credit at the same spot, with the short OpenStreetMap credit for our names', (tester) async {
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: true, baseStyle: BaseMapStyle.satellite, fallbackCenter: const LatLng(39.96, -83.0))));
      await tester.pump();
      final credit = satelliteCredit(ActiveMapDefinition.current);
      expect(credit, contains('Esri'));
      expect(credit, isNot(contains('Protomaps')), reason: 'Protomaps is named in the credits sheet');
      expect(find.text(credit), findsOneWidget);
    });

    testWidgets('ONE fixed spot: the panel rising (bottomClearance) moves the buttons, never the credit; the panel covers it', (tester) async {
      Future<(Rect, Rect)> at(double clearance) async {
        await tester.pumpWidget(_app(CoverageMap(
          pings: const [],
          showTiles: true,
          fallbackCenter: const LatLng(39.96, -83.0),
          position: const LatLng(39.96, -83.0),
          onLayers: () {},
          bottomClearance: clearance,
          creditClearance: 120,
        )));
        await tester.pump();
        return (tester.getRect(find.byKey(const Key('map-attribution'))), tester.getRect(find.byKey(const Key('drive-map-layers'))));
      }

      final (restCredit, restLayers) = await at(120);
      final bottom = tester.getRect(find.byType(CoverageMap)).bottom;
      expect(restCredit.bottom, closeTo(bottom - 120 - kOverlayMargin, 1), reason: 'just above the resting panel');
      expect(restLayers.bottom, lessThan(restCredit.top), reason: 'the buttons sit above the credit');
      final (upCredit, upLayers) = await at(380);
      expect(upCredit, restCredit, reason: 'the credit does not ride up with the panel');
      expect(upLayers.bottom, lessThanOrEqualTo(bottom - 380), reason: 'the buttons ride on the raised panel');
      expect(upCredit.top, greaterThan(bottom - 380), reason: 'under the raised panel: it covers the credit');
    });

    testWidgets('names keep out of the credit box: it is in the map\'s avoid list', (tester) async {
      await tester.pumpWidget(_app(CoverageMap(pings: const [], showTiles: true, fallbackCenter: const LatLng(39.96, -83.0))));
      await tester.pump();
      final state = tester.state(find.byType(CoverageMap));
      final rects = (state as dynamic).debugOverlayRects() as List<Rect>;
      final credit = tester.getRect(find.byKey(const Key('map-attribution')));
      final mapOrigin = tester.getTopLeft(find.byType(CoverageMap));
      expect(rects.any((r) => r.contains(credit.center - mapOrigin)), isTrue, reason: 'names and clusters avoid the credit');
    });
  });

  group('F2 / N3: the resolved base map', () {
    testWidgets('with coverage drawn: the data-first base under the coverage and the names pass above it; none drawn: one plain layer', (tester) async {
      BasemapHealth.instance = BasemapHealth(client: () => throw StateError('offline test'));
      BasemapLayer.debugBuilder = (s, dark) => const SizedBox.shrink();
      addTearDown(() {
        BasemapLayer.debugBuilder = null;
        BasemapHealth.instance = BasemapHealth();
      });
      const cell = NetworkCell(id: '39.96,-83.0', boundary: [HexPoint(39.96, -83.0), HexPoint(39.97, -83.0), HexPoint(39.97, -82.99)], level: CoverageLevel.good);
      Future<List<BasemapLook>> looks(List<NetworkCell> cells) async {
        await tester.pumpWidget(_app(CoverageMap(key: ValueKey(cells.length), pings: const [], showTiles: true, fallbackCenter: const LatLng(39.96, -83.0), networkCells: cells)));
        await tester.pump();
        return tester.widgetList<BasemapLayer>(find.byType(BasemapLayer)).map((l) => l.look).toList();
      }

      expect(await looks(const []), [BasemapLook.road]);
      expect(await looks(const [cell]), [BasemapLook.dataBase, BasemapLook.dataLabels]);
      final order = coverageMapPaintOrder();
      final last = order.indexOf('measured') > order.indexOf('hexes') ? order.indexOf('measured') : order.indexOf('hexes');
      expect(order.indexOf('basemapLabels'), last + 1, reason: 'right above the last coverage layer');
      expect(order.indexOf('basemapLabels'), lessThan(order.indexOf('network')), reason: 'under the repeaters');
    });
  });

  group('F12: basemap recovery', () {
    testWidgets('a reset re-asks for the tiles without emptying the app\'s image cache (avatars and photos stay)', (tester) async {
      BasemapHealth.instance = BasemapHealth(client: () => throw StateError('offline test'));
      var builds = 0;
      BasemapLayer.debugBuilder = (s, dark) {
        builds++;
        return const SizedBox.shrink(key: Key('test-basemap'));
      };
      addTearDown(() {
        BasemapLayer.debugBuilder = null;
        BasemapHealth.instance = BasemapHealth();
      });
      // An avatar in the cache.
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(const Rect.fromLTWH(0, 0, 2, 2), Paint());
      final image = await tester.runAsync(() => recorder.endRecording().toImage(2, 2));
      const avatarKey = 'avatar-of-a-friend';
      final completer = OneFrameImageStreamCompleter(SynchronousFuture(ImageInfo(image: image!)));
      PaintingBinding.instance.imageCache.putIfAbsent(avatarKey, () => completer);
      expect(PaintingBinding.instance.imageCache.containsKey(avatarKey), isTrue);

      final reset = StreamController<void>.broadcast();
      addTearDown(reset.close);
      await tester.pumpWidget(MaterialApp(
        home: SizedBox(
          width: 300,
          height: 200,
          child: FlutterMap(options: const MapOptions(initialCenter: LatLng(39.96, -83.0), initialZoom: 12), children: [BasemapLayer(reset: reset.stream)]),
        ),
      ));
      final before = builds;
      reset.add(null);
      await tester.pump();
      expect(find.byKey(const Key('basemap-recovering')), findsOneWidget, reason: 'off the map for one frame: the old tile layer evicts its own failed tiles');
      await tester.pump();
      expect(find.byKey(const Key('test-basemap')), findsOneWidget, reason: 'and back, asking again');
      expect(builds, greaterThan(before));
      expect(PaintingBinding.instance.imageCache.containsKey(avatarKey), isTrue, reason: 'the rest of the app\'s images are kept');
    });
  });

  group('N3: the base map picker', () {
    test('every choice has a bundled real thumbnail', () {
      for (final s in BaseMapStyle.values) {
        for (final d in [false, true]) {
          expect(s.thumbnailAsset(appDark: d), startsWith('assets/map/thumbs/'));
        }
      }
    });
  });
}
