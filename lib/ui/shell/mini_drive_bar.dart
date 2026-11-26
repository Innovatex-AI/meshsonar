// Build 76: a second small line (counts and what the next ping waits for), a chevron, and Stop as a labelled button.
// The mini drive bar (plan 4.16): a 56 pt, opaque summary of a running drive, shown above the tab bar on every tab except
// Drive (which already is the drive screen, its dock is the bar) and never while Drive is Immersive. Status dot, one hero
// ("2 heard" / "No echo" for the last ping), elapsed time (tabular) and Stop (44 pt, trailing, the usual confirm).
// Tapping the body opens the Drive tab. Pause lives in the Drive controls only.
//
// API for the shell: `MiniDriveBar(onOpen: ...)`; it reads AppState itself and renders nothing when no drive runs.
// Pure text logic is in [miniBarSummary] so tests and the accessibility label share it.

import 'package:flutter/material.dart';

import '../../core/model.dart' show PingKind;
import '../../core/units.dart';
import '../../radio/radio_api.dart';
import '../../app/app_state.dart';
import '../app.dart';
import '../drive/drive_controls.dart' show LiveDot, confirmAndStopDrive;
import '../drive/radio_link_status.dart';
import '../drive/drive_clock.dart';
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

  /// The bar's second line: only what the headline does not say, in few words ("12 pings · Next ping 14 s",
  /// "12 pings · Listening"). Short enough to show whole on a 375 pt phone beside the time and Stop.
  final String detail;
  const MiniBarSummary(this.counts, this.waiting, this.snr, this.snrMeasured, this.snrValue, this.problem, {this.detail = ''});

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
  // The same state in fewer words for the bar's second line; null = the same words as [waiting].
  String? brief;
  var problem = false;
  // The radio words are the shared ones (RadioLinkStatus): "Reconnecting…" and "Not connected", as on the Dock, the chip and the pill.
  if (s.reconnecting) {
    waiting = RadioLinkStatus.reconnectingLabel;
    problem = true;
  } else if (st.state == EngineState.error || !s.connected) {
    waiting = st.state == EngineState.error ? 'Radio problem' : const RadioLinkStatus(RadioLink.notConnected).statusLabel;
    problem = true;
  } else if (s.settings.discoveryMode) {
    waiting = 'Listening only';
  } else if (s.pingsPaused) {
    waiting = 'Pings paused';
    brief = 'Paused';
  } else if (s.pinging || st.state == EngineState.pinging) {
    waiting = 'Listening for echoes';
    brief = 'Listening';
  } else if (st.waitingFor == PingWait.gps) {
    waiting = 'Waiting for GPS';
    brief = 'No GPS fix';
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
  // Discovery sends no pings, so its count is what was heard; otherwise the headline already says what was heard.
  final lead = s.settings.discoveryMode ? counts : '$n ${n == 1 ? 'ping' : 'pings'}';
  return MiniBarSummary(counts, waiting, snr, measured, v, problem, detail: '$lead · ${brief ?? waiting}');
}

/// Height of the bar (plan 4.16).
const double miniDriveBarHeight = 56;

/// The Stop button's square (plan 4.16: 44 pt).
const double miniDriveBarStopSize = 44;

/// Clear space between Stop and the screen edge (plus the system inset in landscape).
const double miniDriveBarEdge = 12;

/// "5:07" or "1:05:07" for [d] (m:ss under an hour).
String miniBarElapsed(Duration d) {
  final secs = d.inSeconds < 0 ? 0 : d.inSeconds;
  final h = secs ~/ 3600, m = (secs % 3600) ~/ 60, sec = secs % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// What the bar's hero says and the sentence VoiceOver reads for the whole drive.
class MiniBarHero {
  /// "2 heard", "No echo", "No pings yet" or the problem ("Reconnecting…").
  final String text;
  final bool problem;

  /// "Drive in progress, 2 repeaters heard last ping, 18 minutes".
  final String spoken;
  const MiniBarHero(this.text, this.problem, this.spoken);
}

MiniBarHero miniBarHero(AppState s, {Duration? elapsed}) {
  final sum = miniBarSummary(s);
  final e = elapsed ?? _elapsed(s);
  final mins = e.inMinutes;
  final time = mins < 1 ? 'less than a minute' : '$mins ${mins == 1 ? 'minute' : 'minutes'}';
  ({int heard, bool silent})? last;
  for (final p in s.recentPings) {
    if (p.kind == PingKind.tx) {
      last = (heard: p.echoes.map((x) => x.repeater).toSet().length, silent: p.heardNothing);
      break;
    }
  }
  String text, said;
  if (sum.problem) {
    text = sum.waiting;
    said = sum.waiting.toLowerCase();
  } else if (last == null) {
    text = 'No pings yet';
    said = 'no pings yet';
  } else if (last.silent || last.heard == 0) {
    text = 'No echo';
    said = 'no repeaters heard last ping';
  } else {
    text = '${last.heard} heard';
    said = '${last.heard} ${last.heard == 1 ? 'repeater' : 'repeaters'} heard last ping';
  }
  return MiniBarHero(text, sum.problem, 'Drive in progress, $said, $time');
}

Duration _elapsed(AppState s) {
  final start = s.currentSession?.startedAt;
  if (start == null) return Duration.zero;
  final d = s.services.clock().difference(start);
  return d.isNegative ? Duration.zero : d;
}

class MiniDriveBar extends StatefulWidget {
  /// Tapped on the body: open the Drive tab.
  final VoidCallback onOpen;
  const MiniDriveBar({super.key, required this.onOpen});
  @override
  State<MiniDriveBar> createState() => _MiniDriveBarState();
}

class _MiniDriveBarState extends State<MiniDriveBar> with DriveClock {

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (!s.driving) {
      wantClock(false);
      return const SizedBox.shrink();
    }
    wantClock(true);

    final t = Theme.of(context);
    final elapsed = _elapsed(s);
    final hero = miniBarHero(s, elapsed: elapsed);
    final sum = miniBarSummary(s);
    final paused = s.pingsPaused;
    // The bar never grows past 1.6x text: a persistent strip must not swallow the screen. Screen readers get the whole
    // sentence regardless, and Dynamic Type 2.5x still reads everywhere else.
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.6);
    // A narrow phone at large text (320 pt at 1.3x and up): Stop keeps its icon alone and the chevron goes, so the text keeps room.
    final tight = MediaQuery.sizeOf(context).width < 360 && scaler.scale(10) >= 12.5;
    // Landscape: keep clear of the notch and the rounded corners.
    final safe = MediaQuery.paddingOf(context);
    // The headline already says it ("1 heard" in Discovery): no second copy on line 2.
    final detail = sum.detail.startsWith('${hero.text} · ') ? sum.detail.substring(hero.text.length + 3) : sum.detail;
    final dotColor = hero.problem ? t.colorScheme.error : (paused ? t.colorScheme.outline : t.colorScheme.primary);
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
                    label: hero.spoken,
                    hint: 'Opens the Drive tab',
                    onTap: widget.onOpen,
                    child: ExcludeSemantics(
                      child: InkWell(
                        key: const Key('mini-bar-open'),
                        onTap: widget.onOpen,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: miniDriveBarHeight),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(Gap.l + safe.left, 4, Gap.s, 4),
                            child: Row(
                              children: [
                                if (hero.problem && !s.connected)
                                  // The radio is the problem: the same glyph and spinner as the Dock (RadioLinkStatus).
                                  RadioLinkStatus.of(s).leading(context, size: 16, color: dotColor)
                                else if (paused)
                                  Icon(Icons.pause_circle_outline_rounded, size: 16, color: dotColor)
                                else
                                  LiveDot(color: dotColor),
                                const SizedBox(width: Gap.s),
                                // Line 1: the headline and, at its right, the time driven. Line 2 runs the full width
                                // under both, so "12 pings · Next ping 14 s" shows whole on a 375 pt phone.
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment: CrossAxisAlignment.center,
                                        children: [
                                          Expanded(
                                            child: Text(hero.text,
                                                key: const Key('mini-bar-hero'),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: numberStyle(context, size: 17)
                                                    .copyWith(color: hero.problem ? t.colorScheme.error : null)),
                                          ),
                                          const SizedBox(width: Gap.s),
                                          Text(miniBarElapsed(elapsed),
                                              key: const Key('mini-bar-elapsed'),
                                              maxLines: 1,
                                              style: t.textTheme.bodyMedium!.copyWith(
                                                  height: 1.0,
                                                  color: t.colorScheme.onSurfaceVariant,
                                                  fontFeatures: const [FontFeature.tabularFigures()])),
                                        ],
                                      ),
                                      // Build 76: what the drive is doing right now ("12 pings · Next ping 14 s", "Paused"),
                                      // so nobody has to open the Drive tab to see that it is still working. Never what
                                      // the headline already says.
                                      if (!hero.problem) ...[
                                        const SizedBox(height: 3),
                                        Text(detail,
                                            key: const Key('mini-bar-next'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: t.textTheme.bodySmall!.copyWith(
                                                color: t.colorScheme.onSurfaceVariant,
                                                fontFeatures: const [FontFeature.tabularFigures()])),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: Gap.xs),
                                // A chevron: the bar opens the Drive tab (it looked like a plain status line).
                                if (!tight) Icon(Icons.chevron_right, size: 20, color: t.colorScheme.onSurfaceVariant),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                // A labelled Stop button like the dock's (build 76): a bare red square read as a recording light.
                FilledButton(
                  key: const Key('mini-bar-stop'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(miniDriveBarStopSize, miniDriveBarStopSize),
                    padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                    backgroundColor: t.colorScheme.error.withValues(alpha: 0.16),
                    foregroundColor: t.colorScheme.error,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: s.busy
                      ? null
                      : () async {
                          await confirmAndStopDrive(context, s);
                        },
                  // The tooltip rides inside the button, so it merges into the button's own semantics node.
                  child: Semantics(
                    tooltip: 'Stop drive',
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.stop_rounded, size: 22),
                      // A narrow phone at large text keeps the icon alone, so the bar never overflows.
                      if (!tight) ...[const SizedBox(width: Gap.xs), const Text('Stop')],
                    ]),
                  ),
                ),
                SizedBox(width: miniDriveBarEdge + safe.right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
