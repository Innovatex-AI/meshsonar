// Moved unchanged from coverage_map.dart (Drive plan WP2, step 1).
import 'package:flutter/material.dart';

import '../../theme.dart';

/// The small "this isn't real" tag shown on the map and the connection chip in Simulator mode.
class SimulatedTag extends StatelessWidget {
  final bool dense;
  const SimulatedTag({super.key, this.dense = false});
  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    return Tooltip(
      message: 'Simulator mode: the position moves along a demo route and the radio is simulated.',
      child: DecoratedBox(
        decoration: BoxDecoration(
          // Build 76: a quiet outlined tag in plain words; the solid orange capitals read as an alarm.
          color: t.colorScheme.surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: t.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: dense ? 4 : 7, vertical: dense ? 1 : 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.science_rounded, size: dense ? 11 : 14, color: mc.textMuted),
              SizedBox(width: dense ? 2 : 4),
              Flexible(
                child: Text(
                  'Simulated drive',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelSmall?.copyWith(
                    color: t.colorScheme.onSurface,
                    fontSize: dense ? 10 : 12,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
