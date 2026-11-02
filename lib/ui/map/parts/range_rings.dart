// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Dashed range rings (1 km / 2 km, or 0.5 mi / 1 mi) around the current position, drawn directly so they stay crisp at any zoom.
class RangeRings extends StatelessWidget {
  final LatLng center;
  final Color color;
  final List<double> ringMetres;
  const RangeRings({super.key, required this.center, required this.color, required this.ringMetres});
  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(painter: RingPainter(camera, center, color, ringMetres), size: Size.infinite),
    );
  }
}

class RingPainter extends CustomPainter {
  final MapCamera camera;
  final LatLng center;
  final Color color;
  final List<double> ringMetres;
  RingPainter(this.camera, this.center, this.color, this.ringMetres);

  @override
  void paint(Canvas canvas, Size size) {
    final c = camera.latLngToScreenOffset(center);
    for (final m in ringMetres) {
      final edge = camera.latLngToScreenOffset(LatLng(center.latitude + m / 111320.0, center.longitude));
      final r = (c - edge).distance;
      if (r < 6 || r > 6000) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: m == ringMetres.first ? 0.55 : 0.35);
      // Dashes: ~60 per ring, capped so small rings stay readable.
      final n = (2 * math.pi * r / 14).clamp(24, 160).round();
      for (var i = 0; i < n; i++) {
        final a0 = 2 * math.pi * i / n;
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), a0, math.pi / n, false, paint);
      }
    }
  }

  @override
  bool shouldRepaint(RingPainter old) =>
      old.center != center ||
      old.color != color ||
      old.ringMetres.first != ringMetres.first ||
      old.camera.center != camera.center ||
      old.camera.zoom != camera.zoom;
}
