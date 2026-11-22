// MAP slice 1, app half (site #363): the coverage summary ladder. The Map Definition `?v=2` ladder is read, the summary tiles
// (`measured-summary`, `predicted-summary`) decode with the share `f`, the hexagons are drawn from zoom 5 to the res-11
// hexagons with a strength that follows the share driven, a hexagon on a tile edge is drawn once, the dot layers step aside,
// a tap on a summary hexagon finds its id, and without the ladder (an older definition) nothing changes.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/coverage_v2.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_definition_v2.dart';
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/map/coverage_tiles_layer.dart';

Map<String, dynamic> _json(String n) => jsonDecode(File('test/fixtures/coverage_v2/$n').readAsStringSync()) as Map<String, dynamic>;
MapDefinition _v2() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-cmh.json').readAsStringSync());
final _tile = File('test/fixtures/map_v2/measured-summary-7-34-47.mvt').readAsBytesSync();

CoverageTileStore _store({http.Client? client}) =>
    CoverageTileStore(CoverageV2Client(Uri.parse('https://x.test'), client: client), decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y));

/// A one-hexagon tile (flat arrays) with H3 id [h], band [band], share [f].
CoverageTileData _hex(String h, int band, double f, {double lat = 40, double lon = -83, double r = 0.05, double o = 0.4}) {
  final ll = <double>[];
  for (var k = 0; k < 6; k++) {
    final a = k * math.pi / 3;
    ll
      ..add(lat + r * math.sin(a))
      ..add(lon + r * math.cos(a));
  }
  return CoverageTileData(Float64List.fromList(ll), Int32List.fromList([0, 6]), Uint8List.fromList([band]), Int32List.fromList([10]), Float32List.fromList([o]), [h], Float32List.fromList([f]));
}

Future<void> _pumpMap(WidgetTester t, {required LatLng at, required double zoom, required List<Widget> layers}) async {
  t.view.physicalSize = const Size(400, 800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(home: FlutterMap(key: UniqueKey(), options: MapOptions(initialCenter: at, initialZoom: zoom), children: layers)));
  await t.pump();
}

void main() {
  final meta = CoverageMeta.fromJson(_json('meta.json'));
  final colors = CoverageBandColors.of(ColourPalette.standard, Brightness.dark);

  group('the ladder in the definition', () {
    test('the live v=2 body gives the ladder; the bundled (version 1) copy gives none', () {
      final l = _v2().coverageLadder!;
      expect(l.fromZoom, 5);
      expect(l.toZoom, 12);
      expect(l.hexFromZoom, 13);
      expect(l.steps, CoverageLadder.nov22.steps);
      expect([for (var z = 5; z <= 12; z++) l.resAt(z)], [5, 6, 6, 7, 8, 9, 9, 10]);
      expect(l.resAt(4), isNull);
      expect(l.resAt(13), isNull);
      expect(l.measuredUrl, contains('measured-summary'));
      expect(MapDefinition.bundled.coverageLadder, isNull, reason: 'no `ladder`: build 72 drawing');
    });

    test('drawsAt: from zoom 5 up to (not including) the res-11 hexagons; tile zoom stays inside the ladder', () {
      final l = CoverageLadder.nov22;
      expect([for (final z in [4.9, 5.0, 8.6, 12.9, 13.0]) l.drawsAt(z)], [false, true, true, true, false]);
      expect([for (final z in [5.2, 8.6, 12.9]) l.tileZoom(z)], [5, 8, 12]);
    });

    test('strength = 0.45 + 0.55 x sqrt(f): one driven road is light, a driven cell solid', () {
      final l = CoverageLadder.nov22;
      expect(l.strength(0), closeTo(0.45, 1e-9));
      expect(l.strength(1), closeTo(1.0, 1e-9));
      expect(l.strength(0.25), closeTo(0.725, 1e-9));
      expect(l.strength(0.01), lessThan(l.strength(0.5)));
    });

    test('the app asks for ?v=2 and a version 1 answer still parses', () {
      expect(requestedMapDefinitionV, 2);
      expect(supportedMapDefinitionV, 2);
    });
  });

  group('summary tiles', () {
    test('the real production tile (z7, Nov 22) decodes into hexagons with a band and a share', () {
      final d = decodeCoverageTile(_tile, CoverageTileLayer.measuredSummary, 7, 34, 47);
      expect(d.length, greaterThan(0));
      for (var f = 0; f < d.length; f++) {
        expect(d.vertexCount(f), inInclusiveRange(3, 12), reason: 'a polygon (a hexagon, clipped at a tile edge, or a pentagon), not a point');
        expect(d.band[f], inInclusiveRange(0, 6));
        expect(d.share(f), inInclusiveRange(0, 1), reason: 'the server rounds a tiny share to 0: drawn at the minimum strength');
        expect(h3ResolutionOf(d.h[f]), 6, reason: 'z7 reads res 6');
      }
      // The layer name in the tile is `measured-summary`: read as the plain measured layer it finds nothing.
      expect(decodeCoverageTile(_tile, CoverageTileLayer.measured, 7, 34, 47).length, 0);
    });

    test('the tile address is tiles/<layer>-summary/z/x/y.mvt with preset and version', () async {
      final asked = <Uri>[];
      final c = CoverageV2Client(Uri.parse('https://cmh.meshsonar.com'), client: MockClient((r) async {
        asked.add(r.url);
        return http.Response.bytes(_tile, 200);
      }));
      await c.tile(CoverageTileLayer.measuredSummary, 7, 34, 47, preset: 'sf7bw62.5', version: 1945);
      await c.tile(CoverageTileLayer.predictedSummary, 8, 69, 94, preset: 'sf7bw62.5');
      expect(asked[0].path, '/api/coverage/tiles/measured-summary/7/34/47.mvt');
      expect(asked[0].queryParameters, {'preset': 'sf7bw62.5', 'v': '1945'});
      expect(asked[1].path, '/api/coverage/tiles/predicted-summary/8/69/94.mvt');
    });

    test('the tap card answer: cells, mean, band, share; a share is never rounded to 0 or 100', () {
      final i = CoverageSummaryInfo.fromJson({
        'h3': '8728E6CA3FFFFFF', 'res': 7, 'preset': 'sf7bw62.5', 'childCells': 2401,
        'measured': {'cells': 214, 'attempts': 1500, 'nOk': 1100, 'nSnr': 1090, 'snrMean': 3.1, 'band': 4, 'share': 0.38},
        'predicted': {'cells': 900, 'snrMean': -4, 'opacity': 0.3, 'band': 3, 'share': 0.37},
      });
      expect(i.h3, '8728e6ca3fffffff'.substring(0, 15));
      expect(i.measured!.cells, 214);
      expect(i.measured!.snrMean, 3.1);
      expect(i.predicted!.share, 0.37);
      expect([0.004, 0.011, 0.38, 0.996, 1.0].map(coverageSharePct).toList(), ['under 1%', '1%', '38%', 'over 99%', '100%']);
      expect(CoverageSummaryInfo.fromJson({'h3': '8728e6ca3ffffff', 'res': 7, 'measured': null, 'predicted': null}).measured, isNull);
    });

    test('h3ResolutionOf reads the resolution out of the index', () {
      expect(h3ResolutionOf('8728e6ca3ffffff'), 7);
      expect(h3ResolutionOf('8b2a1072b59afff'), 11);
      expect(h3ResolutionOf('zz'), isNull);
    });
  });

  group('styles', () {
    test('measured summary: the band colour, a fill that grows with the share driven, no outline', () {
      final s = measuredSummaryStyles(colors, CoverageLadder.nov22);
      expect(s, hasLength(7 * kSummaryStrengthSteps));
      final light = s[measuredSummaryStyleIndex(4, 0.02)], solid = s[measuredSummaryStyleIndex(4, 1)];
      expect(light.fill.a, lessThan(solid.fill.a));
      expect(solid.fill.a, closeTo(colors.definition.drawingValue('measured', 0.85), 0.01));
      expect(light.fill.a, greaterThan(0.4 * 0.85 - 0.05), reason: 'never invisible: 0.45 x measured at least');
      expect(solid.border.a, 0);
      expect(solid.fill.toARGB32() & 0xFFFFFF, colors[4].toARGB32() & 0xFFFFFF);
    });

    test('predicted summary: a hatch under the fill, band 0 is hatch only; strength scales both', () {
      final s = predictedSummaryStyles(colors, CoverageLadder.nov22);
      expect(s, hasLength(6 * kPredictedOpacitySteps * kSummaryStrengthSteps));
      final a = s[predictedSummaryStyleIndex(3, 0.4, 0.05)], b = s[predictedSummaryStyleIndex(3, 0.4, 1)];
      expect(a.hatch, isNotNull);
      expect(a.fill.a, lessThan(b.fill.a));
      expect(a.hatch!.a, lessThan(b.hatch!.a));
      final none = s[predictedSummaryStyleIndex(0, 0.4, 1)];
      expect(none.fill.a, 0);
      expect(none.hatch, isNotNull);
    });
  });

  group('the layer', () {
    final here = LatLng(40, -83);

    testWidgets('draws summary hexagons from the ladder zoom; one hexagon on a tile edge is drawn once', (t) async {
      final store = _store();
      // Camera zoom 8.6 reads tile zoom 8. Two tiles both carry hexagon A; B is only in the second.
      final (x, y) = tileOf(40, -83, 8);
      for (final tx in [x, x + 1, x - 1]) {
        for (final ty in [y, y - 1, y + 1]) {
          final key = coverageTileKey(CoverageTileLayer.measuredSummary, meta.defaultPreset, meta.version, 8, tx, ty);
          store.debugPut(key, tx == x && ty == y ? _hex('8728e6ca3ffffff', 4, 0.5) : (tx == x + 1 && ty == y ? _hex('8728e6ca3ffffff', 4, 0.5) : CoverageTileData.empty));
        }
      }
      await _pumpMap(t, at: here, zoom: 8.6, layers: [CoverageTilesLayer(layer: CoverageTileLayer.measuredSummary, store: store, meta: meta, colors: colors, ladder: CoverageLadder.nov22)]);
      expect(t.state<CoverageTilesLayerState>(find.byType(CoverageTilesLayer)).cellCount, 1, reason: 'the same H3 id in two tiles is one hexagon');
      expect(find.byKey(const ValueKey('coverage-tiles-measuredSummary')), findsOneWidget);
    });

    testWidgets('draws nothing without the ladder, below zoom 5, or from the res-11 hexagons (zoom 13)', (t) async {
      final store = _store();
      for (final z in [4, 8, 13]) {
        final (x, y) = tileOf(40, -83, z);
        store.debugPut(coverageTileKey(CoverageTileLayer.measuredSummary, meta.defaultPreset, meta.version, z, x, y), _hex('8728e6ca3ffffff', 4, 0.5));
      }
      Future<int> cells(double zoom, CoverageLadder? ladder) async {
        await _pumpMap(t, at: here, zoom: zoom, layers: [CoverageTilesLayer(layer: CoverageTileLayer.measuredSummary, store: store, meta: meta, colors: colors, ladder: ladder)]);
        return t.state<CoverageTilesLayerState>(find.byType(CoverageTilesLayer)).cellCount;
      }

      expect(await cells(8.6, null), 0, reason: 'older definition: build 72 drawing');
      expect(await cells(4.4, CoverageLadder.nov22), 0);
      expect(await cells(13.4, CoverageLadder.nov22), 0);
      expect(await cells(8.6, CoverageLadder.nov22), 1);
    });

    testWidgets('the dot layers step aside between zoom 5 and the hexagons only when the ladder is there', (t) async {
      final store = _store();
      final (x, y) = tileOf(40, -83, 8);
      // A measured point tile at z8 (one vertex = a dot) and a predicted one.
      CoverageTileData dot() => CoverageTileData(Float64List.fromList([40, -83]), Int32List.fromList([0, 1]), Uint8List.fromList([4]), Int32List.fromList([5]), Float32List.fromList([0.4]), const ['']);
      store.debugPut(coverageTileKey(CoverageTileLayer.measured, meta.defaultPreset, meta.version, 8, x, y), dot());
      store.debugPut(coverageTileKey(CoverageTileLayer.predicted, meta.defaultPreset, meta.version, 8, x, y), dot());
      Future<(int, int)> counts(CoverageLadder? l) async {
        await _pumpMap(t, at: here, zoom: 8.6, layers: [
          CoverageTilesLayer(key: const Key('m'), layer: CoverageTileLayer.measured, store: store, meta: meta, colors: colors, ladder: l),
          CoverageTilesLayer(key: const Key('p'), layer: CoverageTileLayer.predicted, store: store, meta: meta, colors: colors, ladder: l),
        ]);
        return (t.state<CoverageTilesLayerState>(find.byKey(const Key('m'))).cellCount, t.state<CoverageTilesLayerState>(find.byKey(const Key('p'))).cellCount);
      }

      expect(await counts(null), (1, 1), reason: 'build 72: dots');
      expect(await counts(CoverageLadder.nov22), (0, 0), reason: 'the hexagon picture replaces the dots');
    });

    testWidgets('a tap finds the summary hexagon under it (its id), not a res-11 cell', (t) async {
      final store = _store();
      final (x, y) = tileOf(40, -83, 8);
      store.debugPut(coverageTileKey(CoverageTileLayer.measuredSummary, meta.defaultPreset, meta.version, 8, x, y), _hex('8728e6ca3ffffff', 4, 0.5));
      final hit = coverageTileHit(store, CoverageTileLayer.measuredSummary, meta, 40.0, -83.0, 8);
      expect(hit?.h3, '8728e6ca3ffffff');
      expect(h3ResolutionOf(hit!.h3!), lessThan(kCoverageV2Res));
      expect(coverageTileHit(store, CoverageTileLayer.measuredSummary, meta, 10.0, 10.0, 8), isNull);
    });
  });
}
