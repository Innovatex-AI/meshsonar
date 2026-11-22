// Privacy zones on a map, drawn from the Map Definition's `symbols.tools.zone` and `handle` (MAP slice 6, app half; the twin of the
// website's zone layer): a filled circle (fill + opacity, normal or active when selected) with an edge (colour + width, dashed) and
// the numbered handle that selects it. Drawing only: which pings a zone hides, its radius and how it is stored never pass through
// here.
//
// A definition without `symbols.tools` (the bundled copy, an older server answer) draws what build 73 drew: the zones editor passes
// its [ZoneFallback] (the theme colours it always used) and the layer paints the same CircleLayer; a map that had no zones before
// (the drive report) passes none and the layer draws nothing.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/map_definition.dart';
import '../../../core/map_tool_style.dart';
import '../../../core/privacy_zones.dart';
import '../active_map_definition.dart';

/// A dash pattern written in multiples of the line width (the MapLibre `line-dasharray` rule of the site) as pixels for
/// flutter_map: always an even number of entries, at least one pixel each.
List<double> dashedBorderPattern(List<double> dash, double width) {
  final w = math.max(width, 1.0);
  final px = [for (final d in dash) math.max(d * w, 1.0)];
  return px.length.isEven ? px : [...px, ...px];
}

StrokePattern strokePatternFor(List<double>? dash, double width) =>
    dash == null ? const StrokePattern.solid() : StrokePattern.dashed(segments: dashedBorderPattern(dash, width));

/// The colours the zones editor used before the definition carried tool styles (theme colours: normal = tertiary, selected = primary).
class ZoneFallback {
  final Color normal, selected, onNormal, onSelected;
  const ZoneFallback({required this.normal, required this.selected, required this.onNormal, required this.onSelected});

  factory ZoneFallback.of(ThemeData t) =>
      ZoneFallback(normal: t.colorScheme.tertiary, selected: t.colorScheme.primary, onNormal: t.colorScheme.onTertiary, onSelected: t.colorScheme.onPrimary);
}

/// [points] vertices of the circle of [radiusM] metres around ([lat], [lon]) (a sphere, the same earth as [distanceM]).
List<LatLng> zoneCirclePoints(double lat, double lon, double radiusM, {int points = 72}) {
  const r = 6371000.0;
  final d = radiusM / r;
  final la = lat * math.pi / 180, lo = lon * math.pi / 180;
  return [
    for (var i = 0; i < points; i++)
      () {
        final b = 2 * math.pi * i / points;
        final la2 = math.asin(math.sin(la) * math.cos(d) + math.cos(la) * math.sin(d) * math.cos(b));
        final lo2 = lo + math.atan2(math.sin(b) * math.sin(d) * math.cos(la), math.cos(d) - math.sin(la) * math.sin(la2));
        return LatLng(la2 * 180 / math.pi, wrapLon(lo2 * 180 / math.pi));
      }(),
  ];
}

/// The zone circles (and, in the editor, their numbered handles).
class ZoneLayer extends StatelessWidget {
  final List<PrivacyZone> zones;

  /// The selected zone (drawn with the active opacity and width); null = none.
  final int? selected;

  /// What the editor drew before the definition had tool styles; null = draw nothing without them (the drive report).
  final ZoneFallback? fallback;

  /// The definition to read; null = the active one, followed live.
  final MapDefinition? definition;
  const ZoneLayer({super.key, required this.zones, this.selected, this.fallback, this.definition});

  @override
  Widget build(BuildContext context) {
    if (zones.isEmpty) return const SizedBox.shrink();
    if (definition != null) return _build(context, definition!);
    return ValueListenableBuilder<MapDefinition>(valueListenable: ActiveMapDefinition.notifier, builder: (context, d, _) => _build(context, d));
  }

  Widget _build(BuildContext context, MapDefinition def) {
    final tool = MapToolStyle.of(def);
    if (tool == null) {
      final f = fallback;
      if (f == null) return const SizedBox.shrink();
      return CircleLayer(circles: [
        for (var i = 0; i < zones.length; i++)
          CircleMarker(
            point: LatLng(zones[i].lat, zones[i].lon),
            radius: zones[i].radiusM,
            useRadiusInMeter: true,
            color: (i == selected ? f.selected : f.normal).withValues(alpha: i == selected ? 0.30 : 0.18),
            borderColor: i == selected ? f.selected : f.normal,
            borderStrokeWidth: i == selected ? 3 : 2,
          ),
      ]);
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final z = tool.zone;
    return PolygonLayer(polygons: [
      for (var i = 0; i < zones.length; i++)
        () {
          final active = i == selected;
          final w = z.edgeWidthPx.of(active: active);
          return Polygon(
            points: zoneCirclePoints(zones[i].lat, zones[i].lon, zones[i].radiusM),
            color: Color(z.fill.of(dark: dark)).withValues(alpha: z.fillOpacity.of(active: active)),
            borderColor: Color(z.edge.of(dark: dark)),
            borderStrokeWidth: w,
            pattern: strokePatternFor(z.dash, w),
          );
        }(),
    ]);
  }
}

/// The numbered handle of a zone (the editor's tap target): the definition's handle colours (selected = the move fill), else the
/// theme colours of build 73.
class ZonePin extends StatelessWidget {
  final int index;
  final bool selected;
  final ZoneFallback fallback;
  final MapDefinition? definition;
  const ZonePin({super.key, required this.index, required this.selected, required this.fallback, this.definition});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tool = MapToolStyle.of(definition ?? ActiveMapDefinition.current);
    final dark = t.brightness == Brightness.dark;
    if (tool == null) {
      final fg = selected ? fallback.onSelected : fallback.onNormal;
      return CircleAvatar(
        radius: 13,
        backgroundColor: selected ? fallback.selected : fallback.normal,
        foregroundColor: fg,
        child: Text('${index + 1}', style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: fg)),
      );
    }
    final h = tool.handle;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color(selected ? h.moveFill.of(dark: dark) : h.fill.of(dark: dark)),
        border: Border.all(color: Color(h.edge.of(dark: dark)), width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text('${index + 1}',
          style: t.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700, color: Color(selected ? h.fill.of(dark: dark) : h.edge.of(dark: dark)))),
    );
  }
}
