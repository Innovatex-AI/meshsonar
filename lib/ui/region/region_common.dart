// Shared bits for the region panels: status chip, relative time, injectable API factory, and the two offline states
// every panel uses (stored copy shown with "Offline - as of", or nothing stored yet with a Retry).
import 'package:flutter/material.dart';

import '../../core/region_overview_api.dart';
import '../theme.dart';
import '../widgets.dart';

/// Tests replace this to inject a fake HTTP client. Panels build their API through it.
RegionOverviewApi Function(String baseUrl) regionApiFactory = (b) =>
    RegionOverviewApi(b);

String agoText(DateTime? t, {DateTime? now}) {
  if (t == null) return 'never';
  final d = (now ?? DateTime.now()).toUtc().difference(t.toUtc());
  if (d.inSeconds < 90) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String groupInt(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return n < 0 ? '-$b' : b.toString();
}

class RegionStatusChip extends StatelessWidget {
  final RegionDataStatus status;
  const RegionStatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final m = MeshSonarColors.of(context);
    final (label, bg, fg, icon) = switch (status.state) {
      RegionDataState.ready => (
        'Ready',
        c.primaryContainer,
        c.onPrimaryContainer,
        Icons.check_circle_outline,
      ),
      RegionDataState.partial => (
        'Partial',
        m.beacon.withValues(alpha: .22),
        c.onSurface,
        Icons.timelapse,
      ),
      RegionDataState.pending => (
        'Pending',
        c.surfaceContainerHigh,
        c.onSurfaceVariant,
        Icons.hourglass_empty,
      ),
      RegionDataState.stale => (
        'Stale',
        m.beacon.withValues(alpha: .22),
        c.onSurface,
        Icons.history,
      ),
      RegionDataState.unavailable => (
        'Unavailable',
        c.errorContainer,
        c.onErrorContainer,
        Icons.error_outline,
      ),
    };
    return Container(
      key: const Key('region-status-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Corners.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: fg, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Status chip plus the server's own reason text (shown verbatim, never softened).
class RegionStatusBlock extends StatelessWidget {
  final RegionDataStatus status;
  const RegionStatusBlock(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            RegionStatusChip(status),
            const SizedBox(width: Gap.s),
            if (status.computedAt != null)
              Flexible(
                child: Text(
                  'Updated ${agoText(status.computedAt)}',
                  style: t.textTheme.labelMedium?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        if (status.reason != null) ...[
          const SizedBox(height: 6),
          Text(
            status.reason!,
            key: const Key('region-status-reason'),
            style: t.textTheme.bodyMedium?.copyWith(
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// "Offline - as of 3 h ago".
String offlineAsOfText(DateTime asOf, {DateTime? now}) => 'Offline - as of ${agoText(asOf, now: now)}';

/// The oldest of the given "as of" times (null entries are live answers), or null when none came from the stored copy.
DateTime? oldestAsOf(Iterable<DateTime?> times) {
  DateTime? oldest;
  for (final t in times) {
    if (t != null && (oldest == null || t.isBefore(oldest))) oldest = t;
  }
  return oldest;
}

/// Banner over a panel whose data is the copy stored on this phone because the network failed. One look for every
/// region panel; find it by the key `region-offline-asof`.
class RegionOfflineAsOf extends StatelessWidget {
  final DateTime asOf;
  final VoidCallback? onRetry;
  final DateTime? now;
  const RegionOfflineAsOf({super.key, required this.asOf, this.onRetry, this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return Container(
      key: const Key('region-offline-asof'),
      margin: const EdgeInsets.only(bottom: Gap.s),
      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.xs, Gap.xs, Gap.xs),
      decoration: BoxDecoration(color: c.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Row(
        children: [
          Icon(Icons.cloud_off, size: 18, color: c.onSurfaceVariant),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(
              '${offlineAsOfText(asOf, now: now)}. Showing what this phone saved.',
              key: const Key('region-offline-asof-text'),
              style: t.textTheme.labelLarge,
            ),
          ),
          if (onRetry != null)
            TextButton(key: const Key('region-offline-asof-retry'), onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// A region panel that cannot load because the server cannot be reached and nothing is stored for it yet. Says so
/// plainly (no endless spinner) and offers a Retry that refetches. Keys: `region-offline-empty`, `region-offline-retry`.
class RegionOfflineEmpty extends StatelessWidget {
  /// What could not load, e.g. "the overview".
  final String what;
  final VoidCallback onRetry;
  const RegionOfflineEmpty({super.key, required this.what, required this.onRetry});

  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: const Key('region-offline-empty'),
        child: EmptyState(
          icon: Icons.cloud_off,
          title: 'No connection',
          body: "Can't load $what: the server can't be reached and nothing for this region is saved on this phone yet. "
              'Connect to the internet and tap Retry.',
          action: FilledButton.icon(
            key: const Key('region-offline-retry'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ),
      );
}
