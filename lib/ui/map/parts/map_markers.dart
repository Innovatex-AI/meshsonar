// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme.dart';
import '../map_layers.dart' show HeardPhase;

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

/// A repeater beacon. [phase] null = not heard this drive (dim amber); fresh = pops up and glows; holding = lit,
/// no glow; stale = greyed out. [heardAt] changes every time it's heard again, which replays the pop-up.
class RepeaterMarker extends StatelessWidget {
  final String repeaterKey;

  /// Spoken by VoiceOver (the written name is on the map as a label).
  final String name;
  final Color color;
  final Color onColor;
  final Color greyColor;
  final HeardPhase? phase;
  final int? heardAt;
  final bool selected;
  final VoidCallback onTap;
  const RepeaterMarker({
    super.key,
    required this.repeaterKey,
    required this.name,
    required this.color,
    required this.onColor,
    required this.greyColor,
    required this.phase,
    required this.heardAt,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final fresh = phase == HeardPhase.fresh;
    final holding = phase == HeardPhase.holding;
    final stale = phase == HeardPhase.stale;
    final big = fresh || holding || selected;
    final size = fresh ? 32.0 : (big ? 28.0 : 22.0);
    final Color fill = stale
        ? Color.alphaBlend(greyColor.withValues(alpha: 0.55), surface)
        : (big ? color : Color.alphaBlend(color.withValues(alpha: 0.7), Colors.black));
    final diamond = Transform.rotate(
      angle: math.pi / 4,
      child: Container(
        key: ValueKey('map-repeater-state-$repeaterKey-${phase?.name ?? 'idle'}'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? Theme.of(context).colorScheme.onSurface : surface, width: 2),
          boxShadow: fresh
              ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 16, spreadRadius: 2)]
              : (holding ? [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 8)] : null),
        ),
        child: Transform.rotate(
          angle: -math.pi / 4,
          child: Icon(Icons.cell_tower_rounded, size: big ? 18 : 13, color: stale ? surface : onColor),
        ),
      ),
    );
    Widget child = Center(child: diamond);
    if (fresh) {
      // Pop up and send one ring out each time it's heard.
      child = TweenAnimationBuilder<double>(
        key: ValueKey('pop-$heardAt'),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1100),
        builder: (context, v, d) {
          final scale = v < 0.35 ? 0.6 + 0.75 * Curves.easeOut.transform(v / 0.35) : 1.35 - 0.35 * Curves.easeInOut.transform((v - 0.35) / 0.65);
          return Stack(
            alignment: Alignment.center,
            children: [
              if (v < 1)
                Container(
                  width: 30 + 26 * v,
                  height: 30 + 26 * v,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: (1 - v) * 0.9), width: 2.5),
                  ),
                ),
              Transform.scale(scale: scale, child: d),
            ],
          );
        },
        child: diamond,
      );
    }
    return Semantics(
      button: true,
      label: name.isEmpty ? 'Repeater ${repeaterKey.substring(0, math.min(4, repeaterKey.length))}' : 'Repeater $name',
      hint: 'Shows repeater details',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
    );
  }
}

class RepeaterLabel extends StatelessWidget {
  final String name;
  final String keyHex;
  final String? detail;
  final Color color;
  final VoidCallback onTap;
  const RepeaterLabel({super.key, required this.name, required this.keyHex, this.detail, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final box = Container(
      key: const Key('map-repeater-label'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(Corners.small),
        border: Border.all(color: color, width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
          Text(
            detail == null ? keyHex.substring(0, math.min(8, keyHex.length)) : '${keyHex.substring(0, math.min(4, keyHex.length))} · $detail',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.textTheme.labelSmall,
          ),
        ],
      ),
    );
    return Semantics(
      button: true,
      label: detail == null ? name : '$name, $detail',
      hint: 'Shows repeater details',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(onTap: onTap, child: box),
    );
  }
}
