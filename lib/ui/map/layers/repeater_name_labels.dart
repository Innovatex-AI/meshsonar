// Repeater name labels: the name beside each repeater marker, so nobody has to tap a marker to find out what it is.
//
// One painter for every repeater the map draws (the heard/known diamonds, the region roster dots, the global network
// dots), so labels from different layers avoid each other. Rules, all pure in [placeRepeaterLabels] (unit tested):
//   - Zoom-dependent: nothing below [kLabelMinZoomHeard]; repeaters heard this drive from there, everyone else from
//     [kLabelMinZoom]; a per-zoom budget ([labelBudgetForZoom]) caps the count, so zooming out thins labels out
//     instead of piling them up.
//   - Priority: heard this drive first, then the nearest to you (or to the map centre when there is no fix).
//   - Collision-avoided: a label goes to the right of its marker, else left, above, below; it is dropped when none fits
//     without covering another marker, another label, a cluster bubble, an overlay ([avoid]) or the map edge.
//   - Contrast: ink in onSurface with a surface-coloured halo, in light and dark. Text follows Dynamic Type (capped at
//     1.6x so a label never swallows the map) and is cut with an ellipsis at [kLabelMaxWidth] px.
// The painter has no semantics: every marker already speaks its own name to VoiceOver (see _RepeaterMarker).
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/cluster_index.dart' show clusterRadiusPx, latFromMercatorY, lonFromMercatorX;
import 'clustered_points_layer.dart' show visibleSlice;
import 'repeater_map_source.dart';

/// Below this zoom no label is drawn at all.
const double kLabelMinZoomHeard = 9;

/// Repeaters not heard this drive get a label from this zoom.
const double kLabelMinZoom = 11;

/// Longest a label gets before the ellipsis (logical px, before Dynamic Type).
const double kLabelMaxWidth = 150;

/// Most labels drawn at [zoom] (heard ones count first).
int labelBudgetForZoom(double zoom) {
  if (zoom < kLabelMinZoomHeard) return 0;
  if (zoom < kLabelMinZoom) return 8;
  if (zoom < 12) return 14;
  if (zoom < 13) return 24;
  if (zoom < 14) return 36;
  return 60;
}

/// One repeater the placer knows about. Candidates with [label] false are not labelled (the selected repeater has its
/// own card, a live-heard one its own tag) but still block other labels.
class LabelCandidate {
  final String id;
  final String text;

  /// Marker centre on screen.
  final Offset anchor;

  /// Half the marker's footprint.
  final double markerRadius;

  /// 0 = heard this drive, 1 = everyone else (lower is placed first).
  final int priority;

  /// Screen distance to "here" (ties inside a priority are broken by it).
  final double distance;
  final bool label;
  const LabelCandidate({
    required this.id,
    required this.text,
    required this.anchor,
    required this.markerRadius,
    required this.priority,
    required this.distance,
    this.label = true,
  });
}

/// A label that fits.
class PlacedLabel {
  final LabelCandidate candidate;

  /// Where the text box goes (halo padding included).
  final Rect rect;
  const PlacedLabel(this.candidate, this.rect);
}

/// Greedy collision-avoided placement. [measure] gives a label's size (padding included). [obstacles] are rectangles
/// no label may touch (cluster bubbles, tags, overlays). Pure: same input, same output.
List<PlacedLabel> placeRepeaterLabels({
  required List<LabelCandidate> candidates,
  required Size Function(String text) measure,
  required Rect bounds,
  List<Rect> obstacles = const [],
  required int budget,
  double gap = 3,
}) {
  if (budget <= 0) return const [];
  final order = [for (final c in candidates) if (c.label) c]
    ..sort((a, b) {
      final p = a.priority.compareTo(b.priority);
      if (p != 0) return p;
      final d = a.distance.compareTo(b.distance);
      return d != 0 ? d : a.id.compareTo(b.id);
    });
  Rect markerRect(LabelCandidate c) => Rect.fromCircle(center: c.anchor, radius: c.markerRadius);
  final markers = {for (final c in candidates) c.id: markerRect(c)};
  final placed = <PlacedLabel>[];
  for (final c in order) {
    if (placed.length >= budget) break;
    final s = measure(c.text);
    final a = c.anchor, r = c.markerRadius + gap;
    final tries = [
      Rect.fromLTWH(a.dx + r, a.dy - s.height / 2, s.width, s.height), // right
      Rect.fromLTWH(a.dx - r - s.width, a.dy - s.height / 2, s.width, s.height), // left
      Rect.fromLTWH(a.dx - s.width / 2, a.dy - r - s.height, s.width, s.height), // above
      Rect.fromLTWH(a.dx - s.width / 2, a.dy + r, s.width, s.height), // below
    ];
    for (final box in tries) {
      if (box.left < bounds.left || box.right > bounds.right || box.top < bounds.top || box.bottom > bounds.bottom) continue;
      if (obstacles.any((o) => o.overlaps(box))) continue;
      if (markers.entries.any((m) => m.key != c.id && m.value.overlaps(box))) continue;
      if (placed.any((p) => p.rect.overlaps(box))) continue;
      placed.add(PlacedLabel(c, box));
      break;
    }
  }
  return placed;
}

/// Everything the layer needs to find the repeaters of the "heard / known" diamonds.
class MarkerLabelInput {
  final String key;
  final String name;
  final LatLng point;

  /// Heard this drive (any phase): placed first.
  final bool heard;

  /// Drawn with its own tag (live heard) or its own card (selected): blocks, never labelled.
  final bool ownTag;
  const MarkerLabelInput({required this.key, required this.name, required this.point, this.heard = false, this.ownTag = false});
}

/// The flutter_map child. Reads the camera, so it re-places on every pan and zoom (a few hundred candidates at most).
class RepeaterNameLabels extends StatelessWidget {
  /// The diamonds (known + heard repeaters).
  final List<MarkerLabelInput> markers;

  /// The clustered layers that are on, in priority order (roster before network).
  final List<(RepeaterMapSource source, String layerId)> clustered;

  /// Spots the map writes its own small tags on (link distances, range-ring captions): names keep clear of them.
  final List<LatLng> blockers;

  /// Key of the selected repeater (its own card shows the name), or null.
  final String? selectedKey;

  /// "Here" for the nearest-first rule; null = the map centre.
  final LatLng? origin;

  /// Screen rectangles (map coordinates) labels must stay out of: overlays drawn by the parent (heard box, buttons).
  final List<Rect> Function(Size mapSize)? avoid;

  /// Extra margin at the map edges labels must keep clear of.
  final EdgeInsets inset;

  const RepeaterNameLabels({
    super.key,
    required this.markers,
    required this.clustered,
    this.blockers = const [],
    this.selectedKey,
    this.origin,
    this.avoid,
    this.inset = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (camera.zoom < kLabelMinZoomHeard) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    final here = camera.latLngToScreenOffset(origin ?? camera.center);
    double dist(Offset o) => (o - here).distance;

    final size = camera.size;
    final onScreen = Offset.zero & size;
    final inView = onScreen.inflate(24);
    final cands = <LabelCandidate>[];
    final obstacles = <Rect>[...?avoid?.call(size)];
    final seen = <String>{};
    for (final b in blockers) {
      final o = camera.latLngToScreenOffset(b);
      if (inView.contains(o)) obstacles.add(Rect.fromCenter(center: o, width: 84, height: 26));
    }

    // Heard-live repeaters carry a tag (name + SNR) 17-40 px below the marker: keep labels off it.
    for (final m in markers) {
      final o = camera.latLngToScreenOffset(m.point);
      if (!inView.contains(o) || !seen.add(m.key)) continue;
      // A marker just off screen still blocks, but its name is not written (no name without its marker).
      final ownTag = m.ownTag || m.key == selectedKey || !onScreen.contains(o);
      if (m.ownTag && m.key != selectedKey) obstacles.add(Rect.fromLTRB(o.dx - 62, o.dy + 15, o.dx + 62, o.dy + 43));
      cands.add(LabelCandidate(
        id: m.key,
        text: m.name,
        anchor: o,
        markerRadius: m.heard ? 17 : 13,
        priority: m.heard ? 0 : 1,
        distance: dist(o),
        label: !ownTag,
      ));
    }
    if (camera.zoom >= kLabelMinZoom) {
      for (final (source, layerId) in clustered) {
        final index = source.indexOf(layerId);
        if (index == null || index.indexedCount == 0) continue;
        final pts = source.pointsOf(layerId);
        final slice = visibleSlice(index, camera);
        for (var k = 0; k < slice.length; k++) {
          final pi = slice.point[k];
          if (slice.count[k] > 1 || pi < 0) {
            // A cluster bubble: not a label, but a thing labels must not cover.
            final o = camera.latLngToScreenOffset(LatLng(latFromMercatorY(slice.y[k]), lonFromMercatorX(slice.x[k])));
            if (inView.contains(o)) {
              final rad = clusterRadiusPx(slice.count[k]) + 3;
              obstacles.add(Rect.fromCircle(center: o, radius: rad));
            }
            continue;
          }
          final key = pts.key[pi];
          final o = camera.latLngToScreenOffset(LatLng(pts.lat[pi], pts.lon[pi]));
          if (!inView.contains(o) || !seen.add(key)) continue;
          cands.add(LabelCandidate(
            id: key,
            text: pts.name[pi],
            anchor: o,
            markerRadius: key == selectedKey ? 11 : 8,
            priority: 1,
            distance: dist(o),
            label: key != selectedKey && onScreen.contains(o),
          ));
        }
      }
    }
    if (cands.isEmpty) return const SizedBox.shrink();

    final style = _LabelPainter.styleFor(scheme.onSurface, scaler);
    final bounds = Rect.fromLTRB(inset.left + 4, inset.top + 4, size.width - inset.right - 4, size.height - inset.bottom - 4);
    final placed = placeRepeaterLabels(
      candidates: cands,
      measure: (t) {
        final tp = _LabelPainter.layoutText(t, style, scaler);
        return Size(tp.width + 6, tp.height + 2);
      },
      bounds: bounds,
      obstacles: obstacles,
      budget: labelBudgetForZoom(camera.zoom),
    );
    if (placed.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: ExcludeSemantics(
        child: CustomPaint(
          key: const ValueKey('repeater-name-labels-paint'),
          painter: _LabelPainter(placed: placed, ink: scheme.onSurface, halo: scheme.surface, scaler: scaler),
          size: size,
        ),
      ),
    );
  }
}

class _LabelPainter extends CustomPainter {
  final List<PlacedLabel> placed;
  final Color ink, halo;
  final TextScaler scaler;
  _LabelPainter({required this.placed, required this.ink, required this.halo, required this.scaler});

  static TextStyle styleFor(Color ink, TextScaler scaler) => TextStyle(color: ink, fontSize: 12, fontWeight: FontWeight.w600, height: 1.15);

  static final Map<String, TextPainter> _cache = {};

  static TextPainter layoutText(String text, TextStyle style, TextScaler scaler, {Paint? foreground}) {
    final key = '$text|${style.color?.toARGB32()}|${foreground?.color.toARGB32()}|${scaler.scale(12)}';
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 400) _cache.clear();
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: foreground == null ? style : style.copyWith(color: null, foreground: foreground),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: kLabelMaxWidth * math.min(scaler.scale(1), 1.3));
    return _cache[key] = tp;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final fill = styleFor(ink, scaler);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.4
      ..strokeJoin = StrokeJoin.round
      ..color = halo.withValues(alpha: 0.95);
    for (final p in placed) {
      final at = p.rect.topLeft + const Offset(3, 1);
      layoutText(p.candidate.text, fill, scaler, foreground: stroke).paint(canvas, at);
      layoutText(p.candidate.text, fill, scaler).paint(canvas, at);
    }
  }

  @override
  bool shouldRepaint(_LabelPainter old) => true;
}
