// Settings > Units & display: the unit system (Auto / Metric / Imperial), an optional unit per quantity (distance,
// speed, height, temperature, pressure; each follows the Units setting unless changed), and how long repeaters stay
// bright in the heard list. Every number on screen goes through lib/core/units.dart, so a change here applies everywhere.
import 'package:flutter/material.dart';

import '../../core/colour_palette.dart';
import '../../core/network_coverage.dart' show CoverageLevel;
import '../../core/units.dart';
import '../app.dart';
import '../design/app_symbols.dart';
import '../design/app_widgets.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String displayHelp = 'How numbers and lists look. Nothing stored changes: drives keep metres and m/s, and the '
    'server receives the same data whatever you pick here.';

/// What the Units choice means, including what Auto resolves to on this phone right now, and which quantities have
/// their own unit. The only wording for it.
String unitsExplanation(UnitsPreference pref, Units now) {
  final base = Units(now.system); // the setting itself, without the per-quantity choices
  final current = '${base.isImperial ? 'imperial' : 'metric'} (${base.lengthUnit}, ${base.longDistanceUnit}, ${base.speedUnit})';
  final own = now.isMixed ? ' Own choice below: ${joinAnd(now.exceptions)}.' : '';
  return switch (pref) {
    UnitsPreference.auto => 'Auto follows your phone\'s region: imperial in the US, Liberia and Myanmar, metric '
        'elsewhere. Showing $current.$own',
    _ => 'Showing $current everywhere: distances, speeds, antenna heights and reports.$own',
  };
}

/// One quantity that can have its own unit.
class UnitQuantity {
  /// Settings index id (and widget key) of its row.
  final String id;
  final IconData icon;

  /// The choices, in order, with the first being "follow the Units setting".
  final List<String> Function(Units base) labels;
  final List<String> values;
  final String Function(UnitOverrides o) current;
  final UnitOverrides Function(UnitOverrides o, String v) set;

  /// The unit words for this quantity under [u] ("km and m").
  final String Function(Units u) unitWords;
  const UnitQuantity({
    required this.id,
    required this.icon,
    required this.labels,
    required this.values,
    required this.current,
    required this.set,
    required this.unitWords,
  });
}

List<String> _metricImperial(String metric, String imperial) => ['Metric: $metric', 'Imperial: $imperial'];

final List<UnitQuantity> unitQuantities = [
  UnitQuantity(
    id: 'unit-distance',
    icon: Icons.route_outlined,
    values: [for (final c in UnitChoice.values) c.name],
    labels: (_) => _metricImperial('km and m', 'miles and feet'),
    current: (o) => o.distance.name,
    set: (o, v) => o.copyWith(distance: UnitChoice.parse(v)),
    unitWords: (u) => u.distanceImperial ? 'miles and feet' : 'km and m',
  ),
  UnitQuantity(
    id: 'unit-speed',
    icon: Icons.speed,
    values: [for (final c in UnitChoice.values) c.name],
    labels: (_) => _metricImperial('km/h', 'mph'),
    current: (o) => o.speed.name,
    set: (o, v) => o.copyWith(speed: UnitChoice.parse(v)),
    unitWords: (u) => u.speedUnit,
  ),
  UnitQuantity(
    id: 'unit-height',
    icon: Icons.height,
    values: [for (final c in UnitChoice.values) c.name],
    labels: (_) => _metricImperial('metres', 'feet'),
    current: (o) => o.height.name,
    set: (o, v) => o.copyWith(height: UnitChoice.parse(v)),
    unitWords: (u) => u.heightImperial ? 'feet' : 'metres',
  ),
  UnitQuantity(
    id: 'unit-temperature',
    icon: Icons.thermostat_outlined,
    values: [for (final c in UnitChoice.values) c.name],
    labels: (_) => ['Celsius (°C)', 'Fahrenheit (°F)'],
    current: (o) => o.temperature.name,
    set: (o, v) => o.copyWith(temperature: UnitChoice.parse(v)),
    unitWords: (u) => u.temperatureUnit,
  ),
  UnitQuantity(
    id: 'unit-pressure',
    icon: Icons.compress,
    values: [for (final c in PressureChoice.values) c.name],
    labels: (_) => ['hPa (hectopascal, the same as millibar)', 'inHg (inches of mercury)', 'mmHg (millimetres of mercury)'],
    current: (o) => o.pressure.name,
    set: (o, v) => o.copyWith(pressure: PressureChoice.parse(v)),
    unitWords: (u) => u.pressureUnit,
  ),
];

/// "Follows Units: km and m." or "Always mph, whatever Units says."
String unitOverrideState(UnitQuantity q, Units now) => q.current(now.overrides) == 'follow'
    ? 'Follows Units: ${q.unitWords(now)}.'
    : 'Always ${q.unitWords(now)}, whatever Units says.';

List<Widget> displaySectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  return [
    const SettingsAnchor(id: 'units-tile', child: UnitsTile()),
    for (final q in unitQuantities) SettingsAnchor(id: q.id, child: UnitOverrideTile(quantity: q)),
    const SettingsAnchor(id: 'colour-palette', child: ColourPaletteTile()),
    SettingsAnchor(
      id: 'ui-haptics',
      child: AppSwitchTile(
        key: const Key('ui-haptics'),
        symbol: AppSymbols.waveform,
        title: settingsEntry('ui-haptics').title,
        subtitle: settingsEntry('ui-haptics').summary,
        value: st.haptics,
        onChanged: (v) => s.updateSettings(st.copyWith(haptics: v)),
      ),
    ),
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

/// Metric, imperial, or follow the phone's locale; with per-quantity choices set, a one-tap way back to "all follow".
class UnitsTile extends StatelessWidget {
  const UnitsTile({super.key});

  Future<void> _resetOverrides(BuildContext context) async {
    final s = AppScope.read(context);
    final before = s.settings.unitOverrides;
    await s.updateSettings(s.settings.copyWith(unitOverrides: const UnitOverrides()));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: const Text('Every quantity follows Units again.'),
      action: SnackBarAction(
        key: const Key('units-reset-undo'),
        label: 'Undo',
        onPressed: () => s.updateSettings(s.settings.copyWith(unitOverrides: before)),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final pref = s.settings.units;
    final mixed = !s.settings.unitOverrides.isEmpty;
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
        if (mixed)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('units-reset-overrides'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => _resetOverrides(context),
              child: const Text('Make every quantity follow Units'),
            ),
          ),
      ]),
    );
  }
}

/// One quantity's unit: "Follows Units" by default; tap to pick a fixed unit for it alone.
class UnitOverrideTile extends StatelessWidget {
  final UnitQuantity quantity;
  const UnitOverrideTile({super.key, required this.quantity});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final q = quantity;
    final e = settingsEntry(q.id);
    return ListTile(
      key: Key(q.id),
      leading: Icon(q.icon),
      title: Text(e.title),
      subtitle: Text('${unitOverrideState(q, s.units)} ${e.summary}', key: Key('${q.id}-state')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        final v = await pickUnit(context, q);
        if (v == null || !context.mounted) return;
        final now = AppScope.read(context);
        await now.updateSettings(now.settings.copyWith(unitOverrides: q.set(now.settings.unitOverrides, v)));
      },
    );
  }
}

/// The choices for [q] in a dialog, the current one marked. Returns the picked value, or null when dismissed.
Future<String?> pickUnit(BuildContext context, UnitQuantity q) {
  final s = AppScope.read(context);
  final now = s.units;
  final base = Units(now.system);
  final cur = q.current(now.overrides);
  final labels = ['Follow Units (now ${q.unitWords(base)})', ...q.labels(base)];
  return showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      key: Key('${q.id}-dialog'),
      title: Text(settingsEntry(q.id).title),
      children: [
        for (var i = 0; i < q.values.length; i++)
          Semantics(
            inMutuallyExclusiveGroup: true,
            checked: q.values[i] == cur,
            child: ListTile(
              key: Key('${q.id}-option-${q.values[i]}'),
              leading: Icon(q.values[i] == cur ? Icons.radio_button_checked : Icons.radio_button_unchecked),
              title: Text(labels[i]),
              selected: q.values[i] == cur,
              onTap: () => Navigator.pop(ctx, q.values[i]),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ),
        ),
      ],
    ),
  );
}

/// What each palette is for, in one line (the only wording for it).
String paletteSummary(ColourPalette p) => switch (p) {
  ColourPalette.standard => 'Blue, teal and green for your pings; green, blue, amber and red for network coverage.',
  ColourPalette.colourBlind => 'Blue to yellow to orange. Safe for red-green and blue-yellow colour blindness. Link lines turn dashed.',
  ColourPalette.highContrast => 'Brighter on the dark map and deeper on the light map, for strong separation from the map. Link lines turn dashed.',
};

/// The strength colours of [p] as a strip: strongest to weakest, then "nothing heard" (grey) and "heard, signal unknown"
/// (purple). Shown beside each choice so the person sees the palette before picking it.
class PaletteStrip extends StatelessWidget {
  final ColourPalette palette;
  const PaletteStrip({super.key, required this.palette});

  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.forPalette(palette, Theme.of(context).brightness);
    final colours = [
      for (final l in [CoverageLevel.strong, CoverageLevel.good, CoverageLevel.fair, CoverageLevel.weak, CoverageLevel.none, CoverageLevel.unknown])
        mc.levelColor(l),
    ];
    return ExcludeSemantics(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in colours)
            Container(
              width: 22,
              height: 14,
              margin: const EdgeInsets.only(right: 3),
              decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
            ),
        ],
      ),
    );
  }
}

/// Settings > Units & display > Colour palette: Standard, Colour-blind safe, High contrast. Applies to every strength
/// colour at once (hexes, ping dots, network cells, SNR pills, link lines, charts, the legend).
class ColourPaletteTile extends StatelessWidget {
  const ColourPaletteTile({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final cur = s.settings.colourPalette;
    final e = settingsEntry('colour-palette');
    return Column(
      key: const Key('colour-palette'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: const Icon(Icons.palette_outlined),
          title: Text(e.title),
          subtitle: Text(
            'How signal strength is coloured on every map and chart. Grey (nothing heard) and purple (heard, signal unknown) '
            'stay distinct in all three.',
            key: const Key('colour-palette-explanation'),
          ),
        ),
        for (final p in ColourPalette.values)
          Semantics(
            inMutuallyExclusiveGroup: true,
            checked: p == cur,
            child: ListTile(
              key: Key('colour-palette-${p.id}'),
              minTileHeight: 56,
              leading: Icon(p == cur ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                  color: p == cur ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
              title: Text(p.label),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(paletteSummary(p)),
                  const SizedBox(height: 6),
                  PaletteStrip(palette: p),
                ],
              ),
              selected: p == cur,
              onTap: () => s.updateSettings(s.settings.copyWith(colourPalette: p)),
            ),
          ),
        const SizedBox(height: Gap.xs),
      ],
    );
  }
}
