// The layer registry: every layer the app's map can draw, in paint order, with ids that match the website's
// coverage-page `?show=` keys where the website has the same layer (measured, repeaters, observers, network) and
// app-only ids for the drive's own layers. Design: stream-1-maps.md section 4.1 (table).
//
// Website layers deliberately NOT ported (planner/GIS, shelved or token-gated there): model, reach, sites, candidates,
// population, gaps, hillshade. `model`/`reach` links still parse (core/map_view_state.dart) and are ignored here.
import '../../../core/map_basemaps.dart' show capLayerEstimated, capLayerRedundancy, capLayerSnrLinks;
import '../../../core/map_definition.dart' show MapDefinition, MapGroupDef;
import '../../../core/map_prefs.dart' show LayerPrefs;
import '../active_map_definition.dart';
import '../../../core/map_view_state.dart' show MapViewState, kAppOnlyShowKeys, kHeardCellsLayerId, kWebsiteShowKeys;
export '../../../core/map_view_state.dart' show kHeardCellsLayerId;
import 'map_layer.dart';
import 'repeater_map_source.dart';

// The layers are the Map Definition's (plan unified-map-system §2.4, phase M2): ids, names, groups, defaults and the paint
// order come from `layers[]` ([definitionLayerIds], [layerLabel], [defaultLayerState]). The app keeps four layers of its own
// that belong to its drive panel (the definition's panel-only `drive` layer): This drive (`hexes`) with its Ping dots, the
// highlight of repeaters heard this drive (`heard`) and repeater Names. The [kMapLayers] z values only break ties for those;
// the map paints in the definition's order (coverage_map.dart `_paintOrder`).
const List<MapLayerSpec> kMapLayers = [
  MapLayerSpec(id: 'borders', label: 'Region borders', group: LayerGroup.context, z: 2, defaultOn: true, onWebsite: true, serverFed: false),
  MapLayerSpec(id: 'predicted', label: 'Predicted coverage', group: LayerGroup.coverage, z: 5, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: kHeardCellsLayerId, label: 'Heard by phones', group: LayerGroup.coverage, z: 7, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'measured', label: 'Measured coverage', group: LayerGroup.coverage, z: 10, defaultOn: true, onWebsite: true, serverFed: true),
  // M3-2 (Map Definition `layer.redundancy`): per res-11 cell, how many distinct repeaters were measured there. Off by default.
  MapLayerSpec(id: 'redundancy', label: 'Redundancy', group: LayerGroup.coverage, z: 12, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'hexes', label: 'This drive', group: LayerGroup.coverage, z: 20, defaultOn: true, onWebsite: false, serverFed: false),
  // M3-2 (`layer.snrlinks`): repeater-to-repeater lines coloured by SNR, width by packets. Off by default.
  MapLayerSpec(id: 'snrlinks', label: 'Links by SNR', group: LayerGroup.network, z: 24, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'links', label: 'Link lines', group: LayerGroup.network, z: 25, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: kNetworkLayerId, label: 'All MeshCore repeaters', group: LayerGroup.network, z: 30, defaultOn: false, onWebsite: true, serverFed: true),
  MapLayerSpec(id: kRosterLayerId, label: 'Repeaters', group: LayerGroup.network, z: 40, defaultOn: true, onWebsite: true, serverFed: true),
  // M3-2 (`layer.estimated`): repeaters with no GPS placed from their located neighbours, paler = less sure. On by default.
  MapLayerSpec(id: 'estimated', label: 'Estimated positions', group: LayerGroup.network, z: 42, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'observers', label: 'Observers', group: LayerGroup.network, z: 45, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'phones', label: 'Moving phones', group: LayerGroup.network, z: 47, defaultOn: true, onWebsite: true, serverFed: true),
  MapLayerSpec(id: 'heard', label: 'Heard this drive', group: LayerGroup.network, z: 60, defaultOn: true, onWebsite: false, serverFed: false),
  MapLayerSpec(id: 'pings', label: 'Ping dots', group: LayerGroup.coverage, z: 70, defaultOn: true, onWebsite: false, serverFed: false),
  // Repeater names beside the markers (Andy, Oct 30 2026): a sub-switch under Repeaters (the definition's label rule: from z14
  // with collision; the switch lets a driver turn them off).
  MapLayerSpec(id: kLabelsLayerId, label: 'Names', group: LayerGroup.network, z: 75, defaultOn: true, onWebsite: false, serverFed: false),
];

/// The app id of a definition layer id (the definition's `heard` is the app's `heardcells`, its `drive` the app's `hexes`;
/// `live` has no map layer in the app yet: null).
String? appLayerId(String defId) => switch (defId) {
  'heard' => kHeardCellsLayerId,
  'drive' => 'hexes',
  'live' => null,
  _ => kMapLayerIds.contains(defId) ? defId : null,
};

/// The definition layer id of an app id (inverse of [appLayerId]); null for the app's own drive extras.
String? definitionLayerId(String appId) => switch (appId) {
  kHeardCellsLayerId => 'heard',
  'hexes' => 'drive',
  'pings' || 'heard' || kLabelsLayerId => null,
  _ => appId,
};

/// The app ids of the definition's layers, in its drawing order (bottom to top).
List<String> definitionLayerIds(MapDefinition def) => [for (final l in def.layerDefs) ?appLayerId(l.id)];

/// The layer's name: the definition's, else the app's own label.
String layerLabel(String appId, [MapDefinition? def]) {
  final d = def ?? ActiveMapDefinition.current;
  final defId = definitionLayerId(appId);
  return (defId == null ? null : d.layerDef(defId)?.name) ?? layerSpec(appId)?.label ?? appId;
}

/// One row of the layers sheet: a layer switch, or a sub-switch indented under its parent.
typedef SheetRow = ({String id, String? parent});

/// The layers sheet, group by group, from the definition (the website's Layers panel: groups in `groups` order; inside a group
/// the layers that are not panel-only, top of the map first). The app's drive panel adds This drive (the definition's
/// panel-only `drive` layer) with Ping dots under Coverage, and Names under Repeaters.
List<(MapGroupDef, List<SheetRow>)> sheetRows([MapDefinition? def]) {
  final d = def ?? ActiveMapDefinition.current;
  return [
    for (final g in d.groups)
      (
        g,
        <SheetRow>[
          for (final l in d.layerDefs.reversed)
            if (l.group == g.id && appLayerId(l.id) != null && (!l.panelOnly || l.id == 'drive') && _capabilityOf(l.id, d)) ...[
              (id: appLayerId(l.id)!, parent: null),
              if (l.id == 'drive') (id: 'pings', parent: 'hexes'),
              if (l.id == 'repeaters') (id: kLabelsLayerId, parent: kRosterLayerId),
            ],
        ],
      ),
  ];
}

/// The M3 layers are offered only while the definition advertises their capability string (a client checks it before relying on a
/// feature); every other layer needs none.
bool _capabilityOf(String defId, MapDefinition d) => switch (defId) {
  'estimated' => d.hasCapability(capLayerEstimated),
  'redundancy' => d.hasCapability(capLayerRedundancy),
  'snrlinks' => d.hasCapability(capLayerSnrLinks),
  _ => true,
};

/// The section a layer belongs to (from the definition's group; the app's extras follow their parent).
LayerGroup layerGroupOf(String appId) => layerSpec(appId)?.group ?? LayerGroup.coverage;

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
final MapLayerState kDefaultLayerState = defaultLayerState(MapDefinition.bundled);

/// The definition's defaults (`layers[].defaultOn`, panel-only layers count as on: they draw only while their panel is open)
/// plus the app's drive extras (on).
MapLayerState defaultLayerState([MapDefinition? def]) {
  final d = def ?? ActiveMapDefinition.current;
  final on = <String>{};
  for (final l in kMapLayers) {
    final defId = definitionLayerId(l.id);
    final defOn = defId == null ? null : d.layerDef(defId)?.defaultOn;
    if (defOn ?? l.defaultOn) on.add(l.id);
  }
  return MapLayerState(on: Set.unmodifiable(on), mode: const {'pings': 'snr'});
}

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
const Set<String> kWebsiteKeysDrawn = {'measured', 'predicted', 'repeaters', 'observers', 'network', kHeardCellsLayerId, 'borders', 'phones', 'redundancy', 'snrlinks', 'estimated'};

/// App-only ids, the same list the URL code writes in `meshsonar://` links.
const List<String> kAppOnlyIds = kAppOnlyShowKeys;

/// Website ids the app parses but does not draw.
final Set<String> kWebsiteKeysNotDrawn = kWebsiteShowKeys.toSet().difference(kWebsiteKeysDrawn);
