// A small, still map of one path (page `path`, plus the `node` and `observer` pages' one-place maps): the Map Definition's
// preset decides the layers and the height, [PathLayer] draws the numbered, named route, and the camera frames it
// (fit-selection). The map is hidden from screen readers; [semanticLabel] says what it shows and the page lists the same facts as
// text. Callers only use these when the definition carries `symbols.path` ([activePathStyle]); otherwise they keep build 73.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../theme.dart';
import '../coverage_map.dart' show CoverageMap;
import '../map_preview.dart';
import 'path_layer.dart';
import 'still_nodes.dart';

/// Tiles on unless running under `flutter test` (the same switch the Drive map uses).
bool stillMapTiles(bool? tiles) => tiles ?? CoverageMap.tilesByDefault;

/// The camera of a still map over [pts]: framed bounds for several points, a fixed zoom for one.
({LatLng? center, CameraFit? fit}) stillCamera(List<LatLng> pts, {double padding = 36, double maxZoom = 15}) {
  if (pts.isEmpty) return (center: null, fit: null);
  if (pts.length == 1) return (center: pts.single, fit: null);
  return (center: pts.first, fit: CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: EdgeInsets.all(padding), maxZoom: maxZoom));
}

class StillPathMap extends StatelessWidget {
  final PathSpec spec;
  final MapPathStyle style;

  /// The Map Definition page preset this map belongs to (`path` for every route).
  final String page;
  final String semanticLabel;

  /// Height when the definition's preset says none.
  final double fallbackHeight;
  final bool? tiles;

  /// Drawn under the path (a "You" pin, say).
  final List<Widget> underlays;

  /// Drawn over the path.
  final List<Widget> overlays;

  /// Extra points the camera should frame.
  final List<LatLng> extraPoints;
  final MapPreviewInteraction interaction;
  final Key? mapKey;

  /// The region's loaded repeaters / observers, drawn behind the path when the `path` preset lists those layers (null = none).
  final List<StillNode>? repeaters, observers;
  const StillPathMap({
    super.key,
    this.mapKey,
    required this.spec,
    required this.style,
    this.page = 'path',
    required this.semanticLabel,
    this.fallbackHeight = 220,
    this.tiles,
    this.underlays = const [],
    this.overlays = const [],
    this.extraPoints = const [],
    this.interaction = MapPreviewInteraction.pan,
    this.repeaters,
    this.observers,
  });

  @override
  Widget build(BuildContext context) {
    final pts = [...spec.points, ...extraPoints];
    final cam = stillCamera(pts);
    return Semantics(
      container: true,
      label: semanticLabel,
      excludeSemantics: true,
      child: ClipRRect(
        key: const Key('still-path-map'),
        borderRadius: BorderRadius.circular(Corners.small),
        child: SizedBox(
          height: MapPreview.stillHeight(context, page, fallback: fallbackHeight),
          child: MapPreview(
            mapKey: mapKey,
            page: page,
            center: cam.center,
            zoom: 13,
            fit: cam.fit,
            interaction: interaction,
            repeaters: repeaters,
            observers: observers,
            tiles: stillMapTiles(tiles),
            overlays: [...underlays, PathLayer(spec: spec, style: style), ...overlays],
          ),
        ),
      ),
    );
  }
}
