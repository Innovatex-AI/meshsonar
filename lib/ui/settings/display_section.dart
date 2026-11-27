// Settings > Units & display: the unit system (Auto / Metric / Imperial), an optional unit per quantity (distance,
// speed, height, temperature, pressure; each follows the Units setting unless changed), and how long repeaters stay
// bright in the heard list. Every number on screen goes through lib/core/units.dart, so a change here applies everywhere.
import 'package:flutter/material.dart';

import '../design/app_surfaces.dart';
import '../../core/colour_palette.dart';
import '../map/active_map_definition.dart';
import '../../core/time_format.dart';
import '../../core/units.dart';
import '../app.dart';
import '../design/app_symbols.dart';
import '../map/coverage_bands.dart' show CoverageBandColors;
import '../design/app_widgets.dart';
import 'settings_index.dart';
import 'settings_kit.dart';

const String displayHelp = 'How the map, numbers and lists look. Stored data is unchanged.';

/// What the Units choice means, including what Auto resolves to on this phone right now, and which quantities have
/// their own unit. The only wording for it.
String unitsExplanation(UnitsPreference pref, Units now) {
  final base = Units(now.system); // the setting itself, without the per-quantity choices
  final current = '${base.isImperial ? 'imperial' : 'metric'} (${base.lengthUnit}, ${base.longDistanceUnit}, ${base.speedUnit})';
  final own = now.isMixed ? ' Own unit: ${joinAnd(now.exceptions)}.' : '';
  return switch (pref) {
    UnitsPreference.auto => 'Auto follows your phone\'s region. Showing $current.$own',
    _ => 'Showing $current everywhere.$own',
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
String unitOverrideState(UnitQuantity q, Units now) =>
    q.current(now.overrides) == 'follow' ? 'Follows Units: ${q.unitWords(now)}.' : 'Always ${q.unitWords(now)}, whatever Units says.';

/// Map & display, first level, after the region and the follow switches: units, palette, haptics, heard list hold.
List<Widget> displaySectionRows(BuildContext context) {
  final s = AppScope.of(context);
  final st = s.settings;
  return [
    const SettingsAnchor(id: 'units-tile', child: UnitsTile()),
    const SettingsAnchor(id: 'time-zone', child: TimeZoneTile()),
    const SettingsAnchor(id: 'colour-palette', child: ColourPaletteTile()),
    SettingsAnchor(
      id: 'ui-haptics',
      child: AppSwitchTile(
        key: const Key('ui-haptics'),
        symbol: AppSymbols.waveform,
        title: settingsEntry('ui-haptics').title,
        subtitle: 'Small taps on switches, lists and sends.',
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
        caption: 'A repeater stays bright this long after it was last heard, then greys out.',
        minLabel: '1',
        maxLabel: '10',
        onChanged: (v) => s.updateSettings(s.settings.copyWith(heardHoldPings: v)),
      ),
    ),
  ];
}

/// Map & display > Units per quantity: one row per quantity, each "Follows Units" unless changed.
List<Widget> unitPageRows(BuildContext context) => [
      for (final q in unitQuantities) SettingsAnchor(id: q.id, child: UnitOverrideTile(quantity: q)),
    ];

/// Metric, imperial, or follow the phone's locale; with per-quantity choices set, a one-tap way back to "all follow".
class UnitsTile extends StatelessWidget {
  /// Opens the per-quantity page (set by the Settings shell; null hides nothing, the button just does nothing in a
  /// place with no such page).
  static void Function(BuildContext context)? openPerQuantity;
  const UnitsTile({super.key});

  Future<void> _resetOverrides(BuildContext context) async {
    final s = AppScope.read(context);
    final before = s.settings.unitOverrides;
    await s.updateSettings(s.settings.copyWith(unitOverrides: const UnitOverrides()));
    if (!context.mounted) return;
    showAppToast(
      context,
      'Every quantity follows Units again.',
      actionLabel: 'Undo',
      onAction: () => s.updateSettings(s.settings.copyWith(unitOverrides: before)),
    );
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
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(unitsExplanation(pref, s.units), key: const Key('units-explanation')),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<UnitsPreference>(
              key: const Key('units-selector'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: UnitsPreference.auto, label: segmentLabel('Auto')),
                ButtonSegment(value: UnitsPreference.metric, label: segmentLabel('Metric')),
                ButtonSegment(value: UnitsPreference.imperial, label: segmentLabel('Imperial')),
              ],
              selected: {pref},
              onSelectionChanged: (v) => s.updateSettings(s.settings.copyWith(units: v.first)),
            ),
          ),
          Wrap(spacing: Gap.s, children: [
            TextButton(
              key: const Key('units-per-quantity'),
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 48)),
              onPressed: () => UnitsTile.openPerQuantity?.call(context),
              child: const Text('A different unit for one thing'),
            ),
            if (mixed)
              TextButton(
                key: const Key('units-reset-overrides'),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(48, 48)),
                onPressed: () => _resetOverrides(context),
                child: const Text('All follow Units'),
              ),
          ]),
        ],
      ),
    );
  }
}

/// Map & display > Time zone, directly under Units: the phone's own time (default) or UTC, with a line showing what
/// that gives right now ("Showing 6:14 PM EST"). Every time in the app follows it through lib/core/time_format.dart.
class TimeZoneTile extends StatelessWidget {
  /// Tests set the moment the "Showing" line is worked out for.
  final DateTime? now;
  const TimeZoneTile({super.key, this.now});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final pref = s.settings.timeZone;
    return ListTile(
      key: const Key('time-zone-tile'),
      leading: const Icon(Icons.schedule),
      title: const Text('Time zone'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(showingTimeLine(pref, now: now), key: const Key('time-zone-showing')),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: SegmentedButton<TimeZonePreference>(
              key: const Key('time-zone-selector'),
              showSelectedIcon: false,
              segments: [
                for (final z in TimeZonePreference.values)
                  ButtonSegment(value: z, label: segmentLabel(z.label, key: Key('time-zone-${z.name}'))),
              ],
              selected: {pref},
              onSelectionChanged: (v) => s.updateSettings(s.settings.copyWith(timeZone: v.first)),
            ),
          ),
        ],
      ),
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
      subtitle: Text(unitOverrideState(q, s.units), key: Key('${q.id}-state')),
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

/// The choices for [q] in a sheet, the current one marked. Returns the picked value, or null when dismissed.
Future<String?> pickUnit(BuildContext context, UnitQuantity q) {
  final s = AppScope.read(context);
  final now = s.units;
  final base = Units(now.system);
  final cur = q.current(now.overrides);
  final labels = ['Follow Units (now ${q.unitWords(base)})', ...q.labels(base)];
  return showAppSheet<String>(
    context,
    detents: const [0.6],
    builder: (ctx, controller) => AppSheetScaffold(
      key: Key('${q.id}-dialog'),
      controller: controller,
      title: settingsEntry(q.id).title,
      padding: EdgeInsets.zero,

      secondaryAction: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
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
      ],
    ),
  );
}

/// What each palette is for, in one line (the only wording for it).
String paletteSummary(ColourPalette p) =>
    ActiveMapDefinition.current.paletteDefs.where((d) => d.id == p.id).firstOrNull?.blurb ?? p.label; // the Map Definition's words

/// The coverage colours of [p] as a strip (the same preview as the website's palette picker): Excellent to Edge, then
/// No reply and Heard, no direct signal. Shown beside each choice so the person sees the palette before picking it.
class PaletteStrip extends StatelessWidget {
  final ColourPalette palette;
  const PaletteStrip({super.key, required this.palette});

  @override
  Widget build(BuildContext context) {
    final c = CoverageBandColors.of(palette, Theme.of(context).brightness);
    final colours = [for (final b in const [5, 4, 3, 2, 1, 0, 6]) c[b]];
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

/// Settings > Units & display > Colour palette: Standard or Colour-blind safe. Applies to every strength
/// colour at once (hexes, ping dots, network cells, SNR pills, link lines, charts, the legend).
class ColourPaletteTile extends StatelessWidget {
  const ColourPaletteTile({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final cur = s.settings.colourPalette;
    final e = settingsEntry('colour-palette');
    return ListTile(
      key: const Key('colour-palette'),
      leading: const Icon(Icons.palette_outlined),
      title: Text(e.title),
      subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(paletteSummary(cur), key: const Key('colour-palette-explanation')),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          child: SegmentedButton<ColourPalette>(
            key: const Key('colour-palette-selector'),
            showSelectedIcon: false,
            segments: [
              for (final p in ColourPalette.values)
                ButtonSegment(value: p, label: segmentLabel(p.label, key: Key('colour-palette-${p.id}'))),
            ],
            selected: {cur},
            onSelectionChanged: (v) => s.updateSettings(s.settings.copyWith(colourPalette: v.first)),
          ),
        ),
        PaletteStrip(palette: cur),
        const SizedBox(height: Gap.xs),
      ]),
    );
  }
}
