// The ONE map's previews (plan unified-map-system §2.1 "Previews", phase M2; the website's components/map/one/map-preview.tsx):
// every small map in the app is this widget, not a FlutterMap of its own. Same engine, same basemap (our tiles, OpenFreeMap
// fallback), the same Map Definition (coverage layers drawn in its order and colours, the region border symbol), the same
// credit line. Lists, charts and detail pages draw their own thing on top ([overlays]: a drive's cells, a packet path, a
// repeater's pin). "Open the map" opens the main map (the Drive tab) at that spot.
//
// Two kinds:
//   - a preview ([MapPreviewInteraction.none] / [MapPreviewInteraction.pan]): no taps of its own; [openAt] adds the Open button;
//   - a picker ([MapPreviewInteraction.edit]): the few screens that place something on the map (privacy zones, the home
//     observer, the Plan tools) keep their own taps, on the same component.
//
// Keys: the map keeps the caller's [mapKey]; 'map-preview-open' is the Open button.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/coverage_v2.dart' show CoverageTileLayer;

import '../app.dart' show AppScope;
import '../design/app_symbols.dart';
import '../shell/shell_controller.dart';
import '../theme.dart';
import 'active_map_definition.dart';
import 'basemap_layer.dart';
import 'coverage_bands.dart';
import 'coverage_tiles_layer.dart';
import 'layers/registry.dart' show definitionLayerIds, kHeardCellsLayerId;
import 'main_map_focus.dart';
import 'overlays/mini_map_credit.dart';

enum MapPreviewInteraction {
  /// A still picture of the map (lists, cards).
  none,

  /// Pinch and double-tap to zoom, no drag (inside a scrolling page: a drag scrolls the page).
  zoom,

  /// Pinch and drag to look around; no taps.
  pan,

  /// A picker: everything but rotation, and the caller's [MapPreview.onTap].
  edit,
}

/// The definition coverage layers a preview can draw under its overlays (app registry ids).
const Set<String> kPreviewCoverage = {'predicted', kHeardCellsLayerId, 'measured'};

class MapPreview extends StatelessWidget {
  final Key? mapKey;
  final MapController? controller;
  final LatLng? center;
  final double zoom;
  final CameraFit? fit;
  final double minZoom, maxZoom;
  final MapPreviewInteraction interaction;

  /// The page's own drawing, on top of the definition layers.
  final List<Widget> overlays;

  /// Definition coverage layers to draw (a subset of [kPreviewCoverage]); empty = basemap only (pages that draw their own cells).
  final Set<String> coverage;

  /// Draw the basemap (the Map tiles setting); false = the map background only.
  final bool tiles;

  /// A basemap to draw instead of the online one (an installed offline pack).
  final Widget? basemap;

  /// Where "Open the map" goes; null = no button.
  final LatLng? openAt;
  final double? openZoom;

  final void Function(TapPosition, LatLng)? onTap;
  final void Function(MapCamera, bool)? onPositionChanged;
  final VoidCallback? onMapReady;

  const MapPreview({
    super.key,
    this.mapKey,
    this.controller,
    this.center,
    this.zoom = 13,
    this.fit,
    this.minZoom = 2,
    this.maxZoom = 18,
    this.interaction = MapPreviewInteraction.none,
    this.overlays = const [],
    this.coverage = const {},
    this.tiles = true,
    this.basemap,
    this.openAt,
    this.openZoom,
    this.onTap,
    this.onPositionChanged,
    this.onMapReady,
  });

  int get _flags => switch (interaction) {
    MapPreviewInteraction.none => InteractiveFlag.none,
    MapPreviewInteraction.zoom => InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom,
    MapPreviewInteraction.pan => InteractiveFlag.pinchZoom | InteractiveFlag.drag,
    MapPreviewInteraction.edit => InteractiveFlag.all & ~InteractiveFlag.rotate,
  };

  List<Widget> _coverageLayers(BuildContext context) {
    if (coverage.isEmpty) return const [];
    final s = AppScope.maybeOf(context);
    if (s == null || !s.coverageV2) return const [];
    final mc = MeshSonarColors.of(context);
    final colors = CoverageBandColors.of(mc.palette, Theme.of(context).brightness);
    final out = <Widget>[];
    // The definition's drawing order (predicted under heard under measured).
    for (final id in definitionLayerIds(ActiveMapDefinition.current)) {
      if (!coverage.contains(id)) continue;
      final layer = switch (id) {
        'predicted' => CoverageTileLayer.predicted,
        kHeardCellsLayerId => s.coverageHeard ? CoverageTileLayer.heard : null,
        'measured' => CoverageTileLayer.measured,
        _ => null,
      };
      if (layer == null) continue;
      out.add(
        CoverageTilesLayer(
          key: Key('preview-coverage-$id'),
          layer: layer,
          store: s.coverageTiles,
          meta: s.coverageMeta,
          colors: colors,
          faintBelow: s.coverageMeta.faintBelow,
        ),
      );
    }
    return out;
  }

  void _open(BuildContext context) {
    final at = openAt;
    if (at == null) return;
    MainMapFocus.request(at, openZoom ?? zoom);
    final shell = ShellScope.maybeOf(context);
    if (shell == null) return;
    shell.select(AppTab.drive);
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final map = FlutterMap(
      key: mapKey,
      mapController: controller,
      options: MapOptions(
        initialCenter: center ?? const LatLng(0, 0),
        initialZoom: zoom,
        initialCameraFit: fit,
        minZoom: minZoom,
        maxZoom: maxZoom,
        backgroundColor: mc.mapBackground,
        interactionOptions: InteractionOptions(flags: _flags),
        onTap: interaction == MapPreviewInteraction.edit ? onTap : null,
        onPositionChanged: onPositionChanged,
        onMapReady: onMapReady,
      ),
      children: [
        if (basemap != null) basemap! else if (tiles) const BasemapLayer(),
        ..._coverageLayers(context),
        ...overlays,
        const MiniMapCredit(),
      ],
    );
    if (openAt == null) return map;
    return Stack(
      children: [
        Positioned.fill(child: map),
        Positioned(
          top: 6,
          right: 6,
          child: Semantics(
            button: true,
            label: 'Open the map here',
            child: Material(
              color: t.colorScheme.surface.withValues(alpha: 0.92),
              shape: const StadiumBorder(),
              elevation: 1,
              child: InkWell(
                key: const Key('map-preview-open'),
                customBorder: const StadiumBorder(),
                onTap: () => _open(context),
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppSymbolIcon(AppSymbols.map, size: 13, color: t.colorScheme.primary),
                        const SizedBox(width: 4),
                        Text('Open the map', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
