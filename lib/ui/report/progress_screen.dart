// "Your progress": every drive stored on this phone rolled up (lib/core/personal_progress.dart): totals, ISO weeks
// (Monday start, phone local time, zone named in the captions), distance / heard % / new grid cells / new repeaters
// per week, personal records (tap one to open that drive's report) and "Your radio" (noise floor per drive and by hour
// of day, TX power per drive), each chart with a Table view and its numbers in the semantics label.
// Scope is said plainly at the top: drives stored on this phone. When the upload server offers `driver-summary` and the
// key can use it, a switch (`progress-source`) adds "On the server": the account's history across phones and installs
// (lib/ui/report/server_progress.dart); the two are never mixed in one set of numbers.
// Opened from the Drives tab's progress card (ProgressCard, below).
import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/drive_stats.dart' show formatDuration;
import '../../core/personal_progress.dart';
import '../../core/rf_thresholds.dart';
import '../../core/units.dart';
import '../app.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../onboarding/ui_prefs.dart' show driveLabel;
import '../region/region_common.dart' show groupInt;
import '../widgets.dart';
import 'drive_report_screen.dart' show openDriveReport;
import 'local_drives.dart';
import 'server_progress.dart';

void openProgress(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ProgressScreen()));

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _day(DateTime d) => '${_months[d.month - 1]} ${d.day}';
String _db(double v) => v.toStringAsFixed(1);

/// Weeks drawn in a chart (the table has every week).
const int chartWeeks = 26;

/// "ISO weeks start on Monday, your phone's local time (EDT)."
String weeksCaption(DateTime now) =>
    'ISO weeks starting Monday, your phone\'s local time (${now.toLocal().timeZoneName}). A drive counts in the week it started.';

/// Distance as a plain number in the person's long-distance unit (km or mi), for bar heights.
double _longUnits(double metres, Units u) => metres / u.metresPerLongUnit;

class ProgressScreen extends StatefulWidget {
  const ProgressScreen({super.key});
  @override
  State<ProgressScreen> createState() => _ProgressScreenState();
}

enum ProgressSource { phone, server }

class _ProgressScreenState extends State<ProgressScreen> {
  Future<(PersonalProgress, LocalDrives)>? _future;
  Future<ServerLoad>? _server;
  ProgressSource _source = ProgressSource.server; // the server view wins whenever it is offered
  bool _capsAsked = false;

  Future<(PersonalProgress, LocalDrives)> _load() async {
    final s = AppScope.read(context);
    final local = await loadLocalDrives(s.services.store);
    return (PersonalProgress.compute(local.drives, now: s.services.clock()), local);
  }

  Future<ServerLoad> _loadServer({bool force = false}) async {
    final s = AppScope.read(context);
    final r = await s.driverSummary(force: force);
    var ids = <String>{};
    try {
      ids = {for (final x in await s.services.store.sessions()) x.session.id};
    } catch (_) {}
    return ServerLoad(r, ids);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _load();
    final s = AppScope.of(context);
    if (!_capsAsked) {
      _capsAsked = true;
      // What the upload server offers may not be known yet (first run offline): ask once; AppState notifies when it lands.
      s.refreshUploadSiteConfig().catchError((Object _) {});
    }
    if (s.driverSummaryAvailable) _server ??= _loadServer();
  }

  void _retryLocal() => setState(() {
        _future = _load();
      });

  Widget _local() => FutureBuilder<(PersonalProgress, LocalDrives)>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return ListView(padding: const EdgeInsets.all(Gap.l), children: [
              ErrorBanner('Couldn\'t read the drives on this phone. ${snap.error}', key: const Key('progress-error')),
              const SizedBox(height: Gap.m),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('progress-retry'),
                  onPressed: _retryLocal,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
            ]);
          }
          final d = snap.data;
          if (d == null) return const Center(child: CircularProgressIndicator(key: Key('progress-loading')));
          final (p, local) = d;
          if (p.isEmpty) {
            return const EmptyState(
              key: Key('progress-empty'),
              icon: Icons.insights,
              title: 'No drives yet',
              body: 'From drives stored on this phone. Start a drive on the Drive tab and your progress shows here.',
            );
          }
          return _ProgressBody(progress: p, unreadable: local.unreadable);
        },
      );

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final offered = s.driverSummaryAvailable;
    final showServer = offered && _source == ProgressSource.server;
    return Scaffold(
      key: const Key('progress-screen'),
      appBar: AppBar(title: const Text('Your progress')),
      body: SafeArea(
        child: !offered
            ? _local()
            : Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ProgressSource>(
                      key: const Key('progress-source'),
                      showSelectedIcon: false,
                      style: SegmentedButton.styleFrom(minimumSize: const Size(0, 48)),
                      segments: const [
                        ButtonSegment(
                            value: ProgressSource.server,
                            label: Text('On the server', key: Key('progress-source-server')),
                            tooltip: 'Across all your drives on the server, from every phone'),
                        ButtonSegment(
                            value: ProgressSource.phone,
                            label: Text('On this phone', key: Key('progress-source-phone')),
                            tooltip: 'Only the drives stored on this phone'),
                      ],
                      selected: {_source},
                      onSelectionChanged: (v) => setState(() => _source = v.first),
                    ),
                  ),
                ),
                Expanded(
                  child: showServer
                      ? ServerProgressPanel(
                          future: _server ??= _loadServer(),
                          onRetry: () => setState(() {
                            _server = _loadServer();
                          }),
                          onRefresh: () async {
                            final f = _loadServer(force: true);
                            setState(() {
                              _server = f;
                            });
                            try {
                              await f;
                            } catch (_) {}
                          },
                        )
                      : _local(),
                ),
              ]),
      ),
    );
  }
}

class _ProgressBody extends StatelessWidget {
  final PersonalProgress progress;
  final int unreadable;
  const _ProgressBody({required this.progress, required this.unreadable});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final s = AppScope.of(context);
    final p = progress;
    final now = s.services.clock();
    final first = p.drives.first.session.startedAt;
    final tiles = <(String, String, String)>[
      ('drives', 'Drives', groupInt(p.drives.length)),
      ('distance', 'Distance', u.distance(p.distanceM)),
      ('time', 'Time driving', formatDuration(p.driveTime)),
      ('pings', 'Pings', groupInt(p.pings)),
      ('heard', 'Heard', p.heardPercent == null ? '—' : '${p.heardPercent}%'),
      ('cells', 'Grid cells', groupInt(p.totalCells)),
      ('repeaters', 'Repeaters heard', groupInt(p.totalRepeaters)),
      if (p.bestSnr != null) ('snr', 'Best SNR', '${_db(p.bestSnr!)} dB'),
    ];
    return ListView(
      key: const Key('progress-list'),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
      children: [
        Text(
          'From drives stored on this phone: ${p.drives.length} drive${p.drives.length == 1 ? '' : 's'} since ${formatDateTime(first)}. '
          'Drives deleted from this phone or recorded on another phone are not included.',
          key: const Key('progress-scope'),
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        if (unreadable > 0)
          ErrorBanner('$unreadable drive${unreadable == 1 ? '' : 's'} on this phone could not be read and ${unreadable == 1 ? 'is' : 'are'} not counted.',
              key: const Key('progress-unreadable')),
        const SizedBox(height: Gap.m),
        Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
          for (final (id, k, v) in tiles) ProgressTile(key: Key('progress-total-$id'), label: k, value: v),
        ]),
        const SizedBox(height: Gap.xl),
        _WeekCharts(progress: p, now: now),
        const SizedBox(height: Gap.xl),
        _Records(progress: p),
        const SizedBox(height: Gap.xl),
        _Radio(progress: p, now: now),
      ],
    );
  }
}

class ProgressTile extends StatelessWidget {
  final String label, value;
  const ProgressTile({super.key, required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      width: 150,
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(Corners.small)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 2),
        Text(value, style: t.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
      ]),
    );
  }
}

class _WeekCharts extends StatelessWidget {
  final PersonalProgress progress;
  final DateTime now;
  const _WeekCharts({required this.progress, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final m = MeshSonarColors.of(context);
    final all = progress.weeks;
    final shown = all.length > chartWeeks ? all.sublist(all.length - chartWeeks) : all;
    final labels = [for (final w in shown) _day(w.monday)];
    final every = (shown.length / 6).ceil().clamp(1, 99);
    String weekName(ProgressWeek w) => 'Week ${w.isoWeek} (${_day(w.monday)})';
    final caption = '${weeksCaption(now)}${all.length > shown.length ? ' The chart shows the last $chartWeeks weeks; the table has all ${all.length}.' : ''}';
    final peak = all.reduce((a, b) => b.distanceM > a.distanceM ? b : a);
    final thisWeek = all.last;
    String plural(int n, String w) => '$n $w${n == 1 ? '' : 's'}';

    final heardWeeks = [for (final w in all) if (w.heardPercent != null) w];
    final bestHeard = heardWeeks.isEmpty ? null : heardWeeks.reduce((a, b) => b.heardPercent! > a.heardPercent! ? b : a);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('By week', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.s),
      ChartFrame(
        id: 'progress-distance',
        title: 'Distance per week (${u.longDistanceUnit})',
        summary: '${plural(all.length, 'week')}. Most: ${weekName(peak)}, ${u.distance(peak.distanceM)} in ${plural(peak.drives, 'drive')}. '
            'This week ${u.distance(thisWeek.distanceM)}.',
        caption: caption,
        table: ChartTable(head: ['Week', 'Monday', 'Drives', 'Distance', 'Pings', 'Heard'], rows: [
          for (final w in all)
            ['${w.isoYear}-W${w.isoWeek.toString().padLeft(2, '0')}', _day(w.monday), '${w.drives}', u.distance(w.distanceM), '${w.txPings}',
             w.heardPercent == null ? '—' : '${w.heardPercent}%'],
        ]),
        chart: BarChart(
          labels: labels,
          labelEvery: every,
          yLabel: u.longDistanceUnit,
          series: [BarSeries(name: 'Distance', values: [for (final w in shown) _longUnits(w.distanceM, u)], color: t.colorScheme.primary)],
        ),
      ),
      const SizedBox(height: Gap.l),
      ChartFrame(
        id: 'progress-heard',
        title: 'Heard % per week',
        summary: bestHeard == null
            ? 'No pings sent yet.'
            : 'Best ${weekName(bestHeard)}, ${bestHeard.heardPercent}% of ${bestHeard.txPings} pings. '
                '${thisWeek.heardPercent == null ? 'No pings this week.' : 'This week ${thisWeek.heardPercent}%.'}',
        caption: 'Share of your pings something answered. No bar = no pings that week. ${weeksCaption(now)}',
        table: ChartTable(head: const ['Week', 'Pings', 'Heard', 'Heard %'], rows: [
          for (final w in all) [weekName(w), '${w.txPings}', '${w.heard}', w.heardPercent == null ? '—' : '${w.heardPercent}%'],
        ]),
        chart: BarChart(
          labels: labels,
          labelEvery: every,
          yLabel: '%',
          series: [BarSeries(name: 'Heard %', values: [for (final w in shown) w.heardPercent?.toDouble()], color: m.snrStrong)],
        ),
      ),
      const SizedBox(height: Gap.l),
      ChartFrame(
        id: 'progress-cells',
        title: 'New grid cells per week',
        summary: '${progress.totalCells} grid cells in all. This week ${plural(thisWeek.newCells, 'new cell')}. '
            'Most in ${weekName(all.reduce((a, b) => b.newCells > a.newCells ? b : a))}.',
        caption: 'A cell is new the first time any drive on this phone pings in it (the website\'s coverage grid, '
            'about ${u.shortLength(220)} by ${u.shortLength(210)}). ${weeksCaption(now)}',
        table: ChartTable(head: const ['Week', 'New cells', 'Cells so far'], rows: [
          for (final w in all) [weekName(w), '${w.newCells}', '${w.totalCells}'],
        ]),
        chart: BarChart(
          labels: labels,
          labelEvery: every,
          yLabel: 'cells',
          series: [BarSeries(name: 'New cells', values: [for (final w in shown) w.newCells.toDouble()], color: t.colorScheme.primary)],
        ),
      ),
      const SizedBox(height: Gap.l),
      ChartFrame(
        id: 'progress-repeaters',
        title: 'New repeaters per week',
        summary: '${progress.totalRepeaters} repeaters heard in all. This week ${plural(thisWeek.newRepeaters, 'new repeater')}. '
            'Most in ${weekName(all.reduce((a, b) => b.newRepeaters > a.newRepeaters ? b : a))}.',
        caption: 'A repeater is new the first time any drive on this phone hears it. ${weeksCaption(now)}',
        table: ChartTable(head: const ['Week', 'New repeaters', 'Repeaters so far'], rows: [
          for (final w in all) [weekName(w), '${w.newRepeaters}', '${w.totalRepeaters}'],
        ]),
        chart: BarChart(
          labels: labels,
          labelEvery: every,
          yLabel: 'repeaters',
          series: [BarSeries(name: 'New repeaters', values: [for (final w in shown) w.newRepeaters.toDouble()], color: m.beacon)],
        ),
      ),
    ]);
  }
}

class _Records extends StatelessWidget {
  final PersonalProgress progress;
  const _Records({required this.progress});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final s = AppScope.of(context);
    String value(ProgressRecord r) {
      final d = r.drive;
      return switch (r.id) {
        'longest-distance' => u.distance(d.stats.distanceM),
        'longest-time' => formatDuration(d.stats.duration),
        'best-heard' => '${d.heardPercent}% of ${d.stats.txPings} pings',
        'most-new-cells' => '${d.newCells} new cells',
        'most-repeaters' => '${d.stats.repeaters.length} repeaters',
        _ => '${_db(d.stats.bestSnr!)} dB',
      };
    }

    const names = {
      'longest-distance': 'Longest drive',
      'longest-time': 'Longest time out',
      'best-heard': 'Best heard %',
      'most-new-cells': 'Most new grid cells',
      'most-repeaters': 'Most repeaters on one drive',
      'best-snr': 'Best SNR',
    };
    return Column(key: const Key('progress-records'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Best drives', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      Text('Tap one for its drive report. Best heard % needs at least $minPingsForHeardRecord pings.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      for (final r in progress.records)
        ListTile(
          key: Key('progress-record-${r.id}'),
          contentPadding: EdgeInsets.zero,
          title: Text(names[r.id] ?? r.id),
          subtitle: Text(driveLabel(s, r.drive.session.id, r.drive.session.label) ?? formatDateTime(r.drive.session.startedAt)),
          trailing: Text(value(r), style: t.textTheme.titleSmall),
          onTap: r.drive.stats.pings == 0 ? null : () => openDriveReport(context, r.drive.session.id),
        ),
    ]);
  }
}

/// D6: what the radio reported across drives. Only what exists: no section for data no drive has.
class _Radio extends StatelessWidget {
  final PersonalProgress progress;
  final DateTime now;
  const _Radio({required this.progress, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = AppScope.of(context);
    final noise = progress.drivesWithNoise;
    final tx = progress.drivesWithTxPower;
    final hours = progress.noiseByHour;
    String name(ProgressDrive d) => driveLabel(s, d.session.id, d.session.label) ?? formatDateTime(d.session.startedAt);
    final zone = now.toLocal().timeZoneName;
    final children = <Widget>[
      Text('Your radio', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.s),
    ];
    if (noise.isEmpty && tx.isEmpty) {
      children.add(Text('Your radio has not reported a noise floor or TX power on any drive on this phone.',
          key: const Key('progress-radio-none'), style: t.textTheme.bodyMedium));
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: children);
    }
    if (noise.isNotEmpty) {
      final meds = [for (final d in noise) d.noiseMedianDbm!];
      final loud = noise.where((d) => d.noiseMedianDbm! > noiseFloorInterferenceDbm).length;
      final quiet = noise.reduce((a, b) => b.noiseMedianDbm! < a.noiseMedianDbm! ? b : a);
      final noisy = noise.reduce((a, b) => b.noiseMedianDbm! > a.noiseMedianDbm! ? b : a);
      children.add(ChartFrame(
        id: 'progress-noise',
        title: 'Noise floor per drive (median dBm)',
        summary: '${noise.length} drive${noise.length == 1 ? '' : 's'} with readings. Quietest ${_db(quiet.noiseMedianDbm!)} dBm (${name(quiet)}), '
            'noisiest ${_db(noisy.noiseMedianDbm!)} dBm (${name(noisy)}). '
            '${loud == 0 ? 'None' : '$loud'} above ${noiseFloorInterferenceDbm.round()} dBm.',
        caption: 'One point per drive, at its start. Dashed line: ${noiseFloorInterferenceDbm.round()} dBm, where interference is likely.',
        table: ChartTable(head: const ['Drive', 'Median (dBm)', 'Readings'], rows: [
          for (final d in noise) [name(d), _db(d.noiseMedianDbm!), '${d.noiseReadings}'],
        ]),
        chart: TimeLineChart(
          series: [
            ChartSeries(name: 'Noise floor', points: [for (final d in noise) (d.session.startedAt, d.noiseMedianDbm!)], color: t.colorScheme.tertiary),
          ],
          yLabel: 'dBm',
          refLine: noiseFloorInterferenceDbm,
          refLabel: '${noiseFloorInterferenceDbm.round()} dBm',
          includeLo: meds.reduce((a, b) => a < b ? a : b),
          dotColor: (_) => t.colorScheme.tertiary,
          xFormat: (d) => _day(d.toLocal()),
        ),
      ));
      if (hours.isNotEmpty) {
        final byHour = {for (final h in hours) h.hour: h};
        final peak = hours.reduce((a, b) => b.meanDbm > a.meanDbm ? b : a);
        final calm = hours.reduce((a, b) => b.meanDbm < a.meanDbm ? b : a);
        children
          ..add(const SizedBox(height: Gap.l))
          ..add(ChartFrame(
            id: 'progress-noise-hour',
            title: 'Noise floor by hour of day (mean dBm)',
            summary: 'Noisiest ${peak.hour.toString().padLeft(2, '0')}:00, ${_db(peak.meanDbm)} dBm; quietest '
                '${calm.hour.toString().padLeft(2, '0')}:00, ${_db(calm.meanDbm)} dBm. ${hours.length} of 24 hours have readings.',
            caption: 'Every reading on every drive, by the hour of your phone\'s local time ($zone). Bars start at '
                '${noiseBaseDbm.round()} dBm; taller is noisier. No bar = no readings in that hour.',
            table: ChartTable(head: const ['Hour', 'Mean (dBm)', 'Readings'], rows: [
              for (final h in hours) ['${h.hour.toString().padLeft(2, '0')}:00', _db(h.meanDbm), '${h.n}'],
            ]),
            chart: BarChart(
              labels: [for (var h = 0; h < 24; h++) '$h'],
              labelEvery: 6,
              base: noiseBaseDbm,
              refLine: noiseFloorInterferenceDbm,
              yLabel: 'dBm',
              series: [BarSeries(name: 'Noise', values: [for (var h = 0; h < 24; h++) byHour[h]?.meanDbm], color: t.colorScheme.tertiary)],
              colorOf: (i, v) => v > noiseFloorInterferenceDbm ? t.colorScheme.error : null,
            ),
          ));
      }
    } else {
      children.add(Text('Your radio has not reported a noise floor on any drive on this phone.',
          key: const Key('progress-noise-none'), style: t.textTheme.bodyMedium));
    }
    children.add(const SizedBox(height: Gap.l));
    if (tx.isEmpty) {
      children.add(Text('No drive on this phone recorded the TX power.', key: const Key('progress-tx-none'), style: t.textTheme.bodyMedium));
    } else {
      final levels = {for (final d in tx) d.txDbm!};
      if (levels.length == 1) {
        children.add(Text('TX power ${_db(levels.single)} dBm on all ${tx.length} drive${tx.length == 1 ? '' : 's'} that recorded it.',
            key: const Key('progress-tx-constant'), style: t.textTheme.bodyMedium));
      } else {
        children.add(ChartFrame(
          id: 'progress-txpower',
          title: 'TX power per drive (dBm)',
          summary: '${tx.length} drives, from ${_db(levels.reduce((a, b) => a < b ? a : b))} to ${_db(levels.reduce((a, b) => a > b ? a : b))} dBm.',
          caption: 'The power most of each drive\'s pings were sent at. One point per drive, at its start.',
          table: ChartTable(head: const ['Drive', 'TX power (dBm)'], rows: [for (final d in tx) [name(d), _db(d.txDbm!)]]),
          chart: TimeLineChart(
            series: [ChartSeries(name: 'TX power', points: [for (final d in tx) (d.session.startedAt, d.txDbm!)], color: t.colorScheme.primary)],
            yLabel: 'dBm',
            dotColor: (_) => t.colorScheme.primary,
            xFormat: (d) => _day(d.toLocal()),
          ),
        ));
      }
    }
    return Column(key: const Key('progress-radio'), crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }
}

/// The Drives tab's progress card: this ISO week from the drive list (no ping reading), and the way into the screen.
class ProgressCard extends StatelessWidget {
  final List<SessionSummary> sessions;
  final DateTime now;
  const ProgressCard({super.key, required this.sessions, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final monday = isoMonday(now.toLocal());
    final week = [for (final x in sessions) if (!isoMonday(x.session.startedAt.toLocal()).isBefore(monday)) x];
    final tx = week.fold<int>(0, (a, x) => a + x.txCount);
    final heard = week.fold<int>(0, (a, x) => a + x.heardCount);
    final pings = week.fold<int>(0, (a, x) => a + x.pingCount);
    final line = week.isEmpty
        ? 'No drives yet this week (since Monday ${_day(monday)}).'
        : 'This week (since Monday ${_day(monday)}): ${week.length} drive${week.length == 1 ? '' : 's'}, ${groupInt(pings)} pings'
            '${tx == 0 ? '' : ', ${(100 * heard / tx).round()}% heard'}.';
    return Card(
      key: const Key('progress-card'),
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      elevation: 0,
      color: c.surfaceContainerHigh,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('open-progress'),
        onTap: () => openProgress(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Row(children: [
            Icon(Icons.insights, color: c.primary),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Your progress', style: t.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(line, key: const Key('progress-card-week'), style: t.textTheme.bodyMedium?.copyWith(color: c.onSurfaceVariant)),
              ]),
            ),
            const Icon(Icons.chevron_right),
          ]),
        ),
      ),
    );
  }
}
