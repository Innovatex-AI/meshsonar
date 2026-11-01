// Non-blocking warning on the Map tab while driving: the last few pings heard no repeater. Display only; it reads the
// drive's pings and never touches the radio or the ping cadence.
import 'package:flutter/material.dart';

class DeadAreaChip extends StatelessWidget {
  final int streak;
  const DeadAreaChip({super.key, required this.streak});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const Key('dead-area-chip'),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: c.errorContainer, borderRadius: BorderRadius.circular(16)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.signal_cellular_nodata_rounded, size: 16, color: c.onErrorContainer),
          const SizedBox(width: 6),
          Flexible(
            child: Text('No repeaters heard for $streak pings',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.labelMedium?.copyWith(color: c.onErrorContainer)),
          ),
        ]),
      ),
    );
  }
}
