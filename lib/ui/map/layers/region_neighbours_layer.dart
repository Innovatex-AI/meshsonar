// The map's "Regions" layer (the website's neighbour layer, meshcore-insights src/components/map/neighbour-layer.ts): the
// regions next to the viewed one as quiet dashed outlines with their names. A name is a real button (48 px tall, spoken
// "Switch to <region>"); a neighbour that is off screen keeps its name pinned to the map edge with an arrow toward it (the
// nearest six). Tapping inside an outline is handled by the map (CoverageMap) with [RegionNeighbourSet.hit]. A flutter_map
// child: build it inside `FlutterMap(children: [...])`.
//
// Keys (tests): 'region-outlines' (the polygon layer), 'region-name-<code>' (a name on the map), 'region-edge-<code>' (a name
// pinned to the edge).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/region_lookup.dart' show RegionIndexEntry;
import '../../../core/region_neighbours.dart';
import '../../theme.dart';

/// How many off-screen neighbours keep a pinned name.
const int kRegionEdgePins = 6;

class RegionNeighboursLayer extends StatelessWidget {
  final RegionNeighbourSet set;
  final ValueChanged<RegionIndexEntry> onPick;

  /// Space the parent covers with its own controls (chips, buttons, the control panel): names are not placed under it.
  final EdgeInsets avoid;

  /// Rectangles (in the map's own coordinates) of the parent's overlays, read each build: a name is not placed under one;
  /// a pinned name slides along the edge to the nearest free spot.
  final List<Rect> Function()? obstacles;
  const RegionNeighboursLayer({super.key, required this.set, required this.onPick, this.avoid = EdgeInsets.zero, this.obstacles});

  static final StrokePattern _dashed = StrokePattern.dashed(segments: const [7, 6]);

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (camera.zoom > kRegionLayerMaxZoom) return const SizedBox.shrink();
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final line = t.brightness == Brightness.dark ? t.colorScheme.onSurface.withValues(alpha: 0.65) : t.colorScheme.primary.withValues(alpha: 0.75);
    final size = camera.size;
    final safe = Rect.fromLTRB(avoid.left + 8, avoid.top + 8, size.width - avoid.right - 8, size.height - avoid.bottom - 8);
    final visible = Rect.fromLTWH(0, 0, size.width, size.height);

    final obs = obstacles?.call() ?? const <Rect>[];
    bool free(Rect r) => !obs.any((o) => o.overlaps(r));
    final names = <Widget>[];
    final edge = <Widget>[];
    var pinned = 0;
    for (final n in set.neighbours) {
      final o = camera.latLngToScreenOffset(LatLng(n.label.lat, n.label.lon));
      final box = Rect.fromCenter(center: o, width: _NameButton.width, height: _NameButton.height);
      if (visible.contains(o) && safe.contains(o)) {
        if (!free(box)) continue; // under an overlay: the outline still takes the tap
        names.add(Positioned(
          key: ValueKey('region-name-pos-${n.region.code}'),
          left: o.dx - _NameButton.width / 2,
          top: o.dy - _NameButton.height / 2,
          width: _NameButton.width,
          height: _NameButton.height,
          child: _NameButton(key: Key('region-name-${n.region.code}'), n: n, onPick: onPick, mc: mc),
        ));
      } else if (pinned < kRegionEdgePins && !visible.contains(o)) {
        pinned++;
        final pin = _edgePin(context, n, o, safe, size, free);
        if (pin != null) edge.add(pin);
      }
    }

    return SizedBox.expand(
      child: Stack(children: [
        PolygonLayer(
          key: const Key('region-outlines'),
          polygons: [
            for (final n in set.neighbours)
              for (final ring in n.rings)
                Polygon(
                  points: [for (final p in ring) LatLng(p.lat, p.lon)],
                  color: line.withValues(alpha: 0.05),
                  borderColor: line,
                  borderStrokeWidth: 1.5,
                  pattern: _dashed,
                ),
          ],
        ),
        ...names,
        ...edge,
      ]),
    );
  }

  /// A name pinned to the map edge, on the line from the middle of the map to the neighbour, with an arrow toward it.
  Widget? _edgePin(BuildContext context, RegionNeighbour n, Offset target, Rect safe, Size size, bool Function(Rect) free) {
    final centre = Offset(size.width / 2, size.height / 2);
    final d = target - centre;
    // Scale the direction so the point lands on the inner rectangle's edge.
    final hx = (_NameButton.width / 2) + 4, hy = (_NameButton.height / 2) + 4;
    final inner = Rect.fromLTRB(math.max(safe.left, hx), math.max(safe.top, hy), math.min(safe.right, size.width - hx), math.min(safe.bottom, size.height - hy));
    final sx = d.dx == 0 ? double.infinity : ((d.dx > 0 ? inner.right : inner.left) - centre.dx) / d.dx;
    final sy = d.dy == 0 ? double.infinity : ((d.dy > 0 ? inner.bottom : inner.top) - centre.dy) / d.dy;
    final s = math.min(sx.abs(), sy.abs());
    var p = centre + d * s;
    // Slide along the edge (the axis the pin is not pinned on) to the nearest spot no overlay covers.
    final onSide = sx.abs() < sy.abs(); // pinned to the left or right edge: slide vertically
    Rect at(Offset q) => Rect.fromCenter(center: q, width: _NameButton.width, height: _NameButton.height);
    if (!free(at(p))) {
      Offset? found;
      for (var step = 1; step <= 40 && found == null; step++) {
        for (final sign in [1, -1]) {
          final q = onSide ? Offset(p.dx, p.dy + sign * step * 28.0) : Offset(p.dx + sign * step * 28.0, p.dy);
          if (inner.contains(q) && free(at(q))) {
            found = q;
            break;
          }
        }
      }
      if (found == null) return null;
      p = found;
    }
    return Positioned(
      key: ValueKey('region-edge-pos-${n.region.code}'),
      left: p.dx - _NameButton.width / 2,
      top: p.dy - _NameButton.height / 2,
      width: _NameButton.width,
      height: _NameButton.height,
      child: _NameButton(key: Key('region-edge-${n.region.code}'), n: n, onPick: onPick, mc: MeshSonarColors.of(context), arrowAngle: math.atan2(d.dy, d.dx)),
    );
  }
}

class _NameButton extends StatelessWidget {
  static const double width = 128;
  static const double height = 48;
  final RegionNeighbour n;
  final ValueChanged<RegionIndexEntry> onPick;
  final MeshSonarColors mc;
  final double? arrowAngle;
  const _NameButton({super.key, required this.n, required this.onPick, required this.mc, this.arrowAngle});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    // Map overlays keep their text at 1.3x at most (the full sentence is read aloud), so names never swallow the map.
    final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final fg = t.colorScheme.onSurface;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: Semantics(
        button: true,
        label: 'Switch to ${n.name}',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(Corners.chip),
          onTap: () => onPick(n.region),
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: t.colorScheme.surface.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(Corners.chip),
                border: Border.all(color: t.colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  if (arrowAngle != null) ...[
                    Transform.rotate(angle: arrowAngle!, child: Icon(Icons.arrow_forward, size: 16, color: fg)),
                    const SizedBox(width: 4),
                  ],
                  Flexible(
                    child: Text(
                      n.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
