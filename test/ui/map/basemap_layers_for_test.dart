// Build 77 (F2 style side): the layer helpers a map uses to draw a resolved base map choice in two passes, the base under the
// coverage and the names above it (ui/map/satellite_layers.dart basemapLayersFor / basemapLabelsLayerFor).
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/ui/map/basemap_layer.dart';
import 'package:meshsonar/ui/map/satellite_layers.dart';
import 'package:meshsonar/ui/map/tile_source.dart';

import 'tile_source_test.dart' show MemCache;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final def = MapDefinition.bundled;
  late MeshTileProvider tiles;
  setUp(() => tiles = MeshTileProvider(client: http.Client(), cache: MemCache(), gate: TileFetchGate(), stats: MapTileStats()));

  List<Widget> base(ResolvedBasemap r) => basemapLayersFor(r, def, tiles: tiles, userAgentPackageName: 'test');

  test('coverage off: one vector layer with the names inside, no names pass (Road, Light, Dark, Topo)', () {
    for (final s in [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark, BaseMapStyle.topo]) {
      final r = BaseMapStyle.resolve(s, appDark: true, coverageOn: false);
      final layers = base(r);
      expect(layers, hasLength(1), reason: s.id);
      final l = layers.single as BasemapLayer;
      expect((l.look, l.dark, l.key), (s.look, r.dark, ValueKey('basemap-${s.id}')), reason: s.id);
      expect(basemapLabelsLayerFor(r, def, tiles: tiles), isNull, reason: s.id);
    }
  });

  test('coverage on: the base has no names and the names pass is a second layer for above the coverage', () {
    for (final (s, baseLook, namesLook) in [
      (BaseMapStyle.chart, BasemapLook.dataBase, BasemapLook.dataLabels),
      (BaseMapStyle.street, BasemapLook.dataBase, BasemapLook.dataLabels),
      (BaseMapStyle.dark, BasemapLook.dataBase, BasemapLook.dataLabels),
      (BaseMapStyle.topo, BasemapLook.topoBase, BasemapLook.topoLabels),
    ]) {
      final r = BaseMapStyle.resolve(s, appDark: false, coverageOn: true);
      final l = base(r).single as BasemapLayer;
      expect((l.look, l.dark), (baseLook, r.dark), reason: s.id);
      final names = basemapLabelsLayerFor(r, def, tiles: tiles)! as BasemapLayer;
      expect((names.look, names.dark, names.key), (namesLook, r.dark, const ValueKey('basemap-labels')), reason: s.id);
      expect(identical(names.tiles, tiles), isTrue, reason: 'the same loader: one disk cache, one request gate');
    }
  });

  test('Satellite: imagery with its names over it when coverage is off; imagery only plus the names pass when it is on', () {
    final off = BaseMapStyle.resolve(BaseMapStyle.satellite, appDark: false, coverageOn: false);
    final offLayers = base(off);
    expect(offLayers.whereType<TileLayer>(), hasLength(2), reason: 'Esri then NAIP');
    expect(offLayers.whereType<BasemapLayer>().single.look, BasemapLook.labels);
    expect(basemapLabelsLayerFor(off, def, tiles: tiles), isNull);

    final on = BaseMapStyle.resolve(BaseMapStyle.satellite, appDark: false, coverageOn: true);
    final onLayers = base(on);
    expect(onLayers.whereType<TileLayer>(), hasLength(2));
    expect(onLayers.whereType<BasemapLayer>(), isEmpty, reason: 'the names are not drawn twice');
    final names = basemapLabelsLayerFor(on, def, tiles: tiles)! as BasemapLayer;
    expect((names.look, names.dark, names.key), (BasemapLook.labels, true, const ValueKey('satellite-labels')));
  });

  test('satelliteLayers keeps its build 76 behaviour by default (names included)', () {
    final layers = satelliteLayers(def, tiles: tiles, userAgentPackageName: 'test');
    expect(layers.last, isA<BasemapLayer>());
    expect(satelliteLayers(def, tiles: tiles, userAgentPackageName: 'test', labels: false).whereType<BasemapLayer>(), isEmpty);
  });
}
