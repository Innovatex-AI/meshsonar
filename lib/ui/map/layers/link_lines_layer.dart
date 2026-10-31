// The lines drawn when a repeater or a coverage cell is tapped (lib/core/map_links.dart): one line per link, coloured by
// its best SNR on the same scale as the rest of the map, the strongest few labelled with their SNR.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/map_links.dart';
import '../map_info_panel.dart' show linkLineColor;

/// The map layers for [set]: lines, a ring on the start, and SNR labels. Empty when there is nothing to draw.
List<Widget> linkLineLayers(BuildContext context, LinkSet set, {required bool labels}) {
  if (set.ends.isEmpty) return const [];
  final t = Theme.of(context);
  final from = LatLng(set.lat, set.lon);
  const lineColor = linkLineColor;
  Color colorOf(LinkEnd e) => lineColor;
  // Weakest first so the strongest lines end up on top.
  final order = [...set.ends]..sort((a, b) => (a.snr ?? -99).compareTo(b.snr ?? -99));
  final labelled = <LinkEnd>[];
  if (labels) {
    final byPings = [...set.ends]..sort((a, b) => b.pings.compareTo(a.pings));
    for (final e in byPings) {
      if (labelled.length >= maxLinkLabels) break;
      if (linkSnrLabel(e.snr) != null) labelled.add(e);
    }
  }
  return [
    PolylineLayer(
      key: const Key('link-lines'),
      polylines: [
        for (final e in order)
          Polyline(
            points: [from, LatLng(e.lat, e.lon)],
            strokeWidth: 3,
            color: lineColor,
            borderStrokeWidth: 1.5,
            borderColor: Colors.black.withValues(alpha: 0.55),
          ),
      ],
    ),
    CircleLayer(
      circles: [
        CircleMarker(point: from, radius: 9, color: Colors.transparent, borderColor: lineColor, borderStrokeWidth: 4),
        for (final e in set.ends)
          CircleMarker(
            point: LatLng(e.lat, e.lon),
            radius: 3.5,
            color: colorOf(e),
            borderColor: Colors.white,
            borderStrokeWidth: 1,
          ),
      ],
    ),
    if (labelled.isNotEmpty)
      MarkerLayer(
        key: const Key('link-labels'),
        markers: [
          for (final e in labelled)
            Marker(
              point: LatLng((set.lat + e.lat) / 2, (set.lon + e.lon) / 2),
              width: 74,
              height: 20,
              child: IgnorePointer(
                child: Center(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: colorOf(e), width: 1.2),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      child: Text(
                        linkSnrLabel(e.snr)!,
                        maxLines: 1,
                        style: t.textTheme.labelSmall?.copyWith(fontSize: 10.5, fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
  ];
}
