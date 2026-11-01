// The map layers sheet, generated from the registry (registry.dart): one section per [LayerGroup] in order, one
// switch per layer that has a renderer, each with its honest status line from [DriveMapModel.statusOf] (count, source,
// "Not available on this server yet", "Couldn't load" + Retry, "Offline copy"), the layer's controls when it is on
// (coverage colour-by / detail / since / source; ping colours) and its legend (advert age for the global repeater
// layer, roster status for the region one). A layer whose data is unsupported or empty is shown with its switch
// disabled and the reason, never hidden; one that is on can always be switched off. Design: stream-1-maps.md 4.1.
//
// Keys: 'layers-sheet', 'layers-group-<group>', the switch per layer from [layerSwitchKey] (the pre-registry keys are
// kept for one release: measured = 'layer-network-coverage', heard = 'layer-repeaters', repeaters (roster) =
// 'layer-region-repeaters'; new layers are 'layer-<id>'), 'layer-<id>-status', 'layer-<id>-retry', 'layer-color-snr',
// 'layer-color-result', 'network-legend', 'roster-legend'.
import 'package:flutter/material.dart';

import '../../../core/network_coverage.dart' show CoverageLevel;
import '../../../core/region_repeaters_api.dart' show RepeaterActivity;
import '../../app.dart' show AppScope;
import '../../drive/drive_map_model.dart';
import '../../theme.dart';
import '../coverage_layer_controls.dart';
import '../coverage_map.dart' show networkLevelColor;
import '../legend_sheet.dart' show showMapLegend;
import '../map_layers.dart' show PingColorMode;
import '../region_repeater_layer.dart' show regionRepeaterColor;
import '../sheets/repeater_sheet.dart' show rosterStatusText;
import 'map_layer.dart';
import 'registry.dart';
import 'repeater_map_source.dart';

/// Layers this build draws. `neighbours` is in the registry (website parity, WP-M4) but has no renderer yet, so the
/// sheet does not offer a switch that would do nothing.
const Set<String> kDrawnLayerIds = {'measured', 'hexes', kNetworkLayerId, kRosterLayerId, 'observers', 'links', 'heard', 'pings', 'rings', kLabelsLayerId};

/// The widget key of a layer's switch. Pre-registry keys stay for one release (tests and muscle memory).
Key layerSwitchKey(String id) => Key(switch (id) {
  'measured' => 'layer-network-coverage',
  'heard' => 'layer-repeaters',
  kRosterLayerId => 'layer-region-repeaters',
  _ => 'layer-$id',
});

/// Icon, title and one-line description per layer.
({IconData icon, String title, String? description}) layerPresentation(BuildContext context, MapLayerSpec spec) => switch (spec.id) {
  'measured' => (icon: Icons.public_rounded, title: 'Network coverage', description: "Everyone's measured coverage, not just this drive"),
  'hexes' => (icon: Icons.hexagon_outlined, title: 'Hex coverage', description: 'Your pings on the same hexagons as the website'),
  kNetworkLayerId => (icon: Icons.hub_outlined, title: spec.label, description: 'Every repeater with a public position, coloured by last advert'),
  kRosterLayerId => (icon: Icons.cell_tower_outlined, title: 'Region repeaters', description: 'Every repeater in this region, by activity'),
  'observers' => (icon: Icons.change_history_rounded, title: 'Observers', description: "The region's observers that share their position"),
  'links' => (icon: Icons.timeline_rounded, title: 'Links to heard repeaters', description: 'With distance'),
  'heard' => (icon: Icons.cell_tower_rounded, title: 'Repeaters', description: 'Repeaters this drive heard'),
  kLabelsLayerId => (icon: Icons.label_outline_rounded, title: 'Repeater names', description: 'Name beside each repeater; fewer as you zoom out'),
  'pings' => (icon: Icons.scatter_plot_rounded, title: 'Pings', description: null),
  'rings' => (
    icon: Icons.radar_rounded,
    title: 'Range rings',
    description: AppScope.unitsOf(context).isImperial ? 'Half a mile and 1 mile around you' : '1 km and 2 km around you',
  ),
  _ => (icon: Icons.layers_outlined, title: spec.label, description: null),
};

/// Opens the sheet for [model] (shared by the Drive screen map and the full-screen map).
Future<void> showGeneratedLayersSheet(BuildContext context, DriveMapModel model) {
  final h = MediaQuery.sizeOf(context).height;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: h * 0.85),
    builder: (context) => SafeArea(child: MapLayersSheet(model: model)),
  );
}

class MapLayersSheet extends StatelessWidget {
  final DriveMapModel model;
  const MapLayersSheet({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([model, model.repeaterSource]),
      builder: (context, _) {
        final t = Theme.of(context);
        final st = model.layerState;
        final groups = layersByGroup();
        return SingleChildScrollView(
          child: Padding(
            key: const Key('layers-sheet'),
            padding: const EdgeInsets.fromLTRB(Gap.s, 0, Gap.s, Gap.m),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.xs, Gap.xs),
                  child: Row(
                    children: [
                      Expanded(child: Semantics(header: true, child: Text('Map layers', style: t.textTheme.titleLarge))),
                      IconButton(
                        key: const Key('layers-legend'),
                        tooltip: 'Map legend',
                        icon: const Icon(Icons.info_outline_rounded),
                        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                        onPressed: () => showMapLegend(context, colorBy: model.colorBy, pingColors: model.layers.pingColors),
                      ),
                    ],
                  ),
                ),
                for (final g in LayerGroup.values)
                  if (groups[g]!.any((l) => kDrawnLayerIds.contains(l.id))) ...[
                    Padding(
                      key: Key('layers-group-${g.name}'),
                      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.m, Gap.m, 0),
                      child: Text(g.label, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary)),
                    ),
                    for (final spec in groups[g]!)
                      if (kDrawnLayerIds.contains(spec.id)) ..._layer(context, spec, st),
                  ],
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _layer(BuildContext context, MapLayerSpec spec, MapLayerState st) {
    final t = Theme.of(context);
    final p = layerPresentation(context, spec);
    final on = st.isOn(spec.id);
    final status = model.statusOf(spec.id);
    final unsupported = status.availability == LayerAvailability.unsupported;
    // Drive layers draw what this phone recorded: no status line. Server-fed layers always say where they stand.
    final detail = spec.serverFed ? status.detail : null;
    final subtitle = [?p.description, ?detail];
    return [
      SwitchListTile(
        key: layerSwitchKey(spec.id),
        secondary: Icon(p.icon),
        title: Text(p.title),
        subtitle: subtitle.isEmpty
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (p.description != null) Text(p.description!),
                  if (detail != null)
                    Text(
                      detail,
                      key: Key('layer-${spec.id}-status'),
                      style: t.textTheme.bodySmall?.copyWith(
                        color: status.availability == LayerAvailability.failed ? t.colorScheme.error : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
        // A default-on layer the server does not offer shows off and disabled (it cannot draw anything). Otherwise
        // unsupported/empty layers cannot be switched on, and a layer that is on can always be switched off.
        value: on && !unsupported,
        onChanged: unsupported ? null : ((on || status.enabled) ? (v) => model.setLayer(spec.id, v) : null),
      ),
      if (spec.serverFed && status.canRetry)
        Padding(
          padding: const EdgeInsets.only(left: 64),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: Key('layer-${spec.id}-retry'),
              onPressed: () => model.retry(spec.id),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Retry'),
            ),
          ),
        ),
      if (spec.id == 'measured' && on) CoverageLayerControls(model: model),
      if (spec.id == 'pings') _PingColors(model: model),
      if (spec.id == kNetworkLayerId && on) Padding(padding: const EdgeInsets.fromLTRB(72, 0, Gap.l, Gap.s), child: NetworkAgeLegend(set: model.repeaterFeed.global)),
      if (spec.id == kRosterLayerId && on) const Padding(padding: EdgeInsets.fromLTRB(72, 0, Gap.l, Gap.s), child: RosterStatusLegend()),
    ];
  }
}

class _PingColors extends StatelessWidget {
  final DriveMapModel model;
  const _PingColors({required this.model});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final l = model.layers;
    return Padding(
      padding: const EdgeInsets.fromLTRB(72, 0, Gap.l, Gap.s),
      child: SegmentedButton<PingColorMode>(
        showSelectedIcon: false,
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? t.colorScheme.primaryContainer : null),
          foregroundColor: WidgetStateProperty.resolveWith((st) => st.contains(WidgetState.selected) ? t.colorScheme.onPrimaryContainer : null),
        ),
        segments: const [
          ButtonSegment(value: PingColorMode.snr, label: Text('By SNR', key: Key('layer-color-snr'))),
          ButtonSegment(value: PingColorMode.result, label: Text('Heard / not', key: Key('layer-color-result'))),
        ],
        selected: {l.pingColors},
        onSelectionChanged: l.pings ? (v) => model.layers = l.copyWith(pingColors: v.first) : null,
      ),
    );
  }
}

/// The global layer's colour key (website advert-age bands, `core/repeater_points.dart` advertAgeBand: inclusive
/// 24 h / 7 d / 30 d edges), the data's own "as of" and its credit line.
class NetworkAgeLegend extends StatelessWidget {
  final MapRepeaterSet set;

  /// One compact row for the map overlay (no as-of / credit lines).
  final bool dense;
  const NetworkAgeLegend({super.key, required this.set, this.dense = false});

  static const List<(CoverageLevel, String)> steps = [
    (CoverageLevel.strong, '24 h'),
    (CoverageLevel.good, '7 d'),
    (CoverageLevel.fair, '30 d'),
    (CoverageLevel.none, 'Older'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = (dense ? t.textTheme.labelSmall : t.textTheme.bodySmall)?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final row = Wrap(
      spacing: dense ? 6 : Gap.s,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (!dense) Text('Last advert:', style: style),
        for (final (level, label) in steps)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Dot(color: networkLevelColor(context, level), size: dense ? 8 : 10),
              const SizedBox(width: 3),
              Text(label, style: style),
            ],
          ),
        if (!dense) ...[
          Row(mainAxisSize: MainAxisSize.min, children: [_Ring(color: t.colorScheme.onSurfaceVariant), const SizedBox(width: 3), Text('room server', style: style)]),
        ],
      ],
    );
    if (dense) return KeyedSubtree(key: const Key('map-network-legend'), child: row);
    final asOf = set.asOf;
    return Column(
      key: const Key('network-legend'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        // One credit line, not two: the source credit and its age together ("Data: MeshCore Map (...), as of ...").
        if (set.attribution != null)
          Text(asOf != null ? '${set.attribution!}, as of ${_stamp(asOf)}' : set.attribution!,
              key: const Key('network-legend-attribution'), style: style)
        else if (asOf != null)
          Text('MeshCore Map data as of ${_stamp(asOf)}', key: const Key('network-legend-asof'), style: style),
      ],
    );
  }

  static String _stamp(DateTime t) {
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }
}

/// The region roster layer's colour key (roster status, same colours the old pin layer used).
class RosterStatusLegend extends StatelessWidget {
  const RosterStatusLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Wrap(
      key: const Key('roster-legend'),
      spacing: Gap.s,
      runSpacing: 2,
      children: [
        for (final a in RepeaterActivity.values)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [_Dot(color: regionRepeaterColor(a), size: 10), const SizedBox(width: 3), Text(rosterStatusText(a), style: style)],
          ),
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  final Color color;
  final double size;
  const _Dot({required this.color, required this.size});
  @override
  Widget build(BuildContext context) => Container(width: size, height: size, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class _Ring extends StatelessWidget {
  final Color color;
  const _Ring({required this.color});
  @override
  Widget build(BuildContext context) =>
      Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color, width: 2)));
}
