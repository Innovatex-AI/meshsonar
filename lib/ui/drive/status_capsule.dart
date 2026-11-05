// StatusCapsule (Drive plan 4.1, 4.12, 4.20): the one top-trailing chip that says what the radio and the GPS are doing. It replaces
// the AppBar's ConnectionChip. Tap = the connection sheet (same destination as before). Colour is never the only signal: each dot
// has a word. At text scale >= 2.0 it collapses to a 44 pt dot button with a word-bearing VoiceOver label while the dock line
// carries the words. Debug builds with the simulator radio show an amber "SIM" badge here (there is no map-corner tag).
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/gps_health.dart';
import '../design/tokens.dart';

enum _Level { ok, warn, bad, idle }

class StatusCapsule extends StatelessWidget {
  final AppState state;
  final VoidCallback onPressed;

  /// Collapse to the 44 pt dot. Decided by the caller from the system text scale (>= 2.0), because the map overlays run under a
  /// clamped MediaQuery and could not see it.
  final bool collapsed;
  const StatusCapsule({super.key = const Key('connection-chip'), required this.state, required this.onPressed, this.collapsed = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.gpsHealth,
      builder: (context, _) => _build(context, state.gpsHealth.value),
    );
  }

  Widget _build(BuildContext context, GpsHealth h) {
    final s = state;
    final c = AppColors.fromTheme(Theme.of(context));
    final sim = s.connected && s.radioKind == RadioKind.simulator;

    final String radioWord;
    final _Level radio;
    if (s.connecting) {
      radioWord = 'Connecting';
      radio = _Level.warn;
    } else if (s.reconnecting && s.driving) {
      radioWord = 'Radio lost';
      radio = _Level.bad;
    } else if (s.connected) {
      radioWord = 'Radio';
      radio = _Level.ok;
    } else {
      radioWord = 'No radio';
      radio = _Level.idle;
    }

    // GPS: only has a health value while a drive runs; idle it follows the location permission.
    final String? gpsWord;
    final _Level gps;
    if (s.driving) {
      switch (h.kind) {
        case GpsHealthKind.good:
          gpsWord = h.accuracyM == null ? 'GPS' : 'GPS ${s.units.shortLength(h.accuracyM!)}';
          gps = _Level.ok;
        case GpsHealthKind.weak:
          gpsWord = 'GPS weak';
          gps = _Level.warn;
        case GpsHealthKind.waiting:
          gpsWord = 'GPS...';
          gps = _Level.warn;
        case GpsHealthKind.noFix:
          gpsWord = 'GPS lost';
          gps = _Level.warn;
        case GpsHealthKind.approximate:
        case GpsHealthKind.noPermission:
          gpsWord = 'GPS off';
          gps = _Level.bad;
        case GpsHealthKind.idle:
          gpsWord = 'GPS';
          gps = _Level.idle;
      }
    } else if (s.locationNote != null) {
      gpsWord = 'GPS off';
      gps = _Level.bad;
    } else {
      gpsWord = null;
      gps = _Level.ok;
    }

    Color col(_Level l) => switch (l) {
          _Level.ok => c.ok,
          _Level.warn => c.warning,
          _Level.bad => c.danger,
          _Level.idle => c.textMuted,
        };
    final label = '${sim ? 'Simulated radio. ' : ''}$radioWord${gpsWord == null ? '' : ', $gpsWord'}. Tap for connection settings';
    final scale = MediaQuery.textScalerOf(context);

    if (collapsed) {
      final dot = (radio == _Level.bad || gps == _Level.bad) ? c.danger : (radio == _Level.warn || gps == _Level.warn ? c.warning : col(radio));
      return Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onPressed,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: c.surface, shape: BoxShape.circle, border: Border.all(color: c.outline)),
              child: Center(child: Container(width: 14, height: 14, decoration: BoxDecoration(color: dot, shape: BoxShape.circle))),
            ),
          ),
        ),
      );
    }

    // Follows the system size to 1.6x, then clamps (plan 4.13).
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale.clamp(maxScaleFactor: 1.6)),
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        onTap: onPressed,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: c.outline)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.connecting)
                      SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: col(radio)))
                    else
                      _Dot(col(radio)),
                    const SizedBox(width: 6),
                    Text(radioWord, key: const Key('capsule-radio'), maxLines: 1, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary)),
                    if (gpsWord != null) ...[
                      const SizedBox(width: 10),
                      _Dot(col(gps)),
                      const SizedBox(width: 6),
                      Text(gpsWord, key: const Key('capsule-gps'), maxLines: 1, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: c.textPrimary)),
                    ],
                    if (sim) ...[
                      const SizedBox(width: 8),
                      Container(
                        key: const Key('chip-simulated'),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: c.warning, borderRadius: BorderRadius.circular(6)),
                        child: Text('SIM', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.bg)),
                      ),
                    ],
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

class _Dot extends StatelessWidget {
  final Color color;
  const _Dot(this.color);
  @override
  Widget build(BuildContext context) => Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}
