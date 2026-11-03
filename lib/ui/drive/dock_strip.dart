// The reserved 28 pt strip at the top of the Drive panel (plan 4.12, R20): ONE plain sentence at a time, by priority, with the
// one fix as a real button. It replaces the full-width GPS banner and the location-note banner row. The dock row below it never
// grows; the strip is shown or hidden without moving Stop / Ping.
//
// Priority: GPS lost > Radio lost > Precise Location > permissions > unsynced pings > weak GPS (battery / storage warnings are
// not available from AppState yet; they join this list when they are).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/gps_health.dart';
import '../../core/startup_location.dart' show LocationAccess, LocationAction;
import '../design/tokens.dart';
import 'panel/panel_physics.dart' show kPanelStripHeight;

enum StripKind { gpsLost, radioLost, preciseOff, permission, unsynced, gpsWeak }

class StripInfo {
  final StripKind kind;
  final String text;

  /// The one fix, or null when the sentence is the whole message.
  final String? actionLabel;
  final VoidCallback? action;
  final bool severe;
  const StripInfo(this.kind, this.text, {this.actionLabel, this.action, this.severe = false});
}

/// The strip to show now, or null. Pure over AppState + the GPS health value (tests call it with fakes through AppState).
StripInfo? stripFor(AppState s, GpsHealth h) {
  VoidCallback? gpsAction() => h.action == GpsHealthAction.none ? null : () => unawaited(s.openGpsSettings(h.action));
  if (s.driving) {
    if (h.kind == GpsHealthKind.noFix) {
      return StripInfo(StripKind.gpsLost, 'GPS lost - pings paused', actionLabel: h.action == GpsHealthAction.none ? null : 'Open Settings', action: gpsAction(), severe: true);
    }
    if (s.reconnecting) return const StripInfo(StripKind.radioLost, 'Radio lost - reconnecting', severe: true);
    if (h.kind == GpsHealthKind.approximate) {
      return StripInfo(StripKind.preciseOff, 'Precise Location is off - data is unusable', actionLabel: 'Open Settings', action: gpsAction(), severe: true);
    }
    if (h.kind == GpsHealthKind.noPermission) {
      return StripInfo(StripKind.permission, 'Location is off for MeshSonar', actionLabel: 'Open Settings', action: gpsAction(), severe: true);
    }
    if (s.unsavedCount > 0) return StripInfo(StripKind.unsynced, '${s.unsavedCount} ping${s.unsavedCount == 1 ? '' : 's'} not saved yet - retrying');
    if (h.kind == GpsHealthKind.weak) {
      final acc = h.accuracyM;
      return StripInfo(StripKind.gpsWeak, acc == null ? 'GPS signal weak' : 'GPS signal weak (+/-${acc.round()} m)',
          actionLabel: h.action == GpsHealthAction.none ? null : 'Open Settings', action: gpsAction());
    }
    // GpsHealthKind.waiting is not trouble yet: the capsule says "GPS..." and the strip stays hidden (the panel does not jump at every start).
    return null;
  }
  // Idle: location trouble has its one-tap fix here (the old banner row is gone).
  final note = s.locationNote;
  if (note != null && !s.connecting) {
    final isPrecise = note.access == LocationAccess.approximate;
    return StripInfo(isPrecise ? StripKind.preciseOff : StripKind.permission, isPrecise ? 'Precise Location is off - data is unusable' : 'Location is off for MeshSonar',
        actionLabel: note.action == null ? null : (note.action == LocationAction.ask ? 'Allow location' : 'Open Settings'),
        action: note.action == null ? null : () => unawaited(s.resolveLocationNote()));
  }
  return null;
}

/// The strip row: icon + one line + optional button. Opaque, 28 pt, text capped at 1.3x (the dock rule).
class DockStripView extends StatelessWidget {
  final StripInfo info;
  const DockStripView({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    final color = info.severe ? c.danger : c.warning;
    final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: info.text,
        child: ExcludeSemantics(
          excluding: info.action == null,
          child: ColoredBox(
            color: c.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
              child: Row(
                children: [
                  Icon(info.severe ? Icons.error_outline_rounded : Icons.warning_amber_rounded, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(child: Text(info.text, key: const Key('dock-strip-text'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color))),
                  if (info.action != null)
                    Semantics(
                      button: true,
                      label: '${info.actionLabel}',
                      excludeSemantics: true,
                      onTap: info.action,
                      child: GestureDetector(
                        key: const Key('dock-strip-action'),
                        behavior: HitTestBehavior.opaque,
                        onTap: info.action,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: kPanelStripHeight, minWidth: 44),
                          child: Center(child: Text(info.actionLabel!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent))),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

