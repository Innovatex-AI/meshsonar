// The Observers map layer: the viewed region's observers whose owner made the position public (`region-observers`
// rows with lat/lon; the server leaves them null otherwise and rounds per `location_public`), drawn as a triangle
// (the website's "triangulation station = observer" glyph): online = filled teal, offline = outline. A region has a
// handful of observers (cmh: 9, 3 with a position), so this stays one small widget per observer. Tap -> ObserverHit.
// Design: stream-1-maps.md 4.1 (z 45) and 4.6. Keys: 'map-observer-<key>' (+ '-online' / '-offline' state key).
// Contract section 8.4 (Nov 9 2026): online MeshSonar phones on the move (`kind: mobile`) are drawn too, at the centre of
// their latest ~5 km cell (never exact): a filled circle with a phone outline ('-mobile' state key), fading out over the 10
// minutes after they were last seen and gone after that. Same as the website's Observers layer (parity).
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

/// How long a moving phone stays on the map after it was last seen (contract section 8.4).
const Duration kMobileObserverFade = Duration(minutes: 10);

/// 1 = just seen, falling to 0.2 at [kMobileObserverFade] (the website's fade); 0 = past it (not drawn). Fixed observers are
/// always 1.
double observerOpacity(RegionObserver o, DateTime now) {
  if (!o.mobile) return 1;
  final seen = o.lastSeen;
  if (seen == null) return o.online ? 1 : 0;
  final age = now.difference(seen);
  if (age.isNegative) return 1;
  if (age >= kMobileObserverFade) return 0;
  return 1 - 0.8 * (age.inSeconds / kMobileObserverFade.inSeconds);
}

/// The observers of [rows] that can be drawn.
List<RegionObserver> positionedObservers(List<RegionObserver> rows) => [for (final o in rows) if (observerHasPosition(o)) o];

class ObserverLayer extends StatelessWidget {
  final List<RegionObserver> observers;
  final String? regionName;
  final ValueChanged<MapHit>? onHit;

  /// The clock for the moving-phone fade (tests pass one).
  final DateTime Function()? now;
  const ObserverLayer({super.key, required this.observers, this.regionName, this.onHit, this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final at = (now ?? DateTime.now)().toUtc();
    return MarkerLayer(
      markers: [
        for (final o in observers)
          if (observerHasPosition(o) && o.mobile && observerOpacity(o, at) > 0)
            Marker(
              point: LatLng(o.lat!, o.lon!),
              width: 40,
              height: 40,
              child: Semantics(
                button: onHit != null,
                label: 'MeshSonar phone on the move, listening',
                excludeSemantics: true,
                onTap: onHit == null ? null : () => onHit!(ObserverHit(o, regionName: regionName)),
                child: GestureDetector(
                  key: ValueKey('map-observer-${o.key}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onHit == null ? null : () => onHit!(ObserverHit(o, regionName: regionName)),
                  child: Center(
                    child: Opacity(
                      opacity: observerOpacity(o, at),
                      child: CustomPaint(
                        key: ValueKey('map-observer-${o.key}-mobile'),
                        size: const Size(18, 18),
                        painter: MobileObserverPainter(fill: t.colorScheme.primary, glyph: t.colorScheme.onPrimary, halo: t.colorScheme.surface),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        for (final o in observers)
          if (observerHasPosition(o) && !o.mobile)
            Marker(
              point: LatLng(o.lat!, o.lon!),
              width: 40,
              height: 40,
              child: Semantics(
                button: onHit != null,
                label: 'Observer, ${o.online ? 'online' : 'offline'}',
                excludeSemantics: true,
                onTap: onHit == null ? null : () => onHit!(ObserverHit(o, regionName: regionName)),
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

/// A moving MeshSonar phone (contract section 8.4): a filled circle with a small phone outline inside. Shared with the
/// legend so the two always match.
class MobileObserverPainter extends CustomPainter {
  final Color fill;
  final Color glyph;
  final Color halo;
  MobileObserverPainter({required this.fill, required this.glyph, required this.halo});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2;
    canvas.drawCircle(c, r + 1.5, Paint()..color = halo.withValues(alpha: 0.9));
    canvas.drawCircle(c, r, Paint()..color = fill);
    final w = r * 0.8, h = r * 1.25;
    final rect = RRect.fromRectAndRadius(Rect.fromCenter(center: c, width: w, height: h), Radius.circular(w * 0.22));
    canvas.drawRRect(rect, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, r / 6)
      ..color = glyph);
    canvas.drawCircle(Offset(c.dx, c.dy + h * 0.3), math.max(0.8, r / 10), Paint()..color = glyph);
  }

  @override
  bool shouldRepaint(MobileObserverPainter old) => old.fill != fill || old.glyph != glyph || old.halo != halo;
}
