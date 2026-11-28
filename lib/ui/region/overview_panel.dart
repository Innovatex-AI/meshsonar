// Analytics > "Overview" (build 77, Round 2 N-U10: the app's one Overview; the website Overview row is gone). Data:
// `region-overview` (freshness, the four tap-through cards, recent events) and `GET /v1/insights/overview?window=`
// (the window picker, "Signal and traffic", one packets chart, hop counts, kinds of packets). The website's
// "Transmissions", "Data span" and its second packets chart are left out: they repeat what is here.
// An older server without `/v1/insights` shows what `region-overview` has (its 24-hour chart), and nothing else.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/network_request.dart';
import '../../core/region_overview_api.dart';
import '../../core/time_format.dart';
import '../../core/v1/insights_api.dart';
import '../../core/v1/packet_models.dart' show packetTypeLabel;
import '../network/packets/packet_ui.dart' show snrText, trimDecimals;
import '../shell/shell_controller.dart' show ShellController;
import '../charts/sparkline.dart';
import '../theme.dart';
import '../widgets.dart';
import 'region_common.dart';

class OverviewPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;
  const OverviewPanel({
    super.key,
    required this.baseUrl,
    required this.regionSlug,
  });

  @override
  State<OverviewPanel> createState() => _OverviewPanelState();
}

class _OverviewPanelState extends State<OverviewPanel> {
  late RegionOverviewApi _api;
  late InsightsApi _insightsApi;
  Future<RegionOverview>? _future;

  /// The window of the picker (`1h`, `24h`, `7d`, `30d`).
  String _window = '24h';
  InsightsOverview? _insights;
  bool _insightsLoading = false, _insightsFailed = false;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _api = regionApiFactory(widget.baseUrl);
    _insightsApi = insightsApiFactory(widget.baseUrl);
    _future = _api.overview();
    unawaited(_loadInsights());
  }

  @override
  void didUpdateWidget(OverviewPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.regionSlug != widget.regionSlug) {
      _api.close();
      _insightsApi.close();
      _api = regionApiFactory(widget.baseUrl);
      _insightsApi = insightsApiFactory(widget.baseUrl);
      _reload();
    }
  }

  @override
  void dispose() {
    _api.close();
    _insightsApi.close();
    super.dispose();
  }

  /// The window's figures. An older server (no `/v1`) or no connection leaves the section out; another failure says so
  /// with Try again.
  Future<void> _loadInsights() async {
    final g = ++_gen;
    setState(() {
      _insightsLoading = true;
      _insightsFailed = false;
    });
    InsightsOverview? got;
    var failed = false;
    try {
      got = await _insightsApi.overview(window: _window);
    } on V1NotLive {
      got = null;
    } on V1Error catch (e) {
      failed = !e.offline;
    } catch (_) {
      failed = true;
    }
    if (!mounted || g != _gen) return;
    setState(() {
      _insights = got;
      _insightsFailed = failed;
      _insightsLoading = false;
    });
  }

  void _setWindow(String w) {
    if (w == _window) return;
    _window = w;
    unawaited(_loadInsights());
  }

  void _reload() {
    setState(() {
      _future = _api.overview();
    });
    unawaited(_loadInsights());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<RegionOverview>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(Gap.xl),
            child: Center(
              child: CircularProgressIndicator(key: Key('overview-loading')),
            ),
          );
        }
        final err = snap.error;
        if (err is RegionApiException && err.offline) {
          return RegionOfflineEmpty(what: 'the overview', onRetry: _reload);
        }
        if (snap.hasError) {
          // What went wrong in plain words first, the server's own text under it, and a full-size button to retry.
          final detail = err is RegionApiException ? err.message : '${snap.error}';
          return Padding(
            key: const Key('overview-error'),
            padding: const EdgeInsets.all(Gap.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('The overview did not load', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.s),
                ErrorBanner(detail),
                const SizedBox(height: Gap.s),
                FilledButton.icon(
                  key: const Key('overview-retry'),
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
              ],
            ),
          );
        }
        final asOf = snap.data!.offlineAsOf;
        final body = OverviewContent(
          overview: snap.data!,
          regionSlug: widget.regionSlug,
          onRefresh: _reload,
          window: _window,
          onWindow: _setWindow,
          insights: _insights,
          insightsLoading: _insightsLoading,
          insightsFailed: _insightsFailed,
          onRetryInsights: _loadInsights,
        );
        if (asOf == null) return body;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [RegionOfflineAsOf(asOf: asOf, onRetry: _reload), body],
        );
      },
    );
  }
}

/// The loaded state, separate so it can be tested without HTTP.
class OverviewContent extends StatelessWidget {
  final RegionOverview overview;
  final String regionSlug;
  final VoidCallback? onRefresh;

  /// The picker's window and what a tap on it does; null [onWindow] hides the picker.
  final String window;
  final ValueChanged<String>? onWindow;

  /// `GET /v1/insights/overview` for [window]; null while loading, on an older server, or when it failed.
  final InsightsOverview? insights;
  final bool insightsLoading, insightsFailed;
  final VoidCallback? onRetryInsights;
  const OverviewContent({
    super.key,
    required this.overview,
    required this.regionSlug,
    this.onRefresh,
    this.window = '24h',
    this.onWindow,
    this.insights,
    this.insightsLoading = false,
    this.insightsFailed = false,
    this.onRetryInsights,
  });

  static String windowWords(String w) => overviewWindows.firstWhere((e) => e.$1 == w, orElse: () => (w, w)).$2;

  String _n(int? v) => v == null ? '—' : groupInt(v);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final o = overview;
    final noData =
        o.status.state == RegionDataState.unavailable ||
        o.status.state == RegionDataState.pending;
    final observers = (o.observersOnline == null && o.observersTotal == null)
        ? '—'
        : '${_n(o.observersOnline)} of ${_n(o.observersTotal)}';
    // A figure opens the list it counts (Packets, Observers, Nodes) when the panel sits in the app's shell.
    final shell = ShellController.of(context);
    VoidCallback? go(NetworkSection section) =>
        shell == null || regionSlug.isEmpty ? null : () => shell.openNetwork(NetworkRequest.section(section, region: regionSlug));
    return Column(
      key: const Key('overview-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Build 76: no second "Region overview" title (the header above already says it); the freshness line and the
        // refresh button share one row.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(padding: const EdgeInsets.only(top: 8), child: RegionStatusBlock(o.status)),
            ),
            if (onRefresh != null)
              IconButton(
                key: const Key('overview-refresh'),
                tooltip: 'Refresh',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        const SizedBox(height: Gap.s),
        if (onWindow != null) _WindowPicker(window: window, onChanged: onWindow!),
        if (noData && o.packets24h == null && o.repeaters == null && insights == null)
          EmptyState(
            icon: Icons.insights_outlined,
            title: 'No overview data yet',
            body: 'Numbers show up here once this region\'s first packets are heard.',
            action: onRefresh == null ? null : OutlinedButton(key: const Key('overview-empty-retry'), onPressed: onRefresh, child: const Text('Check again')),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: _Card(
                  // The packets of the picked window when the server counts them, else the last 24 hours.
                  label: insights?.packets != null ? 'Packets, ${windowWords(window)}' : 'Packets, 24 h',
                  value: _n(insights?.packets ?? o.packets24h),
                  valueKey: const Key('stat-packets'),
                  tapKey: const Key('stat-packets-open'),
                  hint: 'Open Packets',
                  onTap: go(NetworkSection.packets),
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: _Card(
                  label: 'Observers online',
                  value: observers,
                  valueKey: const Key('stat-observers'),
                  tapKey: const Key('stat-observers-open'),
                  hint: 'Open Observers',
                  onTap: go(NetworkSection.observers),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.s),
          Row(
            children: [
              Expanded(
                child: _Card(
                  label: 'Repeaters known',
                  value: _n(o.repeaters),
                  valueKey: const Key('stat-repeaters'),
                  tapKey: const Key('stat-repeaters-open'),
                  hint: 'Open Nodes',
                  onTap: go(NetworkSection.nodes),
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: _Card(
                  label: 'Repeaters heard, 24 h',
                  tapKey: const Key('stat-heard-open'),
                  hint: 'Open Nodes',
                  onTap: go(NetworkSection.nodes),
                  value: _n(o.repeatersHeard24h),
                  valueKey: const Key('stat-heard'),
                ),
              ),
            ],
          ),
          if (insights != null) ..._insightsBlock(context, insights!),
          if (insights == null && insightsLoading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.m),
              child: Text('Loading signal and traffic…', key: const Key('overview-insights-loading'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ),
          if (insights == null && insightsFailed)
            Padding(
              key: const Key('overview-insights-error'),
              padding: const EdgeInsets.only(top: Gap.m),
              child: Row(children: [
                Expanded(child: Text('Signal and traffic did not load.', style: t.textTheme.bodyMedium)),
                if (onRetryInsights != null) TextButton(key: const Key('overview-insights-retry'), onPressed: onRetryInsights, child: const Text('Try again')),
              ]),
            ),
          // One packets chart: the window's when the server counts it, else the last 24 hours of region-overview.
          if (insights == null || insights!.perBucket.isEmpty) ...[
            const SizedBox(height: Gap.s),
            _SparkCard(hours: o.packetsPerHour, lastPacketAt: o.lastPacketAt),
          ],
          if (o.recentEvents.isNotEmpty) ...[
            const SectionLabel('Recent events'),
            for (final e in o.recentEvents.take(6))
              // The time sits under the text, so a long repeater name keeps the full width of a phone and is not cut.
              ListTile(
                contentPadding: EdgeInsets.zero,
                minLeadingWidth: 24,
                leading: Icon(
                  _eventIcon(e.type),
                  size: 20,
                  color: t.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  e.detail,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.bodyMedium,
                ),
                subtitle: Text('${_eventWord(e.type)}${relativeTime(e.at, ifNull: 'time not known')}', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ),
          ],
        ],
      ],
    );
  }

  /// "Signal and traffic", the window's packets chart, hop counts and kinds of packets. Each part only when the server
  /// sent its numbers.
  List<Widget> _insightsBlock(BuildContext context, InsightsOverview x) {
    final t = Theme.of(context);
    final muted = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final tiles = <(String, String, String)>[
      if (x.uniqueNodes != null) ('unique', 'Nodes heard', groupInt(x.uniqueNodes!)),
      if (x.snr != null) ('signal', 'Average signal', snrText(x.snr!.mean)),
      if (x.hops != null) ('hops', 'Average hops', trimDecimals(x.hops!.mean, places: 1)),
      if (x.activeChannels != null) ('channels', 'Active channels', groupInt(x.activeChannels!)),
      if (x.packetSize != null) ('size', 'Average packet size', '${x.packetSize!.mean.round()} bytes'),
    ];
    final hopTotal = x.hopDistribution.fold<int>(0, (a, h) => a + h.$2);
    final typeTotal = x.typeMix.fold<int>(0, (a, h) => a + h.$2);
    String hopWords(int h) => h == 0 ? 'Heard direct' : '$h ${h == 1 ? 'hop' : 'hops'}';
    return [
      if (tiles.isNotEmpty) ...[
        SectionLabel('Signal and traffic, ${windowWords(window)}'),
        LayoutBuilder(builder: (context, c) {
          final w = (c.maxWidth - Gap.s) / 2;
          return Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            for (final (id, label, value) in tiles)
              SizedBox(width: w, child: _Card(label: label, value: value, valueKey: Key('overview-stat-$id'), small: true)),
          ]);
        }),
      ],
      if (x.perBucket.isNotEmpty) ...[
        const SizedBox(height: Gap.s),
        _SeriesCard(points: x.perBucket, daily: x.daily, windowWords: windowWords(window), lastPacketAt: overview.lastPacketAt),
      ],
      if (hopTotal > 0) ...[
        const SectionLabel('Hop counts'),
        for (final (h, n) in x.hopDistribution)
          if (n > 0) _ShareRow(key: Key('overview-hops-$h'), label: hopWords(h), count: n, share: n / hopTotal),
        Text('How many repeaters passed each packet on before an observer heard it.', style: muted),
      ],
      if (typeTotal > 0) ...[
        const SectionLabel('Kinds of packets'),
        for (final (type, n, share) in x.typeMix)
          if (n > 0) _ShareRow(key: Key('overview-type-$type'), label: packetTypeLabel(type), count: n, share: share ?? n / typeTotal),
      ],
    ];
  }
}

/// 1 hour, 24 hours, 7 days, 30 days.
class _WindowPicker extends StatelessWidget {
  final String window;
  final ValueChanged<String> onChanged;
  const _WindowPicker({required this.window, required this.onChanged});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.s),
        // Wraps rather than scrolls: all four windows are in view on a phone, even with large text.
        child: Wrap(
          key: const Key('overview-window'),
          spacing: Gap.s,
          runSpacing: Gap.s,
          children: [
            for (final (w, words) in overviewWindows)
              ChoiceChip(key: Key('overview-window-$w'), label: Text(words), selected: w == window, onSelected: (_) => onChanged(w)),
          ],
        ),
      );
}

/// "Heard direct · 412 · 38%" with a thin bar under it.
class _ShareRow extends StatelessWidget {
  final String label;
  final int count;
  final double share;
  const _ShareRow({super.key, required this.label, required this.count, required this.share});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final pct = (share.clamp(0.0, 1.0) * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Semantics(
        label: '$label: ${groupInt(count)} packets, $pct percent',
        child: ExcludeSemantics(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(label, style: t.textTheme.bodyMedium)),
              Text('${groupInt(count)} · $pct%', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: share.clamp(0.0, 1.0), minHeight: 4, color: t.colorScheme.primary, backgroundColor: t.colorScheme.outlineVariant),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The window's packets, one point per hour (or per day for 7 and 30 days).
class _SeriesCard extends StatelessWidget {
  final List<(DateTime, int)> points;
  final bool daily;
  final String windowWords;
  final DateTime? lastPacketAt;
  const _SeriesCard({required this.points, required this.daily, required this.windowWords, this.lastPacketAt});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final values = [for (final p in points) p.$2.toDouble()];
    final total = points.fold<int>(0, (a, p) => a + p.$2);
    final peak = points.fold<int>(0, (a, p) => math.max(a, p.$2));
    final per = daily ? 'day' : 'hour';
    final muted = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return DecoratedBox(
      key: const Key('overview-series'),
      decoration: BoxDecoration(color: t.colorScheme.surface, borderRadius: BorderRadius.circular(Corners.card), border: Border.all(color: t.colorScheme.outlineVariant)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Days are the server's UTC days, so they say so; hours follow the time setting.
          Text(daily ? utcLabel('Packets per day') : 'Packets per hour', style: t.textTheme.labelMedium),
          const SizedBox(height: Gap.s),
          Sparkline(
            key: const Key('sparkline'),
            height: 64,
            values: values,
            color: t.colorScheme.primary,
            style: SparkStyle.counts,
            fillColor: t.colorScheme.primary.withValues(alpha: .15),
            baseColor: t.colorScheme.outlineVariant,
            summary: total == 0
                ? 'Packets per $per: none in the last $windowWords.'
                : 'Packets per $per, last $windowWords: peak $peak, ${groupInt(total)} in all. ${sparkSummary(<double?>[...values], decimals: 0, gapWord: '${per}s')}',
          ),
          const SizedBox(height: 6),
          Text(total == 0 ? 'No packets in the last $windowWords' : 'Peak ${groupInt(peak)} a $per, ${groupInt(total)} in $windowWords', style: muted),
          Text(daily ? '${utcDayLabel(points.first.$1, label: false)} to ${utcDayLabel(points.last.$1)}' : '${shortDateTime(points.first.$1)} to ${shortDateTime(points.last.$1)}',
              key: const Key('overview-series-range'), style: muted),
          if (lastPacketAt != null) Text('Last packet ${relativeTime(lastPacketAt)}', style: muted),
        ]),
      ),
    );
  }
}


/// The kind of event in plain words, before its time ("Link unstable · 13 h ago"); empty for a kind the app does not know.
String _eventWord(String type) => switch (type) {
  'repeater_new' => 'New repeater · ',
  'repeater_quiet' => 'Repeater went quiet · ',
  'link_new' => 'New link · ',
  'link_lost' => 'Link lost · ',
  'link_flap' => 'Link unstable · ',
  _ => '',
};

IconData _eventIcon(String type) => switch (type) {
  'repeater_new' => Icons.add_circle_outline,
  'repeater_quiet' => Icons.volume_off_outlined,
  'link_new' => Icons.link,
  'link_lost' => Icons.link_off,
  'link_flap' => Icons.sync_problem_rounded,
  _ => Icons.info_outline,
};

class _Card extends StatelessWidget {
  final String label, value;
  final Key valueKey;
  final Key? tapKey;

  /// A smaller figure, for the "Signal and traffic" tiles.
  final bool small;

  /// Opens the list this figure counts; null = a plain figure (no shell above, as in a test of the panel alone).
  final VoidCallback? onTap;

  /// What the tap does, for a screen reader ("Open Packets").
  final String? hint;
  const _Card({
    required this.label,
    required this.value,
    required this.valueKey,
    this.tapKey,
    this.small = false,
    this.onTap,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final radius = BorderRadius.circular(Corners.card);
    return Semantics(
      button: onTap != null,
      hint: onTap == null ? null : hint,
      child: Material(
        color: t.colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: t.colorScheme.outlineVariant)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: tapKey,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    key: valueKey,
                    style: numberStyle(context, size: small ? 24 : 34),
                  ),
                ),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(child: Text(label, style: t.textTheme.labelMedium, maxLines: 2)),
                  if (onTap != null) Icon(Icons.chevron_right, size: 16, color: t.colorScheme.onSurfaceVariant),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SparkCard extends StatelessWidget {
  final List<HourlyCount> hours;
  final DateTime? lastPacketAt;
  const _SparkCard({required this.hours, required this.lastPacketAt});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final total = hours.fold<int>(0, (a, h) => a + h.n);
    final peak = hours.fold<int>(0, (a, h) => math.max(a, h.n));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(Corners.card),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Packets per hour', style: t.textTheme.labelMedium),
            const SizedBox(height: Gap.s),
            if (hours.isEmpty)
              Text(
                'No hourly data.',
                key: const Key('sparkline-empty'),
                style: t.textTheme.bodyMedium,
              )
            else ...[
              Sparkline(
                key: const Key('sparkline'),
                height: 64,
                values: [for (final h in hours) h.n.toDouble()],
                color: t.colorScheme.primary,
                style: SparkStyle.counts,
                fillColor: t.colorScheme.primary.withValues(alpha: .15),
                baseColor: t.colorScheme.outlineVariant,
                summary: total == 0
                    ? 'Packets per hour: none in the last ${hours.length} hours.'
                    : 'Packets per hour, last ${hours.length} hours: peak $peak, ${groupInt(total)} in all. '
                        '${sparkSummary([for (final h in hours) h.n.toDouble()], decimals: 0, gapWord: 'hours')}',
              ),
              const SizedBox(height: 6),
              Text(
                total == 0
                    ? 'No packets in the last ${hours.length} h'
                    : 'Peak $peak/h, ${groupInt(total)} in ${hours.length} h',
                style: t.textTheme.labelMedium?.copyWith(
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (lastPacketAt != null)
              Text(
                'Last packet ${relativeTime(lastPacketAt)}',
                style: t.textTheme.labelMedium?.copyWith(
                  color: t.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
