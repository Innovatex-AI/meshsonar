// The network-coverage layer's controls (the website /coverage layer panel): colour-by (best SNR / share heard /
// noise floor), detail (automatic H3 resolution by zoom, or pinned 7-11), a "since" window and a source filter.
// Lives in the map-layers sheet under the "Network coverage" switch; all state is on [DriveMapModel].
//
// Coverage-growth timeline: the "as of" slider (coverage_timeline_slider.dart) re-queries public-coverage with `until`.
import 'package:flutter/material.dart';

import '../../core/coverage_query.dart';
import '../../core/network_coverage.dart';
import '../drive/drive_map_model.dart';
import '../theme.dart';
import 'coverage_map.dart' show networkLevelColor;
import 'coverage_timeline_slider.dart';

String colorByLabel(CoverageColorBy by) => switch (by) {
  CoverageColorBy.snr => 'Best SNR',
  CoverageColorBy.heard => 'Share heard',
  CoverageColorBy.noise => 'Noise floor',
};

/// Legend steps for a colour-by mode, strongest first (same thresholds as [levelFor]).
List<(CoverageLevel, String)> coverageLegend(CoverageColorBy by) =>
    switch (by) {
      CoverageColorBy.snr => const [
        (CoverageLevel.strong, '+5 dB or better'),
        (CoverageLevel.good, '0 to +5'),
        (CoverageLevel.fair, '-5 to 0'),
        (CoverageLevel.weak, 'below -5'),
        (CoverageLevel.unknown, 'heard, signal unknown'),
        (CoverageLevel.none, 'mapped, nothing heard'),
      ],
      CoverageColorBy.heard => const [
        (CoverageLevel.strong, '75%+ heard'),
        (CoverageLevel.good, '50-75%'),
        (CoverageLevel.fair, '25-50%'),
        (CoverageLevel.weak, 'under 25%'),
        (CoverageLevel.none, 'mapped, nothing heard'),
      ],
      CoverageColorBy.noise => const [
        (CoverageLevel.strong, 'quiet, under -125 dBm'),
        (CoverageLevel.good, '-125 to -115'),
        (CoverageLevel.fair, '-115 to -105'),
        (CoverageLevel.weak, 'noisy, above -105'),
      ],
    };

class CoverageLayerControls extends StatelessWidget {
  final DriveMapModel model;
  const CoverageLayerControls({super.key, required this.model});

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
    final auto = q.res == null;
    return ExpansionTile(
      key: const Key('coverage-layer-controls'),
      leading: const SizedBox(width: 24),
      title: Text('Coverage options', style: t.textTheme.bodyMedium),
      subtitle: Text(
        '${colorByLabel(model.colorBy)} · ${q.res == null ? 'auto detail' : 'res ${q.res}'} · ${q.since.label} · ${q.source.label}',
        style: t.textTheme.bodySmall,
      ),
      shape: const Border(),
      collapsedShape: const Border(),
      childrenPadding: const EdgeInsets.fromLTRB(72, 0, Gap.l, Gap.s),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(
              'Colour by',
              chips<CoverageColorBy>(
                'cov-color',
                CoverageColorBy.values,
                model.colorBy,
                colorByLabel,
                (v) => model.colorBy = v,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: Wrap(
                spacing: Gap.m,
                runSpacing: 2,
                children: [
                  for (final (lvl, text) in coverageLegend(model.colorBy))
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: networkLevelColor(context, lvl),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(text, style: t.textTheme.labelSmall),
                      ],
                    ),
                ],
              ),
            ),
            row(
              auto
                  ? 'Detail (auto: H3 res ${model.effectiveRes})'
                  : 'Detail (H3 res ${q.res})',
              chips<int>(
                'cov-res',
                [0, for (var r = coverageMinRes; r <= coverageMaxRes; r++) r],
                q.res ?? 0,
                (v) => v == 0 ? 'Auto' : '$v',
                (v) => model.coverageQuery = v == 0
                    ? q.copyWith(autoRes: true)
                    : q.copyWith(res: v),
              ),
            ),
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
    );
  }
}
