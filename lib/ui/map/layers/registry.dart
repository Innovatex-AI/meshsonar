// The layer registry: every layer the app's map can draw, in paint order, with ids that match the website's
// coverage-page `?show=` keys where the website has the same layer (measured, repeaters, observers, network) and
// app-only ids for the drive's own layers. Design: stream-1-maps.md section 4.1 (table).
//
// Website layers deliberately NOT ported (planner/GIS, shelved or token-gated there): model, reach, sites, candidates,
// population, gaps, hillshade. `model`/`reach` links still parse (core/map_view_state.dart) and are ignored here.
import '../../../core/map_prefs.dart' show LayerPrefs;
import '../../../core/map_view_state.dart' show MapViewState, kAppOnlyShowKeys, kHeardCellsLayerId, kWebsiteShowKeys;
export '../../../core/map_view_state.dart' show kHeardCellsLayerId;
import 'map_layer.dart';
import 'repeater_map_source.dart';

// Coverage redesign (plan coverage-redesign-plan-2026-11-08.md section 5, Nov 8 2026): two sections, Coverage (Measured
// coverage, Predicted coverage, This drive + its Ping dots) and Network (one Repeaters switch with a This region / All
// MeshCore scope and a Names sub-switch, Observers, Lines to repeaters). Range rings, the colour-by modes and the detail /
// hexagon-size chips are gone. The order here is the PAINT order (predicted under measured, D8); the sheet's own row order
// is [kSheetRows].
const List<MapLayerSpec> kMapLayers = [
  MapLayerSpec(id: 'predicted', label: 'Predicted coverage', group: LayerGroup.coverage, z: 5, defaultOn: true, onWebsite: true, serverFed: true),
  // Heard (no ping), phone observer contract section 8.5: passive evidence, its own layer, painted between the two.
  MapLayerSpec(id: kHeardCellsLayerId, label: 'Heard by phones', group: LayerGroup.coverage, z: 7, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'measured', label: 'Measured coverage', group: LayerGroup.coverage, z: 10, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'hexes', label: 'This drive', group: LayerGroup.coverage, z: 20, defaultOn: true, onWebsite: false, serverFed: false),
  // The Repeaters switch is these three ids together: `repeaters` (the viewed region's roster, scope This region) or `network`
  // (every MeshCore repeater with a public position, scope All MeshCore), plus `heard` (the ones this drive reached, lit).
  MapLayerSpec(id: kNetworkLayerId, label: 'All MeshCore repeaters', group: LayerGroup.network, z: 30, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: kRosterLayerId, label: 'Repeaters', group: LayerGroup.network, z: 40, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'observers', label: 'Observers', group: LayerGroup.network, z: 45, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'links', label: 'Lines to repeaters', group: LayerGroup.network, z: 50, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'heard', label: 'Heard this drive', group: LayerGroup.network, z: 60, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'pings', label: 'Ping dots', group: LayerGroup.coverage, z: 70, defaultOn: true, onWebsite: false, serverFed: false),
  // Repeater names beside the markers (Andy, Oct 30 2026): the Repeaters switch's "Names" sub-switch.
  MapLayerSpec(id: kLabelsLayerId, label: 'Names', group: LayerGroup.network, z: 75, defaultOn: true, onWebsite: false, serverFed: false),
];

/// One row of the layers sheet: a layer switch, or a sub-switch indented under its parent.
typedef SheetRow = ({String id, String? parent});

/// The layers sheet, section by section, in the plan's order (sub-switches under their parent). The Repeaters row stands for
/// `repeaters` + `network` + `heard` ([repeatersOn]).
const Map<LayerGroup, List<SheetRow>> kSheetRows = {
  LayerGroup.coverage: [
    (id: 'measured', parent: null),
    (id: 'predicted', parent: null),
    (id: kHeardCellsLayerId, parent: null),
    (id: 'hexes', parent: null),
    (id: 'pings', parent: 'hexes'),
  ],
  LayerGroup.network: [
    (id: kRosterLayerId, parent: null),
    (id: kLabelsLayerId, parent: kRosterLayerId),
    (id: 'observers', parent: null),
    (id: 'links', parent: null),
  ],
};

/// The Repeaters switch is on (either scope).
bool repeatersOn(MapLayerState s) => s.isOn(kRosterLayerId) || s.isOn(kNetworkLayerId);

/// The Repeaters scope: All MeshCore (true) or This region (false).
bool repeatersAllScope(MapLayerState s) => s.isOn(kNetworkLayerId) || (!s.isOn(kRosterLayerId) && s.modeOf(kRosterLayerId) == 'all');

/// Turns the Repeaters switch on (in the remembered scope) or off (both scopes and the heard highlight).
MapLayerState withRepeaters(MapLayerState s, bool on) {
  if (!on) return s.toggle(kRosterLayerId, false).toggle(kNetworkLayerId, false).toggle('heard', false);
  final all = repeatersAllScope(s);
  return s.toggle(all ? kNetworkLayerId : kRosterLayerId, true).toggle(all ? kRosterLayerId : kNetworkLayerId, false).toggle('heard', true);
}

/// Picks the Repeaters scope (remembered as the roster layer's mode, so it survives the switch being off).
MapLayerState withRepeaterScope(MapLayerState s, {required bool all}) {
  var n = s.withMode(kRosterLayerId, all ? 'all' : 'region');
  if (repeatersOn(s)) n = n.toggle(kNetworkLayerId, all).toggle(kRosterLayerId, !all);
  return n;
}

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

/// The default state: every `defaultOn` layer on (both coverage layers, this drive and its ping dots, region and heard
/// repeaters with names, lines; NOT the 56,889-point `network` scope or observers); pings coloured by SNR.
final MapLayerState kDefaultLayerState = MapLayerState(
  on: Set.unmodifiable({for (final l in kMapLayers) if (l.defaultOn) l.id}),
  mode: const {'pings': 'snr'},
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
  final scope = p.modes[kRosterLayerId];
  if (scope == 'all' || scope == 'region') mode[kRosterLayerId] = scope!;
  return MapLayerState(on: Set.unmodifiable(on), mode: Map.unmodifiable(mode));
}

/// The state a map link asks for (null `show` = the defaults).
MapLayerState layerStateForLink(MapViewState link, {MapLayerState? defaults, bool appLink = false}) {
  final d = defaults ?? kDefaultLayerState;
  // A link's `color=` (the removed colour-by modes) is ignored: coverage has one colour metric now (plan D9).
  return MapLayerState.fromShow(link.show, defaults: d, known: kMapLayerIds, appLink: appLink);
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

  /// Coverage v2 is on for this server, the tiles could not be read (offline), and the timeline / window / source filter looks
  /// at the past (tiles have no time filter, so measured is drawn from the saved cells and predicted is hidden then).
  final bool coverageV2;

  /// The server has the Heard (no ping) layer (`capabilities.coverageHeard`).
  final bool coverageHeard;
  final bool tilesOffline;
  final bool coverageFiltered;

  const MapLayerInputs({
    this.coverageV2 = false,
    this.coverageHeard = false,
    this.tilesOffline = false,
    this.coverageFiltered = false,
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
    case 'predicted':
      if (!inputs.coverageV2) return const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet');
      if (inputs.tilesOffline) {
        return const LayerStatus(LayerAvailability.failed, detail: "Couldn't load. Check the connection and retry.", canRetry: true);
      }
      if (inputs.coverageFiltered) return const LayerStatus(LayerAvailability.ready, detail: 'Hidden while looking back: the estimate is for today');
      return const LayerStatus(LayerAvailability.ready, detail: 'Estimated from nearby measured cells');
    case kHeardCellsLayerId:
      if (!inputs.coverageHeard) return const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet');
      if (inputs.tilesOffline) {
        return const LayerStatus(LayerAvailability.failed, detail: "Couldn't load. Check the connection and retry.", canRetry: true);
      }
      return const LayerStatus(LayerAvailability.ready, detail: 'Where a phone heard a repeater without pinging (not a measurement)');
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
const Set<String> kWebsiteKeysDrawn = {'measured', 'predicted', 'repeaters', 'observers', 'network', kHeardCellsLayerId};

/// App-only ids, the same list the URL code writes in `meshsonar://` links.
const List<String> kAppOnlyIds = kAppOnlyShowKeys;

/// Website ids the app parses but does not draw.
final Set<String> kWebsiteKeysNotDrawn = kWebsiteShowKeys.toSet().difference(kWebsiteKeysDrawn);
