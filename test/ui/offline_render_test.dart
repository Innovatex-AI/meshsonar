// Renders REAL tiles from the hosted CMH pack with vector_tile_renderer and the app's offline style (dark + light),
// and checks the pictures are maps: many colours, water where the reservoir is, labels drawn. Skips without the pack.
// Set MESHSONAR_RENDER_OUT=<dir> to also write the PNGs for a look by eye (nothing is written by default).
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/pmtiles_reader.dart';
import 'package:meshsonar/ui/map/offline_basemap.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../support/real_pack.dart';

Future<ui.Image> renderTile(PmtilesReader r, Map<String, dynamic> style, int z, int x, int y, {double scale = 2}) async {
  final bytes = await r.tile(z, x, y);
  if (bytes == null) throw StateError('no tile $z/$x/$y');
  final theme = vtr.ThemeReader().read(style);
  final tile = vtr.TileFactory(theme, const vtr.Logger.noop()).createTileData(vtr.VectorTileReader().read(bytes)).toTile();
  final src = vtr.TileSource(tileset: vtr.Tileset({'openmaptiles': tile}));
  return vtr.ImageRenderer(theme: theme, scale: scale).render(src, zoom: z.toDouble());
}

Future<Uint8List> rgba(ui.Image img) async => (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();

Map<int, int> histogram(Uint8List px) {
  final h = <int, int>{};
  for (var i = 0; i < px.length; i += 4) {
    final k = (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
    h[k] = (h[k] ?? 0) + 1;
  }
  return h;
}

int rgbOf(String hex) {
  final c = Color(int.parse('ff${hex.substring(1)}', radix: 16));
  return ((c.r * 255).round() << 16) | ((c.g * 255).round() << 8) | (c.b * 255).round();
}

String layerColor(Map<String, dynamic> style, String id, String prop) =>
    ((style['layers'] as List).firstWhere((l) => l['id'] == id) as Map)['paint'][prop] as String;

Map<String, dynamic> withoutSymbols(Map<String, dynamic> style) => {
  ...style,
  'layers': [for (final l in style['layers'] as List) if (l['type'] != 'symbol') l],
};

Future<void> maybeWrite(ui.Image img, String name) async {
  final dir = Platform.environment['MESHSONAR_RENDER_OUT'];
  if (dir == null || dir.isEmpty) return;
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File('$dir/$name.png')
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  final skip = realPackSkip;
  // Hoover Reservoir (north-east Columbus) lies wholly inside this z11 tile.
  final hoover = tileXY(40.135, -82.88, 11);

  for (final dark in [true, false]) {
    final mode = dark ? 'dark' : 'light';
    testWidgets('real z10/z11/z14 Columbus tiles render as a map ($mode)', (tester) async {
      await tester.runAsync(() async {
        final r = await PmtilesReader.open(realPackFile()!);
        try {
          final style = offlineMapStyle(dark: dark);
          final bg = rgbOf(layerColor(style, 'background', 'background-color'));
          final water = rgbOf(layerColor(style, 'water', 'fill-color'));
          for (final (z, x, y) in [(10, 275, 387), (14, 4414, 6205), (11, hoover.$1, hoover.$2)]) {
            final img = await renderTile(r, style, z, x, y);
            await maybeWrite(img, '$mode-z$z-$x-$y');
            final px = await rgba(img);
            final h = histogram(px);
            final total = img.width * img.height;
            expect(h.length, greaterThan(20), reason: 'z$z: only ${h.length} colours');
            final dominant = h.values.reduce((a, b) => a > b ? a : b);
            expect(dominant / total, lessThan(0.9), reason: 'z$z: one colour covers ${(dominant / total * 100).round()}%');
            final notBg = total - (h[bg] ?? 0);
            expect(notBg / total, greaterThan(0.1), reason: 'z$z: mostly background');
            if (z == 11) {
              final w = (h[water] ?? 0) / total;
              expect(w, greaterThan(0.02), reason: 'Hoover Reservoir tile: water colour covers ${(w * 100).toStringAsFixed(1)}%');
              // The reservoir body (about x 245-265, y 190-230 of the 512 px tile) is water; open land is not.
              double share(int x0, int y0, int x1, int y1) {
                var n = 0, hit = 0;
                for (var yy = y0; yy < y1; yy++) {
                  for (var xx = x0; xx < x1; xx++) {
                    final i = (yy * img.width + xx) * 4;
                    n++;
                    if (((px[i] << 16) | (px[i + 1] << 8) | px[i + 2]) == water) hit++;
                  }
                }
                return hit / n;
              }

              expect(share(248, 195, 262, 225), greaterThan(0.6), reason: 'reservoir body');
              expect(share(380, 200, 420, 240), lessThan(0.05), reason: 'farmland east of the reservoir');
            }
          }
        } finally {
          await r.close();
        }
      });
    }, skip: skip != false);

    testWidgets('labels (places, roads, water) draw from the real tiles without glyph files ($mode)', (tester) async {
      await tester.runAsync(() async {
        final r = await PmtilesReader.open(realPackFile()!);
        try {
          final style = offlineMapStyle(dark: dark);
          for (final (z, x, y) in [(10, 275, 387), (14, 4414, 6205)]) {
            final a = await rgba(await renderTile(r, style, z, x, y));
            final withLabels = await renderTile(r, style, z, x, y);
            await maybeWrite(withLabels, '$mode-labels-z$z');
            final b = await rgba(await renderTile(r, withoutSymbols(style), z, x, y));
            var diff = 0;
            for (var i = 0; i < a.length; i += 4) {
              if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) diff++;
            }
            expect(diff, greaterThan(500), reason: 'z$z: labels changed only $diff pixels');
          }
        } finally {
          await r.close();
        }
      });
    }, skip: skip != false);
  }

  test('the style has the label layers and every layer reads a source-layer the real tiles carry', () {
    for (final dark in [true, false]) {
      final style = offlineMapStyle(dark: dark);
      final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
      final ids = {for (final l in layers) l['id']};
      expect(ids, containsAll(['label-city', 'label-town', 'label-village', 'label-road-major', 'label-motorway', 'label-water', 'label-river']));
      const known = {'water', 'waterway', 'landcover', 'landuse', 'park', 'building', 'transportation', 'transportation_name', 'boundary', 'place', 'water_name'};
      for (final l in layers.where((l) => l['type'] != 'background')) {
        expect(known, contains(l['source-layer']), reason: l['id'] as String);
      }
      for (final l in layers.where((l) => l['type'] == 'symbol')) {
        expect((l['paint'] as Map)['text-halo-width'], greaterThanOrEqualTo(2), reason: '${l['id']} halo for the car');
        expect(((l['layout'] as Map)['text-font'] as List).single, isIn(['Barlow', 'BarlowSemiCondensed']));
      }
      // The theme parses (unknown properties would throw or be dropped silently).
      final theme = vtr.ThemeReader().read(style);
      expect(theme.layers.length, layers.length);
      // vector_map_tiles caches rendered tiles by theme id + version: the palettes must not share a key, and the
      // version must follow offlineStyleVersion so a style change invalidates on-device caches.
      expect(theme.id, dark ? 'meshsonar-offline-dark' : 'meshsonar-offline-light');
      expect(theme.version, '$offlineStyleVersion');
    }
  });

  testWidgets('the committed real-tile fixture renders with labels in both palettes (runs without the big pack)', (tester) async {
    await tester.runAsync(() async {
      final r = await PmtilesReader.open(File('test/fixtures/cmh_mini.pmtiles'));
      try {
        for (final dark in [true, false]) {
          final style = offlineMapStyle(dark: dark);
          final a = await rgba(await renderTile(r, style, 10, 275, 387));
          final b = await rgba(await renderTile(r, withoutSymbols(style), 10, 275, 387));
          expect(histogram(a).length, greaterThan(20));
          var diff = 0;
          for (var i = 0; i < a.length; i += 4) {
            if (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) diff++;
          }
          expect(diff, greaterThan(500), reason: 'labels drew');
        }
      } finally {
        await r.close();
      }
    });
  });
}
