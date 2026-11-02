// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'package:flutter/material.dart';


class PingDot extends StatelessWidget {
  final Key dotKey;
  final Color color;
  final Color ring;
  final bool pulse;
  const PingDot({super.key, required this.dotKey, required this.color, required this.ring, required this.pulse});

  @override
  Widget build(BuildContext context) {
    final dot = DecoratedBox(
      key: dotKey,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 2),
      ),
      child: const SizedBox(width: 15, height: 15),
    );
    if (!pulse) return Center(child: dot);
    // One expanding ring when a ping lands (not repeating, so the map is calm between pings).
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1400),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Stack(
        alignment: Alignment.center,
        children: [
          if (v < 1)
            Container(
              width: 15 + 25 * v,
              height: 15 + 25 * v,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color.withValues(alpha: 1 - v), width: 2.5),
              ),
            ),
          child!,
        ],
      ),
      child: dot,
    );
  }
}

class PositionMarker extends StatelessWidget {
  final Color color;
  final Color ring;
  const PositionMarker({super.key, required this.color, required this.ring});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.18)),
        alignment: Alignment.center,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: ring, width: 3),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6)],
          ),
        ),
      ),
    );
  }
}
