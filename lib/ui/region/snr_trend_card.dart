// Repeater detail: "30-day signal trend" (`region-repeater` `snrDaily`, server capability `snrDaily`). What MeshSonar's own
// trusted observers hear: the mean SNR of this repeater's adverts heard directly (0 hops), one point per UTC day. Days
// without a reading are gaps (never interpolated, never zero). Chart / Table switch with the numbers in the semantics label.
import 'package:flutter/material.dart';

import '../../core/repeater_detail_api.dart';
import '../../core/snr_trend.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../theme.dart';

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _day(DateTime t) => '${_months[t.month - 1]} ${t.day}';
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
        'No direct readings in the last 30 days. Our observers have not heard this repeater\'s adverts directly '
        '(no relay in between) in that time, or it is out of their range.',
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
          title: 'Mean SNR per day (dB)',
          summary: summary,
          height: 170,
          startWithTable: pts.length < 2,
          caption: 'What MeshSonar\'s own observers hear: this repeater\'s adverts received directly (no relay), averaged per UTC day '
              'from trusted observers only. A day without a reading is a gap, not a zero. Days are UTC dates.',
          table: ChartTable(head: const ['Day (UTC)', 'Mean SNR (dB)', 'Adverts'], rows: [
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
