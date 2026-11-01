// The map's layer vocabulary: layer specs (id, label, group, paint order), each layer's availability with an honest
// reason, the on/off + mode state that round-trips through the website's `?show=` list, and what a tap hit.
// Design: stream-1-maps.md section 4.1. The renderer for each layer is attached by the host at integration (WP-M2);
// this file holds no drawing code and reads no app state.
import 'package:flutter/foundation.dart';

import '../../../core/cluster_index.dart' show ClusterTap;
import '../../../core/map_view_state.dart' show kAppOnlyShowKeys, kWebsiteShowKeys;
import '../../../core/network_coverage.dart' show NetworkCell;
import '../../../core/region_overview_api.dart' show RegionObserver;
import 'repeater_map_source.dart' show RepeaterPoint;

/// The registry id of the neighbouring-regions layer (also the website's `?show=` key).
const String kRegionsLayerId = 'regions';

/// Sections of the layers sheet, in this order.
enum LayerGroup { drive, coverage, network, context }

extension LayerGroupLabel on LayerGroup {
  String get label => switch (this) {
    LayerGroup.drive => 'This drive',
    LayerGroup.coverage => 'Coverage',
    LayerGroup.network => 'Network',
    LayerGroup.context => 'Around you',
  };
}

/// One layer the map can draw.
@immutable
class MapLayerSpec {
  /// The website's `?show=` key where the website has the same layer; otherwise an app-only key.
  final String id;
  final String label;
  final LayerGroup group;

  /// Paint order, low first (strictly increasing over the registry).
  final int z;
  final bool defaultOn;

  /// The website draws this layer under the same key.
  final bool onWebsite;

  /// The data comes from the server (so it can be loading, missing on this server, failed or empty); false for layers
  /// drawn from what this phone recorded.
  final bool serverFed;

  const MapLayerSpec({
    required this.id,
    required this.label,
    required this.group,
    required this.z,
    required this.defaultOn,
    required this.onWebsite,
    required this.serverFed,
  });

  @override
  String toString() => 'MapLayerSpec($id)';
}

enum LayerAvailability {
  /// Data present and drawable.
  ready,

  /// First load in progress, nothing stored yet.
  loading,

  /// Loaded, nothing to draw.
  empty,

  /// The server does not offer this data (404 from its endpoint).
  unsupported,

  /// The last load failed and nothing is stored.
  failed,

  /// Stored copy shown; the last refresh failed (offline).
  stale,
}

/// What the layers sheet shows for one layer: whether its switch works, and the line under it.
@immutable
class LayerStatus {
  final LayerAvailability availability;

  /// Text under the switch (count, source, reason it is off). Null = nothing to add.
  final String? detail;

  /// The host should offer Retry next to [detail].
  final bool canRetry;

  const LayerStatus(this.availability, {this.detail, this.canRetry = false});

  /// The switch can be turned on. Unsupported or empty layers are shown disabled with the reason, never hidden.
  bool get enabled => availability != LayerAvailability.unsupported && availability != LayerAvailability.empty;

  @override
  bool operator ==(Object other) =>
      other is LayerStatus && other.availability == availability && other.detail == detail && other.canRetry == canRetry;
  @override
  int get hashCode => Object.hash(availability, detail, canRetry);
  @override
  String toString() => 'LayerStatus(${availability.name}, $detail)';
}

/// Which layers are on, plus per-layer modes (`{'measured': 'noise'}`, `{'pings': 'result'}`).
@immutable
class MapLayerState {
  final Set<String> on;
  final Map<String, String> mode;
  const MapLayerState({this.on = const {}, this.mode = const {}});

  bool isOn(String id) => on.contains(id);
  String? modeOf(String id) => mode[id];

  MapLayerState toggle(String id, bool value) {
    if (value == on.contains(id)) return this;
    final n = {...on};
    value ? n.add(id) : n.remove(id);
    return MapLayerState(on: Set.unmodifiable(n), mode: mode);
  }

  MapLayerState withMode(String id, String m) {
    if (mode[id] == m) return this;
    return MapLayerState(on: on, mode: Map.unmodifiable({...mode, id: m}));
  }

  /// The `show=` value: website keys in the website's order, then the app's own (only when [web] is false).
  String toShow({bool web = true}) => [
    for (final k in kWebsiteShowKeys)
      if (on.contains(k)) k,
    if (!web)
      for (final k in kAppOnlyShowKeys)
        if (on.contains(k)) k,
  ].join(',');

  /// The state for a link's `show` list. Null [show] (the link did not say) gives [defaults]. Website-only layers the
  /// app does not draw (`model`, `reach`) are ignored. Layers that `show` cannot express for the web (app-only drive
  /// layers) keep their [defaults] value unless the link is an app link that lists app keys ([appLink]).
  static MapLayerState fromShow(List<String>? show, {required MapLayerState defaults, required Set<String> known, bool appLink = false}) {
    if (show == null) return defaults;
    final listed = show.where(known.contains).toSet();
    final n = <String>{};
    for (final id in known) {
      final expressible = kWebsiteShowKeys.contains(id) || (appLink && kAppOnlyShowKeys.contains(id));
      if (expressible ? listed.contains(id) : defaults.on.contains(id)) n.add(id);
    }
    return MapLayerState(on: Set.unmodifiable(n), mode: defaults.mode);
  }

  @override
  bool operator ==(Object other) =>
      other is MapLayerState && setEquals(other.on, on) && mapEquals(other.mode, mode);
  @override
  int get hashCode => Object.hash(Object.hashAllUnordered(on), Object.hashAllUnordered(mode.entries.map((e) => '${e.key}=${e.value}')));
  @override
  String toString() => 'MapLayerState(on: ${on.toList()..sort()}, mode: $mode)';
}

/// What a tap on the map hit. Hosts walk visible layers top-down (by descending z); the first hit wins.
sealed class MapHit {
  const MapHit();
}

/// A measured-coverage cell (opens the existing cell sheet).
final class CellHit extends MapHit {
  final NetworkCell cell;
  const CellHit(this.cell);
}

/// One repeater (global or roster layer).
final class RepeaterHit extends MapHit {
  final RepeaterPoint point;
  const RepeaterHit(this.point);
}

/// A cluster on a clustered layer: zoom to its members, or list them when they all sit on one spot.
final class ClusterHit extends MapHit {
  final String layerId;
  final ClusterTap tap;

  /// The members when they are co-located (a stack of repeaters on one tower); empty otherwise.
  final List<RepeaterPoint> colocated;
  const ClusterHit(this.layerId, this.tap, {this.colocated = const []});
}

/// An observer of the viewed region (opens the observer sheet). Only observers whose owner made the position public
/// are drawn (the server sends `lat`/`lon` per the observer's `location_public`; otherwise null).
final class ObserverHit extends MapHit {
  final RegionObserver observer;

  /// The region the observer belongs to (display name), for the sheet's source line.
  final String? regionName;
  const ObserverHit(this.observer, {this.regionName});
}
