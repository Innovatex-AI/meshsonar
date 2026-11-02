// Colours and tap results shared by the repeater painter (layers/repeater_painter_layer.dart). The clustered widget that
// used to live here was folded into the one painter (Drive plan 6.1); what stays is the mapping from a list's colour
// band to the three freshness colours (plan 6.3) and the [MapHit] for a tap on a single or a cluster.
import 'package:flutter/material.dart';

import '../../../core/cluster_index.dart';
import '../../../core/region_repeaters_api.dart' show RepeaterActivity;
import 'map_layer.dart';
import 'repeater_map_source.dart';
import 'repeater_sprites.dart';

/// Colours for the global layer's age bands 0..3 (24 h = Fresh, 7 d = Recent, 30 d and older merge into Stale).
List<Color> networkBandColors(BuildContext context) {
  final b = Theme.of(context).brightness;
  return [for (var band = 0; band < 4; band++) freshnessColor(freshnessOfAdvertBand(band), b)];
}

/// Colours for the roster layer, indexed by [RepeaterActivity.index].
List<Color> rosterBandColors(BuildContext context) {
  final b = Theme.of(context).brightness;
  return [for (final a in RepeaterActivity.values) freshnessColor(freshnessOfActivity(a), b)];
}

/// Colour of a roster status (active and new are Fresh, quiet Recent, stale Stale).
Color regionRepeaterColor(RepeaterActivity s, Brightness b) => freshnessColor(freshnessOfActivity(s), b);

/// The [MapHit] for a tap on [layerId]'s list.
MapHit repeaterHitFor(RepeaterMapSource source, String layerId, ClusterTap t) {
  if (!t.isCluster && t.colocated.isEmpty) return RepeaterHit(source.pointAt(layerId, t.point!));
  return ClusterHit(layerId, t, colocated: [for (final i in t.colocated) source.pointAt(layerId, i)]);
}
