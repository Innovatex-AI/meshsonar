// "Region overview": stat cards for one region, mirroring the website region home. Data: `region-overview`.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/region_overview_api.dart';
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
  Future<RegionOverview>? _future;

  @override
  void initState() {
    super.initState();
    _api = regionApiFactory(widget.baseUrl);
    _future = _api.overview();
  }

  @override
  void didUpdateWidget(OverviewPanel old) {
    super.didUpdateWidget(old);
    if (old.baseUrl != widget.baseUrl || old.regionSlug != widget.regionSlug) {
      _api.close();
      _api = regionApiFactory(widget.baseUrl);
      _reload();
    }
  }

  @override
  void dispose() {
    _api.close();
    super.dispose();
  }

  void _reload() => setState(() {
    _future = _api.overview();
  });

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
          return Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ErrorBanner('${snap.error}'),
                TextButton.icon(
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
  const OverviewContent({
    super.key,
    required this.overview,
    required this.regionSlug,
    this.onRefresh,
  });

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
        : '${_n(o.observersOnline)} / ${_n(o.observersTotal)}';
    return Column(
      key: const Key('overview-content'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Region overview', style: t.textTheme.titleLarge),
            ),
            if (onRefresh != null)
              IconButton(
                tooltip: 'Refresh',
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
              ),
          ],
        ),
        RegionStatusBlock(o.status),
        const SizedBox(height: Gap.m),
        if (noData && o.packets24h == null && o.repeaters == null)
          const EmptyState(
            icon: Icons.insights_outlined,
            title: 'No overview data yet',
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: _Card(
                  label: 'Packets, 24 h',
                  value: _n(o.packets24h),
                  valueKey: const Key('stat-packets'),
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: _Card(
                  label: 'Observers online',
                  value: observers,
                  valueKey: const Key('stat-observers'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.s),
          Row(
            children: [
              Expanded(
                child: _Card(
                  label: 'Repeaters',
                  value: _n(o.repeaters),
                  valueKey: const Key('stat-repeaters'),
                  color: MeshSonarColors.of(context).beacon,
                ),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: _Card(
                  label: 'Repeaters heard, 24 h',
                  value: _n(o.repeatersHeard24h),
                  valueKey: const Key('stat-heard'),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.s),
          _SparkCard(hours: o.packetsPerHour, lastPacketAt: o.lastPacketAt),
          if (o.recentEvents.isNotEmpty) ...[
            const SectionLabel('Recent events'),
            for (final e in o.recentEvents.take(6))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  _eventIcon(e.type),
                  size: 20,
                  color: t.colorScheme.onSurfaceVariant,
                ),
                title: Text(
                  e.detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: Text(agoText(e.at), style: t.textTheme.labelMedium),
              ),
          ],
        ],
      ],
    );
  }
}

IconData _eventIcon(String type) => switch (type) {
  'repeater_new' => Icons.add_circle_outline,
  'repeater_quiet' => Icons.volume_off_outlined,
  'link_new' => Icons.link,
  'link_lost' => Icons.link_off,
  _ => Icons.info_outline,
};

class _Card extends StatelessWidget {
  final String label, value;
  final Key valueKey;
  final Color? color;
  const _Card({
    required this.label,
    required this.value,
    required this.valueKey,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
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
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                value,
                key: valueKey,
                style: numberStyle(context, size: 34, color: color),
              ),
            ),
            const SizedBox(height: 4),
            Text(label, style: t.textTheme.labelMedium, maxLines: 2),
          ],
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
                'Last packet ${agoText(lastPacketAt)}',
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
