// "Your progress", server view: the account's history across phones and installs (`GET driver-summary`,
// lib/core/driver_summary.dart). Offered by progress_screen.dart only when the upload server advertises `driverSummary`
// and the key is approved or pending. Never mixed with the phone view: the scope line says which numbers these are and
// when they were fetched; a stored copy is labelled "Offline - as of ...". Every state has a key:
//   progress-server-loading / -error-<401|403|429|offline|other> (+ progress-server-retry) / -empty / -list,
//   progress-server-offline / -paused / -updated (status line), progress-server-skipped, progress-server-compare.
// Weeks are UTC ISO weeks (Monday start); weeks the server did not list are drawn as empty weeks (said in the caption).
import 'package:flutter/material.dart';

import '../../core/api.dart' show CmatException;
import '../../core/driver_summary.dart';
import '../../core/region_cache.dart' show asOfLabel;
import '../../core/units.dart';
import '../app.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../region/region_common.dart' show groupInt;
import '../widgets.dart';
import 'drive_report_screen.dart' show openDriveReport;
import 'progress_screen.dart' show ProgressTile, chartWeeks;

/// The summary plus the ids of the drives stored on this phone (for "on this phone" and the compare line).
class ServerLoad {
  final DriverSummaryResult result;
  final Set<String> localIds;
  const ServerLoad(this.result, this.localIds);
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _day(DateTime d) => '${_months[d.month - 1]} ${d.day}'; // a UTC Monday: read the calendar fields as they are
String _date(DateTime t) {
  final l = t.toLocal();
  return '${l.day} ${_months[l.month - 1]} ${l.year}';
}

const serverWeeksCaption =
    'Weeks start on Monday, UTC. A drive counts in the week it started. Weeks the server lists no drive for are drawn as empty weeks.';

/// Plain words for a failed ask: (key suffix, text, offer retry).
({String id, String text, bool retry}) serverSummaryError(Object e) {
  if (e is CmatException) {
    switch (e.status) {
      case 401:
        return (id: '401', text: 'The server does not recognise this driver key, so it cannot share your history. Check the key in Settings.', retry: false);
      case 403:
        final why = switch (e.serverStatus) {
          'rejected' => 'This driver key was rejected',
          'revoked' => 'This driver key was revoked',
          'banned' => 'This driver is banned',
          _ => 'This driver key is not allowed',
        };
        return (id: '403', text: '$why, so the server will not share your history. Your drives on this phone are still here.', retry: false);
      case 429:
        return (id: '429', text: 'The server asked for a pause (too many requests). Try again in a minute.', retry: true);
      case null:
        return (
          id: 'offline',
          text: 'No connection to the server, and no copy of your history is stored on this phone yet. '
              'Your drives on this phone are still under "On this phone".',
          retry: true
        );
      default:
        return (id: 'other', text: 'The server answered with an error (${e.status}), so your history cannot be shown.', retry: true);
    }
  }
  return (id: 'other', text: 'Couldn\'t load your history from the server.', retry: true);
}

class ServerProgressPanel extends StatelessWidget {
  final Future<ServerLoad> future;
  final VoidCallback onRetry;
  final Future<void> Function() onRefresh;
  const ServerProgressPanel({super.key, required this.future, required this.onRetry, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ServerLoad>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(key: Key('progress-server-loading')));
        }
        if (snap.hasError) {
          final e = serverSummaryError(snap.error!);
          return ListView(padding: const EdgeInsets.all(Gap.l), children: [
            ErrorBanner(e.text, key: Key('progress-server-error-${e.id}')),
            if (e.retry) ...[
              const SizedBox(height: Gap.m),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  key: const Key('progress-server-retry'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ),
            ],
          ]);
        }
        return RefreshIndicator(onRefresh: onRefresh, child: _ServerBody(load: snap.data!));
      },
    );
  }
}

class _ServerBody extends StatelessWidget {
  final ServerLoad load;
  const _ServerBody({required this.load});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final s = AppScope.of(context);
    final now = s.services.clock();
    final r = load.result;
    final d = r.summary;
    final st = d.stats;
    final children = <Widget>[];

    final first = st.firstDriveAt;
    children.add(Text(
      'Across all your drives on the server, from every phone and install on this account'
      '${first == null ? '' : ', since ${_date(first)}'}. Drives only on this phone and not uploaded are not included.',
      key: const Key('progress-server-scope'),
      style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
    ));
    children.add(const SizedBox(height: Gap.s));
    final when = asOfLabel(r.fetchedAt, now.toUtc(), offline: r.offline);
    if (r.offline) {
      children.add(_Status(const Key('progress-server-offline'), Icons.cloud_off, '$when. Pull down to refresh when back online.'));
    } else if (r.paused) {
      children.add(_Status(const Key('progress-server-paused'), Icons.hourglass_top,
          'The server asked for a pause, so this is the copy from ${asOfLabel(r.fetchedAt, now.toUtc(), offline: false).replaceFirst('Updated ', '')}. Try again in a minute.'));
    } else {
      children.add(_Status(const Key('progress-server-updated'), Icons.cloud_done_outlined, when));
    }
    if (d.skipped > 0) {
      children.add(ErrorBanner('${d.skipped} row${d.skipped == 1 ? '' : 's'} from the server could not be read and ${d.skipped == 1 ? 'is' : 'are'} left out.',
          key: const Key('progress-server-skipped')));
    }
    children.add(const SizedBox(height: Gap.m));

    if (d.isEmpty) {
      children.add(const EmptyState(
        key: Key('progress-server-empty'),
        icon: Icons.cloud_queue,
        title: 'No drives uploaded yet',
        body: 'Drives appear here once they are uploaded to the server with your driver key. Drives on this phone are under "On this phone".',
      ));
      return _list(children);
    }

    String n(int? v) => v == null ? '—' : groupInt(v);
    final tiles = <(String, String, String)>[
      ('drives', 'Drives', n(st.drives ?? d.drives.length)),
      ('distance', 'Distance', st.km == null ? '—' : u.distance(st.km! * 1000)),
      ('pings', 'Pings', n(st.pings)),
      ('heard', 'Heard', st.heardPercent == null ? '—' : '${st.heardPercent}%'),
      ('cells', 'Grid cells', n(st.cells)),
      ('repeaters', 'Repeaters heard', n(st.repeatersHeard)),
      ('first', 'First drive', first == null ? '—' : _date(first)),
      ('last', 'Latest drive', st.lastDriveAt == null ? '—' : _date(st.lastDriveAt!)),
    ];
    children.add(Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
      for (final (id, k, v) in tiles) ProgressTile(key: Key('progress-server-total-$id'), label: k, value: v),
    ]));

    if (st.settledPings != null && st.confirmedPings != null) {
      children
        ..add(const SizedBox(height: Gap.m))
        ..add(Text(
          st.confirmedPercent == null
              ? 'Mesh confirmation: no ping has settled yet. A ping waits a few minutes for an observer to confirm it.'
              : 'Confirmed by the mesh: ${st.confirmedPercent}% (${groupInt(st.confirmedPings!)} of ${groupInt(st.settledPings!)} settled pings). '
                  'Pings still waiting for confirmation are left out of both numbers.',
          key: const Key('progress-server-confirmed'),
          style: t.textTheme.bodyMedium,
        ));
    }

    // Compare with this phone, by drive id (only what the server listed: the newest 200 at most).
    final onPhone = [for (final x in d.drives) if (load.localIds.contains(x.id)) x].length;
    final notHere = d.drives.length - onPhone;
    final listed = d.drives.length;
    final total = st.drives ?? listed;
    children
      ..add(const SizedBox(height: Gap.s))
      ..add(Text(
        notHere == 0
            ? 'All $listed drive${listed == 1 ? '' : 's'} listed here ${listed == 1 ? 'is' : 'are'} also stored on this phone.'
            : 'The server has $notHere drive${notHere == 1 ? '' : 's'} that ${notHere == 1 ? 'is' : 'are'} not on this phone '
                '(deleted here, or recorded on another phone). $onPhone of the $listed listed ${onPhone == 1 ? 'is' : 'are'} on this phone.',
        key: const Key('progress-server-compare'),
        style: t.textTheme.bodyMedium,
      ));
    children.add(const SizedBox(height: Gap.xl));

    // Weekly charts.
    final all = d.weeksFilled(now);
    if (all.isNotEmpty) {
      final shown = all.length > chartWeeks ? all.sublist(all.length - chartWeeks) : all;
      final labels = [for (final w in shown) _day(w.monday)];
      final every = (shown.length / 6).ceil().clamp(1, 99);
      String weekName(ServerWeek w) => 'Week of ${_day(w.monday)}';
      final caption = '$serverWeeksCaption${all.length > shown.length ? ' The chart shows the last $chartWeeks weeks; the table has all ${all.length}.' : ''}';
      final last = all.last;
      final km = [for (final w in all) if (w.km != null) w];
      final peak = km.isEmpty ? null : km.reduce((a, b) => b.km! > a.km! ? b : a);
      final heardWeeks = [for (final w in all) if (w.heardPercent != null) w];
      final bestHeard = heardWeeks.isEmpty ? null : heardWeeks.reduce((a, b) => b.heardPercent! > a.heardPercent! ? b : a);
      final cellsWeeks = [for (final w in all) if (w.newCells != null) w];
      final peakCells = cellsWeeks.isEmpty ? null : cellsWeeks.reduce((a, b) => b.newCells! > a.newCells! ? b : a);
      final m = MeshSonarColors.of(context);
      String dist(double? v) => v == null ? '—' : u.distance(v * 1000);
      children.addAll([
        Text('By week', style: t.textTheme.titleMedium),
        const SizedBox(height: Gap.s),
        ChartFrame(
          id: 'server-distance',
          title: 'Distance per week (${u.longDistanceUnit})',
          summary: '${all.length} weeks. ${peak == null ? 'No distance reported.' : 'Most: ${weekName(peak)}, ${dist(peak.km)} in ${peak.drives ?? 0} drive${peak.drives == 1 ? '' : 's'}.'} '
              '${last.km == null ? '' : 'This week ${dist(last.km)}.'}',
          caption: caption,
          table: ChartTable(head: const ['Week of (Monday, UTC)', 'Drives', 'Distance', 'Pings', 'Heard'], rows: [
            for (final w in all)
              [_day(w.monday), w.drives?.toString() ?? '—', dist(w.km), w.pings?.toString() ?? '—', w.heardPercent == null ? '—' : '${w.heardPercent}%'],
          ]),
          chart: BarChart(
            labels: labels,
            labelEvery: every,
            yLabel: u.longDistanceUnit,
            series: [BarSeries(name: 'Distance', values: [for (final w in shown) w.km == null ? null : w.km! * 1000 / u.metresPerLongUnit], color: t.colorScheme.primary)],
          ),
        ),
        const SizedBox(height: Gap.l),
        ChartFrame(
          id: 'server-heard',
          title: 'Heard % per week',
          summary: bestHeard == null
              ? 'No pings sent yet.'
              : 'Best ${weekName(bestHeard)}, ${bestHeard.heardPercent}% of ${bestHeard.pings} pings. '
                  '${last.heardPercent == null ? 'No pings this week.' : 'This week ${last.heardPercent}%.'}',
          caption: 'Share of pings something answered. No bar = no pings that week. $serverWeeksCaption',
          table: ChartTable(head: const ['Week of (Monday, UTC)', 'Pings', 'Heard', 'Heard %'], rows: [
            for (final w in all) [_day(w.monday), w.pings?.toString() ?? '—', w.heardPings?.toString() ?? '—', w.heardPercent == null ? '—' : '${w.heardPercent}%'],
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
          id: 'server-cells',
          title: 'New grid cells per week',
          summary: '${st.cells == null ? 'Grid cells not reported.' : '${groupInt(st.cells!)} grid cells in all.'} '
              '${last.newCells == null ? '' : 'This week ${last.newCells} new cell${last.newCells == 1 ? '' : 's'}.'} '
              '${peakCells == null ? '' : 'Most in ${weekName(peakCells)}, ${peakCells.newCells}.'}',
          caption: 'A cell is new the first time any of your drives pings in it (the website\'s coverage grid, about ${u.shortLength(220)} by ${u.shortLength(210)}). $serverWeeksCaption',
          table: ChartTable(head: const ['Week of (Monday, UTC)', 'New cells'], rows: [
            for (final w in all) [_day(w.monday), w.newCells?.toString() ?? '—'],
          ]),
          chart: BarChart(
            labels: labels,
            labelEvery: every,
            yLabel: 'cells',
            series: [BarSeries(name: 'New cells', values: [for (final w in shown) w.newCells?.toDouble()], color: t.colorScheme.primary)],
          ),
        ),
        const SizedBox(height: Gap.xl),
      ]);
    }

    // Drive list.
    children.add(Text('Drives on the server', style: t.textTheme.titleMedium));
    children.add(Text(
      listed < total
          ? 'The newest $listed of ${groupInt(total)}. Tap one for its details; a drive that is also on this phone opens its drive report.'
          : 'Newest first. Tap one for its details; a drive that is also on this phone opens its drive report.',
      key: const Key('progress-server-drives-note'),
      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
    ));
    for (final x in d.drives) {
      children.add(_DriveRow(drive: x, here: load.localIds.contains(x.id), units: u));
    }
    return _list(children);
  }

  Widget _list(List<Widget> children) => ListView(
        key: const Key('progress-server-list'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
        children: children,
      );
}

class _Status extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Status(Key key, this.icon, this.text) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 16, color: t.colorScheme.onSurfaceVariant),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
    ]);
  }
}

class _DriveRow extends StatelessWidget {
  final ServerDrive drive;
  final bool here;
  final Units units;
  const _DriveRow({required this.drive, required this.here, required this.units});

  @override
  Widget build(BuildContext context) {
    final x = drive;
    final t = Theme.of(context);
    final review = x.reviewWords;
    return ListTile(
      key: Key('progress-server-drive-${x.id}'),
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 12,
      title: Text(x.label ?? formatDateTime(x.startedAt)),
      subtitle: Text([
        if (x.label != null) formatDateTime(x.startedAt),
        [
          if (x.pings != null) '${groupInt(x.pings!)} pings',
          if (x.heardPercent != null) '${x.heardPercent}% heard',
          if (x.km != null) units.distance(x.km! * 1000),
        ].join(' · '),
        if (here) 'Also on this phone',
        ?review,
      ].where((e) => e.isNotEmpty).join('\n')),
      isThreeLine: false,
      trailing: Icon(here ? Icons.chevron_right : Icons.info_outline, color: t.colorScheme.onSurfaceVariant),
      onTap: () => here ? openDriveReport(context, x.id) : _sheet(context, x, units),
    );
  }
}

void _sheet(BuildContext context, ServerDrive x, Units u) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      final t = Theme.of(context);
      final review = x.reviewWords;
      Widget row(String k, String v) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 2, child: Text(k, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
              Expanded(flex: 3, child: Text(v, style: t.textTheme.bodyMedium)),
            ]),
          );
      return SafeArea(
        child: SingleChildScrollView(
          key: const Key('progress-server-drive-sheet'),
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(x.label ?? formatDateTime(x.startedAt), style: t.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text('This drive is on the server but not on this phone.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.s),
            row('Started', formatDateTime(x.startedAt)),
            row('Ended', x.endedAt == null ? 'not recorded' : formatDateTime(x.endedAt!)),
            if (x.callsign != null) row('Driver', x.callsign!),
            row('Distance', x.km == null ? '—' : u.distance(x.km! * 1000)),
            row('Pings', x.pings == null ? '—' : groupInt(x.pings!)),
            row('Heard', x.heardPercent == null ? '—' : '${x.heardPercent}% (${x.heardPings} of ${x.pings})'),
            row('Repeaters', x.repeaters == null ? '—' : groupInt(x.repeaters!)),
            row('Best SNR', x.bestSnr == null ? '—' : '${x.bestSnr!.toStringAsFixed(1)} dB'),
            if (x.settledPings != null && x.confirmedPings != null && x.settledPings! > 0)
              row('Confirmed by the mesh', '${x.confirmedPings} of ${x.settledPings} settled pings'),
            if (review != null) row('Status', review),
            if (x.flags.isNotEmpty) row('Flags', x.flags.join(', ')),
            const SizedBox(height: Gap.s),
            Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))),
          ]),
        ),
      );
    },
  );
}
