// Settings > Units & display: the unit system and how long repeaters stay bright in the heard list.
import 'package:flutter/material.dart';

import '../../core/units.dart';
import '../app.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String displayHelp = 'How numbers and lists look. Nothing stored changes: drives keep metres and m/s, and the '
    'server receives the same data whatever you pick here.';

/// What the Units choice means, including what Auto resolves to on this phone right now. The only wording for it.
String unitsExplanation(UnitsPreference pref, Units now) {
  final current = '${now.isImperial ? 'imperial' : 'metric'} (${now.lengthUnit}, ${now.longDistanceUnit}, ${now.speedUnit})';
  return switch (pref) {
    UnitsPreference.auto => 'Auto follows your phone\'s region: imperial in the US, Liberia and Myanmar, metric '
        'elsewhere. Showing $current.',
    _ => 'Showing $current everywhere: distances, speeds, antenna heights and reports.',
  };
}

List<Widget> displaySectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  return [
    const SettingsAnchor(id: 'units-tile', child: UnitsTile()),
    SettingsAnchor(
      id: 'heard-hold',
      child: SliderTile(
        key: const Key('heard-hold'),
        sliderKey: const Key('heard-hold-slider'),
        icon: Icons.cell_tower,
        title: settingsEntry('heard-hold').title,
        stops: holdStops,
        value: st.heardHoldPings,
        label: (v) => '$v ping${v == 1 ? '' : 's'}',
        caption: 'Keep repeaters in the heard list for this many pings after they were last heard, then grey '
            'them out (they never disappear during a drive).',
        minLabel: '1',
        maxLabel: '10',
        onChanged: (v) => s.updateSettings(s.settings.copyWith(heardHoldPings: v)),
      ),
    ),
  ];
}

/// Metric, imperial, or follow the phone's locale.
class UnitsTile extends StatelessWidget {
  const UnitsTile({super.key});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final pref = s.settings.units;
    return ListTile(
      key: const Key('units-tile'),
      leading: const Icon(Icons.straighten),
      title: const Text('Units'),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(unitsExplanation(pref, s.units), key: const Key('units-explanation')),
        ),
        Padding(
        padding: const EdgeInsets.only(top: 8),
        child: SegmentedButton<UnitsPreference>(
          key: const Key('units-selector'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: UnitsPreference.auto, label: Text('Auto')),
            ButtonSegment(value: UnitsPreference.metric, label: Text('Metric')),
            ButtonSegment(value: UnitsPreference.imperial, label: Text('Imperial')),
          ],
          selected: {pref},
          onSelectionChanged: (v) => s.updateSettings(s.settings.copyWith(units: v.first)),
        ),
        ),
      ]),
    );
  }
}
