// PingDotsLayer (build 77, Round 1 F12): the drive's ping dots in ONE paint pass. Until build 76 every ping was its own Marker
// with a GestureDetector and a PingDot widget, uncapped: a long drive built thousands of widgets on the map. Now one painter
// draws every dot in view, the newest one keeps its one-shot ring (a single widget, and no ring under Reduce Motion: F11),
// and the nearest [kPingProxyCount] dots to the middle of the view get an invisible 40 pt tap and VoiceOver proxy (keys
// 'map-ping-tap-<id>' and 'map-ping-<id>'), so screen readers and tests reach them without one widget per ping.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/model.dart' show DrivePing;
import '../../../core/time_format.dart' as tf;

/// Hit radius of a ping dot (a 40 pt target, as the old marker was).
const double kPingTapRadius = 20;

/// The dots nearest the middle of the view that get a tap and screen-reader proxy.
const int kPingProxyCount = 20;

class PingDotsLayer extends StatelessWidget {
  /// Oldest first (the newest is painted on top).
  final List<DrivePing> pings;
  final Color Function(DrivePing p) colorOf;
  final Color ring;

  /// The newest ping's id: it gets the one-shot ring when it lands.
  final String? latestId;
  final ValueChanged<DrivePing> onTap;
  const PingDotsLayer({super.key, required this.pings, required this.colorOf, required this.ring, required this.onTap, this.latestId});

  /// Tests and profiling: the dots the last paint drew (id -> centre in the layer, colour), and how many paint passes ran.
  @visibleForTesting
  static final Map<String, (Offset, Color)> debugPainted = {};
  @visibleForTesting
  static int debugPaints = 0;

  /// Tests: the colour the last paint gave the dot of [id] (null when it was not drawn).
  @visibleForTesting
  static Color? debugColorOf(String id) => debugPainted[id]?.$2;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final size = camera.size;
    final view = (Offset.zero & size).inflate(24);
    final origin = camera.pixelOrigin;
    final at = <Offset>[];
    final drawn = <DrivePing>[];
    final colors = <Color>[];
    for (final p in pings) {
      final o = camera.projectAtZoom(LatLng(p.lat, p.lon)) - origin;
      if (!view.contains(o)) continue;
      at.add(o);
      drawn.add(p);
      colors.add(colorOf(p));
    }
    if (drawn.isEmpty) return const SizedBox.shrink();
    final painter = _PingDotsPainter(at: at, colors: colors, ring: ring, ids: [for (final p in drawn) p.id]);
    // The proxies: the dots nearest the middle of the view.
    final mid = size.center(Offset.zero);
    final order = List<int>.generate(drawn.length, (i) => i)..sort((a, b) => (at[a] - mid).distanceSquared.compareTo((at[b] - mid).distanceSquared));
    final proxies = order.take(kPingProxyCount).toList();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final latest = latestId == null ? -1 : drawn.lastIndexWhere((p) => p.id == latestId);
    return MobileLayerTransformer(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.deferToChild,
              onTapUp: (d) {
                final i = painter.pickAt(d.localPosition);
                if (i != null) onTap(drawn[i]);
              },
              child: CustomPaint(key: const Key('map-ping-dots'), painter: painter, size: size),
            ),
          ),
          // The newest ping's ring (one widget; none under Reduce Motion, where the dot simply appears).
          if (latest >= 0 && !reduceMotion)
            Positioned(
              left: at[latest].dx - 20,
              top: at[latest].dy - 20,
              width: 40,
              height: 40,
              child: IgnorePointer(child: _LandingRing(key: ValueKey('map-ping-ring-${drawn[latest].id}'), color: colors[latest])),
            ),
          for (final i in proxies)
            Positioned(
              left: at[i].dx - kPingTapRadius,
              top: at[i].dy - kPingTapRadius,
              width: kPingTapRadius * 2,
              height: kPingTapRadius * 2,
              child: GestureDetector(
                key: ValueKey('map-ping-tap-${drawn[i].id}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onTap(drawn[i]),
                child: Semantics(
                  button: true,
                  label: 'Ping at ${tf.timeOfDay(drawn[i].ts)}',
                  child: SizedBox.expand(key: ValueKey('map-ping-${drawn[i].id}')),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _PingDotsPainter extends CustomPainter {
  final List<Offset> at;
  final List<Color> colors;
  final List<String> ids;
  final Color ring;
  _PingDotsPainter({required this.at, required this.colors, required this.ring, required this.ids});

  static const double _r = 7.5; // a 15 pt dot with a 2 pt ring, as before

  @override
  void paint(Canvas canvas, Size size) {
    PingDotsLayer.debugPaints++;
    PingDotsLayer.debugPainted.clear();
    final fill = Paint();
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = ring;
    for (var i = 0; i < at.length; i++) {
      fill.color = colors[i];
      canvas.drawCircle(at[i], _r, fill);
      canvas.drawCircle(at[i], _r - 1, stroke);
      PingDotsLayer.debugPainted[ids[i]] = (at[i], colors[i]);
    }
  }

  /// The topmost dot within the tap radius of [p].
  int? pickAt(Offset p) {
    int? best;
    var bestD = double.infinity;
    for (var i = at.length - 1; i >= 0; i--) {
      final d = (at[i] - p).distance;
      if (d <= kPingTapRadius && d < bestD - 0.5) {
        best = i;
        bestD = d;
      }
    }
    return best;
  }

  @override
  bool? hitTest(Offset position) => pickAt(position) != null;

  @override
  bool shouldRepaint(_PingDotsPainter old) => !listEquals(old.at, at) || !listEquals(old.colors, colors) || old.ring != ring;
}

/// One expanding ring when a ping lands (not repeating, so the map is calm between pings).
class _LandingRing extends StatelessWidget {
  final Color color;
  const _LandingRing({super.key, required this.color});

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 1400),
    curve: Curves.easeOutCubic,
    builder: (context, v, _) => v >= 1
        ? const SizedBox.shrink()
        : Center(
            child: Container(
              width: 15 + 25 * v,
              height: 15 + 25 * v,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: color.withValues(alpha: math.max(0, 1 - v)), width: 2.5)),
            ),
          ),
  );
}
