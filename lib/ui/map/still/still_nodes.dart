// The repeaters (and observers) a small map can draw behind its own drawing (MAP slice 5, app half, build 75): the Map Definition
// page presets `path`, `node` and `observer` list the `repeaters` / `observers` layers, but a preview has no node feed of its own.
// A caller that already holds the region's loaded node list passes it ([StillNode]); nothing is fetched here and nothing is drawn
// when none is passed. Every node is drawn with the ONE node symbol set ([NodeSymbol]). A region has thousands of rows, so only
// those inside the camera are drawn and at most [kStillNodesCap] of them (the ones nearest the centre).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../app.dart' show AppScope;
import '../node_symbol.dart';

/// One node a small map may draw: its key (lower-case hex), name, role (`repeater`, `room`, `observer`), place and last-heard time.
class StillNode {
  final String key;
  final String? name;
  final String role;
  final double lat, lon;
  final DateTime? lastSeen;
  const StillNode({required this.key, required this.lat, required this.lon, this.name, this.role = 'repeater', this.lastSeen});

  LatLng get point => LatLng(lat, lon);

  /// The name, or the first 8 key characters.
  String get label => (name ?? '').trim().isEmpty ? (key.length > 8 ? key.substring(0, 8) : key) : name!.trim();
}

/// At most this many nodes are drawn behind a small map.
const int kStillNodesCap = 150;

/// The viewed region's loaded repeater list as [StillNode]s, or null when none is loaded or [regionSlug] is not the region the
/// app is viewing (a roster of another region would put the wrong nodes on the map). No network call.
List<StillNode>? stillRepeatersOf(BuildContext context, {required String? regionSlug}) {
  if (regionSlug == null || regionSlug.isEmpty) return null;
  final s = AppScope.maybeOf(context);
  if (s == null) return null;
  final viewing = s.viewingRegion?.slug;
  if (viewing == null || viewing.toLowerCase() != regionSlug.toLowerCase()) return null;
  final rows = s.regionRepeaterSet.rows;
  if (rows.isEmpty) return null;
  return [
    for (final r in rows)
      StillNode(key: r.key.toLowerCase(), name: r.name, role: r.isRoom ? 'room' : 'repeater', lat: r.lat, lon: r.lon, lastSeen: r.lastAdvert),
  ];
}

/// `fresh` (heard in the last day), `recent` (the last week) or `stale`; an unknown time reads `stale`.
String stillFreshness(DateTime? at, DateTime now) {
  if (at == null) return 'stale';
  final age = now.difference(at);
  if (age <= const Duration(days: 1)) return 'fresh';
  if (age <= const Duration(days: 7)) return 'recent';
  return 'stale';
}

/// The nodes of [all] inside [bounds] (the whole list when null), the [cap] nearest [centre] first. Pure.
List<StillNode> stillNodesInView(List<StillNode> all, {LatLngBounds? bounds, LatLng? centre, int cap = kStillNodesCap}) {
  final inside = [
    for (final n in all)
      if (n.lat.isFinite && n.lon.isFinite && (bounds == null || bounds.contains(n.point))) n,
  ];
  if (inside.length <= cap) return inside;
  if (centre != null) {
    const d = Distance();
    inside.sort((a, b) => d(centre, a.point).compareTo(d(centre, b.point)));
  }
  return inside.take(cap).toList();
}

/// The repeaters / observers of a small map: one node symbol each, under the page's own drawing.
class StillNodesLayer extends StatelessWidget {
  final List<StillNode> nodes;

  /// Test seam: null = the clock.
  final DateTime? now;
  const StillNodesLayer({super.key, required this.nodes, this.now});

  @override
  Widget build(BuildContext context) {
    final cam = MapCamera.maybeOf(context);
    final shown = stillNodesInView(nodes, bounds: cam?.visibleBounds, centre: cam?.center);
    if (shown.isEmpty) return const SizedBox.shrink();
    final t = now ?? DateTime.now();
    return IgnorePointer(
      child: MarkerLayer(
        markers: [
          for (final n in shown)
            Marker(
              point: n.point,
              width: 22,
              height: 22,
              child: Center(child: NodeSymbol(key: Key('still-node-${n.key}'), role: n.role, freshness: stillFreshness(n.lastSeen, t), size: 16, scaled: false)),
            ),
        ],
      ),
    );
  }
}
