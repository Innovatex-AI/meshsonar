// The Observers map layer: the viewed region's observers whose owner made the position public (`region-observers`
// rows with lat/lon; the server leaves them null otherwise and rounds per `location_public`), drawn as a triangle
// (the website's "triangulation station = observer" glyph): online = filled teal, offline = outline. A region has a
// handful of observers (cmh: 9, 3 with a position), so this stays one small widget per observer. Tap -> ObserverHit.
// Design: stream-1-maps.md 4.1 (z 45) and 4.6. Keys: 'map-observer-<key>' (+ '-online' / '-offline' state key).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../../core/region_overview_api.dart' show RegionObserver;
import '../../theme.dart';
import 'map_layer.dart';

/// True when [o] carries a drawable public position (both set, finite, in range, not 0/0).
bool observerHasPosition(RegionObserver o) {
  final la = o.lat, lo = o.lon;
  if (la == null || lo == null || !la.isFinite || !lo.isFinite) return false;
  if (la.abs() > 90 || lo.abs() > 180) return false;
  return !(la == 0 && lo == 0);
}

/// The observers of [rows] that can be drawn.
List<RegionObserver> positionedObservers(List<RegionObserver> rows) => [for (final o in rows) if (observerHasPosition(o)) o];

class ObserverLayer extends StatelessWidget {
  final List<RegionObserver> observers;
  final String? regionName;
  final ValueChanged<MapHit>? onHit;
  const ObserverLayer({super.key, required this.observers, this.regionName, this.onHit});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    return MarkerLayer(
      markers: [
        for (final o in observers)
          if (observerHasPosition(o))
            Marker(
              point: LatLng(o.lat!, o.lon!),
              width: 40,
              height: 40,
              child: GestureDetector(
                key: ValueKey('map-observer-${o.key}'),
                behavior: HitTestBehavior.opaque,
                onTap: onHit == null ? null : () => onHit!(ObserverHit(o, regionName: regionName)),
                child: Center(
                  child: CustomPaint(
                    key: ValueKey('map-observer-${o.key}-${o.online ? 'online' : 'offline'}'),
                    size: const Size(20, 18),
                    painter: _TrianglePainter(
                      fill: o.online ? t.colorScheme.primary : null,
                      stroke: o.online ? t.colorScheme.surface : mc.silent,
                      halo: t.colorScheme.surface,
                    ),
                  ),
                ),
              ),
            ),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color? fill;
  final Color stroke;
  final Color halo;
  _TrianglePainter({required this.fill, required this.stroke, required this.halo});

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final path = Path()
      ..moveTo(w / 2, 0)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.5
      ..strokeJoin = StrokeJoin.round
      ..color = halo.withValues(alpha: 0.9));
    if (fill != null) canvas.drawPath(path, Paint()..color = fill!);
    canvas.drawPath(path, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = fill == null ? 2.4 : 1.4
      ..strokeJoin = StrokeJoin.round
      ..color = stroke);
    // A small dot at the centroid so the glyph reads as a station, not an arrow.
    canvas.drawCircle(Offset(w / 2, h * 2 / 3), math.max(1.5, w / 12), Paint()..color = fill == null ? stroke : halo);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.fill != fill || old.stroke != stroke || old.halo != halo;
}
