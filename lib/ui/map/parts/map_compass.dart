// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'dart:math' as math;

import 'package:flutter/material.dart';

class MapCompass extends StatelessWidget {
  final double rotation;
  final VoidCallback onPressed;
  const MapCompass({super.key, required this.rotation, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final northUp = rotation.abs() < 0.5;
    return FloatingActionButton.small(
      key: const Key('map-compass'),
      heroTag: null,
      tooltip: northUp ? 'North up' : 'Turn map north up',
      onPressed: onPressed,
      child: Transform.rotate(
        angle: rotation * math.pi / 180,
        child: Icon(Icons.navigation_rounded, color: northUp ? t.colorScheme.onSurface : t.colorScheme.error),
      ),
    );
  }
}
