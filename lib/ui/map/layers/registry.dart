// The layer registry: every layer the app's map can draw, in paint order, with ids that match the website's
// coverage-page `?show=` keys where the website has the same layer (measured, repeaters, observers, network) and
// app-only ids for the drive's own layers. Design: stream-1-maps.md section 4.1 (table).
//
// Website layers deliberately NOT ported (planner/GIS, shelved or token-gated there): model, reach, sites, candidates,
// population, gaps, hillshade. `model`/`reach` links still parse (core/map_view_state.dart) and are ignored here.
import '../../../core/map_prefs.dart' show LayerPrefs;
import '../../../core/map_view_state.dart' show MapViewState, kAppOnlyShowKeys, kWebsiteShowKeys;
import 'map_layer.dart';
import 'repeater_map_source.dart';

const List<MapLayerSpec> kMapLayers = [
  MapLayerSpec(id: 'measured', label: 'Network coverage', group: LayerGroup.coverage, z: 10, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'hexes', label: 'Your coverage', group: LayerGroup.drive, z: 20, defaultOn: true, onWebsite: false, serverFed: false),
  // `network` (56,889 points) is OFF by default for a driver (Drive plan 7.1, D11 revised): region repeaters (122 positioned in
  // CMH) and the ones heard this drive stay on. Scoped to the viewed region when one is known, grouped clusters with counts for
  // the whole world otherwise (AppStateRepeaterFeed).
  MapLayerSpec(id: kNetworkLayerId, label: 'All MeshCore repeaters', group: LayerGroup.repeaters, z: 30, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: kRosterLayerId, label: 'Region repeaters', group: LayerGroup.repeaters, z: 40, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'observers', label: 'Observers', group: LayerGroup.repeaters, z: 45, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'links', label: 'Lines to repeaters', group: LayerGroup.drive, z: 50, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'heard', label: 'Heard this drive', group: LayerGroup.repeaters, z: 60, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'pings', label: 'Pings', group: LayerGroup.drive, z: 70, defaultOn: true, onWebsite: false, serverFed: false),
  // Repeater names beside the markers (Andy, Oct 30 2026): app-only, on by default.
  MapLayerSpec(id: kLabelsLayerId, label: 'Repeater names', group: LayerGroup.display, z: 75, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'rings', label: 'Range rings', group: LayerGroup.display, z: 80, defaultOn: true, onWebsite: false, serverFed: false),
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

/// The default state: every `defaultOn` layer on (the drive layers, measured coverage, region and heard repeaters, names and
/// rings; NOT the 56,889-point `network` layer or observers); modes measured=snr, pings=snr.
final MapLayerState kDefaultLayerState = MapLayerState(
  on: Set.unmodifiable({for (final l in kMapLayers) if (l.defaultOn) l.id}),
  mode: const {'measured': 'snr', 'pings': 'snr'},
);

/// Pings colour modes the registry knows.
const Set<String> kPingModes = {'snr', 'result'};

/// The state [p] remembers on top of the defaults (Drive plan 7.2). Unknown ids and modes (a file from a newer or older build)
/// are ignored. [labelsFallback] is the old `Settings.mapRepeaterLabels` value, used while the person has not chosen here.
MapLayerState layerStateFromPrefs(LayerPrefs p, {MapLayerState? defaults, bool? labelsFallback}) {
  final d = defaults ?? kDefaultLayerState;
  final on = {...d.on};
  if (labelsFallback != null && !p.toggles.containsKey(kLabelsLayerId)) labelsFallback ? on.add(kLabelsLayerId) : on.remove(kLabelsLayerId);
  for (final e in p.toggles.entries) {
    if (!kMapLayerIds.contains(e.key)) continue;
    e.value ? on.add(e.key) : on.remove(e.key);
  }
  final mode = {...d.mode};
  final pings = p.modes['pings'];
  if (pings != null && kPingModes.contains(pings)) mode['pings'] = pings;
  return MapLayerState(on: Set.unmodifiable(on), mode: Map.unmodifiable(mode));
}

/// The state a map link asks for (null `show` = the defaults).
MapLayerState layerStateForLink(MapViewState link, {MapLayerState? defaults, bool appLink = false}) {
  final d = defaults ?? kDefaultLayerState;
  var s = MapLayerState.fromShow(link.show, defaults: d, known: kMapLayerIds, appLink: appLink);
  if (link.color != null) s = s.withMode('measured', link.color!);
  return s;
}

/// What the measured-coverage and observers layers need to say about themselves. The repeater layers
/// report through [RepeaterMapSource.statusOf].
class MapLayerInputs {
  /// Measured coverage (`public-coverage`).
  final MapFeedState coverageState;
  final int coverageCells;

  /// When the saved copy of the measured coverage was fetched, when that copy (not a live answer) is what is on screen.
  final DateTime? coverageSavedAt;

  /// The viewed region's observers (`region-observers`): how many there are and how many have a public position.
  final MapFeedState observersState;
  final int observersWithPosition;

  /// The viewed region's display name, null when none.
  final String? regionName;

  const MapLayerInputs({
    this.coverageState = MapFeedState.idle,
    this.coverageCells = 0,
    this.coverageSavedAt,
    this.observersState = MapFeedState.idle,
    this.observersWithPosition = 0,
    this.regionName,
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
        staleNote: inputs.coverageSavedAt == null ? null : 'Saved copy from ${_monthDay(inputs.coverageSavedAt!.toLocal())}',
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
    default:
      return const LayerStatus(LayerAvailability.ready);
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _monthDay(DateTime d) => '${_months[d.month - 1]} ${d.day}';

LayerStatus _feedStatus(MapFeedState s, int count, {required String Function(int) what, required String none, String? staleNote}) {
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
          : LayerStatus(LayerAvailability.stale, detail: '${what(count)} · ${staleNote ?? 'Offline copy'}', canRetry: true);
  }
}

/// Sanity: the registry's website ids are exactly the website keys the app draws (asserted by tests).
const Set<String> kWebsiteKeysDrawn = {'measured', 'repeaters', 'observers', 'network'};

/// App-only ids, the same list the URL code writes in `meshsonar://` links.
const List<String> kAppOnlyIds = kAppOnlyShowKeys;

/// Website ids the app parses but does not draw.
final Set<String> kWebsiteKeysNotDrawn = kWebsiteShowKeys.toSet().difference(kWebsiteKeysDrawn);
