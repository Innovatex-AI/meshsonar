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
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// The label font of the app's basemap styles (tool/basemap/make_basemap_styles.mjs): the system font.
const appLabelFont = 'CupertinoSystemText';

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

  group('build 77: every style is well formed', () {
    final all = <String, Map<String, dynamic>>{
      for (final dark in [false, true])
        for (final look in BasemapLook.values) 'ours ${look.name} ${dark ? 'dark' : 'light'}': basemapStyle(BasemapSource.ours, dark: dark, look: look),
      for (final dark in [false, true]) 'openFreeMap ${dark ? 'dark' : 'light'}': basemapStyle(BasemapSource.openFreeMap, dark: dark),
    };
    for (final e in all.entries) {
      test('${e.key}: every layer reads a source the style has; layer ids are unique; the renderer reads it with no warning', () {
        final style = e.value;
        final sources = (style['sources'] as Map).keys.toSet();
        final layers = (style['layers'] as List).cast<Map<String, dynamic>>();
        expect(layers, isNotEmpty);
        final ids = <String>{};
        for (final l in layers) {
          expect(ids.add(l['id'] as String), isTrue, reason: 'layer id ${l['id']} twice');
          if (l['type'] == 'background') {
            expect(l.containsKey('source'), isFalse);
          } else {
            expect(sources, contains(l['source']), reason: 'layer ${l['id']} reads source ${l['source']}');
          }
        }
        final log = _Capture();
        final theme = vtr.ThemeReader(logger: log).read(style);
        expect(log.warnings, isEmpty, reason: log.warnings.join('\n'));
        expect(theme.layers.length, layers.length);
        expect(style.toString(), isNot(contains('http')));
      });
    }
  });

  group('build 77: names above coverage (base without names + names-only pass)', () {
    List<Map<String, dynamic>> layersOf(BasemapLook look, bool dark) => (basemapStyle(BasemapSource.ours, dark: dark, look: look)['layers'] as List).cast<Map<String, dynamic>>();
    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      for (final (whole, base, names) in [(BasemapLook.data, BasemapLook.dataBase, BasemapLook.dataLabels), (BasemapLook.topo, BasemapLook.topoBase, BasemapLook.topoLabels)]) {
        test('${whole.name} $theme: the base has no symbol layer, the names pass has only symbol layers, together they are the whole map', () {
          final b = layersOf(base, dark), n = layersOf(names, dark), w = layersOf(whole, dark);
          expect(b.where((l) => l['type'] == 'symbol'), isEmpty, reason: 'no names in the base under the coverage');
          expect(n, isNotEmpty);
          expect(n.every((l) => l['type'] == 'symbol'), isTrue, reason: 'no ground, water or road lines above the coverage');
          expect(n.any((l) => l['type'] == 'background'), isFalse);
          expect([...b, ...n], w, reason: 'nothing lost, nothing drawn twice');
          expect(base.labelsPass, names);
          expect(names.isLabelsOnly, isTrue);
          expect(base.isBaseOnly, isTrue);
          // Street and town names are both there.
          expect(n.map((l) => l['id']), containsAll(['roads_labels_major', 'roads_labels_minor', 'places_locality']));
        });
      }
    }

    test('the Satellite names look is still names only, and the whole-map looks are neither base-only nor names-only', () {
      expect(BasemapLook.labels.isLabelsOnly, isTrue);
      for (final l in [BasemapLook.road, BasemapLook.topo, BasemapLook.data]) {
        expect(l.isLabelsOnly || l.isBaseOnly, isFalse, reason: l.name);
        expect(l.labelsPass, isNull);
      }
    });

    test('OpenFreeMap has one look: a base-only or data-first look asked of the fallback is its whole style, names included', () {
      for (final dark in [false, true]) {
        final ofm = basemapStyle(BasemapSource.openFreeMap, dark: dark);
        for (final look in [BasemapLook.data, BasemapLook.dataBase, BasemapLook.topoBase]) {
          expect(identical(basemapStyle(BasemapSource.openFreeMap, dark: dark, look: look), ofm), isTrue, reason: look.name);
        }
        expect((ofm['layers'] as List).any((l) => l['type'] == 'symbol'), isTrue, reason: 'the fallback keeps its names under the coverage');
      }
    });
  });

  group('build 77: the data-first road map (drawn while coverage is on)', () {
    Map<String, Map<String, dynamic>> byId(BasemapLook look, bool dark) => {
      for (final l in (basemapStyle(BasemapSource.ours, dark: dark, look: look)['layers'] as List).cast<Map<String, dynamic>>()) l['id'] as String: l,
    };
    double alpha(Object? colour) {
      final m = RegExp(r'^rgba\(\d+,\d+,\d+,([\d.]+)\)$').firstMatch(colour as String);
      return m == null ? 1 : double.parse(m.group(1)!);
    }

    for (final dark in [false, true]) {
      final theme = dark ? 'dark' : 'light';
      test('$theme: no building outlines until street zoom (16); the road map draws them at every zoom', () {
        final data = byId(BasemapLook.data, dark), road = byId(BasemapLook.road, dark);
        expect(data['buildings']!['minzoom'], 16);
        expect(road['buildings']!.containsKey('minzoom'), isFalse);
      });

      test('$theme: side streets are dimmer than main roads and dimmer than on the road map; their casings are gone', () {
        final data = byId(BasemapLook.data, dark), road = byId(BasemapLook.road, dark);
        double a(Map<String, Map<String, dynamic>> s, String id) => alpha((s[id]!['paint'] as Map)['line-color']);
        expect(a(road, 'roads_minor'), a(road, 'roads_highway'), reason: 'the road map draws every road at one strength (the problem)');
        expect(a(data, 'roads_minor'), lessThan(a(road, 'roads_minor') * 0.6));
        expect(a(data, 'roads_minor_service'), lessThan(a(data, 'roads_minor')));
        expect(a(data, 'roads_minor'), lessThan(a(data, 'roads_major')));
        expect(a(data, 'roads_major'), lessThan(a(data, 'roads_highway')));
        expect(a(data, 'roads_highway'), greaterThan(a(road, 'roads_highway')), reason: 'main roads stay the skeleton of the map');
        for (final id in ['roads_minor_casing', 'roads_minor_service_casing', 'roads_link_casing', 'roads_tunnels_minor_casing', 'roads_bridges_minor_casing']) {
          expect(road.containsKey(id), isTrue, reason: id);
          expect(data.containsKey(id), isFalse, reason: id);
        }
        expect(data.containsKey('roads_highway_casing_late'), isTrue);
      });

      test('$theme: brighter water, and the faint land-use washes are not drawn', () {
        final data = byId(BasemapLook.data, dark), road = byId(BasemapLook.road, dark);
        expect(alpha((data['water']!['paint'] as Map)['fill-color']), greaterThan(alpha((road['water']!['paint'] as Map)['fill-color']) * 1.5));
        expect(data.keys.where((id) => id.startsWith('landuse_')), ['landuse_park']);
        expect(data.length, lessThan(road.length - 10), reason: 'a simpler map: fewer layers to draw');
      });

      test('$theme: fewer street names (side streets from zoom 16, no house numbers), in full ink on a solid halo', () {
        final data = byId(BasemapLook.data, dark), road = byId(BasemapLook.road, dark);
        expect(road['roads_labels_minor']!['minzoom'], 15);
        expect(data['roads_labels_minor']!['minzoom'], 16);
        expect(data.containsKey('address_label'), isFalse);
        expect(data['roads_labels_major']!['minzoom'], road['roads_labels_major']!['minzoom'], reason: 'main road names are kept');
        final ink = dark ? '230,232,234' : '27,31,36', paper = dark ? '18,20,23' : '250,250,250';
        final paint = data['roads_labels_major']!['paint'] as Map;
        expect(paint['text-color'], startsWith('rgba($ink,'));
        expect(alpha(paint['text-color']), greaterThanOrEqualTo(0.85));
        expect(paint['text-halo-color'], startsWith('rgba($paper,'));
        expect(alpha(paint['text-halo-color']), greaterThanOrEqualTo(0.9));
        expect(paint['text-halo-width'], greaterThan(1));
        expect((data['places_locality']!['paint'] as Map)['text-color'], 'rgb($ink)');
      });
    }

    test('dark road map: street names are ink at 80 %, not slate (grey on grey); light keeps slate', () {
      expect((byId(BasemapLook.road, true)['roads_labels_major']!['paint'] as Map)['text-color'], 'rgba(230,232,234,0.8)');
      expect((byId(BasemapLook.road, false)['roads_labels_major']!['paint'] as Map)['text-color'], 'rgb(91,99,109)');
    });

    testWidgets('a real downtown tile: the data-first base is a calmer picture than the road map, in both themes', (tester) async {
      await tester.runAsync(() async {
        final bytes = File('test/fixtures/basemap/protomaps-13-2207-3102.mvt').readAsBytesSync();
        for (final dark in [false, true]) {
          Future<double> busy(BasemapLook look) async {
            final img = await _render(basemapStyle(BasemapSource.ours, dark: dark, look: look), 'protomaps', bytes, 13);
            final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
            final ground = dark ? 18 : 250; // --paper, red channel
            var n = 0;
            for (var i = 0; i < px.length; i += 4) {
              if ((px[i] - ground).abs() > 10) n++;
            }
            return n / (px.length / 4);
          }

          final road = await busy(BasemapLook.road), data = await busy(BasemapLook.dataBase);
          expect(road, greaterThan(0.05), reason: 'the road map draws downtown');
          expect(data, greaterThan(0.005), reason: 'the data-first map still draws its main roads and water');
          expect(data, lessThan(road * 0.75), reason: 'dark $dark: road $road, data-first $data');
        }
      });
    });

    testWidgets('a real downtown tile: the names pass is a clear sheet (nothing painted but names)', (tester) async {
      await tester.runAsync(() async {
        final bytes = File('test/fixtures/basemap/protomaps-13-2207-3102.mvt').readAsBytesSync();
        for (final look in [BasemapLook.dataLabels, BasemapLook.topoLabels]) {
          final img = await _render(basemapStyle(BasemapSource.ours, dark: true, look: look), 'protomaps', bytes, 13);
          final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          var clear = 0;
          for (var i = 3; i < px.length; i += 4) {
            if (px[i] == 0) clear++;
          }
          // (The test font draws every letter as a solid block, so names cover far more here than on a phone.)
          expect(clear / (px.length / 4), greaterThan(0.3), reason: '${look.name}: the coverage must show through');
        }
      });
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
