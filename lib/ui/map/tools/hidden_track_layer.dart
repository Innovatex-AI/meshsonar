// The part of a drive the public does not see (inside a privacy zone), drawn faded and dashed from the Map Definition's
// `symbols.tools.hiddenTrack` (MAP slice 6, app half). Drawing only: it is given the runs of positions, it never decides what is hidden.
// A definition without the block draws nothing (build 73 drew no such line).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/map_definition.dart';
import '../../../core/map_tool_style.dart';
import '../../../core/privacy_zones.dart';
import '../../../core/model.dart' show DrivePing;
import 'zone_layer.dart' show strokePatternFor;

/// Runs of consecutive pings (in time order) the [gate] hides; a run of one ping has no line. A run is joined to the visible ping on
/// each side so the dashed line meets the solid track.
List<List<LatLng>> hiddenRuns(List<DrivePing> pings, PrivacyZones gate) {
  final runs = <List<LatLng>>[];
  List<LatLng>? cur;
  for (var i = 0; i < pings.length; i++) {
    final p = pings[i];
    final hidden = gate.hides(p.lat, p.lon);
    if (hidden) {
      cur ??= [if (i > 0) LatLng(pings[i - 1].lat, pings[i - 1].lon)];
      cur.add(LatLng(p.lat, p.lon));
    } else if (cur != null) {
      cur.add(LatLng(p.lat, p.lon));
      runs.add(cur);
      cur = null;
    }
  }
  if (cur != null) runs.add(cur);
  return [for (final r in runs) if (r.length >= 2) r];
}

class HiddenTrackLayer extends StatelessWidget {
  final List<List<LatLng>> runs;
  final MapDefinition definition;
  const HiddenTrackLayer({super.key, required this.runs, required this.definition});

  @override
  Widget build(BuildContext context) {
    final tool = MapToolStyle.of(definition);
    if (tool == null || runs.isEmpty) return const SizedBox.shrink();
    final h = tool.hiddenTrack;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PolylineLayer(polylines: [
      for (final r in runs)
        Polyline(
          points: r,
          strokeWidth: h.widthPx,
          color: Color(h.colour.of(dark: dark)).withValues(alpha: h.opacity),
          pattern: strokePatternFor(h.dash, h.widthPx),
          strokeCap: StrokeCap.round,
          strokeJoin: StrokeJoin.round,
        ),
    ]);
  }
}
