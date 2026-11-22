// The route of a Path Inspector candidate or a trace as the ONE path map's spec (MAP slice 5, app half, build 75; the website's
// path-inspector.tsx and trace-viewer.tsx). The `/v1` answers carry no hop positions (`ToolNode` is key, name and role), so each hop's
// place comes from the region's already-loaded repeater list ([StillNode]), looked up by the node's key; no network call. A hop the
// server could not name is looked up by its prefix in that list: one match is certain, several are likely (the nearest to the hop
// before it, else the first), none leaves it unplaced. A hop with no position keeps its number, is left out of the drawing and
// breaks the line; the screen lists it under the map with the style's unplaced note.
import 'package:latlong2/latlong.dart';

import '../../../core/v1/tools_api.dart' show ToolNode;
import '../../map/still/path_layer.dart' as pl;
import '../../map/still/still_nodes.dart';

/// One hop as a tool answered it: the prefix, the node the server named (null = none), and whether the server was sure of it.
class ToolHopInput {
  final String prefix;
  final ToolNode? node;
  final bool sure;
  const ToolHopInput({required this.prefix, this.node, this.sure = true});
}

/// The spec of [hops] over [nodes]. Pure.
pl.PathSpec toolPathSpec(List<ToolHopInput> hops, List<StillNode> nodes) {
  final byKey = {for (final n in nodes) n.key: n};
  final out = <pl.PathHop>[];
  LatLng? last;
  for (var i = 0; i < hops.length; i++) {
    final h = hops[i];
    final named = h.node;
    StillNode? at;
    var certain = h.sure;
    if (named != null) {
      at = byKey[named.key.toLowerCase()];
    } else {
      final p = h.prefix.toLowerCase();
      final matches = p.isEmpty ? const <StillNode>[] : [for (final n in nodes) if (n.key.startsWith(p)) n];
      if (matches.length == 1) {
        at = matches.single;
        certain = true;
      } else if (matches.length > 1) {
        at = matches.first;
        final from = last;
        if (from != null) {
          const d = Distance();
          at = matches.reduce((a, b) => d(from, a.point) <= d(from, b.point) ? a : b);
        }
        certain = false;
      }
    }
    final name = named?.name ?? at?.name ?? h.prefix;
    out.add(pl.PathHop(
      n: i + 1,
      name: name.trim().isEmpty ? h.prefix : name.trim(),
      lat: at?.lat,
      lon: at?.lon,
      certainty: certain ? pl.PathCertainty.certain : pl.PathCertainty.likely,
    ));
    if (at != null) last = at.point;
  }
  return pl.PathSpec(hops: out);
}

/// "3 · a1, 5 · c4": the hops of [spec] that are not drawn, as the list under the map says them.
String unplacedListText(pl.PathSpec spec) => [for (final h in spec.unplaced) '${h.n} · ${h.name}'].join(', ');
