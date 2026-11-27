// The nodes and their names on the Live map (MAP slice 2 and 3, plan 4.2, 4.3 and section 7; build 77 Round 1 F1). The region's
// repeaters and room servers are drawn by the Drive map's repeater painter (the same sprites, rings = how recently heard, one
// atlas draw): a node can be tapped and opens the same repeater panel as on Drive, idle nodes cluster, and "Colour nodes by"
// tints them. Idle nodes are dimmed to 62 % so the packets stay the picture; a node a packet is crossing now is a full-strength
// badge (never hidden in a cluster) and is named from zoom 9, the rule "relaying in Live" of the label spec. Where the nodes come
// from: `GET /v1/nodes` (the `nodes` layer), never the Live stream's own context.
import 'package:flutter/material.dart';

import '../../../core/map_definition.dart' show MapDefinition;
import '../../../core/map_definition_pages.dart';
import '../../../core/map_prefs.dart';
import '../../../core/map_styles.dart' show BaseMapStyle;
import '../../../core/v1/nodes_api.dart' show NodeRow;
import '../../drive_detail_map.dart' show driveDetailLayerState;
import '../../map/active_map_definition.dart';
import '../../map/layers/map_layer.dart' show MapLayerState;
import '../../../core/repeater_points.dart' show MapRepeaterRow;
import '../../map/layers/map_layer.dart' show MapHit, RepeaterHit;
import '../../map/layers/repeater_map_source.dart';
import '../../map/layers/repeater_name_labels.dart';
import '../../map/layers/repeater_painter_layer.dart' show RepeaterBadge, RepeaterPainterLayer;
import '../../map/layers/repeater_sprites.dart' show RepeaterFreshness, freshnessOfAge;
import '../../map/map_size_controls.dart' show colourByNow;
import '../../map/node_symbol.dart' show nodeTintArgb;

/// What the Live page's Layers sheet starts with: the definition's `live` page preset (repeaters, names, region borders) when it
/// has one, else what build 74 drew (the nodes and their names, nothing else). The person's own choices sit on top (page `live`).
MapLayerState liveDefaultLayerState([MapDefinition? def]) {
  final d = def ?? ActiveMapDefinition.current;
  final fromPreset = d.hasPages ? driveDetailLayerState(d, page: 'live') : null;
  return fromPreset ?? MapLayerState(on: Set.unmodifiable({kRosterLayerId, kLabelsLayerId}), mode: const {'pings': 'snr'});
}

/// The registry layers the Live map draws: the nodes (Repeaters, with Names under it), with a preset the region border, and
/// Measured coverage as an opt-in layer, off by default (build 77, Round 1 decision 4; each tab keeps its own switches).
const Set<String> kLiveDrawnLayerIds = {kRosterLayerId, kLabelsLayerId, 'borders', 'measured'};

/// Tests: how many times the node markers rebuilt (the layer must not rebuild per packet).
@visibleForTesting
int liveNodeMarkerBuilds = 0;

/// The Live nodes that can be drawn: repeaters and room servers with a position.
List<NodeRow> liveDrawableNodes(Iterable<NodeRow> rows) => [
  for (final r in rows)
    if (r.position != null && (r.role == 'repeater' || r.role == 'room') && r.position!.lat.abs() <= 90 && r.position!.lon.abs() <= 180) r,
];

/// The symbol-set freshness id of a node: heard in 24 h solid, 7 d dashed, older none.
String liveNodeFreshness(NodeRow r, DateTime now) => switch (freshnessOfAge(r.lastHeardAt ?? r.lastAdvertAt, now)) {
  RepeaterFreshness.fresh => 'fresh',
  RepeaterFreshness.recent => 'recent',
  RepeaterFreshness.stale => 'stale',
};

/// The tint id of [r] under "Colour nodes by" [variable] (`status`, `hash`, `role`), or null for neutral.
String? liveNodeTint(NodeRow r, String variable) => switch (variable) {
  'status' => r.status,
  'role' => r.role,
  'hash' => r.hashSize == null ? 'unknown' : (r.hashSize! >= 2 ? 'multi' : 'one'),
  _ => null,
};

/// The Live nodes as the repeater painter's rows: the `network` list of [liveNodeSource] (band = advert age, so the ring is how
/// recently each was heard).
List<MapRepeaterRow> liveNodeRows(List<NodeRow> nodes) => [
  for (final r in liveDrawableNodes(nodes))
    MapRepeaterRow(
      key: r.key.toLowerCase(),
      name: r.label,
      lat: r.position!.lat,
      lon: r.position!.lon,
      isRoom: r.role == 'room',
      lastSeen: r.lastHeardAt ?? r.lastAdvertAt,
    ),
];

/// The painter source of the Live nodes (build 77, Round 1 F1): `GET /v1/nodes` as the `network` list of a [RepeaterMapSource],
/// so Live's repeaters are drawn by the Drive map's painter: tappable, clustered when idle, one atlas draw.
class LiveNodeSource {
  final StaticRepeaterMapFeed feed = StaticRepeaterMapFeed();
  late final RepeaterMapSource source = RepeaterMapSource(feed);
  Map<String, NodeRow> _byKey = const {};

  void setNodes(List<NodeRow> nodes) {
    _byKey = {for (final r in liveDrawableNodes(nodes)) r.key.toLowerCase(): r};
    feed.global = MapRepeaterSet(rows: liveNodeRows(nodes), state: MapFeedState.ready);
  }

  NodeRow? row(String key) => _byKey[key.toLowerCase()];
  Iterable<NodeRow> get rows => _byKey.values;

  void dispose() {
    source.dispose();
    feed.dispose();
  }
}

/// The two flutter_map children that draw the nodes and their names: the repeater painter (idle nodes dimmed to 62 % and
/// clustered; a node a packet is crossing is a full-strength badge, never inside a cluster), then the names above it. A tap
/// goes to [onHit], the map's own resolver: the same repeater panel as on Drive.
List<Widget> liveNodeLayers({
  required LiveNodeSource nodes,
  required Set<String> inUse,
  required BaseMapStyle style,
  required Brightness brightness,
  required ValueChanged<MapHit> onHit,
  bool showNames = true,
  DateTime? now,
}) {
  final rows = nodes.rows.toList();
  if (rows.isEmpty) return const [];
  final tone = labelToneFor(style, brightness);
  final at = now ?? DateTime.now();
  // The nodes in use left the clustered list (the host sets `claimedKeys` when the set changes) and are badges on top.
  final source = nodes.source;
  final badges = [
    for (final k in inUse)
      if (nodes.row(k) case final r?)
        RepeaterBadge(
          key: k,
          name: r.label,
          lat: r.position!.lat,
          lon: r.position!.lon,
          isRoom: r.role == 'room',
          freshness: freshnessOfAge(r.lastHeardAt ?? r.lastAdvertAt, at),
          lastSeen: r.lastHeardAt ?? r.lastAdvertAt,
        ),
  ];
  final dark = brightness == Brightness.dark;
  void badgeTap(RepeaterBadge b) => onHit(RepeaterHit(RepeaterPoint(
        layerId: kNetworkLayerId,
        source: RepeaterPointSource.global,
        key: b.key,
        name: b.name,
        isRoom: b.isRoom,
        lat: b.lat,
        lon: b.lon,
        band: 0,
        lastSeen: b.lastSeen,
      )));
  return [
    KeyedSubtree(
      key: const Key('live-nodes-markers'),
      child: Builder(builder: (context) {
        liveNodeMarkerBuilds++;
        return ListenableBuilder(
          listenable: MapPrefs.shared,
          builder: (context, _) {
            final variable = colourByNow();
            return RepeaterPainterLayer(
              sources: [(source, kNetworkLayerId)],
              badges: badges,
              // Dim, so the packets stay the picture (the site's Live nodes are at 0.5); a node a packet is crossing is solid.
              sourceOpacity: 0.62,
              tintOf: variable == 'none' ? null : (k) => nodeTintArgb(variable, nodes.row(k) == null ? null : liveNodeTint(nodes.row(k)!, variable), dark: dark),
              onHit: onHit,
              onBadgeTap: badgeTap,
            );
          },
        );
      }),
    ),
    RepeaterNameLabels(
      key: const Key('live-nodes-names'),
      sources: [(source, kNetworkLayerId)],
      showNames: showNames,
      pill: tone.pill,
      darkMap: tone.dark,
      badges: [for (final b in badges) RepeaterBadge(key: b.key, name: b.name, lat: b.lat, lon: b.lon, isRoom: b.isRoom, freshness: b.freshness, heard: true, lastSeen: b.lastSeen)],
    ),
  ];
}
