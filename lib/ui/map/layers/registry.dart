// The layer registry: every layer the app's map can draw, in paint order, with ids that match the website's
// coverage-page `?show=` keys where the website has the same layer (measured, repeaters, observers, network) and
// app-only ids for the drive's own layers. Design: stream-1-maps.md section 4.1 (table).
//
// Website layers deliberately NOT ported (planner/GIS, shelved or token-gated there): model, reach, sites, candidates,
// population, gaps, hillshade. `model`/`reach` links still parse (core/map_view_state.dart) and are ignored here.
import '../../../core/map_view_state.dart' show MapViewState, kAppOnlyShowKeys, kWebsiteShowKeys;
import 'map_layer.dart';
import 'repeater_map_source.dart';

const List<MapLayerSpec> kMapLayers = [
  MapLayerSpec(id: 'measured', label: 'Network coverage', group: LayerGroup.coverage, z: 10, defaultOn: true, onWebsite: true, serverFed: true),
  // The regions next to the viewed one: dashed outlines and names, tap to switch (the website's "Regions" layer). Default on, shown at region zoom.
  MapLayerSpec(id: kRegionsLayerId, label: 'Neighbouring regions', group: LayerGroup.coverage, z: 15, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'hexes', label: 'Drive hexagons', group: LayerGroup.drive, z: 20, defaultOn: true, onWebsite: false, serverFed: false),
  // Default ON (Andy, Oct 24 2026; D3): scoped to the viewed region when one is detected or picked, grouped clusters
  // with counts for the whole world otherwise (AppStateRepeaterFeed).
  MapLayerSpec(id: kNetworkLayerId, label: 'All MeshCore repeaters', group: LayerGroup.network, z: 30, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: kRosterLayerId, label: 'Region repeaters', group: LayerGroup.network, z: 40, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'observers', label: 'Observers', group: LayerGroup.network, z: 45, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'links', label: 'Links to repeaters', group: LayerGroup.drive, z: 50, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'neighbours', label: 'Neighbours of the selected repeater', group: LayerGroup.network, z: 55, defaultOn: false, onWebsite: false, serverFed: true),
  MapLayerSpec(id: 'heard', label: 'Repeaters heard', group: LayerGroup.drive, z: 60, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'pings', label: 'Pings', group: LayerGroup.drive, z: 70, defaultOn: true, onWebsite: false, serverFed: false),
  // Repeater names beside the markers (Andy, Oct 30 2026): app-only, on by default, persisted in Settings.mapRepeaterLabels.
  MapLayerSpec(id: kLabelsLayerId, label: 'Repeater names', group: LayerGroup.network, z: 75, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'rings', label: 'Range rings', group: LayerGroup.context, z: 80, defaultOn: true, onWebsite: false, serverFed: false),
];

/// Every registry id.
final Set<String> kMapLayerIds = {for (final l in kMapLayers) l.id};

/// The spec for [id], or null.
MapLayerSpec? layerSpec(String id) {
  for (final l in kMapLayers) {
    if (l.id == id) return l;
  }
  return null;
}

/// The layers each sheet section lists, in paint order.
Map<LayerGroup, List<MapLayerSpec>> layersByGroup() => {
  for (final g in LayerGroup.values) g: [for (final l in kMapLayers) if (l.group == g) l],
};

/// The default state: every `defaultOn` layer on (the drive layers, measured coverage and the global repeater layer);
/// modes measured=snr, pings=snr.
final MapLayerState kDefaultLayerState = MapLayerState(
  on: Set.unmodifiable({for (final l in kMapLayers) if (l.defaultOn) l.id}),
  mode: const {'measured': 'snr', 'pings': 'snr'},
);

/// The state a map link asks for (null `show` = the defaults).
MapLayerState layerStateForLink(MapViewState link, {MapLayerState? defaults, bool appLink = false}) {
  final d = defaults ?? kDefaultLayerState;
  var s = MapLayerState.fromShow(link.show, defaults: d, known: kMapLayerIds, appLink: appLink);
  if (link.color != null) s = s.withMode('measured', link.color!);
  return s;
}

/// What the measured-coverage, observers and neighbours layers need to say about themselves. The repeater layers
/// report through [RepeaterMapSource.statusOf].
class MapLayerInputs {
  /// Measured coverage (`public-coverage`).
  final MapFeedState coverageState;
  final int coverageCells;

  /// The viewed region's observers (`region-observers`): how many there are and how many have a public position.
  final MapFeedState observersState;
  final int observersWithPosition;

  /// The viewed region's display name, null when none.
  final String? regionName;

  /// A repeater is selected (the neighbours layer draws its links only).
  final bool repeaterSelected;

  /// The regions list is on the phone (cache or fetch) and how many neighbouring regions the viewed one has.
  final bool regionIndexLoaded;
  final int regionNeighbours;

  const MapLayerInputs({
    this.coverageState = MapFeedState.idle,
    this.coverageCells = 0,
    this.observersState = MapFeedState.idle,
    this.observersWithPosition = 0,
    this.regionName,
    this.repeaterSelected = false,
    this.regionIndexLoaded = false,
    this.regionNeighbours = 0,
  });
}

/// Status of every layer. Drive layers are always [LayerAvailability.ready] (they draw what this phone recorded, which
/// may be nothing yet).
LayerStatus layerStatus(String id, MapLayerInputs inputs, {RepeaterMapSource? repeaters}) {
  switch (id) {
    case kNetworkLayerId:
    case kRosterLayerId:
      if (repeaters == null) return const LayerStatus(LayerAvailability.loading, detail: 'Loading repeaters…');
      return repeaters.statusOf(id);
    case 'measured':
      return _feedStatus(
        inputs.coverageState,
        inputs.coverageCells,
        what: (n) => '$n ${n == 1 ? 'cell' : 'cells'} measured',
        none: 'Nothing measured here yet',
      );
    case 'observers':
      if (inputs.regionName == null) {
        return const LayerStatus(LayerAvailability.empty, detail: 'Pick a region to see its observers');
      }
      return _feedStatus(
        inputs.observersState,
        inputs.observersWithPosition,
        what: (n) => '$n ${n == 1 ? 'observer' : 'observers'} with a public position',
        none: 'No observers with a public position in ${inputs.regionName}',
      );
    case kRegionsLayerId:
      if (!inputs.regionIndexLoaded) return const LayerStatus(LayerAvailability.empty, detail: 'Region outlines load once the phone is online');
      if (inputs.regionName == null || inputs.regionNeighbours == 0) {
        return LayerStatus(LayerAvailability.empty, detail: inputs.regionName == null ? 'Pick a region to see its neighbours' : 'No neighbouring regions known for ${inputs.regionName}');
      }
      return LayerStatus(LayerAvailability.ready, detail: '${inputs.regionNeighbours} nearby · shown zoomed out to region level');
    case 'neighbours':
      return inputs.repeaterSelected
          ? const LayerStatus(LayerAvailability.ready)
          : const LayerStatus(LayerAvailability.empty, detail: 'Tap a region repeater first');
    default:
      return const LayerStatus(LayerAvailability.ready);
  }
}

LayerStatus _feedStatus(MapFeedState s, int count, {required String Function(int) what, required String none}) {
  switch (s) {
    case MapFeedState.unsupported:
      return const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet');
    case MapFeedState.idle:
    case MapFeedState.loading:
      return const LayerStatus(LayerAvailability.loading, detail: 'Loading…');
    case MapFeedState.failed:
      return const LayerStatus(LayerAvailability.failed, detail: "Couldn't load. Check the connection and retry.", canRetry: true);
    case MapFeedState.ready:
      return count == 0 ? LayerStatus(LayerAvailability.empty, detail: none) : LayerStatus(LayerAvailability.ready, detail: what(count));
    case MapFeedState.stale:
      return count == 0
          ? LayerStatus(LayerAvailability.empty, detail: none)
          : LayerStatus(LayerAvailability.stale, detail: '${what(count)} · Offline copy', canRetry: true);
  }
}

/// Sanity: the registry's website ids are exactly the website keys the app draws (asserted by tests).
const Set<String> kWebsiteKeysDrawn = {'measured', 'repeaters', 'observers', 'regions', 'network'};

/// App-only ids, the same list the URL code writes in `meshsonar://` links.
const List<String> kAppOnlyIds = kAppOnlyShowKeys;

/// Website ids the app parses but does not draw.
final Set<String> kWebsiteKeysNotDrawn = kWebsiteShowKeys.toSet().difference(kWebsiteKeysDrawn);
