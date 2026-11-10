// The coverage layers' options (the website /coverage layer panel): a "measured in the last" window, the source filter and
// the coverage-growth timeline ("as of" slider, coverage_timeline_slider.dart, re-queries public-coverage with `until`).
// The colour-by modes and the detail (H3 resolution) chips were removed with the coverage redesign (plan D1, D9): one colour
// metric and one cell size. Lives in the map-layers sheet under "Coverage options"; all state is on [DriveMapModel].
//
// With coverage v2 any of these filters switches the measured layer from the tiles to the `metric=mean` cells for that query,
// and hides the predicted layer (an estimate for today).
import 'package:flutter/material.dart';

import '../../core/coverage_query.dart';
import '../../core/network_coverage.dart';
import '../drive/drive_map_model.dart';
import '../../core/map_definition.dart' show MapFilterOptionDef;
import '../theme.dart';
import 'active_map_definition.dart';
import 'coverage_timeline_slider.dart';

/// The old (pre-v2) best-SNR legend steps, strongest first (same thresholds as [levelFor]).
List<(CoverageLevel, String)> coverageLegend() => const [
  (CoverageLevel.strong, '+5 dB or better'),
  (CoverageLevel.good, '0 to +5'),
  (CoverageLevel.fair, '-5 to 0'),
  (CoverageLevel.weak, 'below -5'),
  (CoverageLevel.unknown, 'heard, signal unknown'),
  (CoverageLevel.none, 'mapped, nothing heard'),
];

/// The Filters section of the Layers sheet (the website's: "Measured in" and "Drives from", option names from the Map
/// Definition's `filters`), plus the app's coverage-growth timeline slider between them.
class CoverageOptionsBody extends StatelessWidget {
  final DriveMapModel model;
  const CoverageOptionsBody({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = model.coverageQuery;
    final def = ActiveMapDefinition.current;
    final time = def.filter('time'), source = def.filter('source');
    final label = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    Widget row(String title, Widget chips) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: label), const SizedBox(height: 4), chips]),
    );
    Widget chips(String prefix, List<MapFilterOptionDef> options, String selected, ValueChanged<String> onPick) => Wrap(
      spacing: Gap.s,
      runSpacing: 0,
      children: [
        for (final o in options)
          ChoiceChip(
            key: Key('$prefix-${o.id}'),
            label: Text(o.label),
            selected: o.id == selected,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onPick(o.id),
          ),
      ],
    );
    final note = time.note;
    return KeyedSubtree(
      key: const Key('coverage-layer-controls'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (time.available) ...[
            row(
              'Measured in',
              chips('cov-since', time.options.where((o) => CoverageSince.ofDefinitionId(o.id) != null).toList(), q.since.definitionId, (id) {
                model.coverageQuery = q.copyWith(since: CoverageSince.ofDefinitionId(id));
              }),
            ),
            CoverageTimelineSlider(model: model),
            row(
              'Drives from',
              chips('cov-source', source.options.where((o) => CoverageSource.values.any((v) => v.wire == o.id)).toList(), q.source.wire, (id) {
                model.coverageQuery = q.copyWith(source: CoverageSource.values.firstWhere((v) => v.wire == id));
              }),
            ),
            if (note != null && (q.since != CoverageSince.all || q.until != null))
              Text(note, key: const Key('cov-time-note'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ] else if (note != null)
            Text(note, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
