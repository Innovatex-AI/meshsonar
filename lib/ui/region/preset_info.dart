// Honest radio-preset states for a region: where a preset's numbers come from, and what to say when a region has none.
// The app never fills a missing preset with another region's (the US one in particular) and never writes to the radio.
import 'package:flutter/material.dart';

import '../../core/api.dart';

/// "Published by MeshCore" / "Community-observed" and the stored note, or null when the server gave no provenance.
String? presetProvenanceText(RadioPreset p) {
  final basis = switch (p.basis) {
    'published' => 'Published in the MeshCore preset list',
    'community-observed' => 'Observed from the community radios on the open analyzers',
    final String b => b,
    null => null,
  };
  if (basis == null && p.note == null) return null;
  return [if (basis != null) '$basis.', if (p.note != null) p.note!].join(' ');
}

/// The explanation shown where a preset would be, for a region with none on file. [none] is the server's stored reason
/// (shown as written) or null when the server has not sent one; either way the page says so instead of guessing.
class NoPresetNote extends StatelessWidget {
  final String regionName;
  final PresetNone? none;
  const NoPresetNote({super.key, required this.regionName, required this.none});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final style = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Column(
      key: const Key('no-preset-note'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$regionName has no radio preset on file.', style: t.textTheme.bodyMedium),
        const SizedBox(height: 4),
        if (none != null) ...[
          Text(none!.reason, key: const Key('no-preset-reason'), style: style),
          if (none!.source != null) Text('Evidence: ${none!.source}', key: const Key('no-preset-source'), style: style),
        ] else
          Text('The server has not said why.', key: const Key('no-preset-no-reason'), style: style),
        const SizedBox(height: 4),
        Text('MeshSonar does not guess one and does not show another region\'s in its place. Ask your local mesh community which settings they use.',
            style: style),
      ],
    );
  }
}
