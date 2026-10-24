// Shared bits for the region panels: status chip, relative time, injectable API factory.
import 'package:flutter/material.dart';

import '../../core/region_overview_api.dart';
import '../theme.dart';

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
