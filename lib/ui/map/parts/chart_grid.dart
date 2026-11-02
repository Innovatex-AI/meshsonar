// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// A faint lat/lon grid that moves with the map: the "chart paper" you see when tiles can't load.
class ChartGrid extends StatelessWidget {
  final Color color;
  const ChartGrid({super.key, required this.color});
  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(painter: GridPainter(camera, color), size: Size.infinite),
    );
  }
}

class GridPainter extends CustomPainter {
  final MapCamera camera;
  final Color color;
  GridPainter(this.camera, this.color);

  static const _steps = [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0];

  @override
  void paint(Canvas canvas, Size size) {
    final pxPerDeg = 256 * math.pow(2, camera.zoom) / 360;
    var step = _steps.last;
    for (final s in _steps) {
      if (s * pxPerDeg >= 70) {
        step = s;
        break;
      }
    }
    final b = camera.visibleBounds;
    final minor = Paint()
      ..color = color.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = color.withValues(alpha: 0.14)
      ..strokeWidth = 1;
    final west = b.west - step, east = b.east + step;
    final south = math.max(-85.0, b.south - step), north = math.min(85.0, b.north + step);
    var i = (south / step).floor();
    for (var lat = i * step; lat <= north; lat += step, i++) {
      final a = camera.latLngToScreenOffset(LatLng(lat, west.clamp(-180.0, 180.0)));
      final c = camera.latLngToScreenOffset(LatLng(lat, east.clamp(-180.0, 180.0)));
      canvas.drawLine(a, c, i % 5 == 0 ? major : minor);
    }
    var j = (west / step).floor();
    for (var lon = j * step; lon <= east; lon += step, j++) {
      final a = camera.latLngToScreenOffset(LatLng(south, lon));
      final c = camera.latLngToScreenOffset(LatLng(north, lon));
      canvas.drawLine(a, c, j % 5 == 0 ? major : minor);
    }
  }

  @override
  bool shouldRepaint(GridPainter old) =>
      old.camera.center != camera.center ||
      old.camera.zoom != camera.zoom ||
      old.camera.rotation != camera.rotation ||
      old.color != color ||
      old.camera.size != camera.size;
}
