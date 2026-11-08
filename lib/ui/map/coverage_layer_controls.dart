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
import '../theme.dart';
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

/// The options page body of the coverage layers: window, growth slider and source.
class CoverageOptionsBody extends StatelessWidget {
  final DriveMapModel model;
  const CoverageOptionsBody({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = model.coverageQuery;
    final label = t.textTheme.labelMedium?.copyWith(
      color: t.colorScheme.onSurfaceVariant,
    );
    Widget row(String title, Widget chips) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: label),
          const SizedBox(height: 4),
          chips,
        ],
      ),
    );
    Widget chips<T>(
      String prefix,
      List<T> values,
      T selected,
      String Function(T) text,
      ValueChanged<T> onPick,
    ) => Wrap(
      spacing: Gap.s,
      runSpacing: 0,
      children: [
        for (final v in values)
          ChoiceChip(
            key: Key('$prefix-${text(v)}'),
            label: Text(text(v)),
            selected: v == selected,
            visualDensity: VisualDensity.compact,
            onSelected: (_) => onPick(v),
          ),
      ],
    );
    return KeyedSubtree(
      key: const Key('coverage-layer-controls'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(
              'Measured in the last',
              chips<CoverageSince>(
                'cov-since',
                CoverageSince.values,
                q.since,
                (v) => v.label,
                (v) => model.coverageQuery = q.copyWith(since: v),
              ),
            ),
            CoverageTimelineSlider(model: model),
            row(
              'Source',
              chips<CoverageSource>(
                'cov-source',
                CoverageSource.values,
                q.source,
                (v) => v.label,
                (v) => model.coverageQuery = q.copyWith(source: v),
              ),
            ),
          ],
        ),
      ],
      ),
    );
  }
}
