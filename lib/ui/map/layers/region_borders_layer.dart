// The Region borders layer (Map Definition `borders`, group Context, default on; the website's region outline): the viewed
// region's boundary as a thin line with a faint fill, in the definition's border symbol (`symbols.border`: width, colour per
// theme, opacity, fill opacity). No tags and no names on the line (plan §2.4: pointer tags are gone for good).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/region_lookup.dart' show RegionIndexEntry;
import '../active_map_definition.dart';

/// The outer rings of a GeoJSON Polygon / MultiPolygon as LatLng lists (holes are left out: a border is drawn, not a mask).
List<List<LatLng>> boundaryRings(Map<String, dynamic>? geo) {
  if (geo == null) return const [];
  List<LatLng> ring(Object? r) => [
    for (final p in (r as List? ?? const []))
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()),
  ];
  final c = geo['coordinates'];
  if (c is! List) return const [];
  final List<List<LatLng>> rings = switch (geo['type']) {
    'Polygon' => [if (c.isNotEmpty) ring(c.first)],
    'MultiPolygon' => [for (final poly in c) if (poly is List && poly.isNotEmpty) ring(poly.first)],
    _ => <List<LatLng>>[],
  };
  return [for (final r in rings) if (r.length >= 3) r];
}

/// The rings of [r]'s boundary, else its bbox as a rectangle (the website does the same), else none.
List<List<LatLng>> regionBorderRings(RegionIndexEntry? r) {
  if (r == null) return const [];
  final rings = boundaryRings(r.boundary);
  if (rings.isNotEmpty) return rings;
  final b = r.bbox;
  if (b == null || b.length != 4) return const [];
  return [
    [LatLng(b[1], b[0]), LatLng(b[1], b[2]), LatLng(b[3], b[2]), LatLng(b[3], b[0])],
  ];
}

class RegionBordersLayer extends StatelessWidget {
  final List<List<LatLng>> rings;
  const RegionBordersLayer({super.key, required this.rings});

  @override
  Widget build(BuildContext context) {
    final d = ActiveMapDefinition.current;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final sym = d.symbol('border');
    final colour = Color(d.symbolColour('border', 'x', dark: dark));
    final width = (sym['widthPx'] as num?)?.toDouble() ?? 1.4;
    final opacity = (sym['opacity'] as num?)?.toDouble() ?? 0.75;
    final fill = (sym['fillOpacity'] as num?)?.toDouble() ?? 0.04;
    return IgnorePointer(
      child: PolygonLayer(
        polygons: [
          for (final r in rings)
            Polygon(points: r, color: colour.withValues(alpha: fill), borderColor: colour.withValues(alpha: opacity), borderStrokeWidth: width),
        ],
      ),
    );
  }
}
