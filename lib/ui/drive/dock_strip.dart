// The reserved strip at the top of the Drive panel (plan 4.12, R20): ONE plain sentence at a time, by priority, with the
// one fix as a real button. It replaces the full-width GPS banner and the location-note banner row. The dock row below it never
// grows; the strip is shown or hidden without moving Stop / Ping.
//
// Build 77 (Round 1 F6): the strip is the ONE place for these messages (the half-open panel no longer repeats "pings not
// saved" or the location note), 44 pt tall (it was 28: a 28 pt tap target) and its sentence wraps to two lines.
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
      return StripInfo(StripKind.preciseOff, 'Precise Location is off', actionLabel: 'Open Settings', action: gpsAction(), severe: true);
    }
    if (h.kind == GpsHealthKind.noPermission) {
      return StripInfo(StripKind.permission, 'Location is off', actionLabel: 'Open Settings', action: gpsAction(), severe: true);
    }
    if (s.unsavedCount > 0) return StripInfo(StripKind.unsynced, '${s.unsavedCount} ping${s.unsavedCount == 1 ? '' : 's'} not yet saved to this phone - retrying');
    if (h.kind == GpsHealthKind.weak) {
      final acc = h.accuracyM;
      return StripInfo(StripKind.gpsWeak, acc == null ? 'GPS signal weak' : 'GPS signal weak (+/-${s.units.shortLength(acc)})',
          actionLabel: h.action == GpsHealthAction.none ? null : 'Open Settings', action: gpsAction());
    }
    // GpsHealthKind.waiting is not trouble yet: the capsule says "GPS..." and the strip stays hidden (the panel does not jump at every start).
    return null;
  }
  // Idle: location trouble has its one-tap fix here (the old banner row is gone).
  // Shown whatever the radio is doing (build 76). It used to hide while a connect try ran, so with location off the panel grew
  // and shrank by the strip's height on every try of the automatic reconnect (eight tries in two minutes).
  final note = s.locationNote;
  if (note != null) {
    final isPrecise = note.access == LocationAccess.approximate;
    return StripInfo(isPrecise ? StripKind.preciseOff : StripKind.permission, isPrecise ? 'Precise Location is off' : 'Location is off',
        actionLabel: note.action == null ? null : (note.action == LocationAction.ask ? 'Allow location' : 'Open Settings'),
        action: note.action == null ? null : () => unawaited(s.resolveLocationNote()));
  }
  // Idle: pings a write could not save yet (the Medium banner that said it a second time is gone, Round 1 F6). Same order
  // as while driving: after the location messages.
  if (s.unsavedCount > 0) return StripInfo(StripKind.unsynced, '${s.unsavedCount} ping${s.unsavedCount == 1 ? '' : 's'} not yet saved to this phone - retrying');
  return null;
}

/// The strip row: icon + up to two lines + optional button. Opaque, 44 pt, text capped at 1.3x (the dock rule).
class DockStripView extends StatelessWidget {
  final StripInfo info;
  const DockStripView({super.key, required this.info});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.fromTheme(Theme.of(context));
    final color = info.severe ? c.danger : c.warning;
    final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    // A location strip keeps the key of the location note it replaced in the Drive panel (Round 1 F6): 'location-note'.
    final location = info.kind == StripKind.permission || info.kind == StripKind.preciseOff;
    return MediaQuery(
      key: location ? const Key('location-note') : null,
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: Semantics(
        container: true,
        liveRegion: true,
        label: info.text,
        child: ExcludeSemantics(
          excluding: info.action == null,
          // The whole strip runs its one fix (build 76), and it is 44 pt tall (build 77).
          child: GestureDetector(
            key: info.action == null ? null : const Key('dock-strip-hit'),
            behavior: HitTestBehavior.opaque,
            onTap: info.action,
            child: ColoredBox(
            color: c.surface,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
              child: Row(
                children: [
                  Icon(info.severe ? Icons.error_outline_rounded : Icons.warning_amber_rounded, size: 16, color: color),
                  const SizedBox(width: 6),
                  Expanded(child: Text(info.text, key: const Key('dock-strip-text'), maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1.15, fontWeight: FontWeight.w600, color: color))),
                  if (info.action != null)
                    Semantics(
                      button: true,
                      label: '${info.actionLabel}',
                      excludeSemantics: true,
                      onTap: info.action,
                      child: ConstrainedBox(
                        key: const Key('dock-strip-action'),
                        constraints: const BoxConstraints(minHeight: kPanelStripHeight, minWidth: 44),
                        child: Center(child: Text(info.actionLabel!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.accent))),
                      ),
                    ),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}
