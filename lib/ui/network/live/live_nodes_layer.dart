// The nodes and their names on the Live map (MAP slice 2 and 3, plan 4.2, 4.3 and section 7): until build 73 the Live map drew
// packet paths over a bare chart with town names only, so a packet crossing "a repeater" showed no repeater at all. Now the region's
// repeaters and room servers are on it, as the one node symbol set (the same badges as every other map, ring = how recently
// heard, tinted only when "Colour nodes by" is on), dimmed so the packets stay the picture, and named by the one label engine
// (budget, collision, halo or pill by the basemap showing). A node a packet is crossing now is drawn at full strength and named
// from zoom 9, the rule "relaying in Live" of the label spec. Where the nodes come from: `GET /v1/nodes` (the `nodes` layer; the
// region roster when `/v1` is not live), never the Live stream's own context.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/map_definition_v2.dart';
import '../../../core/map_prefs.dart';
import '../../../core/map_styles.dart' show BaseMapStyle;
import '../../../core/v1/nodes_api.dart' show NodeRow;
import '../../map/active_map_definition.dart';
import '../../map/layers/repeater_name_labels.dart';
import '../../map/layers/repeater_painter_layer.dart' show RepeaterBadge;
import '../../map/layers/repeater_sprites.dart' show RepeaterFreshness, freshnessOfAge, spriteVariantFor;
import '../../map/map_size_controls.dart' show colourByNow;
import '../../map/node_symbol.dart';

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

/// The two flutter_map children that draw the nodes and their names: the markers, then the names above them.
List<Widget> liveNodeLayers({
  required List<NodeRow> nodes,
  required Set<String> inUse,
  required BaseMapStyle style,
  required Brightness brightness,
  bool showNames = true,
  DateTime? now,
}) {
  final rows = liveDrawableNodes(nodes);
  if (rows.isEmpty) return const [];
  final tone = labelToneFor(style, brightness);
  return [
    _LiveNodeMarkers(key: const Key('live-nodes-markers'), rows: rows, inUse: inUse, now: now),
    RepeaterNameLabels(
      key: const Key('live-nodes-names'),
      sources: const [],
      showNames: showNames,
      pill: tone.pill,
      darkMap: tone.dark,
      badges: [
        for (final r in rows)
          RepeaterBadge(
            key: r.key.toLowerCase(),
            name: r.label,
            lat: r.position!.lat,
            lon: r.position!.lon,
            isRoom: r.role == 'room',
            freshness: switch (liveNodeFreshness(r, now ?? DateTime.now())) {
              'fresh' => RepeaterFreshness.fresh,
              'recent' => RepeaterFreshness.recent,
              _ => RepeaterFreshness.stale,
            },
            heard: inUse.contains(r.key.toLowerCase()),
            lastSeen: r.lastHeardAt ?? r.lastAdvertAt,
          ),
      ],
    ),
  ];
}

class _LiveNodeMarkers extends StatelessWidget {
  final List<NodeRow> rows;
  final Set<String> inUse;
  final DateTime? now;
  const _LiveNodeMarkers({super.key, required this.rows, required this.inUse, this.now});

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final spec = ActiveMapDefinition.current.labelSpec;
    // Below the spec's first name zoom a whole region of badges is a smear: only the ones in use are drawn.
    final far = camera.zoom < spec.minZoom;
    final at = now ?? DateTime.now();
    return ListenableBuilder(
      listenable: MapPrefs.shared,
      builder: (context, _) {
        final variable = colourByNow();
        final size = spriteVariantFor(camera.zoom).diameter * MapPrefs.shared.iconScale;
        return MarkerLayer(
          markers: [
            for (final r in rows)
              if (!far || inUse.contains(r.key.toLowerCase()))
                Marker(
                  point: LatLng(r.position!.lat, r.position!.lon),
                  width: size + 8,
                  height: size + 8,
                  child: IgnorePointer(
                    child: Center(
                      child: NodeSymbol(
                        key: ValueKey('live-node-${r.key.toLowerCase()}'),
                        role: r.role,
                        freshness: liveNodeFreshness(r, at),
                        tint: liveNodeTint(r, variable),
                        tintVariable: variable,
                        size: size,
                        // Dim, so the packets stay the picture (the site's Live nodes are at 0.5); a node a packet is crossing is solid.
                        opacity: inUse.contains(r.key.toLowerCase()) ? 1 : 0.62,
                      ),
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}
