// Every map in the app shows its tile credit without interaction (OSM Attribution Guidelines; unified map plan M0 / M2, audit
// 03 table 1.0 found 11 mini maps without one). Source-level: each file that builds a FlutterMap must draw the shared credit
// (MiniMapCredit / BasemapCredit, or the Drive map's AttributionLine), which names the source actually drawn
// ("Protomaps © OpenStreetMap contributors", or OpenFreeMap's credit on the fallback). A hard-coded OSM line is no longer
// enough: it would be wrong whenever the fallback draws.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every FlutterMap in lib/ draws a map credit', () {
    final credit = RegExp(r'MiniMapCredit\(|BasemapCredit\(|AttributionLine\(');
    final missing = <String>[];
    var maps = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      if (!src.contains('FlutterMap(')) continue;
      maps++;
      if (!credit.hasMatch(src)) missing.add(f.path);
    }
    expect(maps, greaterThan(5), reason: 'the scan found the maps');
    expect(missing, isEmpty, reason: 'maps without a visible credit');
  });

  test('every FlutterMap that draws a basemap draws the shared one (BasemapLayer), never its own tile URL', () {
    final raster = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      if (!src.contains('FlutterMap(') || !src.contains('TileLayer(')) continue;
      // The Drive map keeps one raster TileLayer, for Topo (style.tileUrl), until M3.
      if (f.path.endsWith('coverage_map.dart') && src.contains('urlTemplate: style.tileUrl')) continue;
      raster.add(f.path);
    }
    expect(raster, isEmpty, reason: 'maps with their own raster tile layer');
  });

  test('the mini map credit follows the source drawn', () {
    final src = File('lib/ui/map/basemap_layer.dart').readAsStringSync();
    expect(src, contains('basemapSourceAt(MapCamera.of(context)).attribution'));
    expect(File('lib/ui/map/overlays/mini_map_credit.dart').readAsStringSync(), contains('typedef MiniMapCredit = BasemapCredit'));
  });
}
