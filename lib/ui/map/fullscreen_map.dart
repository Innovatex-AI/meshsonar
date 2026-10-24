// Full-screen live map: the whole screen is map, with the heard box, layer toggles, follow/recenter, a compass
// (two-finger rotate; tap the compass for north-up) and the controls you need while driving (status, Ping now,
// Stop) still in thumb reach. Works in portrait and landscape, and keeps clear of the notch and home indicator.
//
// Opened from the Drive screen's map with the DriveMapModel the Drive screen already keeps, so the GPS stream,
// the heard snapshot, the selected repeater and the layer choices are shared both ways.
//
// Keys: 'fullscreen-map' (the screen), 'fullscreen-close', 'map-layers', 'layers-sheet', 'layer-pings',
// 'layer-color-result', 'layer-color-snr', 'layer-repeaters', 'layer-links', 'layer-rings',
// 'layer-network-coverage'.
import 'package:flutter/material.dart';

import '../app.dart';
import '../drive/drive_controls.dart';
import '../drive/drive_map_model.dart';
import '../drive/heard_box.dart';
import 'coverage_layer_controls.dart';
import 'coverage_map.dart';
import 'region_center.dart';
import 'map_layers.dart';

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
          final pings = model.pings;
          final latest = s.recentPings.isEmpty ? null : s.recentPings.first;
          return Stack(
            children: [
              Positioned.fill(
                child: CoverageMap(
                  key: const Key('fullscreen-coverage-map'),
                  pings: pings,
                  repeaters: model.repeaters,
                  position: model.position,
                  repeaterLabel: s.repeaterLabel,
                  heard: model.heard,
                  layers: model.layers,
                  networkCells: model.networkCells,
                  regionRepeaters: model.regionRepeaters,
                  highlightKey: model.selected,
                  onSelectRepeater: model.select,
                  simulated: model.simulated,
                  onZoomChanged: model.onMapZoom,
                  fallbackCenter: viewedRegionCenter(s),
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
              // Top: heard box (left), close + layers (right).
              Positioned(
                left: safe.left + Gap.m,
                top: safe.top + Gap.m,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: mq.size.height - safe.top - safe.bottom - (landscape ? 2 * Gap.m : panelHeight + 2 * Gap.m),
                  ),
                  child: SingleChildScrollView(
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
              Positioned(
                right: safe.right + Gap.m,
                top: safe.top + Gap.m,
                child: Column(
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
                  ],
                ),
              ),
              if (latest != null && s.driving)
                Positioned(
                  left: 0,
                  right: landscape ? panelWidth : 0,
                  bottom: safe.bottom + (landscape ? 0 : panelHeight) + 64,
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

/// Layer toggles (shared with the Drive screen map).
Future<void> showMapLayersSheet(BuildContext context, DriveMapModel model) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: AnimatedBuilder(
        animation: model,
        builder: (context, _) {
          final t = Theme.of(context);
          final l = model.layers;
          void set(MapLayers n) => model.layers = n;
          return SingleChildScrollView(
            child: Padding(
            key: const Key('layers-sheet'),
            padding: const EdgeInsets.fromLTRB(Gap.s, 0, Gap.s, Gap.m),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.s),
                  child: Text('Map layers', style: t.textTheme.titleLarge),
                ),
                SwitchListTile(
                  key: const Key('layer-network-coverage'),
                  secondary: const Icon(Icons.public_rounded),
                  title: const Text('Network coverage'),
                  subtitle: const Text("Everyone's measured coverage, not just this drive"),
                  value: l.networkCoverage,
                  onChanged: (v) => set(l.copyWith(networkCoverage: v)),
                ),
                if (l.networkCoverage) CoverageLayerControls(model: model),
                SwitchListTile(
                  key: const Key('layer-hexes'),
                  secondary: const Icon(Icons.hexagon_outlined),
                  title: const Text('Hex coverage'),
                  subtitle: const Text('Your pings on the same hexagons as the website'),
                  value: l.hexes,
                  onChanged: (v) => set(l.copyWith(hexes: v)),
                ),
                SwitchListTile(
                  key: const Key('layer-pings'),
                  secondary: const Icon(Icons.scatter_plot_rounded),
                  title: const Text('Pings'),
                  value: l.pings,
                  onChanged: (v) => set(l.copyWith(pings: v)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(72, 0, Gap.l, Gap.s),
                  child: SegmentedButton<PingColorMode>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith(
                        (st) => st.contains(WidgetState.selected) ? t.colorScheme.primaryContainer : null,
                      ),
                      foregroundColor: WidgetStateProperty.resolveWith(
                        (st) => st.contains(WidgetState.selected) ? t.colorScheme.onPrimaryContainer : null,
                      ),
                    ),
                    segments: const [
                      ButtonSegment(value: PingColorMode.snr, label: Text('By SNR', key: Key('layer-color-snr'))),
                      ButtonSegment(value: PingColorMode.result, label: Text('Heard / not', key: Key('layer-color-result'))),
                    ],
                    selected: {l.pingColors},
                    onSelectionChanged: l.pings ? (v) => set(l.copyWith(pingColors: v.first)) : null,
                  ),
                ),
                SwitchListTile(
                  key: const Key('layer-repeaters'),
                  secondary: const Icon(Icons.cell_tower_rounded),
                  title: const Text('Repeaters'),
                  value: l.repeaters,
                  onChanged: (v) => set(l.copyWith(repeaters: v)),
                ),
                SwitchListTile(
                  key: const Key('layer-region-repeaters'),
                  secondary: const Icon(Icons.cell_tower_outlined),
                  title: const Text('Region repeaters'),
                  subtitle: const Text('Every repeater in this region, by activity'),
                  value: l.regionRepeaters,
                  onChanged: (v) => set(l.copyWith(regionRepeaters: v)),
                ),
                SwitchListTile(
                  key: const Key('layer-links'),
                  secondary: const Icon(Icons.timeline_rounded),
                  title: const Text('Links to heard repeaters'),
                  subtitle: const Text('With distance'),
                  value: l.links,
                  onChanged: (v) => set(l.copyWith(links: v)),
                ),
                SwitchListTile(
                  key: const Key('layer-rings'),
                  secondary: const Icon(Icons.radar_rounded),
                  title: const Text('Range rings'),
                  subtitle: const Text('1 km and 2 km around you'),
                  value: l.rings,
                  onChanged: (v) => set(l.copyWith(rings: v)),
                ),
              ],
            ),
            ),
          );
        },
      ),
    ),
  );
}
