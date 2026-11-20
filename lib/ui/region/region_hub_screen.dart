// What is left of the old Region tab (its thirteen tabs moved into the Network tab's five sections in build 71, AZ-3.1:
// lib/ui/shell/network_tab.dart, lib/ui/network/network_sections.dart): the machine-derived outline note under the title.
import 'package:flutter/material.dart';

/// A quiet line under the title of a region whose outline the server drew by machine (`machine_derived`): the border
/// is approximate until a person reviews it. Nothing here changes how the app treats the region.
class MachineDerivedNote extends StatelessWidget {
  final String regionName;
  const MachineDerivedNote({super.key, required this.regionName});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      key: const Key('region-machine-derived-note'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_fix_normal_outlined, size: 14, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Machine-derived outline: the border of $regionName was drawn automatically from open map data and node '
            'positions and has not been reviewed yet, so it is approximate near the edge.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
          ),
        ),
      ]),
    );
  }
}
