// A flutter_map child that draws a [ClusterIndex] with ONE CustomPainter: only what is in the viewport (the index's
// viewport query), clusters or single points depending on zoom, singles batched per colour with drawPoints, cluster
// counts from a small TextPainter cache. No widget per point, so 20k points cost what the ~100 visible items cost.
// It hit-tests itself: a tap on a point or cluster is absorbed and reported; a tap anywhere else falls through to the
// map (and to layers below). Design: stream-1-maps.md section 4.4.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/cluster_index.dart';

/// Extra margin (screen px) queried around the viewport so items entering during a pan are already drawn.
const double kClusterViewportMarginPx = 40;

/// Below this zoom single points are drawn small, without the halo or the room-server ring, and a tap on one zooms in
/// instead of opening a sheet (level of detail for the whole-world view).
const double kClusterDetailZoom = 5;

class ClusteredPointsLayer extends StatelessWidget {
  final ClusterIndex index;

  /// Per point: 3 = room server (drawn as a ring), anything else a filled dot. Null = all dots.
  final Uint8List? kind;

  /// Colour per band (index = band); bands past the end use the last colour.
  final List<Color> bandColors;

  /// Outline around dots and clusters, so they read on any basemap (usually the surface colour).
  final Color haloColor;

  /// Count text on clusters.
  final Color labelColor;

  /// Point to draw highlighted (selected), or null.
  final int? selectedPoint;
  final Color? selectedColor;

  /// Called for a tap on a point or a cluster.
  final ValueChanged<ClusterTap>? onTap;

  final double singleRadiusPx;
  final double tapRadiusPx;

  /// Key prefix for the paint surface (`<layerKey>-paint`), so tests and hosts can find the layer.
  final String layerKey;

  const ClusteredPointsLayer({
    super.key,
    required this.index,
    required this.bandColors,
    required this.haloColor,
    required this.labelColor,
    required this.layerKey,
    this.kind,
    this.selectedPoint,
    this.selectedColor,
    this.onTap,
    this.singleRadiusPx = 5,
    this.tapRadiusPx = 22,
  });

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final slice = visibleSlice(index, camera);
    final painter = ClusteredPointsPainter(
      index: index,
      slice: slice,
      camera: camera,
      kind: kind,
      bandColors: bandColors,
      haloColor: haloColor,
      labelColor: labelColor,
      selectedPoint: selectedPoint,
      selectedColor: selectedColor ?? labelColor,
      singleRadiusPx: singleRadiusPx,
      tapRadiusPx: tapRadiusPx,
    );
    return MobileLayerTransformer(
      child: GestureDetector(
        behavior: HitTestBehavior.deferToChild,
        onTapUp: onTap == null
            ? null
            : (d) {
                final hit = painter.tapAt(d.localPosition);
                if (hit != null) onTap!(hit);
              },
        child: CustomPaint(key: ValueKey('$layerKey-paint'), painter: painter, size: camera.size, isComplex: true),
      ),
    );
  }
}

/// The items to draw for [camera]'s viewport (plus [kClusterViewportMarginPx]).
ClusterSlice visibleSlice(ClusterIndex index, MapCamera camera) {
  final scale = worldPixels(camera.zoom);
  final o = camera.pixelOrigin;
  final size = camera.size;
  const m = kClusterViewportMarginPx;
  return index.query(
    (o.dx - m) / scale,
    (o.dy - m) / scale,
    (o.dx + size.width + m) / scale,
    (o.dy + size.height + m) / scale,
    camera.zoom,
  );
}

/// Hit test from a map-level tap (`MapOptions.onTap` gives the LatLng): the same rule the layer's own tap uses. For
/// hosts that walk layers top-down instead of letting each layer catch its own taps.
ClusterTap? clusterTapAt(ClusterIndex index, MapCamera camera, LatLng p, {double tapRadiusPx = 22, double singleRadiusPx = 5}) =>
    _lod(index.hitTest(mercatorX(p.longitude), mercatorY(p.latitude), camera.zoom, radiusPx: tapRadiusPx, singleRadiusPx: singleRadiusPx), index, camera.zoom);

/// Below [kClusterDetailZoom] a single is not opened: it is reported as a one-member cluster (zoom in).
ClusterTap? _lod(ClusterTap? t, ClusterIndex index, double zoom) {
  if (t == null || zoom >= kClusterDetailZoom || t.isCluster) return t;
  return ClusterTap(id: t.id, count: 1, point: null, lat: t.lat, lon: t.lon, bounds: t.bounds, colocated: t.colocated.isEmpty ? [t.point!] : t.colocated);
}

/// The camera move for a tap on a cluster: fit its members with [padding], or (members on one spot, or a single at
/// low zoom) centre on it two zoom levels closer. Capped at [maxZoom].
CameraFit cameraFitForCluster(ClusterTap t, MapCamera camera, {EdgeInsets padding = const EdgeInsets.all(48), double maxZoom = 18}) {
  final b = t.bounds;
  final degenerate = (b.north - b.south).abs() < 1e-6 && (b.east - b.west).abs() < 1e-6;
  if (degenerate) {
    final z = math.min(maxZoom, math.max(camera.zoom + 2, kClusterDetailZoom));
    return CameraFit.coordinates(coordinates: [LatLng(t.lat, t.lon)], maxZoom: z, minZoom: z);
  }
  return CameraFit.bounds(
    bounds: LatLngBounds(LatLng(b.south, b.west), LatLng(b.north, b.east)),
    padding: padding,
    maxZoom: maxZoom,
  );
}

/// Ink for a cluster count on [fill]: whichever of near-black and white has the higher contrast ratio (WCAG). Every
/// band colour of both themes gets at least 4.5:1 this way (asserted by tests).
Color clusterLabelInk(Color fill) {
  const dark = Color(0xFF1B1F24), light = Color(0xFFFFFFFF);
  return contrastRatio(dark, fill) >= contrastRatio(light, fill) ? dark : light;
}

/// WCAG contrast ratio of two opaque colours (1..21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = math.max(la, lb), lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// Count text size: 13 px, 15 px from 100 members (the bubble is then at its largest).
double clusterFontSize(int count) => count >= 100 ? 15 : 13;

/// The drawn bubble radius: the size-by-count radius, grown if needed so the count text has 5 px of fill around it.
double clusterBubbleRadius(int count, double labelWidth, {double singleRadiusPx = 5}) =>
    math.max(clusterRadiusPx(count, singleRadiusPx: singleRadiusPx), labelWidth / 2 + 5);

/// What a screen reader says for a cluster: "1,234 repeaters".
String clusterSemanticsLabel(int count) {
  final s = '$count';
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '$b repeaters';
}

class ClusteredPointsPainter extends CustomPainter {
  final ClusterIndex index;
  final ClusterSlice slice;
  final MapCamera camera;
  final Uint8List? kind;
  final List<Color> bandColors;
  final Color haloColor, labelColor, selectedColor;
  final int? selectedPoint;
  final double singleRadiusPx, tapRadiusPx;

  ClusteredPointsPainter({
    required this.index,
    required this.slice,
    required this.camera,
    required this.kind,
    required this.bandColors,
    required this.haloColor,
    required this.labelColor,
    required this.selectedColor,
    required this.selectedPoint,
    required this.singleRadiusPx,
    required this.tapRadiusPx,
  });

  double get _scale => worldPixels(camera.zoom);

  /// Where item [k] of the slice is on this painter's canvas.
  Offset offsetOf(int k) {
    final s = _scale, o = camera.pixelOrigin;
    return Offset(slice.x[k] * s - o.dx, slice.y[k] * s - o.dy);
  }

  /// Number of items painted on the last frame, singles and clusters (for tests and profiling).
  int debugSingles = 0, debugClusters = 0;

  Color _band(int b) => bandColors.isEmpty ? labelColor : bandColors[b < bandColors.length ? b : bandColors.length - 1];

  /// The tap at [local] (canvas coordinates), or null.
  ClusterTap? tapAt(Offset local) {
    final s = _scale, o = camera.pixelOrigin;
    final x = (o.dx + local.dx) / s, y = (o.dy + local.dy) / s;
    return _lod(index.hitTest(x, y, camera.zoom, radiusPx: tapRadiusPx, singleRadiusPx: singleRadiusPx), index, camera.zoom);
  }

  @override
  bool? hitTest(Offset position) => tapAt(position) != null;

  @override
  void paint(Canvas canvas, Size size) {
    final detail = camera.zoom >= kClusterDetailZoom;
    final r = detail ? singleRadiusPx : math.max(2.5, singleRadiusPx * 0.6);
    final byBand = <int, List<Offset>>{};
    final rooms = <Offset>[];
    final all = <Offset>[];
    Offset? selected;
    final clusters = <int>[];
    for (var k = 0; k < slice.length; k++) {
      if (slice.count[k] > 1) {
        clusters.add(k);
        continue;
      }
      final p = offsetOf(k);
      all.add(p);
      (byBand[slice.band[k]] ??= <Offset>[]).add(p);
      final pi = slice.point[k];
      if (detail && kind != null && pi >= 0 && kind![pi] == 3) rooms.add(p);
      if (pi >= 0 && pi == selectedPoint) selected = p;
    }
    debugSingles = all.length;
    debugClusters = clusters.length;
    if (all.isNotEmpty) {
      if (detail) {
        canvas.drawPoints(
          ui.PointMode.points,
          all,
          Paint()
            ..color = haloColor
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 2 * (r + 1.5),
        );
      }
      final keys = byBand.keys.toList()..sort();
      for (final b in keys) {
        canvas.drawPoints(
          ui.PointMode.points,
          byBand[b]!,
          Paint()
            ..color = _band(b)
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 2 * r,
        );
      }
      if (rooms.isNotEmpty) {
        canvas.drawPoints(
          ui.PointMode.points,
          rooms,
          Paint()
            ..color = haloColor
            ..strokeCap = StrokeCap.round
            ..strokeWidth = 2 * (r - 2),
        );
      }
    }
    if (selected != null) {
      canvas.drawCircle(
        selected,
        r + 5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = selectedColor,
      );
    }
    for (final k in clusters) {
      final c = offsetOf(k);
      final n = slice.count[k];
      final col = _band(slice.band[k]);
      final tp = _label(clusterLabel(n), clusterLabelInk(col), clusterFontSize(n));
      final rad = clusterBubbleRadius(n, tp.width, singleRadiusPx: singleRadiusPx);
      canvas.drawCircle(c, rad + 2, Paint()..color = haloColor);
      // Opaque fill: the count's contrast is then exactly the ink-on-fill ratio, whatever the basemap below.
      canvas.drawCircle(c, rad, Paint()..color = col.withValues(alpha: 1));
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
    }
  }

  /// One semantics node per visible cluster ("1,234 repeaters"), so the counts are read out and testable.
  @override
  SemanticsBuilderCallback get semanticsBuilder => (size) {
    final out = <CustomPainterSemantics>[];
    for (var k = 0; k < slice.length; k++) {
      final n = slice.count[k];
      if (n <= 1) continue;
      final c = offsetOf(k);
      final rad = clusterRadiusPx(n, singleRadiusPx: singleRadiusPx) + 2;
      final rect = Rect.fromCircle(center: c, radius: rad);
      if (!rect.overlaps(Offset.zero & size)) continue;
      out.add(
        CustomPainterSemantics(
          key: ValueKey('cluster-${slice.level}-${slice.cluster[k]}'),
          rect: rect,
          properties: SemanticsProperties(label: clusterSemanticsLabel(n), textDirection: TextDirection.ltr, button: true),
        ),
      );
    }
    return out;
  };

  @override
  bool shouldRebuildSemantics(ClusteredPointsPainter oldDelegate) => !identical(oldDelegate.slice, slice) || oldDelegate.camera != camera;

  static final Map<String, TextPainter> _labels = {};

  /// A laid-out count label, cached by text and colour (visible clusters are bounded by the viewport, so this stays
  /// small; it is cleared past 256 entries).
  static TextPainter _label(String text, Color color, double fontSize) {
    final key = '$text|${color.toARGB32()}|$fontSize';
    final hit = _labels[key];
    if (hit != null) return hit;
    if (_labels.length > 256) _labels.clear();
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize, fontWeight: FontWeight.w800, height: 1),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    return _labels[key] = tp;
  }

  @override
  bool shouldRepaint(ClusteredPointsPainter old) =>
      !identical(old.slice, slice) ||
      old.camera != camera ||
      !identical(old.index, index) ||
      old.selectedPoint != selectedPoint ||
      old.haloColor != haloColor ||
      old.labelColor != labelColor ||
      !_sameColors(old.bandColors, bandColors);

  static bool _sameColors(List<Color> a, List<Color> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
