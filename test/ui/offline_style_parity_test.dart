// The offline vector style must look like the online map: Carto colours through the SAME matrices the app applies
// to OSM raster tiles. These tests pin that link (matrix copies, colour transform) and the web/app variants.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/offline_style.dart';
import 'package:meshsonar/ui/theme.dart';

void main() {
  test('core matrix copies equal the matrices the online map applies (ui/theme.dart)', () {
    expect(osmTintLight, MeshSonarColors.light.tileMatrix);
    expect(osmTintDark, MeshSonarColors.dark.tileMatrix);
  });

  test('tintHex matches what ColorFilter.matrix does to an OSM pixel', () {
    // Carto land #f2efe9 through the light matrix: 0.2446*242 + 0.8227*239 + 0.0831*233 - 51.33 = 223.8 -> e0
    expect(tintHex('#f2efe9', osmTintLight), '#e0e5e7');
    expect(tintHex('#000000', osmTintLight), '#00000a');
    expect(tintHex('#ffffff', osmTintDark), '#0d1b26'); // white streets become the dark chart background
    expect(tintHex('#000000', osmTintDark), '#ffffff');
  });

  test('both palettes keep the online hierarchy: motorway darker than streets (light), water distinct from land', () {
    for (final dark in [false, true]) {
      final m = dark ? osmTintDark : osmTintLight;
      final land = lumaOf(tintHex(cartoColors['land']!, m));
      final water = lumaOf(tintHex(cartoColors['water']!, m));
      final motorway = lumaOf(tintHex(cartoColors['motorway']!, m));
      final minor = lumaOf(tintHex(cartoColors['minor']!, m));
      expect((land - water).abs(), greaterThan(0.02), reason: 'water vs land ($dark)');
      expect((motorway - minor).abs(), greaterThan(0.1), reason: 'motorway vs street ($dark)');
    }
  });

  test('web variant: glyph stacks, pmtiles source, glyphs URL; app variant has neither', () {
    final web = offlineStyle(dark: false, target: OfflineStyleTarget.web, pmtilesUrl: 'https://tiles.meshsonar.com/CMH-v261024.pmtiles');
    expect(web['glyphs'], 'https://tiles.meshsonar.com/fonts/{fontstack}/{range}.pbf');
    expect((web['sources'] as Map)['openmaptiles']['url'], 'pmtiles://https://tiles.meshsonar.com/CMH-v261024.pmtiles');
    final fonts = {
      for (final l in (web['layers'] as List).where((l) => l['type'] == 'symbol')) ...((l['layout'] as Map)['text-font'] as List),
    };
    expect(fonts, {webFontRegular, webFontMedium, webFontBold});
    final app = offlineStyle(dark: false);
    expect(app.containsKey('glyphs'), isFalse);
    expect(app.containsKey('sprite'), isFalse);
    expect(web.containsKey('sprite'), isFalse); // no icon layers: no sprite needed
    expect((app['sources'] as Map)['openmaptiles'].containsKey('url'), isFalse);
    // Same layers, same colours: only fonts, the source and the label ORDER differ. vector_tile_renderer gives the
    // first symbol layer priority, MapLibre the last, so the web labels are reversed to keep the same priorities.
    List<String> ids(Map<String, dynamic> s, bool symbols) => [
      for (final l in s['layers'] as List)
        if ((l['type'] == 'symbol') == symbols) l['id'] as String,
    ];
    expect(ids(web, false), ids(app, false));
    expect(ids(web, true), ids(app, true).reversed.toList());
    expect(ids(app, true).first, 'label-city'); // cities win collisions in the app
    expect(ids(web, true).last, 'label-city'); // and on the web
  });

  test('every colour in the style is reachable from a Carto colour through the matrix (no stray hand-picked colours)', () {
    for (final dark in [false, true]) {
      final m = dark ? osmTintDark : osmTintLight;
      final allowed = {for (final v in cartoColors.values) tintHex(v, m)};
      final style = offlineStyle(dark: dark);
      for (final l in (style['layers'] as List).cast<Map<String, dynamic>>()) {
        for (final e in (l['paint'] as Map).entries) {
          if (e.value is String && (e.value as String).startsWith('#')) {
            expect(allowed, contains(e.value), reason: '${l['id']} ${e.key}');
          }
        }
      }
    }
  });

  test('Color sanity: tinted colours parse as Flutter colours', () {
    final c = Color(int.parse('ff${tintHex('#aad3df', osmTintLight).substring(1)}', radix: 16));
    expect(c.a, 1.0);
  });
}
