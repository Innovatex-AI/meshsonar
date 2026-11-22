// The small map on a node's or an observer's page (Map Definition pages `node` and `observer`; MAP slice 5, app half): the
// page's preset decides its layers, border and height, the one place is drawn with the ONE node symbol set, and its name sits
// under it when the preset says names are on. Draws nothing of its own when the place has no position (the page says why in its
// text). Tiles are off under `flutter test`.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../theme.dart';
import '../map_preview.dart';
import '../node_symbol.dart';
import 'path_map.dart' show stillMapTiles;
import 'still_nodes.dart';

class StillPlaceMap extends StatelessWidget {
  /// `node` or `observer`.
  final String page;

  /// The node symbol role (`repeater`, `room`, `companion`, `sensor`, `observer`).
  final String role;
  final String name;
  final double lat, lon;
  final String freshness;
  final double fallbackHeight;
  final bool? tiles;

  /// The region's loaded repeaters / observers, drawn behind the place when the page preset lists those layers (null = none).
  /// [nodeKey] is the place's own node, left out of them (it is drawn above).
  final List<StillNode>? repeaters, observers;
  final String? nodeKey;
  const StillPlaceMap({
    super.key,
    required this.page,
    required this.role,
    required this.name,
    required this.lat,
    required this.lon,
    this.freshness = 'fresh',
    this.fallbackHeight = 200,
    this.tiles,
    this.repeaters,
    this.observers,
    this.nodeKey,
  });

  List<StillNode>? _without(List<StillNode>? l) {
    final own = nodeKey?.toLowerCase();
    if (l == null || own == null) return l;
    return [for (final n in l) if (n.key != own) n];
  }

  @override
  Widget build(BuildContext context) {
    final at = LatLng(lat, lon);
    final t = Theme.of(context);
    final names = MapPreview.presetNames(page) ?? false;
    return Semantics(
      container: true,
      label: 'Map of $name.',
      excludeSemantics: true,
      child: ClipRRect(
        key: Key('still-$page-map'),
        borderRadius: BorderRadius.circular(Corners.small),
        child: SizedBox(
          height: MapPreview.stillHeight(context, page, fallback: fallbackHeight),
          child: MapPreview(
            page: page,
            center: at,
            zoom: 13,
            interaction: MapPreviewInteraction.pan,
            tiles: stillMapTiles(tiles),
            repeaters: _without(repeaters),
            observers: _without(observers),
            openAt: at,
            overlays: [
              IgnorePointer(
                child: MarkerLayer(markers: [
                  Marker(
                    point: at,
                    width: 170,
                    height: 76,
                    child: Stack(alignment: Alignment.center, children: [
                      Center(child: NodeSymbol(role: role, freshness: freshness)),
                      if (names)
                        Positioned(
                          top: 52,
                          left: 0,
                          right: 0,
                          child: Text(
                            name,
                            key: const Key('still-place-name'),
                            maxLines: 1,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600, shadows: [Shadow(color: t.colorScheme.surface, blurRadius: 3)]),
                          ),
                        ),
                    ]),
                  ),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
