// Full-screen live map: the whole screen is map, with the heard box, layer toggles, follow/recenter, a compass
// (two-finger rotate; tap the compass for north-up) and the controls you need while driving (status, Ping now,
// Stop) still in thumb reach. Works in portrait and landscape, and keeps clear of the notch and home indicator.
//
// Opened from the Drive screen's map with the DriveMapModel the Drive screen already keeps, so the GPS stream,
// the heard snapshot, the selected repeater and the layer choices are shared both ways.
//
// Keys: 'fullscreen-map' (the screen), 'fullscreen-close', 'map-layers', and the layers sheet's keys (see
// layers/layers_sheet.dart: 'layers-sheet', 'layer-pings', 'layer-color-result', 'layer-color-snr', 'layer-repeaters',
// 'layer-links', 'layer-rings', 'layer-network-coverage', 'layer-region-repeaters', 'layer-network', 'layer-observers').
import 'package:flutter/material.dart';

import '../app.dart';
import '../drive/drive_controls.dart';
import '../drive/gps_health_banner.dart';
import '../drive/drive_map_model.dart';
import '../drive/heard_box.dart';
import 'coverage_timeline_slider.dart';
import '../region/region_switch_sheet.dart' show confirmRegionSwitch;
import 'coverage_map.dart';
import 'layers/layers_sheet.dart' show showGeneratedLayersSheet;
import 'map_health_overlay.dart';
import 'map_tools.dart';
import 'region_center.dart';
import 'repeater_page_link.dart';

void openFullscreenMap(BuildContext context, DriveMapModel model) {
  Navigator.of(context).push(
    PageRouteBuilder<void>(
      settings: const RouteSettings(name: 'fullscreen-map'),
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) => FullscreenMapScreen(model: model),
      transitionsBuilder: (_, a, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
        child: ScaleTransition(scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)), child: child),
      ),
    ),
  );
}

class FullscreenMapScreen extends StatelessWidget {
  final DriveMapModel model;
  const FullscreenMapScreen({super.key = const Key('fullscreen-map'), required this.model});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final mq = MediaQuery.of(context);
    final safe = mq.padding;
    final landscape = mq.size.width > mq.size.height;
    // Bottom control panel: full width in portrait; bottom-right in landscape so the heard box keeps the left side.
    final panelWidth = landscape ? (mq.size.width * 0.5).clamp(360.0, 520.0) : mq.size.width;
    const panelHeight = 136.0;

    return Scaffold(
      backgroundColor: MeshSonarColors.of(context).mapBackground,
      body: AnimatedBuilder(
        animation: model,
        builder: (context, _) {
          final pings = model.visiblePings;
          final latest = s.recentPings.isEmpty ? null : s.recentPings.first;
          return Stack(
            children: [
              Positioned.fill(
                child: CoverageMap(
                  key: const Key('fullscreen-coverage-map'),
                  pings: pings,
                  repeaters: model.repeaters,
                  position: model.position ?? (pings.isEmpty ? idleMapPosition(s) : null),
                  puck: model.puck,
                  telemetry: model.telemetry,
                  showRings: s.driving,
                  repeaterLabel: s.repeaterLabel,
                  heard: model.heard,
                  layers: model.layers,
                  networkCells: model.visibleNetworkCells,
                  baseStyle: model.baseStyle,
                  onBoundsChanged: model.onMapBounds,
                  regionRepeaters: model.regionRepeaters,
                  repeaterSource: model.repeaterSource,
                  layerState: model.layerState,
                  observers: model.observers,
                  observersRegionName: s.viewingRegion?.name,
                  openRepeaterPage: openRepeaterPageFromMap,
                  highlightKey: model.selected,
                  onSelectRepeater: model.select,
                  simulated: model.simulated,
                  onZoomChanged: model.onMapZoom,
                  hexRes: model.coverageQuery.res,
                  labelAvoidKeys: model.fullscreenOverlayKeys,
                  fallbackCenter: viewedRegionCenter(s),
                fallbackBounds: viewedRegionBounds(s),
                  regionNeighbours: s.regionNeighbours,
                  onPickRegion: (r) => confirmRegionSwitch(context, r),
                  rotatable: true,
                  // Keep map buttons, attribution and framed repeaters clear of the control panel (bottom in
                  // portrait, bottom-right in landscape).
                  overlayPadding: EdgeInsets.fromLTRB(
                    safe.left,
                    safe.top,
                    landscape ? panelWidth : safe.right,
                    (landscape ? 0 : panelHeight) + safe.bottom,
                  ),
                ),
              ),
              Positioned(left: 0, right: 0, top: safe.top, child: GpsBannerSlot(state: s, height: model.gpsBannerHeight, compact: true)),
              // Top: heard box (left), close + layers (right), both under the GPS banner while it shows.
              ValueListenableBuilder<double>(
                valueListenable: model.gpsBannerHeight,
                builder: (context, bannerH, child) => Positioned(left: safe.left + Gap.m, top: safe.top + Gap.m + bannerH, child: child!),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    // Never negative: with the keyboard up over a short window the sum goes below zero and layout throws.
                    maxHeight: (mq.size.height - safe.top - safe.bottom - (landscape ? 2 * Gap.m : panelHeight + 2 * Gap.m)).clamp(0.0, double.infinity),
                  ),
                  child: SingleChildScrollView(
                    key: model.fullscreenOverlayKeys[0],
                    child: HeardBox(
                      heard: model.heard,
                      holdPings: s.settings.heardHoldPings,
                      here: model.position,
                      selected: model.selected,
                      onSelect: model.select,
                      driving: s.driving,
                      maxRows: landscape ? 4 : 7,
                      width: landscape ? 250 : (mq.size.width - safe.left - safe.right - 46 - 3 * Gap.m).clamp(200.0, 300.0),
                    ),
                  ),
                ),
              ),
              // Bottom-left, above the map's credit stack (the heard box owns the top-left corner).
              Positioned(
                left: safe.left + Gap.m,
                bottom: safe.bottom + (landscape ? Gap.m : panelHeight + Gap.m) + model.attributionStackHeight + 6,
                child: CoverageAsOfBadge(model: model),
              ),
              Positioned(left: safe.left + Gap.m, bottom: safe.bottom + (landscape ? Gap.m : panelHeight + Gap.m) + model.attributionStackHeight + 46, child: MapHealthOverlay(model: model)),
              ValueListenableBuilder<double>(
                valueListenable: model.gpsBannerHeight,
                builder: (context, bannerH, child) => Positioned(right: safe.right + Gap.m, top: safe.top + Gap.m + bannerH, child: child!),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: (mq.size.height - safe.top - safe.bottom - panelHeight - 2 * Gap.m - model.gpsBannerHeight.value).clamp(0.0, double.infinity)),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.topRight,
                    child: Column(
                  key: model.fullscreenOverlayKeys[1],
                  children: [
                    MapIconButton(
                      key: const Key('fullscreen-close'),
                      icon: Icons.close_fullscreen_rounded,
                      tooltip: 'Exit full screen',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(height: Gap.s),
                    MapIconButton(
                      key: const Key('map-layers'),
                      icon: Icons.layers_rounded,
                      tooltip: 'Map layers',
                      onPressed: () => showMapLayersSheet(context, model),
                    ),
                    const SizedBox(height: Gap.s),
                    MapToolColumn(model: model, keyPrefix: 'full'),
                  ],
                ),
                  ),
                ),
              ),
              if (latest != null && s.driving)
                Positioned(
                  left: 0,
                  right: landscape ? panelWidth : 0,
                  bottom: safe.bottom + (landscape ? 0 : panelHeight) + Gap.s + model.attributionStackHeight + 8,
                  child: Center(child: PingResultFlash(ping: latest, label: model.labelFor)),
                ),
              // Bottom: status + Ping now / Stop.
              Positioned(
                right: 0,
                bottom: 0,
                width: panelWidth,
                child: Container(
                  decoration: BoxDecoration(
                    color: t.colorScheme.surface.withValues(alpha: 0.95),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(Corners.card),
                      topRight: Radius.circular(landscape ? 0 : Corners.card),
                    ),
                    border: Border(top: BorderSide(color: t.colorScheme.outlineVariant)),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 16)],
                  ),
                  padding: EdgeInsets.only(bottom: safe.bottom, right: safe.right, left: landscape ? 0 : safe.left),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DriveStatusRow(state: s, padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.m, 0)),
                      // Start drive is disabled until the radio's antenna is set up; say why, here too.
                      if (s.needsAntennaSetup && !s.driving) const AntennaSetupHint(),
                      DriveActionButtons(
                        state: s,
                        compact: true,
                        padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, Gap.m),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Layer toggles (shared with the Drive screen map): the sheet generated from the layer registry
/// (layers/layers_sheet.dart).
Future<void> showMapLayersSheet(BuildContext context, DriveMapModel model) => showGeneratedLayersSheet(context, model);
