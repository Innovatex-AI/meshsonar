// The mini drive bar: a slim, always-there summary of a running drive, shown above the tab bar on every tab except the
// Map tab (which already is the drive screen). Live dot, pings sent / heard, what the next ping is waiting for, the
// last SNR, Pause pings and Stop (with the usual confirm). Tapping the summary opens the Map tab in Drive mode.
//
// API for the shell: `MiniDriveBar(onOpen: ...)`; it reads AppState itself and renders nothing when no drive runs.
// Pure text logic is in [miniBarSummary] so tests and the accessibility label share it.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/units.dart';
import '../../radio/radio_api.dart';
import '../../app/app_state.dart';
import '../app.dart';
import '../drive/drive_controls.dart' show LiveDot, confirmStopDrive;
import '../widgets.dart' show bestSnr;

/// Text the bar shows for a drive, split for layout (visual) and one sentence for screen readers.
class MiniBarSummary {
  /// "12 pings · 8 heard"
  final String counts;

  /// What the next ping is waiting for ("Next ping 14 s", "Move 40 m", "Waiting for GPS", "Paused", ...).
  final String waiting;

  /// "+6.5 dB", "none" (heard nothing) or null (no ping yet).
  final String? snr;

  /// True when the SNR is a measured reading (strength colour allowed); false for "none".
  final bool snrMeasured;
  final double? snrValue;
  final bool problem;
  const MiniBarSummary(this.counts, this.waiting, this.snr, this.snrMeasured, this.snrValue, this.problem);

  String get spoken =>
      'Drive in progress. $counts. $waiting.${snr == null ? '' : ' Last SNR ${snrValue != null ? '${snrValue!.toStringAsFixed(1)} decibels' : snr}.'}';
}

MiniBarSummary miniBarSummary(AppState s, {Units? units}) {
  final u = units ?? s.units;
  final st = s.status;
  final n = s.pingCount;
  final counts = s.settings.discoveryMode
      ? '${s.heardCount} heard'
      : '$n ${n == 1 ? 'ping' : 'pings'} · ${s.heardCount} heard';
  String waiting;
  var problem = false;
  if (s.reconnecting) {
    waiting = 'Radio reconnecting';
    problem = true;
  } else if (st.state == EngineState.error || !s.connected) {
    waiting = st.state == EngineState.error ? 'Radio problem' : 'Waiting for radio';
    problem = true;
  } else if (s.settings.discoveryMode) {
    waiting = 'Listening only';
  } else if (s.pingsPaused) {
    waiting = 'Pings paused';
  } else if (s.pinging || st.state == EngineState.pinging) {
    waiting = 'Listening for echoes';
  } else if (st.waitingFor == PingWait.gps) {
    waiting = 'Waiting for GPS';
  } else if (st.waitingFor == PingWait.distance && st.metresToGo != null && st.metresToGo! > 0) {
    waiting = 'Move ${u.shortLength(st.metresToGo!.ceilToDouble())}';
  } else {
    final next = st.nextPingAt;
    final secs = next == null ? 0 : (next.difference(s.services.clock()).inMilliseconds / 1000).ceil();
    if (st.waitingFor == PingWait.distance) {
      waiting = 'Keep moving';
    } else if (secs > 0) {
      waiting = 'Next ping ${secs.clamp(0, 9999)} s';
    } else {
      waiting = 'Ping due';
    }
  }
  final last = s.recentPings.isEmpty ? null : s.recentPings.first;
  String? snr;
  double? v;
  var measured = false;
  if (last != null) {
    if (last.heardNothing) {
      snr = 'none';
    } else {
      v = bestSnr(last);
      if (v == null) {
        snr = '—';
      } else {
        measured = true;
        snr = '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} dB';
      }
    }
  }
  return MiniBarSummary(counts, waiting, snr, measured, v, problem);
}

/// Smallest height of the bar; its buttons are 48 square so the bar is 48 tall.
const double miniDriveBarHeight = 48;

class MiniDriveBar extends StatefulWidget {
  /// Tapped on the summary: open the Map tab in Drive mode.
  final VoidCallback onOpen;
  const MiniDriveBar({super.key, required this.onOpen});
  @override
  State<MiniDriveBar> createState() => _MiniDriveBarState();
}

class _MiniDriveBarState extends State<MiniDriveBar> {
  Timer? _tick;

  void _wantTick(bool on) {
    if (on && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!on && _tick != null) {
      _tick!.cancel();
      _tick = null;
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (!s.driving) {
      _wantTick(false);
      return const SizedBox.shrink();
    }
    final next = s.status.nextPingAt;
    _wantTick(next != null && TickerMode.valuesOf(context).enabled && next.isAfter(s.services.clock()));

    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final sum = miniBarSummary(s, units: AppScope.unitsOf(context));
    final discovery = s.settings.discoveryMode;
    final paused = s.pingsPaused;
    // The bar never grows past 1.6x text: a persistent strip must not swallow the screen. Screen readers get the whole
    // sentence regardless, and Dynamic Type 2.5x still reads everywhere else.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    final snrColor = sum.snr == null
        ? null
        : sum.snrMeasured
            ? mc.forPing(heard: true, snr: sum.snrValue)
            : (sum.snr == 'none' ? mc.silent : null);

    final dotColor = sum.problem ? t.colorScheme.error : (paused ? t.colorScheme.outline : t.colorScheme.primary);
    final small = t.textTheme.labelMedium!;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: Material(
        key: const Key('mini-drive-bar'),
        color: t.colorScheme.surfaceContainerHigh,
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: t.colorScheme.outlineVariant))),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: miniDriveBarHeight),
            child: Row(
              children: [
                Expanded(
                  child: Semantics(
                    button: true,
                    container: true,
                    label: sum.spoken,
                    hint: 'Opens the Map tab',
                    onTap: widget.onOpen,
                    child: ExcludeSemantics(
                      child: InkWell(
                        key: const Key('mini-bar-open'),
                        onTap: widget.onOpen,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: miniDriveBarHeight),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 4),
                            child: Row(
                              children: [
                                if (paused)
                                  Icon(Icons.pause_circle_outline_rounded, size: 16, color: dotColor)
                                else
                                  LiveDot(color: dotColor),
                                const SizedBox(width: Gap.m),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(sum.counts,
                                          key: const Key('mini-bar-counts'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: numberStyle(context, size: 15)),
                                      Text.rich(
                                        TextSpan(children: [
                                          TextSpan(text: sum.waiting),
                                          if (sum.snr != null) ...[
                                            const TextSpan(text: '  ·  SNR '),
                                            TextSpan(
                                              text: sum.snr,
                                              style: TextStyle(color: snrColor, fontWeight: FontWeight.w700),
                                            ),
                                          ],
                                        ]),
                                        key: const Key('mini-bar-waiting'),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: small.copyWith(
                                            color: sum.problem ? t.colorScheme.error : t.colorScheme.onSurfaceVariant),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (!discovery)
                  IconButton(
                    key: const Key('mini-bar-pause'),
                    tooltip: paused ? 'Resume pings' : 'Pause pings',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    onPressed: s.busy ? null : () => s.setPingsPaused(!paused),
                    icon: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 26),
                  ),
                IconButton(
                  key: const Key('mini-bar-stop'),
                  tooltip: 'Stop drive',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  color: t.colorScheme.error,
                  onPressed: s.busy
                      ? null
                      : () async {
                          if (await confirmStopDrive(context)) unawaited(s.stopDrive());
                        },
                  icon: const Icon(Icons.stop_rounded, size: 28),
                ),
                const SizedBox(width: Gap.xs),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
