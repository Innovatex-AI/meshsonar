// The tap card of a coverage summary hexagon (MAP slice 1; the site's "Coverage summary"): what the big cell was rolled up from,
// the mean signal, and how much of the area has been driven. It says it is a picture, not a measurement of its own, and offers
// "Zoom in" to the finer rung. Every statistic elsewhere still counts res-11 cells only.
import 'package:flutter/material.dart';

import '../../../core/coverage_v2.dart';
import '../../design/app_type.dart' show AppType;
import '../../theme.dart';
import '../coverage_bands.dart';
import 'coverage_cell_sheet.dart' show CoverageBandSwatch;
import '../map_layers.dart' show formatSnrShort;

/// One line for the panel header.
String coverageSummaryLine(CoverageSummaryInfo? info) {
  final m = info?.measured;
  if (info == null) return 'Coverage summary';
  if (m == null) return info.predicted == null ? 'Nothing measured or predicted here yet' : 'Predicted only  ·  not measured';
  return 'Summary of ${m.cells} measured ${m.cells == 1 ? 'cell' : 'cells'}${m.snrMean == null ? '' : '  ·  mean ${formatSnrShort(m.snrMean!)} dB'}  ·  ${coverageSharePct(m.share)} driven';
}

class CoverageSummarySheet extends StatelessWidget {
  final CoverageSummaryInfo? info;
  final CoverageMeta meta;
  final VoidCallback? onZoomIn;
  const CoverageSummarySheet({super.key, required this.info, required this.meta, this.onZoomIn});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bands = CoverageBandColors.of(MeshSonarColors.of(context).palette, t.brightness);
    final muted = t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final i = info;
    final m = i?.measured, p = i?.predicted;
    Widget band(int b, {bool predicted = false}) => Padding(
      padding: const EdgeInsets.only(bottom: Gap.xs),
      child: Row(children: [
        CoverageBandSwatch(band: b, colors: bands, predicted: predicted, size: 16),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(meta.labelOf(b), style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600))),
      ]),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (m != null) ...[
          band(m.band),
          Text(
            '${m.cells} measured ${m.cells == 1 ? 'cell' : 'cells'}${m.snrMean == null ? '' : ', mean ${formatSnrShort(m.snrMean!)} dB'}. ${coverageSharePct(m.share)} of this area driven.',
            key: const Key('coverage-summary-measured'),
            style: t.textTheme.bodyLarge?.copyWith(fontFeatures: AppType.tabular),
          ),
        ],
        if (p != null) ...[
          if (m != null) const SizedBox(height: Gap.s),
          band(p.band, predicted: true),
          Text(
            '${p.cells} estimated ${p.cells == 1 ? 'cell' : 'cells'}, ${coverageSharePct(p.share)} of this area.',
            key: const Key('coverage-summary-predicted'),
            style: t.textTheme.bodyLarge,
          ),
        ],
        if (i != null && m == null && p == null) Text('Nothing measured or predicted in this area yet.', style: muted),
        const SizedBox(height: Gap.s),
        Text('This is many small cells seen from far away. Zoom in to see each one.', style: muted),
        if (onZoomIn != null)
          Padding(
            padding: const EdgeInsets.only(top: Gap.s),
            // Full width, 48 pt (build 76).
            child: FilledButton.tonalIcon(key: const Key('coverage-summary-zoom-in'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)), onPressed: onZoomIn, icon: const Icon(Icons.zoom_in_rounded), label: const Text('Zoom in to the cells')),
          ),
      ],
    );
  }
}
