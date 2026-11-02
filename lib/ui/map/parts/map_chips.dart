// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'package:flutter/material.dart';

import '../../theme.dart';

/// A small text pill drawn on the map (distance on a link, a heard repeater's name).
class MapTag extends StatelessWidget {
  final String text;
  final Color color;
  final bool strong;
  const MapTag({super.key, required this.text, required this.color, this.strong = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: strong ? 0.9 : 0.5), width: strong ? 1.4 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: numberStyle(
            context,
            size: 12.5,
            weight: FontWeight.w600,
            color: strong ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class MapPill extends StatelessWidget {
  final Widget child;
  const MapPill({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), child: child),
    );
  }
}
