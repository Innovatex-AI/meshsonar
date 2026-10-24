// Region "RF" tab, mirroring the website's /analysis RF tab (meshcore-insights analysis-page.tsx RfTab): a one-line
// reading, figures (observers reporting, quietest/noisiest mean noise floor, weak-signal share), noise floor per
// observer over time with the -100 dBm interference line, noise floor by hour of day, and the SNR histogram. Data:
// `region-rf` (lib/core/region_rf_api.dart). Honest gaps: an observer that stopped reporting (e.g. INNO-OB-2 since
// 2026-10-21) is named with the time of its last reading, and its line stops there; the x axis runs to the server's
// computedAt, so the gap is visible instead of the line being stretched. Times: phone local time, said in captions;
// the hour-of-day chart is shifted from the server's UTC hours to local hours when the phone's offset is whole hours.
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_rf_api.dart';
import '../../core/rf_thresholds.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../theme.dart';
import '../widgets.dart';
import 'region_dataset_view.dart';

/// Observers drawn as their own line (the website's MAX_RF_SERIES); the rest are in the table.
const maxRfSeries = 6;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _dayHour(DateTime t) {
  final l = t.toLocal();
  return '${_months[l.month - 1]} ${l.day} ${two(l.hour)}:00';
}

class RfPanel extends StatelessWidget {
  final String baseUrl;
  final String regionSlug;

  /// Test seams.
  final http.Client? client;
  final Duration? utcOffset;
  final DateTime Function() now;
  const RfPanel({super.key, required this.baseUrl, required this.regionSlug, this.client, this.utcOffset, this.now = DateTime.now});

  @override
  Widget build(BuildContext context) => RegionDatasetView<RegionRf>(
        id: 'rf',
        title: '${regionSlug.toUpperCase()} RF and noise floor',
        reloadKey: '$baseUrl|$regionSlug',
        now: now,
        load: () => RegionRfApi(baseUrl, client: client).fetch(),
        status: (d) => d.status,
        isEmpty: (d) => d.isEmpty,
        emptyText: 'No RF measurements yet. Observers report their noise floor in their status messages; it charts here once they do.',
        build: (context, d) => _body(context, d),
      );

  List<Widget> _body(BuildContext context, RegionRf d) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final palette = chartPalette(context);
    final offset = utcOffset ?? now().timeZoneOffset;
    final whole = offset.inMinutes % 60 == 0;
    String localHour(int utcHour) => whole ? '${two((utcHour + offset.inHours) % 24)}:00 your time' : '${two(utcHour)}:00 UTC';
    final asOf = d.status.computedAt ?? now().toUtc();
    final silent = d.silentObservers(asOf);
    final means = d.observerMeans..sort();
    final weak = d.weakSnrShare;
    final ref = noiseFloorInterferenceDbm.round();
    final finding = d.finding(hourText: localHour);

    final shown = d.observers.where((o) => o.series.isNotEmpty).take(maxRfSeries).toList();
    final extra = d.observers.where((o) => o.series.isNotEmpty).length - shown.length;
    final lineSummary = [
      for (final o in d.observers)
        '${o.label}: mean ${o.meanDbm == null ? 'unknown' : '${db1(o.meanDbm!)} dBm'}, max ${o.maxDbm == null ? 'unknown' : '${db1(o.maxDbm!)} dBm'}'
            '${o.lastAt == null ? ', no readings' : silent.contains(o) ? ', no data since ${formatDateTime(o.lastAt!)}' : ''}.',
    ].join(' ');

    // Noise by hour of day, re-ordered to local hours when possible.
    final hours = [for (final h in d.noiseByHour) if (h.meanDbm != null) h];
    final byLocal = List<double?>.filled(24, null);
    for (final h in d.noiseByHour) {
      byLocal[whole ? (h.hour + offset.inHours) % 24 : h.hour] = h.meanDbm;
    }
    final vals = [for (final v in byLocal) ?v];
    final base = (([noiseBaseDbm, ...vals].reduce((a, b) => a < b ? a : b)) / 5).floor() * 5.0;
    final loudest = hours.isEmpty ? null : hours.reduce((a, b) => b.meanDbm! > a.meanDbm! ? b : a);
    final quietest = hours.isEmpty ? null : hours.reduce((a, b) => b.meanDbm! < a.meanDbm! ? b : a);

    final bins = d.snrHistogram;
    final binTotal = bins.fold<int>(0, (a, b) => a + b.n);
    final peakBin = bins.isEmpty ? null : bins.reduce((a, b) => b.n > a.n ? b : a);

    return [
      if (finding != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: Text(finding, key: const Key('rf-finding'), style: t.textTheme.bodyLarge),
        ),
      FigureStrip([
        ('Observers reporting', '${d.observers.length}', null),
        ('Quietest noise floor', means.isEmpty ? '—' : '${means.first.round()} dBm', 'Lower is better'),
        ('Noisiest noise floor', means.isEmpty ? '—' : '${means.last.round()} dBm', 'Higher is worse'),
        ('Weak signals', weak == null ? '—' : '${(weak * 100).round()}%', 'At or below 0 dB SNR'),
      ]),
      const SizedBox(height: Gap.m),
      for (final o in silent)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.s),
          child: Row(key: Key('rf-silent-${o.key}'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.history, size: 18, color: m.beacon),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${o.label} has sent no noise reading since ${formatDateTime(o.lastAt!)} '
                '(${_age(asOf.difference(o.lastAt!))} before this data was computed). Its line stops there.',
                style: t.textTheme.bodyMedium,
              ),
            ),
          ]),
        ),
      if (d.observers.any((o) => noiseVerdict(o.meanDbm) != null))
        DatasetCard(
          child: Column(key: const Key('rf-verdicts'), crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('What this means', style: t.textTheme.titleSmall),
            const SizedBox(height: Gap.xs),
            for (final o in d.observers)
              if (noiseVerdict(o.meanDbm) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('${o.label}: ${noiseVerdictText(noiseVerdict(o.meanDbm)!)} (mean ${o.meanDbm!.round()} dBm)'),
                ),
            if (weak != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${(weak * 100).round()}% of received packets are at or below 0 dB SNR, near the edge of what a radio can decode.'),
              ),
          ]),
        ),
      if (d.observers.isNotEmpty)
        DatasetCard(
          child: ChartFrame(
            id: 'rf-noise',
            title: 'Noise floor by observer (dBm), lower is quieter',
            summary: lineSummary,
            height: 200,
            caption: 'Dashed line: $ref dBm, where interference is likely. A line breaks where an observer sent nothing for '
                'more than 3 hours. Times are your phone\'s local time.${extra > 0 ? ' $extra more observers are in the table, not drawn.' : ''}',
            table: ChartTable(head: const ['Observer', 'Mean (dBm)', 'Max (dBm)', 'Last reading'], rows: [
              for (final o in d.observers)
                [
                  o.label,
                  o.meanDbm == null ? '—' : db1(o.meanDbm!),
                  o.maxDbm == null ? '—' : db1(o.maxDbm!),
                  o.lastAt == null ? '—' : formatDateTime(o.lastAt!),
                ],
            ]),
            chart: shown.isEmpty
                ? const SizedBox()
                : TimeLineChart(
                    series: [
                      for (var i = 0; i < shown.length; i++)
                        ChartSeries(
                            name: shown[i].label,
                            points: [for (final p in shown[i].series) (p.at, p.dbm)],
                            color: palette[i % palette.length]),
                    ],
                    yLabel: 'dBm',
                    refLine: noiseFloorInterferenceDbm,
                    refLabel: '$ref dBm',
                    breakGap: const Duration(hours: 3),
                    xEnd: asOf,
                    xFormat: _dayHour,
                    legend: true,
                  ),
          ),
        ),
      if (hours.isNotEmpty)
        DatasetCard(
          child: ChartFrame(
            id: 'rf-hours',
            title: 'Noise floor by hour of day',
            summary: 'Mean across observers. Noisiest ${localHour(loudest!.hour)} at ${db1(loudest.meanDbm!)} dBm, '
                'quietest ${localHour(quietest!.hour)} at ${db1(quietest.meanDbm!)} dBm.',
            caption: '${whole ? 'Hours are your phone\'s local time (the server reports UTC hours).' : 'Hours are UTC.'} '
                'Bars start at ${base.round()} dBm, a quiet receiver; a taller bar is a noisier hour. Red bars are above $ref dBm.',
            table: ChartTable(head: [whole ? 'Hour (your time)' : 'Hour (UTC)', 'Mean (dBm)'], rows: [
              for (var h = 0; h < 24; h++)
                if (byLocal[h] != null) ['${two(h)}:00', db1(byLocal[h]!)],
            ]),
            chart: BarChart(
              labels: [for (var h = 0; h < 24; h++) two(h)],
              series: [BarSeries(name: 'Noise floor', values: byLocal, color: t.colorScheme.tertiary)],
              base: base,
              refLine: noiseFloorInterferenceDbm,
              colorOf: (i, v) => v > noiseFloorInterferenceDbm ? t.colorScheme.error : null,
              labelEvery: 3,
              yLabel: 'dBm',
            ),
          ),
        ),
      if (bins.isNotEmpty)
        DatasetCard(
          child: ChartFrame(
            id: 'rf-snr',
            title: 'SNR of received packets (dB)',
            summary: '$binTotal packets. Most common ${_range(peakBin!)} dB (${peakBin.n} packets).'
                '${weak == null ? '' : ' ${(weak * 100).round()}% at or below 0 dB.'}',
            caption: 'Higher is better; below 0 dB is at the edge of decoding (those bars are drawn in the weak colour).',
            table: ChartTable(head: const ['SNR range (dB)', 'Packets'], rows: [
              for (final b in bins) [_range(b), '${b.n}'],
            ]),
            chart: BarChart(
              labels: [for (final b in bins) b.fromDb.round().toString()],
              series: [BarSeries(name: 'Packets', values: [for (final b in bins) b.n.toDouble()], color: t.colorScheme.primary)],
              colorOf: (i, v) => bins[i].toDb <= snrWeakDb ? m.snrWeak : null,
              labelEvery: bins.length > 8 ? 2 : 1,
              yLabel: 'packets',
            ),
          ),
        ),
    ];
  }

  static String _range(SnrBin b) => '${b.fromDb.round()} to ${b.toDb.round()}';
  static String _age(Duration d) => d.inHours < 48 ? '${d.inHours} hours' : '${d.inDays} days';
}
