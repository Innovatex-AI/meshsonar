// The Satellite basemap (M3-1): the Map Definition's imagery sources drawn as flutter_map tile layers, bottom to top (website
// `satelliteStyle`): Esri World Imagery through MeshSonar's own proxy (`/api/map/satellite/esri/{z}/{y}/{x}`, worldwide; left out
// when the server has no key: `esriAvailable` false), then USGS NAIP over it inside the contiguous US (native tiles end at z16, the
// layer is drawn up to z17), then our town and road names (vector, black flavour, labels only) over the imagery while the view is
// inside our extract. Every request goes through the same MeshTileProvider as the vector map (disk cache, request gate, circuit
// breaker, health counters). No key, header or identifier is sent to any imagery host: the Esri key lives on the server only.
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/basemap.dart' show BasemapLook;
import '../../core/map_basemaps.dart';
import '../../core/map_definition.dart';
import '../../core/map_styles.dart' show ResolvedBasemap;
import 'basemap_layer.dart';
import 'tile_source.dart';

/// The layers of the Satellite base map for [def]; empty when the definition has no usable imagery source (Satellite is then not
/// offered either, [MapBasemaps.offersSatellite]).
List<Widget> satelliteLayers(
  MapDefinition def, {
  required MeshTileProvider tiles,
  required String userAgentPackageName,
  Stream<void>? reset,
  bool wide = false,

  /// False = the imagery only: the caller draws the names itself above its own layers ([basemapLabelsLayerFor]).
  bool labels = true,
}) {
  final sat = def.satellite;
  if (sat == null) return const [];
  return [
    for (final s in sat.usable)
      TileLayer(
        key: ValueKey('satellite-${s.id}'),
        urlTemplate: s.tiles,
        userAgentPackageName: userAgentPackageName,
        tileDimension: s.tileSize,
        minNativeZoom: s.minZoom,
        maxNativeZoom: s.maxZoom,
        maxZoom: (s.layerMaxZoom ?? 22).toDouble(),
        tileBounds: LatLngBounds(LatLng(s.bounds[1], s.bounds[0]), LatLng(s.bounds[3], s.bounds[2])),
        tileProvider: tiles,
        reset: reset,
        tileDisplay: const TileDisplay.fadeIn(duration: Duration(milliseconds: 150)),
        keepBuffer: wide ? 4 : 1,
        panBuffer: wide ? 1 : 0,
      ),
    if (labels && sat.labels) BasemapLayer(key: const ValueKey('satellite-labels'), dark: true, look: BasemapLook.labels, tiles: tiles, reset: reset),
  ];
}

/// The bottom layers of a map for a resolved base map choice (`BaseMapStyle.resolve`, build 77): one vector layer, or Satellite's
/// imagery (with its names over it unless [resolved] asks for them as a separate pass). Put the coverage layers after these and
/// [basemapLabelsLayerFor] after the coverage.
List<Widget> basemapLayersFor(
  ResolvedBasemap resolved,
  MapDefinition def, {
  required MeshTileProvider tiles,
  required String userAgentPackageName,
  Stream<void>? reset,
  bool wide = false,
}) {
  final base = resolved.base;
  if (base == null) {
    return satelliteLayers(def, tiles: tiles, userAgentPackageName: userAgentPackageName, reset: reset, wide: wide, labels: resolved.labels == null);
  }
  return [BasemapLayer(key: ValueKey('basemap-${resolved.choice.id}'), dark: resolved.dark, look: base, tiles: tiles, reset: reset)];
}

/// The names pass to draw ABOVE the coverage for [resolved]; null when the names are already in the base layer (coverage off)
/// or Satellite's definition has no names. It draws nothing while the map is on the OpenFreeMap fallback (whose base layer
/// carries its own names) or outside our extract. Keys: 'satellite-labels' over imagery (as before), else 'basemap-labels'.
Widget? basemapLabelsLayerFor(ResolvedBasemap resolved, MapDefinition def, {MeshTileProvider? tiles, Stream<void>? reset}) {
  final look = resolved.labels;
  if (look == null) return null;
  if (resolved.isSatellite && def.satellite?.labels != true) return null;
  return BasemapLayer(
    key: ValueKey(resolved.isSatellite ? 'satellite-labels' : 'basemap-labels'),
    dark: resolved.dark,
    look: look,
    tiles: tiles,
    reset: reset,
  );
}

/// The credit the map must show while Satellite draws: the usable imagery sources' own lines, plus the OpenStreetMap / Protomaps line
/// when our names are drawn over them.
String satelliteCredit(MapDefinition def) {
  final sat = def.satellite;
  if (sat == null) return '';
  final imagery = {for (final s in sat.sources) ...s.attribution}; // an Esri line is not shown when Esri is not drawn
  final lines = [...sat.credits, if (sat.labels) ...def.basemapCredits('satellite').where((a) => !imagery.contains(a))];
  return lines.join(' · ');
}
