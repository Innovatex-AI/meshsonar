// "Did the drive keep its schedule": sent vs expected, typical and worst gap, how late pings went out, and what held them back. Read from
// the drive's trace (the engine writes a `timing` record when the drive stops), so it works for any drive recorded from this version on.
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/drive_timing.dart';
import '../theme.dart';

class DriveTimingCard extends StatelessWidget {
  final AppState state;
  final String sessionId;
  const DriveTimingCard({super.key = const Key('drive-timing'), required this.state, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DriveTimingSummary?>(
      future: state.driveTimingFor(sessionId),
      builder: (context, snap) {
        final t = snap.data;
        if (t == null || t.sent == 0) return const SizedBox.shrink();
        return DriveTimingView(summary: t, over: state.units.shortLength(50));
      },
    );
  }
}

class DriveTimingView extends StatelessWidget {
  final DriveTimingSummary summary;

  /// The 50 m flag distance in the person's units ("50 m" / "164 ft").
  final String over;
  const DriveTimingView({super.key, required this.summary, required this.over});

  static String _s(double? v) => v == null ? '-' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} s';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final s = summary;
    final held = s.skippedLine;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
      child: Material(
        color: t.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Corners.small),
        child: Padding(
          padding: const EdgeInsets.all(Gap.m),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Ping timing', style: t.textTheme.titleSmall),
              const SizedBox(height: Gap.xs),
              Text(s.line, key: const Key('timing-line'), style: t.textTheme.bodyMedium),
              Text(
                'Gap between pings: typical ${_s(s.gapP50S)}, 95% under ${_s(s.gapP95S)}, worst ${_s(s.gapMaxS)}. '
                'Late against schedule: typical ${_s(s.lateP50S)}, worst ${_s(s.lateMaxS)}.'
                '${s.firstPingS == null ? '' : ' First ping after ${_s(s.firstPingS)}.'}',
                key: const Key('timing-detail'),
                style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              if (held != null) Text(held, key: const Key('timing-held'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              if (s.lowAccuracyPings > 0)
                Text(
                  '${s.lowAccuracyPings} ping${s.lowAccuracyPings == 1 ? ' was' : 's were'} sent from a GPS fix worse than $over; its accuracy is stored with the ping.',
                  key: const Key('timing-lowacc'),
                  style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
