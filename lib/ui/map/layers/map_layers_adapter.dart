// Bridge between today's fixed `MapLayers` bool bag (lib/ui/map/map_layers.dart, used by DriveMapModel, the
// fullscreen layers sheet and CoverageMap) and the registry's [MapLayerState], so callers can migrate one at a time
// (stream-1-maps.md 4.1: kept for one release). Id renames: MapLayers.repeaters (heard beacons) -> `heard`,
// MapLayers.regionRepeaters -> `repeaters` (the website's key), MapLayers.networkCoverage -> `measured`.
import '../map_layers.dart';
import 'map_layer.dart';

extension MapLayersToState on MapLayers {
  MapLayerState toLayerState({Map<String, String> mode = const {}}) => MapLayerState(
    on: Set.unmodifiable({
      if (networkCoverage) 'measured',
      if (hexes) 'hexes',
      if (regionRepeaters) 'repeaters',
      if (links) 'links',
      if (repeaters) 'heard',
      if (pings) 'pings',
      if (rings) 'rings',
    }),
    mode: Map.unmodifiable({...mode, 'pings': pingColors == PingColorMode.result ? 'result' : 'snr'}),
  );
}

/// The `MapLayers` for [s]. Layers MapLayers has no field for (network, observers, neighbours) are not represented.
MapLayers mapLayersFromState(MapLayerState s) => MapLayers(
  pings: s.isOn('pings'),
  hexes: s.isOn('hexes'),
  pingColors: s.modeOf('pings') == 'result' ? PingColorMode.result : PingColorMode.snr,
  repeaters: s.isOn('heard'),
  links: s.isOn('links'),
  rings: s.isOn('rings'),
  networkCoverage: s.isOn('measured'),
  regionRepeaters: s.isOn('repeaters'),
);
