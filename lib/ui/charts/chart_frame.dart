// The frame every chart in the app sits in (same model as the website's ChartFrame + SimpleTable,
// meshcore-insights src/components/region/analysis-shared.tsx):
//   - a title and a Chart / Table switch; the table shows every number the chart draws, so nothing is chart-only;
//   - the chart is ONE semantics node labelled "<title>. <summary>": the summary is mandatory and must carry the
//     numbers ("Peak 52 packets per hour at 14:00"), never just "chart", so VoiceOver reads the data;
//   - an optional caption (time zone, units, what the reference line means).
// Colours come only from the theme (colorScheme + MeshSonarColors), so light and dark both work.
import 'package:flutter/material.dart';

import '../theme.dart';

/// What the Table view shows: display strings, already formatted for the person (units, local time).
class ChartTable {
  final List<String> head;
  final List<List<String>> rows;
  const ChartTable({required this.head, required this.rows});
}

/// Up to six series colours from the theme (series beyond six reuse them; charts cap their series well before that).
List<Color> chartPalette(BuildContext context) {
  final c = Theme.of(context).colorScheme;
  final m = MeshSonarColors.of(context);
  return [c.primary, m.beacon, c.tertiary, m.snrStrong, c.secondary, m.snrWeak];
}

/// Axis text style for painters.
TextStyle chartLabelStyle(BuildContext context) {
  final t = Theme.of(context);
  return (t.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(color: t.colorScheme.onSurfaceVariant);
}

class ChartFrame extends StatefulWidget {
  /// Key prefix: `chart-<id>` (frame), `chart-<id>-toggle`, `chart-<id>-chart`, `chart-<id>-table`.
  final String id;
  final String title;

  /// One or two sentences with the numbers; the chart's whole semantics label after the title.
  final String summary;
  final ChartTable table;
  final Widget chart;
  final String? caption;
  final double height;

  /// Starts on the table (e.g. when a chart would be a single bar).
  final bool startWithTable;

  const ChartFrame({
    super.key,
    required this.id,
    required this.title,
    required this.summary,
    required this.table,
    required this.chart,
    this.caption,
    this.height = 170,
    this.startWithTable = false,
  });

  @override
  State<ChartFrame> createState() => _ChartFrameState();
}

class _ChartFrameState extends State<ChartFrame> {
  late bool _table = widget.startWithTable;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final w = widget;
    return Column(
      key: Key('chart-${w.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Large text: the Chart / Table switch goes under the title instead of overflowing beside it.
        if (MediaQuery.textScalerOf(context).scale(14) / 14 > 1.3) ...[
          Text(w.title, style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          Align(alignment: Alignment.centerRight, child: _toggle(w)),
        ] else
          Row(children: [
            Expanded(child: Text(w.title, style: t.textTheme.titleSmall)),
            const SizedBox(width: 8),
            _toggle(w),
          ]),
        const SizedBox(height: 8),
        if (_table)
          _TableView(key: Key('chart-${w.id}-table'), table: w.table, title: w.title)
        else
          Semantics(
            key: Key('chart-${w.id}-chart'),
            container: true,
            image: true,
            label: '${w.title}. ${w.summary}',
            excludeSemantics: true,
            child: SizedBox(height: w.height, width: double.infinity, child: w.chart),
          ),
        if (w.caption != null) ...[
          const SizedBox(height: 6),
          Text(w.caption!, style: t.textTheme.bodySmall?.copyWith(color: MeshSonarColors.of(context).textMuted)),
        ],
      ],
    );
  }

  Widget _toggle(ChartFrame w) => SegmentedButton<bool>(
        key: Key('chart-${w.id}-toggle'),
        showSelectedIcon: false,
        style: const ButtonStyle(visualDensity: VisualDensity.compact, tapTargetSize: MaterialTapTargetSize.padded),
        segments: const [
          ButtonSegment(value: false, label: Text('Chart'), tooltip: 'Show as a chart'),
          ButtonSegment(value: true, label: Text('Table'), tooltip: 'Show as a table'),
        ],
        selected: {_table},
        onSelectionChanged: (s) => setState(() => _table = s.first),
      );
}

class _TableView extends StatelessWidget {
  final ChartTable table;
  final String title;
  const _TableView({super.key, required this.table, required this.title});

  /// Tables longer than this scroll inside a fixed-height list built lazily (a drive can have thousands of pings).
  static const lazyAfter = 40;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    if (table.rows.isEmpty) return Text('No rows.', style: t.textTheme.bodyMedium);
    final num = t.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    if (table.rows.length > lazyAfter) {
      Widget row(List<String> cells, TextStyle? style) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Row(children: [
              for (var i = 0; i < table.head.length; i++)
                Expanded(child: Text(i < cells.length ? cells[i] : '', style: style, overflow: TextOverflow.ellipsis)),
            ]),
          );
      return Semantics(
        label: '$title, table, ${table.rows.length} rows',
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          row(table.head, t.textTheme.labelMedium),
          const Divider(height: 1),
          SizedBox(
            height: 320,
            child: ListView.builder(
              primary: false,
              itemCount: table.rows.length,
              itemExtent: 28,
              itemBuilder: (_, i) => row(table.rows[i], num),
            ),
          ),
          Text('${table.rows.length} rows', style: t.textTheme.labelSmall),
        ]),
      );
    }
    return Semantics(
      label: '$title, table, ${table.rows.length} rows',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 34,
          dataRowMinHeight: 28,
          dataRowMaxHeight: 34,
          columnSpacing: 18,
          horizontalMargin: 4,
          columns: [for (final h in table.head) DataColumn(label: Text(h, style: t.textTheme.labelMedium))],
          rows: [
            for (final r in table.rows)
              DataRow(cells: [
                for (var i = 0; i < table.head.length; i++) DataCell(Text(i < r.length ? r[i] : '', style: num)),
              ]),
          ],
        ),
      ),
    );
  }
}
