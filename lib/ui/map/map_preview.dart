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
// The person's layer choices (lib/core/map_prefs.dart): a preview is kept under a page id ([layerPage]: `detail` for the
// detail pages, `plan` for the planner's small maps). A coverage layer the person switched off there (or, with no choice
// there, on the Drive map) is not drawn, even if the page asks for it; a preview never adds a layer the page did not ask for.
// [planOverlay] draws the `plan` layer (layers/plan_layer.dart) on top, unless the page's choice switched it off.
//
// MAP slice 5 (app half, build 74): [page] names a Map Definition page preset (`path`, `node`, `observer`, ...; lib/core/
// map_definition_pages.dart). With a preset in the active definition the preset decides which coverage layers and whether the
// region border the still map draws (it replaces the caller's [coverage] set), and [MapPreview.stillHeight] gives its height from
// `pages.mapHeights`. Without [page], or when the definition has no `pages` / no such preset (MapDefinition.bundled, a version 1
// answer), the map draws exactly what build 73 drew: the caller's [coverage] set.
//
// Build 75: a page preset that lists `repeaters` / `observers` draws them (node symbols) from the nodes the caller passes in
// [MapPreview.repeaters] / [MapPreview.observers]: the region's already-loaded list; no list, nothing drawn, nothing fetched.
//
// Build 77 (Round 1 N6): every small map matches the main map. It follows the base map the person chose (Road, Light, Dark, Topo,
// Satellite; one vector layer, names inside: BaseMapStyle.resolve(..., labelsAbove: false)), on the style's own background (no
// navy flash before the tiles), with the one credit pill, one mini legend ("Weak → strong") whenever it draws coverage, and one
// of two standard heights ([MapPreview.compactHeight], [MapPreview.tallHeight]). "Open the map" opens the map of the tab you
// are in: Network > Live on a Network page, the Plan map on the Plan tab, else the Drive map.
//
// Keys: the map keeps the caller's [mapKey]; 'map-preview-open' is the Open button; 'map-preview-legend' the mini legend.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/basemap.dart' show BasemapSource;
import '../../core/coverage_v2.dart' show CoverageTileLayer;
import '../../core/map_styles.dart';
import '../../core/map_definition_pages.dart';
import '../../core/map_definition_v2.dart';
import '../../core/map_prefs.dart';

import '../app.dart' show AppScope;
import '../design/app_symbols.dart';
import '../shell/shell_controller.dart';
import '../theme.dart';
import 'active_map_definition.dart';
import 'basemap_layer.dart';
import 'coverage_bands.dart';
import 'coverage_tiles_layer.dart';
import 'layers/plan_layer.dart' show planLayerWidgets;
import 'layers/region_borders_layer.dart' show RegionBordersLayer, regionBorderRings;
import 'layers/plan_overlay.dart' show PlanOverlayController;
import 'layers/registry.dart' show definitionLayerIds, kHeardCellsLayerId, kPlanLayerId;
import 'coverage_map.dart' show CoverageMap;
import 'main_map_focus.dart';
import 'satellite_layers.dart' show basemapLayersFor;
import '../network/live/live_map_focus.dart';
import 'overlays/mini_map_credit.dart';
import 'still/still_nodes.dart';

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

  /// A Map Definition page preset id (`path`, `node`, `observer`); null = no preset, the caller's [coverage] decides.
  final String? page;

  /// The page's own drawing, on top of the definition layers.
  final List<Widget> overlays;

  /// MAP slice 5 (build 75): the region's already-loaded repeaters / observers, drawn with the node symbols when the page preset lists
  /// the `repeaters` / `observers` layer and the person has not switched it off. Null or empty = nothing drawn (a preview has no
  /// node feed of its own, and nothing is fetched for it).
  final List<StillNode>? repeaters, observers;

  /// Definition coverage layers to draw (a subset of [kPreviewCoverage]); empty = basemap only (pages that draw their own cells).
  final Set<String> coverage;

  /// Draw the basemap (the Map tiles setting); false = the map background only.
  final bool tiles;

  /// A basemap layer to draw instead of the default one (another style: Light, Dark, Topo).
  final Widget? basemap;

  /// Where "Open the map" goes; null = no button.
  final LatLng? openAt;
  final double? openZoom;

  /// The page id the person's layer choices are read under ([kDetailLayerPage] or [kPlanLayerPage]).
  final String layerPage;

  /// The remembered choices; null = [MapPrefs.shared].
  final MapPrefs? prefs;

  /// The plan to draw on top (the `plan` layer); null = none.
  final PlanOverlayController? planOverlay;

  final void Function(TapPosition, LatLng)? onTap;
  final void Function(MapCamera, bool)? onPositionChanged;
  final VoidCallback? onMapReady;

  const MapPreview({
    super.key,
    this.mapKey,
    this.page,
    this.controller,
    this.center,
    this.zoom = 13,
    this.fit,
    this.minZoom = 2,
    this.maxZoom = 18,
    this.interaction = MapPreviewInteraction.none,
    this.overlays = const [],
    this.repeaters,
    this.observers,
    this.coverage = const {},
    this.tiles = true,
    this.basemap,
    this.openAt,
    this.openZoom,
    this.layerPage = kDetailLayerPage,
    this.prefs,
    this.planOverlay,
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

  /// The preset of [page] in the active definition; null when there is no [page], no `pages` or no such preset.
  MapPagePreset? get preset => presetOf(page);

  /// The preset of page [id] in the active definition, or null (the caller keeps its build 73 drawing).
  static MapPagePreset? presetOf(String? id) {
    if (id == null) return null;
    final d = ActiveMapDefinition.current;
    return d.hasPages ? d.pagePreset(id) : null;
  }

  /// Height of the still map of page [id]: the preset's `height` word in `pages.mapHeights` (`tall` is a share of the screen),
  /// else [fallback] (what the caller used in build 73, or the definition says nothing).
  static double stillHeight(BuildContext context, String? id, {required double fallback}) {
    final preset = presetOf(id);
    final word = preset?.height;
    if (word == null) return fallback;
    final d = ActiveMapDefinition.current;
    if (word == 'tall') {
      final t = d.tallMapHeight;
      if (t == null) return fallback;
      return (MediaQuery.sizeOf(context).height * t.share).clamp(t.minPx, t.maxPx).toDouble();
    }
    return d.stillMapHeight(word) ?? fallback;
  }

  /// Whether the page's preset shows node names; null = it does not say (or there is no preset).
  static bool? presetNames(String? id) => presetOf(id)?.names;

  /// The coverage layers this preview draws: the page preset's (when there is one) else what the caller asks for, less what the
  /// person switched off.
  Set<String> effectiveCoverage(MapPrefs p) {
    final pr = preset;
    final asked = pr == null
        ? coverage
        : {
            for (final id in kPreviewCoverage)
              if (pr.has(id == kHeardCellsLayerId ? 'heard' : id)) id,
          };
    return {
      for (final id in kPreviewCoverage)
        if (asked.contains(id) && p.previewLayerOn(layerPage, id, fallback: true)) id,
    };
  }

  List<Widget> _coverageLayers(BuildContext context, Set<String> coverage) {
    if (coverage.isEmpty) return const [];
    final s = AppScope.maybeOf(context);
    if (s == null || !s.coverageV2) return const [];
    final mc = MeshSonarColors.of(context);
    final colors = CoverageBandColors.of(mc.palette, Theme.of(context).brightness);
    final out = <Widget>[];
    final ladder = ActiveMapDefinition.current.coverageLadder;
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
      // MAP slice 1: the summary picture under the same layer's res-11 tiles (a preview shows a whole region too).
      if (ladder != null && layer.summary != null) {
        out.add(
          CoverageTilesLayer(
            key: Key('preview-coverage-$id-summary'),
            layer: layer.summary!,
            store: s.coverageTiles,
            meta: s.coverageMeta,
            colors: colors,
            ladder: ladder,
          ),
        );
      }
      out.add(
        CoverageTilesLayer(
          key: Key('preview-coverage-$id'),
          layer: layer,
          store: s.coverageTiles,
          meta: s.coverageMeta,
          colors: colors,
          faintBelow: s.coverageMeta.faintBelow,
          ladder: ladder,
        ),
      );
    }
    return out;
  }

  /// The region border (the preset has `borders`): the viewed region's outline in the definition's border symbol.
  List<Widget> _borders(BuildContext context) {
    final rings = regionBorderRings(AppScope.maybeOf(context)?.viewingRegion);
    if (rings.isEmpty) return const [];
    return [RegionBordersLayer(key: const Key('preview-region-borders'), rings: rings)];
  }

  /// The `repeaters` then `observers` layers of the page preset, from the nodes the caller passed (none = nothing).
  List<Widget> _nodeLayers(MapPrefs p) {
    final pr = preset;
    if (pr == null) return const [];
    return [
      if (repeaters != null && repeaters!.isNotEmpty && pr.has('repeaters') && p.previewLayerOn(layerPage, 'repeaters', fallback: true))
        StillNodesLayer(key: const Key('preview-repeaters'), nodes: repeaters!),
      if (observers != null && observers!.isNotEmpty && pr.has('observers') && p.previewLayerOn(layerPage, 'observers', fallback: true))
        StillNodesLayer(key: const Key('preview-observers'), nodes: observers!),
    ];
  }

  /// The two standard heights of a small map (Round 1 N6): a card or list row, and a detail page's map.
  static const double compactHeight = 180;
  static const double tallHeight = 260;

  /// "Open the map": the map of the tab the person is in (Round 1 N6): Network > Live from a Network page, the Plan map from the
  /// Plan tab, the Drive map from anywhere else (Drive, Chat, More).
  void _open(BuildContext context) {
    final at = openAt;
    if (at == null) return;
    final shell = ShellScope.maybeOf(context);
    final z = openZoom ?? zoom;
    switch (shell?.tab) {
      case AppTab.network:
        LiveMapFocus.request(at, z);
        Navigator.of(context).popUntil((r) => r.isFirst);
        shell!.openNetwork(const NetworkRequest(section: NetworkSection.live));
      case AppTab.plan:
        MainMapFocus.request(at, z, target: 'plan');
        Navigator.of(context).popUntil((r) => r.isFirst);
      case _:
        MainMapFocus.request(at, z);
        if (shell == null) return;
        shell.select(AppTab.drive);
        Navigator.of(context).popUntil((r) => r.isFirst);
    }
  }

  /// The base map the person chose (Settings / Layers), resolved for a small map: one layer, names inside.
  static ResolvedBasemap resolvedFor(BuildContext context, {required bool coverageOn}) {
    final s = AppScope.maybeOf(context);
    final choice = BaseMapStyle.effective(BaseMapStyle.parse(s?.settings.baseMapStyle), ActiveMapDefinition.current);
    return BaseMapStyle.resolve(choice, appDark: Theme.of(context).brightness == Brightness.dark, coverageOn: coverageOn, labelsAbove: false);
  }

  @override
  Widget build(BuildContext context) {
    final p = prefs ?? MapPrefs.shared;
    return ListenableBuilder(listenable: p, builder: (context, _) => _build(context, p));
  }

  Widget _build(BuildContext context, MapPrefs p) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final cov = effectiveCoverage(p);
    final covLayers = _coverageLayers(context, cov);
    final r = resolvedFor(context, coverageOn: covLayers.isNotEmpty);
    // The style's own background (the main map's): no navy flash before the tiles; Satellite and no tiles keep the theme's.
    final bg = tiles && basemap == null && r.base != null ? (basemapBackgroundColor(BasemapSource.ours, dark: r.dark, look: r.base!) ?? mc.mapBackground) : mc.mapBackground;
    final map = FlutterMap(
      key: mapKey,
      mapController: controller,
      options: MapOptions(
        initialCenter: center ?? const LatLng(0, 0),
        initialZoom: zoom,
        initialCameraFit: fit,
        minZoom: minZoom,
        maxZoom: maxZoom,
        backgroundColor: bg,
        interactionOptions: InteractionOptions(flags: _flags),
        onTap: interaction == MapPreviewInteraction.edit ? onTap : null,
        onPositionChanged: onPositionChanged,
        onMapReady: onMapReady,
      ),
      children: [
        if (basemap != null)
          basemap!
        else if (tiles)
          ...basemapLayersFor(r, ActiveMapDefinition.current, tiles: BasemapLayer.sharedTiles, userAgentPackageName: CoverageMap.userAgentPackageName),
        ...covLayers,
        if (preset?.has('borders') == true) ..._borders(context),
        ..._nodeLayers(p),
        ...overlays,
        if (planOverlay case final plan? when p.previewLayerOn(layerPage, kPlanLayerId, fallback: true)) ...planLayerWidgets(plan),
        MiniMapCredit(style: basemap == null ? r.choice : BaseMapStyle.chart),
        // The one mini legend whenever coverage is drawn (Round 1 N6), in the main map's wording.
        if (covLayers.isNotEmpty) const MiniMapLegend(),
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

/// The small maps' legend (Round 1 N6): the band ramp and "Weak → strong", top-left, not tappable. The main map's chip wording.
class MiniMapLegend extends StatelessWidget {
  const MiniMapLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bands = CoverageBandColors.of(MeshSonarColors.of(context).palette, t.brightness);
    return Align(
      alignment: Alignment.topLeft,
      child: IgnorePointer(
        child: Container(
          key: const Key('map-preview-legend'),
          margin: const EdgeInsets.all(6),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: t.colorScheme.surface.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(12), border: Border.all(color: t.colorScheme.outlineVariant)),
          child: Semantics(
            label: 'Legend: weak to strong signal',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final b in const [1, 2, 3, 4, 5]) ExcludeSemantics(child: Padding(padding: const EdgeInsets.only(right: 2), child: Container(width: 9, height: 9, color: bands[b]))),
              const SizedBox(width: 4),
              ExcludeSemantics(child: Text('Weak → strong', style: t.textTheme.labelSmall)),
            ]),
          ),
        ),
      ),
    );
  }
}
