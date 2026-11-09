// The map credit for the small maps that are not the shared CoverageMap (Where to drive, repeater position / reach / your
// drives, contact, radio tools, live packets). The OSM tile usage policy and Attribution Guidelines want the credit visible
// in a corner without interaction; the Drive map has its own AttributionLine + Credits sheet. Every mini map draws OSM
// raster tiles (CoverageMap.tileUrl), so the line is the OSM credit. Key 'mini-map-credit'.
import 'package:flutter/material.dart';

import '../../../core/map_styles.dart';

/// The text of the credit: the OSM line of the Chart / Street / Dark base maps.
String get miniMapCreditText => BaseMapStyle.chart.attribution;

/// A small credit pill in the bottom-right corner. Put it last in a FlutterMap's children (it is a plain widget, not a layer).
class MiniMapCredit extends StatelessWidget {
  const MiniMapCredit({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Align(
      alignment: Alignment.bottomRight,
      child: IgnorePointer(
        child: Container(
          key: const Key('mini-map-credit'),
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: t.colorScheme.surface.withValues(alpha: 0.78), borderRadius: BorderRadius.circular(3)),
          child: Text(
            miniMapCreditText,
            style: (t.textTheme.labelSmall ?? const TextStyle()).copyWith(fontSize: 10, height: 1.2, color: t.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
