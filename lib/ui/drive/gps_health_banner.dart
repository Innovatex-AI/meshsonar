// The GPS health line for the drive screen: "Waiting for GPS (12 s)", "GPS weak (47 m)", "No GPS for 8 s", "Precise Location is off", with the one
// button that fixes it when there is one (lib/core/gps_health.dart is the model; AppState.gpsHealth holds the value). Self-contained and
// cheap: it listens to the ValueNotifier, which changes a few times a minute, so placing it anywhere (above the map, over it, in the
// status row) costs nothing per fix. Shows nothing outside a drive; while the GPS is fine it is one quiet line, `showWhenGood: false`
// hides even that.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/gps_health.dart';
import '../theme.dart';

class GpsHealthBanner extends StatelessWidget {
  final AppState state;
  final bool showWhenGood;
  final bool compact;
  const GpsHealthBanner({super.key = const Key('gps-health'), required this.state, this.showWhenGood = true, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<GpsHealth>(
      valueListenable: state.gpsHealth,
      builder: (context, h, _) => GpsHealthView(
        health: h,
        showWhenGood: showWhenGood,
        compact: compact,
        onAction: h.action == GpsHealthAction.none ? null : () => unawaited(state.openGpsSettings(h.action)),
      ),
    );
  }
}

/// The pure view of a [GpsHealth] (tests and the map agent can place it with any value).
class GpsHealthView extends StatelessWidget {
  final GpsHealth health;
  final bool showWhenGood;
  final VoidCallback? onAction;

  /// On a short map pane: the line and the button only. The advice would take a third of the map; Open Settings is the fix.
  final bool compact;
  const GpsHealthView({super.key, required this.health, this.showWhenGood = true, this.onAction, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final h = health;
    if (h.kind == GpsHealthKind.idle) return const SizedBox.shrink();
    if (h.kind == GpsHealthKind.good && !showWhenGood && h.advice == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    final bad = h.kind == GpsHealthKind.noPermission || h.kind == GpsHealthKind.approximate || h.kind == GpsHealthKind.noFix;
    final warn = h.kind == GpsHealthKind.weak || h.kind == GpsHealthKind.waiting;
    final color = bad ? t.colorScheme.error : (warn ? t.colorScheme.tertiary : t.colorScheme.primary);
    final icon = switch (h.kind) {
      GpsHealthKind.good => Icons.gps_fixed,
      GpsHealthKind.weak => Icons.gps_not_fixed,
      GpsHealthKind.waiting => Icons.gps_not_fixed,
      _ => Icons.gps_off,
    };
    return Semantics(
      container: true,
      liveRegion: h.needsAttention,
      label: 'GPS. ${h.line}${h.advice == null ? '' : ' ${h.advice}'}',
      child: ExcludeSemantics(
        // Opaque: over a map the words would otherwise run into the tiles and whatever sits under them.
        child: Container(
          decoration: BoxDecoration(
            color: t.colorScheme.surface,
            border: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.xs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 18, color: color)),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(h.line, key: const Key('gps-health-line'), style: t.textTheme.bodyMedium?.copyWith(color: color, fontWeight: FontWeight.w600)),
                    if (h.advice != null && !compact)
                      Text(h.advice!, key: const Key('gps-health-advice'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              if (onAction != null)
                TextButton(
                  key: const Key('gps-health-action'),
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: onAction,
                  child: const Text('Open Settings'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The GPS health banner for the top slot of a map (MapOverlayHost places the slots under it from its size, so no height
/// is measured or shared).
class GpsBannerSlot extends StatelessWidget {
  final AppState state;
  final bool compact;
  const GpsBannerSlot({super.key, required this.state, this.compact = false});

  @override
  Widget build(BuildContext context) => GpsHealthBanner(state: state, showWhenGood: false, compact: compact);
}
