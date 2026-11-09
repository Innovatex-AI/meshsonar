// Coverage v2 in the app (WP5): the painter's zoomed-out dots and hatch, the tile layer's hit test, the cell inspector (measured,
// predicted, this drive, repeater names), the model's tiles-vs-JSON switch, and goldens of the inspector and the legend (layout
// only: the test font draws no real glyphs; SF Pro is checked on the simulator).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/coverage_query.dart';
import 'package:meshsonar/core/coverage_v2.dart';
import 'package:meshsonar/core/hex_cells.dart' show HexCell, HexPoint;
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/cell_raster_layer.dart';
import 'package:meshsonar/ui/map/core/map_view_controller.dart';
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/coverage_tiles_layer.dart';
import 'package:meshsonar/ui/map/legend_sheet.dart';
import 'package:meshsonar/ui/map/sheets/coverage_cell_sheet.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';

Map<String, dynamic> _json(String n) => jsonDecode(File('test/fixtures/coverage_v2/$n').readAsStringSync()) as Map<String, dynamic>;
Uint8List _bytes(String n) => File('test/fixtures/coverage_v2/$n').readAsBytesSync();
final _meta = CoverageMeta.fromJson(_json('meta.json'));

Future<void> _pump(WidgetTester t, Widget child, {Brightness b = Brightness.light, Size size = const Size(390, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: meshSonarTheme(b),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
  await t.pumpAndSettle();
}

void main() {
  tapGroup();
  group('painter', () {
    const style = CellStyle(Color(0xFF00FF00), Color(0x00000000), 0);
    const hidden = CellStyle(Color(0x00000000), Color(0x00000000), 0, Color(0x55000000), Color(0x00000000), 1);
    final hex = [HexPoint(40, -83), HexPoint(40.0003, -83), HexPoint(40.0003, -82.9996), HexPoint(40, -82.9996)];

    test('below dotBelowZoom every cell is a dot; a transparent dot style is left out (predicted band 0)', () {
      final data = CellLayerData([CellShape(hex, 0), CellShape(hex, 1)], const [style, hidden], dotBelowZoom: 13, dotPx: 3);
      final low = paintCells(data, const LatLng(40, -83), 11, 400, 400, 1);
      expect(low.cellsDrawn, 1, reason: 'only the visible dot');
      low.dispose();
      final high = paintCells(data, const LatLng(40, -83), 15, 400, 400, 1);
      expect(high.cellsDrawn, 2, reason: 'zoomed in both are outlines; the hatched one draws its hatch');
      high.dispose();
    });

    test('a single-vertex shape (a z <= 12 tile point) is a dot at every zoom', () {
      final pt = Float64List.fromList([40, -83]);
      final data = CellLayerData([CellShape.slice(pt, 0, 1, 0)], const [style]);
      final r = paintCells(data, const LatLng(40, -83), 16, 400, 400, 1);
      expect(r.cellsDrawn, 1);
      r.dispose();
    });
  });

  group('tile hit test', () {
    test('zoomed in: the hexagon under the finger and its H3 id; zoomed out: the nearest dot within the radius', () async {
      final store = CoverageTileStore(
        CoverageV2Client(Uri.parse('https://x.test')),
        decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y),
      );
      final d13 = decodeCoverageTile(_bytes('measured-13-2207-3102.mvt'), CoverageTileLayer.measured, 13, 2207, 3102);
      // Seed the store as if fetched (the cache key is all the hit test reads).
      final key = coverageTileKey(CoverageTileLayer.measured, _meta.defaultPreset, _meta.version, 13, 2207, 3102);
      store.debugPut(key, d13);
      // The centroid of the first hexagon is inside it.
      var lat = 0.0, lon = 0.0;
      for (var v = d13.starts[0]; v < d13.starts[1]; v++) {
        lat += d13.latLon[2 * v] / 6;
        lon += d13.latLon[2 * v + 1] / 6;
      }
      final hit = coverageTileHit(store, CoverageTileLayer.measured, _meta, lat, lon, 13);
      expect(hit, isNotNull);
      expect(hit!.h3, d13.h[0]);
      expect(coverageTileHit(store, CoverageTileLayer.measured, _meta, 39.0, -83.5, 13), isNull, reason: 'another tile, not loaded');

      final d9 = decodeCoverageTile(_bytes('measured-9-137-193.mvt'), CoverageTileLayer.measured, 9, 137, 193);
      store.debugPut(coverageTileKey(CoverageTileLayer.measured, _meta.defaultPreset, _meta.version, 9, 137, 193), d9);
      final pLat = d9.latLon[0], pLon = d9.latLon[1];
      final dot = coverageTileHit(store, CoverageTileLayer.measured, _meta, pLat + 0.0005, pLon, 9, radiusDeg: 0.01);
      expect(dot, isNotNull);
      expect(dot!.h3, isNull, reason: 'points carry no id: the caller resolves the centroid with h3');
      expect(coverageTileHit(store, CoverageTileLayer.measured, _meta, pLat + 0.5, pLon, 9, radiusDeg: 0.01), isNull);
    });
  });

  group('tile stand-ins', () {
    // Andy's field shot (dark, z14, Polaris, Nov 8): a z12 point tile stood in for the z13/z14 tiles still loading and drew a
    // fine dot-matrix over the whole area. At a hexagon zoom only hexagon tiles may stand in.
    Future<CoverageTilesLayerState> pumpAt(WidgetTester t, CoverageTileStore store, LatLng at, double zoom) async {
      t.view.physicalSize = const Size(400, 800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: FlutterMap(
          key: UniqueKey(),
          options: MapOptions(initialCenter: at, initialZoom: zoom),
          children: [
            CoverageTilesLayer(
              layer: CoverageTileLayer.measured,
              store: store,
              meta: _meta,
              colors: CoverageBandColors.of(ColourPalette.standard, Brightness.dark),
            ),
          ],
        ),
      ));
      await t.pump();
      return t.state<CoverageTilesLayerState>(find.byType(CoverageTilesLayer));
    }

    testWidgets('z14 with only a z12 point tile loaded draws nothing; a z13 hexagon tile stands in', (t) async {
      final d13 = decodeCoverageTile(_bytes('measured-13-2207-3102.mvt'), CoverageTileLayer.measured, 13, 2207, 3102);
      var lat = 0.0, lon = 0.0;
      for (var v = d13.starts[0]; v < d13.starts[1]; v++) {
        lat += d13.latLon[2 * v] / 6;
        lon += d13.latLon[2 * v + 1] / 6;
      }
      final store = CoverageTileStore(CoverageV2Client(Uri.parse('https://x.test')), decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y));
      final (tx, ty) = tileOf(lat, lon, 12);
      store.debugPut(
        coverageTileKey(CoverageTileLayer.measured, _meta.defaultPreset, _meta.version, 12, tx, ty),
        CoverageTileData(Float64List.fromList([lat, lon]), Int32List.fromList([0, 1]), Uint8List.fromList([4]), Int32List.fromList([5]), Float32List(1), const ['']),
      );
      var s = await pumpAt(t, store, LatLng(lat, lon), 14.2);
      expect(s.cellCount, 0, reason: 'no z12 points at z14');
      s = await pumpAt(t, store, LatLng(lat, lon), 12.5);
      expect(s.cellCount, 1, reason: 'zoomed out the point tile is the right kind');
      store.debugPut(coverageTileKey(CoverageTileLayer.measured, _meta.defaultPreset, _meta.version, 13, 2207, 3102), d13);
      s = await pumpAt(t, store, LatLng(lat, lon), 14.2);
      expect(s.cellCount, greaterThan(0), reason: 'the z13 hexagon tile stands in for z14');
    });
  });

  // Pinned clock: the inspector's ages are relative, so a real clock made the golden drift hourly.
  final goldenNow = DateTime.utc(2026, 11, 8, 17);

  group('inspector', () {
    final measured = CoverageCellInfo.fromJson(_json('cell-measured.json'));
    final predicted = CoverageCellInfo.fromJson(_json('cell-predicted.json'));
    const mine = HexCell(id: '8b2a95620b46fff', boundary: [], sent: 4, heard: 3, snrMeanDb: 5.5, nSnr: 3, band: 4);

    testWidgets('measured: band with its dB range, mean, replies, sources, repeaters by name (unknown keys as the key)', (t) async {
      await _pump(t, CoverageCellSheet(info: measured, meta: _meta, h3: measured.h3, mine: mine, repeaterName: (k) => k == '297d' ? 'Alpha Tower' : null));
      expect(find.text('Good  (+2.5 to +7.5 dB)'), findsOneWidget);
      expect(find.text('+6.3 dB'), findsOneWidget);
      expect(find.text('5 of 5 (100%)'), findsOneWidget);
      expect(find.text('MeshSonar 1, MeshMapper 4'), findsOneWidget);
      expect(find.text('Alpha Tower'), findsOneWidget);
      expect(find.text('da5d'), findsOneWidget);
      expect(find.byKey(const Key('coverage-cell-mine')), findsOneWidget);
      expect(coverageCellSummary(measured, _meta), 'Good  ·  mean +6.3 dB  ·  5 pings');
    });

    testWidgets('predicted: estimate, nearest measured cell, contributors, "not a measurement"', (t) async {
      await _pump(t, CoverageCellSheet(info: predicted, meta: _meta, h3: predicted.h3));
      expect(find.text('Good  (+2.5 to +7.5 dB)'), findsOneWidget);
      expect(find.text('+6.5 dB'), findsOneWidget); // 6.55 rounds to 6.5 in binary floating point
      expect(find.text('976 m'), findsOneWidget);
      expect(find.text('2 measured cells'), findsOneWidget);
      expect(find.textContaining('not a measurement'), findsOneWidget);
      expect(coverageCellSummary(predicted, _meta), 'Predicted good  ·  about +6.5 dB');
    });

    test('summaries for No reply and an empty answer', () {
      const none = CoverageCellInfo(h3: 'x', preset: 'sf7bw62.5', measured: MeasuredCellInfo(nOk: 0, nFail: 2, nSnr: 0, band: 0));
      expect(coverageCellSummary(none, _meta), 'No reply  ·  2 pings');
      expect(coverageCellSummary(const CoverageCellInfo(h3: 'x', preset: 'p'), _meta), 'Nothing measured here yet');
      expect(coverageCellSummary(null, _meta, mine: mine), 'Your pings here: 4');
    });

    for (final b in Brightness.values) {
      testWidgets('golden: measured inspector ${b.name}', (t) async {
        await _pump(t, CoverageCellSheet(info: measured, meta: _meta, h3: measured.h3, mine: mine, repeaterName: (k) => k == '297d' ? 'Alpha Tower' : null, now: goldenNow), b: b);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/coverage_inspector_measured_${b.name}.png'));
      });
      testWidgets('golden: coverage v2 legend ${b.name}', (t) async {
        await _pump(t, MapLegendSheet(coverageV2: true, meta: _meta), b: b, size: const Size(390, 2600));
        await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/coverage_v2_legend_${b.name}.png'));
      });
    }

    test('every palette has a band ramp in both brightnesses', () {
      for (final p in ColourPalette.values) {
        for (final b in Brightness.values) {
          expect(CoverageBandColors.of(p, b).band, hasLength(7));
        }
      }
    });
  });

  group('model', () {
    testWidgets('v2 draws tiles live; a window, source or timeline switches to the metric=mean cells and hides predicted', (t) async {
      final h = Harness();
      h.client.siteConfigResult = const SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'coverageV2'});
      await t.runAsync(() async {
        await h.state.init();
        await h.state.refreshSiteConfig();
      });
      final m = DriveMapModel(h.state);
      addTearDown(m.dispose);
      expect(m.coverageV2, isTrue);
      expect(m.effectiveRes, 11, reason: 'one cell size at every zoom (D1)');
      expect(m.drawTiles, isTrue);
      m.coverageQuery = m.coverageQuery.copyWith(since: CoverageSince.week);
      expect(m.coverageFiltered, isTrue);
      expect(m.drawTiles, isFalse);
      expect(m.statusOf('predicted').detail, 'Hidden while looking back: the estimate is for today');
      m.coverageQuery = const CoverageQuery();
      expect(m.drawTiles, isTrue);
      h.state.coverageTiles.networkFailures = 3;
      expect(m.drawTiles, isFalse, reason: 'offline: the saved cells draw instead');
      expect(m.statusOf('predicted').canRetry, isTrue);
      await m.retry('predicted');
      expect(h.state.coverageTiles.offline, isFalse);
    });
  });
}

// ---------------------------------------------------------------------------------------------- tap -> inspector, real H3
H3? _loadH3() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib']) {
    if (!File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

void tapGroup() {
  final h3 = _loadH3();
  group('tap a v2 cell (libh3 by path, as the app loads it on iOS)', () {
    late H3? saved;
    setUp(() {
      saved = CoverageMap.hexEngine;
      CoverageMap.hexEngine = h3;
    });
    tearDown(() => CoverageMap.hexEngine = saved);

    for (final z in [13.6, 12.2]) {
      testWidgets('a measured cell under the finger opens the v2 inspector at zoom $z', (t) async {
        final d13 = decodeCoverageTile(_bytes('measured-13-2207-3102.mvt'), CoverageTileLayer.measured, 13, 2207, 3102);
        final d12 = decodeCoverageTile(_bytes('measured-9-137-193.mvt'), CoverageTileLayer.measured, 9, 137, 193);
        final store = CoverageTileStore(CoverageV2Client(Uri.parse('https://x.test')), decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y));
        store.debugPut(coverageTileKey(CoverageTileLayer.measured, _meta.defaultPreset, _meta.version, 13, 2207, 3102), d13);
        // the z12 tile for the zoomed-out case: re-key the z9 points under every z12 tile around them is overkill; use z13 points
        // through the z13 hexagons' centroids instead (same cells, as dots).
        var lat = 0.0, lon = 0.0;
        for (var v = d13.starts[0]; v < d13.starts[1]; v++) {
          lat += d13.latLon[2 * v] / 6;
          lon += d13.latLon[2 * v + 1] / 6;
        }
        if (z < 13) {
          final pts = Float64List.fromList([lat, lon]);
          final (tx, ty) = tileOf(lat, lon, 12);
          store.debugPut(
            coverageTileKey(CoverageTileLayer.measured, _meta.defaultPreset, _meta.version, 12, tx, ty),
            CoverageTileData(pts, Int32List.fromList([0, 1]), Uint8List.fromList([4]), Int32List.fromList([5]), Float32List(1), const ['']),
          );
        }
        expect(d12.length, greaterThan(0));
        final asked = <String>[];
        t.view.physicalSize = const Size(400, 800);
        t.view.devicePixelRatio = 1;
        addTearDown(t.view.reset);
        final vc = MapViewController();
        addTearDown(vc.dispose);
        // Camera 120 px north of the cell, so the tap is not on the position puck.
        final centre = LatLng(lat + 120 * 360 / (256 * math.pow(2, z)) * math.cos(lat * math.pi / 180), lon);
        await t.pumpWidget(MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          home: Scaffold(
            body: CoverageMap(
              viewController: vc,
              pings: const [],
              repeaters: const [],
              follow: false,
              showTiles: false,
              fallbackCenter: centre,
              coverageV2: CoverageV2Inputs(
                tiles: store,
                meta: _meta,
                fetchCell: (id) async {
                  asked.add(id);
                  return CoverageCellInfo.fromJson({..._json('cell-measured.json'), 'h3': id});
                },
              ),
            ),
          ),
        ));
        await t.pump(const Duration(milliseconds: 200));
        vc.map.move(centre, z);
        await t.pump(const Duration(milliseconds: 200));
        final cam = MapCamera.of(t.element(find.byType(CoverageTilesLayer).first));
        final at = t.getTopLeft(find.byType(FlutterMap)) + cam.latLngToScreenOffset(LatLng(lat, lon));
        await t.tapAt(at);
        await t.pump(const Duration(milliseconds: 300));
        await t.pump(const Duration(milliseconds: 300));
        expect(asked, hasLength(1), reason: 'the inspector read the tapped cell');
        expect(asked.single, d13.h[0], reason: 'the res-11 cell of that hexagon');
        expect(find.byKey(const Key('info-panel-header')), findsOneWidget);
      }, skip: h3 == null);
    }
  });
}
