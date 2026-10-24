// The two clustered repeater layers as flutter_map children: `network` (every MeshCore repeater, coloured by advert
// age with the website's four tokens: 24 h green, 7 d blue, 30 d amber, older grey) and `repeaters` (the viewed
// region's roster, coloured by roster status as the old pin layer was). Room servers are rings, repeaters dots.
// Taps become [MapHit]s (a repeater, or a cluster to zoom into / list). Design: stream-1-maps.md 4.3-4.4, D5.
import 'package:flutter/material.dart';

import '../../../core/cluster_index.dart';
import '../../../core/network_coverage.dart' show CoverageLevel;
import '../../../core/region_repeaters_api.dart' show RepeaterActivity;
import '../coverage_map.dart' show networkLevelColor;
import '../region_repeater_layer.dart' show regionRepeaterColor;
import 'clustered_points_layer.dart';
import 'map_layer.dart';
import 'repeater_map_source.dart';

/// Colours for the global layer's age bands 0..3 (website tokens; old is grey, not red: old is not "bad").
List<Color> networkBandColors(BuildContext context) => [
  networkLevelColor(context, CoverageLevel.strong),
  networkLevelColor(context, CoverageLevel.good),
  networkLevelColor(context, CoverageLevel.fair),
  networkLevelColor(context, CoverageLevel.none),
];

/// Colours for the roster layer, indexed by [RepeaterActivity.index].
List<Color> rosterBandColors() => [for (final a in RepeaterActivity.values) regionRepeaterColor(a)];

/// The [MapHit] for a tap on [layerId]'s clustered layer.
MapHit repeaterHitFor(RepeaterMapSource source, String layerId, ClusterTap t) {
  if (!t.isCluster && t.colocated.isEmpty) return RepeaterHit(source.pointAt(layerId, t.point!));
  return ClusterHit(layerId, t, colocated: [for (final i in t.colocated) source.pointAt(layerId, i)]);
}

class RepeaterClusterLayer extends StatelessWidget {
  final RepeaterMapSource source;

  /// [kNetworkLayerId] or [kRosterLayerId].
  final String layerId;

  /// Key of the selected repeater (drawn with a ring), or null.
  final String? selectedKey;
  final ValueChanged<MapHit>? onHit;

  const RepeaterClusterLayer({super.key, required this.source, required this.layerId, this.selectedKey, this.onHit});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: source,
      builder: (context, _) {
        final index = source.indexOf(layerId);
        if (index == null || index.indexedCount == 0) return const SizedBox.shrink();
        final pts = source.pointsOf(layerId);
        final scheme = Theme.of(context).colorScheme;
        final sel = selectedKey == null ? -1 : pts.indexOf(selectedKey!);
        return ClusteredPointsLayer(
          layerKey: 'layer-$layerId',
          index: index,
          kind: pts.kind,
          bandColors: layerId == kNetworkLayerId ? networkBandColors(context) : rosterBandColors(),
          haloColor: scheme.surface,
          labelColor: scheme.onSurface,
          selectedPoint: sel < 0 ? null : sel,
          selectedColor: scheme.primary,
          onTap: onHit == null ? null : (t) => onHit!(repeaterHitFor(source, layerId, t)),
        );
      },
    );
  }
}
