// The two things a person can change about how big a map draws (app-next-pass item 7, Andy Nov 22 2026: "user editable label and
// icon sizes on the maps ... nothing too elaborate"): Label size and Icon size, each Small / Normal / Large (0.85 / 1.0 / 1.25),
// one choice for every map, saved on the device. And Colour nodes by (Map Definition `variables.colourBy`). They sit in the
// Layers sheet; the Live map's panel shows the same rows. The choices live in [MapPrefs.shared]; every map listens to it.
import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';

import '../../core/map_definition_v2.dart';
import '../../core/map_prefs.dart';
import '../design/tokens.dart' show Gap;
import 'active_map_definition.dart';

/// "Label size" and "Icon size" rows.
class MapSizeControls extends StatelessWidget {
  final MapPrefs? prefs;
  const MapSizeControls({super.key, this.prefs});

  @override
  Widget build(BuildContext context) {
    final p = prefs ?? MapPrefs.shared;
    final t = Theme.of(context);
    Widget row(String keyId, String title, MapSizeChoice value, void Function(MapSizeChoice) set) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.xs),
      child: Row(
        children: [
          Expanded(child: Text(title, style: t.textTheme.bodyLarge)),
          CupertinoSlidingSegmentedControl<MapSizeChoice>(
            key: Key('map-$keyId-size'),
            groupValue: value,
            children: {
              for (final c in MapSizeChoice.values)
                c: Padding(padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 6), child: Text(c.label, key: Key('map-$keyId-size-${c.id}'))),
            },
            onValueChanged: (v) {
              if (v != null) set(v);
            },
          ),
        ],
      ),
    );
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => Column(
        key: const Key('map-size-controls'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('label', 'Label size', p.labelSize, (v) => p.labelSize = v),
          row('icon', 'Icon size', p.iconSize, (v) => p.iconSize = v),
        ],
      ),
    );
  }
}

/// "Colour nodes by": Nothing (neutral) / Status / Hash size / Role (options the server marks unavailable are left out).
/// Renders nothing when the definition in use has no `variables.colourBy`.
class ColourByControl extends StatelessWidget {
  final MapPrefs? prefs;
  const ColourByControl({super.key, this.prefs});

  @override
  Widget build(BuildContext context) {
    final def = ActiveMapDefinition.current.colourBy;
    if (def == null) return const SizedBox.shrink();
    final p = prefs ?? MapPrefs.shared;
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) {
        final current = p.colourBy != null && def.pickable.contains(p.colourBy) ? p.colourBy! : def.defaultId;
        return Padding(
          key: const Key('map-colour-by'),
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.s),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Colour nodes by', style: t.textTheme.bodyLarge),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.s,
                children: [
                  for (final o in def.options)
                    if (o.available)
                      ChoiceChip(
                        key: Key('map-colour-by-${o.id}'),
                        label: Text(o.label),
                        selected: current == o.id,
                        onSelected: (_) => p.colourBy = o.id,
                      ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// The colour-by choice in force: the person's, else the definition's default (`none`).
String colourByNow([MapPrefs? prefs]) {
  final def = ActiveMapDefinition.current.colourBy;
  final c = (prefs ?? MapPrefs.shared).colourBy;
  if (def == null) return 'none';
  return c != null && def.pickable.contains(c) ? c : def.defaultId;
}
