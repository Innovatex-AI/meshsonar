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
          color: mc.beacon,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: dense ? 4 : 7, vertical: dense ? 1 : 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.science_rounded, size: dense ? 10 : 13, color: mc.onBeacon),
              SizedBox(width: dense ? 2 : 4),
              Flexible(
                child: Text(
                  'SIMULATED GPS & RADIO',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelSmall?.copyWith(
                    color: mc.onBeacon,
                    fontSize: dense ? 9 : 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
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
