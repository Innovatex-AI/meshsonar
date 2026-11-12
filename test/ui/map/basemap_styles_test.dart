// The app's basemap styles (lib/core/basemap_styles.g.dart, generated from the website's styles by
// tool/basemap/make_basemap_styles.mjs) are fully readable by the app's renderer (vector_tile_renderer warns about any
// expression it cannot read; zero warnings allowed), use the app's system font (SF Pro) and no glyph or sprite files, carry
// the website palette, and draw REAL tiles from our server and from OpenFreeMap (fixtures in test/fixtures/basemap) as maps.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/core/offline_style.dart' show appLabelFont;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

class _Capture implements vtr.Logger {
  final warnings = <String>[];
  @override
  void log(vtr.MessageFunction message) {}
  @override
  void warn(vtr.MessageFunction message) => warnings.add(message());
}

const _sources = [BasemapSource.ours, BasemapSource.openFreeMap];

Future<ui.Image> _render(Map<String, dynamic> style, String source, Uint8List bytes, int z) async {
  final theme = vtr.ThemeReader().read(style);
  final tile = vtr.TileFactory(theme, const vtr.Logger.noop()).createTileData(vtr.VectorTileReader().read(bytes)).toTile();
  return vtr.ImageRenderer(theme: theme, scale: 1).render(vtr.TileSource(tileset: vtr.Tileset({source: tile})), zoom: z.toDouble());
}

Future<Map<int, int>> _histogram(ui.Image img) async {
  final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final h = <int, int>{};
  for (var i = 0; i < px.length; i += 4) {
    final k = (px[i] << 16) | (px[i + 1] << 8) | px[i + 2];
    h[k] = (h[k] ?? 0) + 1;
  }
  return h;
}

void main() {
  for (final source in _sources) {
    for (final dark in [false, true]) {
      final name = '${source.name} ${dark ? 'dark' : 'light'}';
      test('$name: the renderer reads every layer with no warning', () {
        final log = _Capture();
        final style = basemapStyle(source, dark: dark);
        final theme = vtr.ThemeReader(logger: log).read(style);
        expect(log.warnings, isEmpty, reason: log.warnings.join('\n'));
        expect(theme.layers.length, (style['layers'] as List).length, reason: 'every layer was kept');
        expect(theme.layers.length, greaterThan(40));
        expect((style['sources'] as Map).keys.single, source.styleSource);
      });

      test('$name: labels in the system font (SF Pro), no glyphs, no sprites, no URLs', () {
        final style = basemapStyle(source, dark: dark);
        expect(style.containsKey('glyphs'), isFalse);
        expect(style.containsKey('sprite'), isFalse);
        final symbols = [for (final l in style['layers'] as List) if (l['type'] == 'symbol') l as Map];
        expect(symbols, isNotEmpty);
        for (final l in symbols) {
          expect((l['layout'] as Map)['text-font'], [appLabelFont], reason: l['id'] as String);
          expect((l['layout'] as Map).containsKey('icon-image'), isFalse, reason: l['id'] as String);
        }
        expect(basemapStyle(source, dark: dark).toString(), isNot(contains('http')));
      });

      test('$name: the website palette (paper ground, ink-tinted roads)', () {
        final layers = basemapStyle(source, dark: dark)['layers'] as List;
        final bg = layers.firstWhere((l) => l['type'] == 'background') as Map;
        expect((bg['paint'] as Map)['background-color'], dark ? 'rgb(18,20,23)' : 'rgb(250,250,250)'); // --paper
        final road = layers.firstWhere((l) => l['type'] == 'line' && RegExp('road|highway').hasMatch(l['id'] as String) && !RegExp('casing|case').hasMatch(l['id'] as String)) as Map;
        expect((road['paint'] as Map)['line-color'], dark ? 'rgba(230,232,234,0.2)' : 'rgba(27,31,36,0.16)'); // --ink at the road alpha
      });
    }
  }

  group('M3 looks: Topo (the definition\'s palette) and the Satellite labels', () {
    final def = jsonDecode(File('assets/map/map-definition.json').readAsStringSync()) as Map<String, dynamic>;
    final topo = ((def['basemaps'] as List).cast<Map<String, dynamic>>().firstWhere((b) => b['id'] == 'topo'))['topo'] as Map<String, dynamic>;

    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      test('topo $theme: the renderer reads every layer with no warning; one source; system font; no URLs', () {
        final log = _Capture();
        final style = basemapStyle(BasemapSource.ours, dark: dark, look: BasemapLook.topo);
        final read = vtr.ThemeReader(logger: log).read(style);
        expect(log.warnings, isEmpty, reason: log.warnings.join('\n'));
        expect(read.layers.length, (style['layers'] as List).length);
        expect((style['sources'] as Map).keys.single, 'protomaps');
        expect(style.toString(), isNot(contains('http')));
        for (final l in (style['layers'] as List).where((l) => l['type'] == 'symbol')) {
          expect((l['layout'] as Map)['text-font'], [appLabelFont]);
        }
      });

      test('topo $theme: the ground and the water are the definition\'s override colours, untinted', () {
        final overrides = (topo['overrides'] as Map<String, dynamic>)[theme] as Map<String, dynamic>;
        final layers = (basemapStyle(BasemapSource.ours, dark: dark, look: BasemapLook.topo)['layers'] as List).cast<Map<String, dynamic>>();
        final bg = layers.firstWhere((l) => l['type'] == 'background');
        expect(((bg['paint'] as Map)['background-color'] as String).toLowerCase(), (overrides['background'] as String).toLowerCase());
        final water = layers.firstWhere((l) => l['id'] == 'water');
        expect(((water['paint'] as Map)['fill-color']).toString().toLowerCase(), (overrides['water'] as String).toLowerCase());
        final road = basemapStyle(BasemapSource.ours, dark: dark);
        expect(((road['layers'] as List).first as Map)['paint'], isNot((bg['paint'])), reason: 'Topo is not the Road palette');
      });
    }

    test('OpenFreeMap has one look: Topo asked of the fallback is its own style', () {
      expect(basemapStyle(BasemapSource.openFreeMap, dark: false, look: BasemapLook.topo), basemapStyle(BasemapSource.openFreeMap, dark: false));
    });

    test('labels: only symbol layers (town and road names), white-on-dark flavour, readable with no warning', () {
      final log = _Capture();
      final style = basemapStyle(BasemapSource.ours, dark: true, look: BasemapLook.labels);
      final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
      expect(layers, isNotEmpty);
      expect(layers.every((l) => l['type'] == 'symbol'), isTrue, reason: 'no ground, water or road lines over the imagery');
      expect(layers.any((l) => (l['id'] as String).contains('poi')), isFalse);
      vtr.ThemeReader(logger: log).read(style);
      expect(log.warnings, isEmpty, reason: log.warnings.join('\n'));
      expect(basemapStyle(BasemapSource.ours, dark: false, look: BasemapLook.labels), style, reason: 'one look over imagery, whatever the app theme');
    });
  });

  test('no POI layer (the map is about the mesh), labels last', () {
    final layers = basemapStyle(BasemapSource.ours, dark: false)['layers'] as List;
    expect(layers.where((l) => (l['id'] as String).contains('poi')), isEmpty);
    final firstSymbol = layers.indexWhere((l) => l['type'] == 'symbol');
    expect(layers.skip(firstSymbol).every((l) => l['type'] == 'symbol'), isTrue);
  });

  final fixtures = {
    'protomaps z13 downtown Columbus': (BasemapSource.ours, 'test/fixtures/basemap/protomaps-13-2207-3102.mvt', 13),
    'protomaps z10 Columbus': (BasemapSource.ours, 'test/fixtures/basemap/protomaps-10-275-387.mvt', 10),
    'openfreemap z13 downtown Columbus': (BasemapSource.openFreeMap, 'test/fixtures/basemap/openfreemap-13-2207-3102.mvt', 13),
  };
  for (final e in fixtures.entries) {
    for (final dark in [false, true]) {
      testWidgets('${e.key} (${dark ? 'dark' : 'light'}) renders as a map', (tester) async {
        await tester.runAsync(() async {
          final (source, path, z) = e.value;
          final style = basemapStyle(source, dark: dark);
          final img = await _render(style, source.styleSource, File(path).readAsBytesSync(), z);
          final h = await _histogram(img);
          final total = img.width * img.height;
          expect(h.length, greaterThan(20), reason: 'only ${h.length} colours: nothing drawn');
          final dominant = h.values.reduce((a, b) => a > b ? a : b);
          expect(dominant / total, lessThan(0.97), reason: 'one colour covers the tile');
          // Mostly the paper ground in the website's light / dark: light tiles are light, dark tiles are dark.
          final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          var lum = 0.0;
          for (var i = 0; i < px.length; i += 4) {
            lum += 0.2126 * px[i] + 0.7152 * px[i + 1] + 0.0722 * px[i + 2];
          }
          lum /= total;
          expect(dark ? lum < 90 : lum > 180, isTrue, reason: 'mean luminance $lum');
        });
      });
    }
  }
}
