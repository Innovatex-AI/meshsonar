// Repeater detail: "30-day signal trend" (`region-repeater` `snrDaily`, server capability `snrDaily`). What MeshSonar's own
// trusted observers hear: the mean SNR of this repeater's adverts heard directly (0 hops), one point per UTC day. Days
// without a reading are gaps (never interpolated, never zero). Chart / Table switch with the numbers in the semantics label.
import 'package:flutter/material.dart';

import '../../core/time_format.dart' show utcDayLabel;
import '../../core/repeater_detail_api.dart';
import '../../core/snr_trend.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../theme.dart';

/// A server UTC day, without the "(UTC)" the captions and the table heading already say.
String _day(DateTime t) => utcDayLabel(t, label: false);
String _db(double v) => '${v.toStringAsFixed(1)} dB';

class SnrTrendCard extends StatelessWidget {
  final List<DailySnr> daily;
  const SnrTrendCard({super.key, required this.daily});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final s = SnrTrend.of(daily);
    final muted = t.textTheme.bodyMedium?.copyWith(color: m.textMuted);
    Widget body;
    if (daily.isEmpty || !s.hasData) {
      body = Text(
        'No readings in the last 30 days: no MeshSonar observer has heard this repeater directly (it may be out of their range).',
        key: const Key('snrtrend-empty'),
        style: muted,
      );
    } else {
      final pts = [for (final d in daily) if (d.meanDb != null) (d.day, d.meanDb!)];
      final first = daily.first.day, last = daily.last.day;
      final latest = s.latest!;
      final summary = '${s.daysWithData} of ${s.days} days with readings, ${s.readings} adverts. '
          'Latest ${_db(latest.meanDb!)} on ${_day(latest.day)} (UTC), lowest ${_db(s.minDb!)} on ${_day(s.minDay!.day)}, '
          'highest ${_db(s.maxDb!)} on ${_day(s.maxDay!.day)}.${s.sentence == null ? '' : ' ${s.sentence}'}';
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          'Latest ${_db(latest.meanDb!)} (${_day(latest.day)}) · lowest ${_db(s.minDb!)} · highest ${_db(s.maxDb!)} · '
          '${s.daysWithData} of ${s.days} days with readings',
          key: const Key('snrtrend-summary'),
          style: t.textTheme.bodyMedium,
        ),
        if (s.sentence != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.sentence!, key: const Key('snrtrend-sentence'), style: t.textTheme.bodyMedium),
          ),
        const SizedBox(height: Gap.s),
        ChartFrame(
          id: 'snr-trend',
          title: 'Average signal per day (SNR, dB)',
          summary: summary,
          height: 170,
          startWithTable: pts.length < 2,
          caption: 'How well MeshSonar\'s observers hear this repeater directly, averaged per UTC day. Higher is better; a gap is a day with no reading.',
          table: ChartTable(head: const ['Day (UTC)', 'Average SNR (dB)', 'Times heard'], rows: [
            for (final d in daily) [_day(d.day), d.meanDb == null ? 'no reading' : d.meanDb!.toStringAsFixed(1), '${d.n}'],
          ]),
          chart: pts.length < 2
              ? const SizedBox()
              : TimeLineChart(
                  series: [ChartSeries(name: 'Mean SNR', points: pts, color: m.snrStrong)],
                  yLabel: 'dB',
                  signedTicks: true,
                  dashedGrid: {0.0},
                  breakGap: const Duration(hours: 30),
                  xStart: first,
                  xEnd: last,
                  xFormat: _day,
                  dotColor: (_) => m.snrStrong,
                ),
        ),
      ]);
    }
    return Padding(
      key: const Key('repdetail-snr-trend'),
      padding: const EdgeInsets.only(bottom: Gap.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('30-day signal trend', style: t.textTheme.titleMedium),
        const SizedBox(height: Gap.s),
        body,
      ]),
    );
  }
}
