// Region "Growth" tab: how the region's known node list grew, from `region-ext-growth?days=365` (external sources
// merged with MeshSonar's observers; lib/core/region_growth_api.dart), as on the website's /sources page
// (sources-charts.tsx GrowthChart + MixCharts): cumulative merged nodes by day, weekly churn (appeared / gone), roles,
// hash sizes, firmware (shown only when the server has any; it is an empty list today). Days and weeks are UTC calendar
// dates, as the server sends them, and the captions say so. The attribution names the server's `status.source`.
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_growth_api.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../theme.dart';
import 'region_common.dart' show groupInt;
import 'region_dataset_view.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _utcDay(DateTime t) {
  final u = t.toUtc();
  return '${_months[u.month - 1]} ${u.day}';
}

String _dayWords(String ymd) {
  final t = DateTime.tryParse('${ymd}T00:00:00Z');
  return t == null ? ymd : '${_utcDay(t)} ${t.year}';
}

String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

class GrowthPanel extends StatelessWidget {
  final String baseUrl;
  final String regionSlug;

  /// Test seams.
  final http.Client? client;
  final DateTime Function() now;
  const GrowthPanel({super.key, required this.baseUrl, required this.regionSlug, this.client, this.now = DateTime.now});

  @override
  Widget build(BuildContext context) => RegionDatasetView<RegionGrowth>(
        id: 'growth',
        title: '${regionSlug.toUpperCase()} network growth',
        reloadKey: '$baseUrl|$regionSlug',
        now: now,
        load: () => RegionGrowthApi(baseUrl, client: client).fetch(),
        status: (d) => d.status,
        isEmpty: (d) => d.isEmpty,
        emptyText: 'No growth history yet. It appears once the region\'s sources have reported nodes.',
        build: (context, d) => _body(context, d),
      );

  List<Widget> _body(BuildContext context, RegionGrowth d) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final cum = d.cumulative();
    final source = d.status.source;
    final appeared = d.churn.fold<int>(0, (a, w) => a + w.appeared);
    final gone = d.churn.fold<int>(0, (a, w) => a + w.gone);
    final roleTotal = d.roles.fold<int>(0, (a, r) => a + r.$2);
    final hashTotal = d.hashSizes.fold<int>(0, (a, h) => a + h.$2);
    final fwTotal = d.firmware.fold<int>(0, (a, f) => a + f.$2);
    String pct(int n, int of) => of == 0 ? '—' : '${(100 * n / of).round()}%';
    return [
      if (source != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: Text('Source: $source.', key: const Key('growth-source'), style: t.textTheme.bodyMedium),
        ),
      FigureStrip([
        ('Known nodes', groupInt(d.total), cum.isEmpty ? null : 'by ${_dayWords(cum.last.$1.day)}'),
        ('Appeared', groupInt(appeared), '${d.churn.length} weeks'),
        ('Gone', groupInt(gone), '${d.churn.length} weeks'),
      ]),
      const SizedBox(height: Gap.m),
      if (cum.length >= 2)
        DatasetCard(
          child: ChartFrame(
            id: 'growth-total',
            title: 'Known nodes over time',
            summary: '${groupInt(d.before)} before ${_dayWords(cum.first.$1.day)}, ${groupInt(cum.last.$2)} by '
                '${_dayWords(cum.last.$1.day)}: ${groupInt(cum.last.$2 - d.before)} added on ${cum.length} days.',
            caption: 'Running total of nodes first seen, all sources merged (a node two sources know counts once). Days are UTC.'
                '${d.hasObservedBasis ? ' One source publishes no first-seen date, so its nodes count from the day MeshSonar first saw them.' : ''}',
            table: ChartTable(head: const ['Day (UTC)', 'New', 'Total'], rows: [
              for (final (day, total) in cum) [day.day, '${day.merged}', groupInt(total)],
            ]),
            chart: TimeLineChart(
              series: [ChartSeries(name: 'Known nodes', points: [for (final (day, total) in cum) (day.at, total.toDouble())], color: t.colorScheme.primary)],
              yLabel: 'nodes',
              fill: true,
              xFormat: _utcDay,
            ),
          ),
        )
      else if (cum.length == 1)
        DatasetCard(
          child: Text('Not enough history yet to draw growth: ${groupInt(cum.single.$2)} nodes known on ${_dayWords(cum.single.$1.day)}.',
              key: const Key('growth-total-short')),
        ),
      if (d.churn.isNotEmpty)
        DatasetCard(
          child: ChartFrame(
            id: 'growth-churn',
            title: 'Churn by week',
            summary: '$appeared nodes appeared and $gone went quiet over ${d.churn.length} weeks. '
                'Latest week (${_dayWords(d.churn.last.week)}): ${d.churn.last.appeared} appeared, ${d.churn.last.gone} gone.',
            caption: 'Weeks start on Monday (UTC).',
            table: ChartTable(head: const ['Week of (UTC)', 'Appeared', 'Gone'], rows: [
              for (final w in d.churn) [w.week, '${w.appeared}', '${w.gone}'],
            ]),
            chart: BarChart(
              labels: [for (final w in d.churn) w.week.length >= 10 ? w.week.substring(5) : w.week],
              series: [
                BarSeries(name: 'Appeared', values: [for (final w in d.churn) w.appeared.toDouble()], color: m.snrStrong),
                BarSeries(name: 'Gone', values: [for (final w in d.churn) w.gone.toDouble()], color: m.silent),
              ],
              labelEvery: d.churn.length > 8 ? 2 : 1,
              legend: true,
            ),
          ),
        ),
      if (d.roles.isNotEmpty)
        DatasetCard(
          child: ChartFrame(
            id: 'growth-roles',
            title: 'Nodes by role',
            summary: [for (final r in d.roles) '${_cap(r.$1)} ${r.$2} (${pct(r.$2, roleTotal)}).'].join(' '),
            table: ChartTable(head: const ['Role', 'Nodes', 'Share'], rows: [
              for (final r in d.roles) [_cap(r.$1), '${r.$2}', pct(r.$2, roleTotal)],
            ]),
            height: 150,
            chart: BarChart(
              labels: [for (final r in d.roles) _cap(r.$1)],
              series: [BarSeries(name: 'Nodes', values: [for (final r in d.roles) r.$2.toDouble()], color: m.beacon)],
            ),
          ),
        ),
      if (d.hashSizes.isNotEmpty)
        DatasetCard(
          child: ChartFrame(
            id: 'growth-hash',
            title: 'Nodes by hash size',
            summary: [for (final h in d.hashSizes) '${h.$1}-byte ${h.$2} (${pct(h.$2, hashTotal)}).'].join(' '),
            caption: 'Shorter hashes are cheaper on air but collide more often.',
            table: ChartTable(head: const ['Hash size', 'Nodes', 'Share'], rows: [
              for (final h in d.hashSizes) ['${h.$1}-byte', '${h.$2}', pct(h.$2, hashTotal)],
            ]),
            height: 150,
            chart: BarChart(
              labels: [for (final h in d.hashSizes) '${h.$1}-byte'],
              series: [BarSeries(name: 'Nodes', values: [for (final h in d.hashSizes) h.$2.toDouble()], color: t.colorScheme.tertiary)],
            ),
          ),
        ),
      if (d.firmware.isNotEmpty)
        DatasetCard(
          child: ChartFrame(
            id: 'growth-firmware',
            title: 'Nodes by firmware',
            summary: [for (final f in d.firmware) '${f.$1} ${f.$2} (${pct(f.$2, fwTotal)}).'].join(' '),
            table: ChartTable(head: const ['Firmware', 'Nodes', 'Share'], rows: [
              for (final f in d.firmware) [f.$1, '${f.$2}', pct(f.$2, fwTotal)],
            ]),
            startWithTable: true,
            chart: BarChart(
              labels: [for (final f in d.firmware) f.$1],
              series: [BarSeries(name: 'Nodes', values: [for (final f in d.firmware) f.$2.toDouble()], color: t.colorScheme.secondary)],
            ),
          ),
        ),
    ];
  }
}
