// The dock row (72 pt) in its three states (Drive plan 4.2, 4.4, 5.2):
//   idle      status line + subtitle on the left, Start drive 148x52 at the Stop position
//   driving   three elements only: hero block (repeaters that heard the last ping + time since), Ping circle (64, draining
//             ring, seconds to the next automatic ping), Stop 104x52 always labelled
//   finished  summary + View report + Start new
// Start, Ping and Stop are opaque 48+ pt hit boxes that never scroll.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/app_state.dart';
import '../../../core/dead_area.dart' show silentPingStreak;
import '../../../core/model.dart';
import '../../../radio/radio_api.dart';
import '../../design/tokens.dart';
import '../drive_controls.dart' show confirmAndStopDrive, openConnect, openFinishedDriveReport;
import 'auto_collapse.dart';

/// Distinct repeaters that heard [p]. A repeater is counted once however many echoes it produced.
int heardBy(DrivePing p) => {for (final e in p.echoes) e.repeater}.length;

/// The newest transmitted ping, from a newest-first list (AppState.recentPings), or null.
DrivePing? lastTxPing(Iterable<DrivePing> newestFirst) {
  for (final p in newestFirst) {
    if (p.kind == PingKind.tx) return p;
  }
  return null;
}

/// "4 s", "1m05s": elapsed since a ping, for the hero caption.
String agoShort(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  if (s < 60) return '$s s';
  final m = s ~/ 60;
  return '${m}m${(s % 60).toString().padLeft(2, '0')}s';
}

class DriveDock extends StatelessWidget {
  final AppState state;

  /// Called for a Ping tap that passed the debounce; the owner may inject a fake in tests.
  final Future<void> Function()? onPing;
  final PingDebounce debounce;
  const DriveDock({super.key, required this.state, required this.debounce, this.onPing});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final Widget row;
    if (s.driving) {
      row = _DrivingDock(state: s, debounce: debounce, onPing: onPing);
    } else if (s.lastFinishedSessionId != null) {
      row = _FinishedDock(state: s, sessionId: s.lastFinishedSessionId!);
    } else {
      row = _IdleDock(state: s);
    }
    return Padding(padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin), child: row);
  }
}

// ------------------------------------------------------------------------------------------------ idle

class _IdleDock extends StatelessWidget {
  final AppState state;
  const _IdleDock({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final c = AppColors.fromTheme(t);
    final busy = s.busy || s.connecting;
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.statusLine, key: const Key('status-line'), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                s.needsAntennaSetup && s.connected ? 'Set your antenna first (open the panel)' : s.connectionLabel,
                key: const Key('dock-subtitle'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: c.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _StartStopButton(state: s, busy: busy),
      ],
    );
  }
}

/// Start drive / Connect radio (idle) or Stop (driving): the one button at the thumb corner. 148x52 idle, 104x52 driving.
class _StartStopButton extends StatelessWidget {
  final AppState state;
  final bool busy;
  const _StartStopButton({required this.state, required this.busy});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final driving = s.driving;
    final dark = t.brightness == Brightness.dark;
    final stopBg = dark ? const Color(0xFFFF8A80) : t.colorScheme.error;
    final stopFg = dark ? const Color(0xFF2A0A08) : t.colorScheme.onError;
    return SizedBox(
      width: driving ? 104 : 148,
      height: 52,
      child: FilledButton(
        key: const Key('start-stop'),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          backgroundColor: driving ? stopBg : null,
          foregroundColor: driving ? stopFg : null,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          minimumSize: const Size(0, 52),
        ),
        onPressed: busy || (!driving && s.needsAntennaSetup)
            ? null
            : () async {
                if (driving) {
                  await confirmAndStopDrive(context, s);
                } else if (!s.connected) {
                  openConnect(context);
                } else {
                  s.startDrive();
                }
              },
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(driving ? Icons.stop_rounded : (s.connected ? Icons.play_arrow_rounded : Icons.bluetooth_searching_rounded), size: 22),
              const SizedBox(width: 6),
              Text(driving ? 'Stop' : (s.connected ? 'Start drive' : 'Connect radio'), maxLines: 1, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ finished

class _FinishedDock extends StatelessWidget {
  final AppState state;
  final String sessionId;
  const _FinishedDock({required this.state, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final c = AppColors.fromTheme(Theme.of(context));
    final heard = s.heardCount, total = s.pingCount;
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Drive saved', key: Key('status-line'), maxLines: 1, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(total == 0 ? 'No pings this drive' : '$heard of $total pings heard', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.textMuted)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 48,
          child: OutlinedButton(
            key: const Key('view-report'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 10)),
            onPressed: () => openFinishedDriveReport(context, sessionId),
            child: const FittedBox(fit: BoxFit.scaleDown, child: Text('Report', maxLines: 1)),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          height: 48,
          child: FilledButton(
            key: const Key('start-stop'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 48), padding: const EdgeInsets.symmetric(horizontal: 12)),
            onPressed: s.busy ? null : () => s.connected ? s.startDrive() : openConnect(context),
            child: FittedBox(fit: BoxFit.scaleDown, child: Text(s.connected ? 'Start new' : 'Connect radio', maxLines: 1)),
          ),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------------------------------------ driving

class _DrivingDock extends StatelessWidget {
  final AppState state;
  final PingDebounce debounce;
  final Future<void> Function()? onPing;
  const _DrivingDock({required this.state, required this.debounce, this.onPing});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final discovery = s.settings.discoveryMode;
    return Row(
      children: [
        Expanded(child: DockHero(state: s)),
        if (!discovery) ...[
          const SizedBox(width: 12),
          PingCircle(state: s, debounce: debounce, onPing: onPing),
        ],
        const SizedBox(width: 16),
        _StartStopButton(state: s, busy: s.busy),
      ],
    );
  }
}

/// Left of the driving dock: the number of repeaters that heard the last ping (34 pt), its caption and the time since.
class DockHero extends StatefulWidget {
  final AppState state;
  const DockHero({super.key, required this.state});
  @override
  State<DockHero> createState() => _DockHeroState();
}

class _DockHeroState extends State<DockHero> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && TickerMode.valuesOf(context).enabled) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final c = AppColors.fromTheme(Theme.of(context));
    final last = lastTxPing(s.recentPings);
    final scale = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    if (last == null) {
      return MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scale),
        child: Semantics(
          label: 'Listening, no ping yet',
          excludeSemantics: true,
          child: Text('Listening', key: const Key('dock-hero-listening'), maxLines: 1, style: TextStyle(fontSize: 15, color: c.textMuted)),
        ),
      );
    }
    final n = heardBy(last);
    final none = n == 0;
    final ago = agoShort(s.services.clock().toUtc().difference(last.ts.toUtc()));
    final streak = silentPingStreak(s.drivePings);
    final color = none ? c.warning : c.textPrimary;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scale),
      child: Semantics(
        label: none ? 'No repeater heard the last ping, $ago ago' : '$n ${n == 1 ? 'repeater' : 'repeaters'} heard the last ping, $ago ago',
        value: s.heardPercent == null ? null : '${s.heardCount} of ${s.pingCount} pings heard',
        excludeSemantics: true,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$n', key: const Key('dock-hero'), style: TextStyle(fontSize: 34, height: 1.0, fontWeight: FontWeight.w600, color: color, fontFeatures: const [FontFeature.tabularFigures()])),
                if (streak >= 5) ...[const SizedBox(width: 4), Icon(Icons.warning_amber_rounded, key: const Key('dock-hero-streak'), size: 18, color: c.warning)],
              ],
            ),
            const SizedBox(height: 2),
            Text(none ? 'No echo · $ago' : 'heard · $ago', key: const Key('dock-hero-caption'), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: none ? c.warning : c.textMuted)),
          ],
        ),
      ),
    );
  }
}

/// The Ping button: 64 pt circle, a 4 pt ring that drains between automatic pings, the seconds to the next one. Tap = ping now,
/// ignored while a ping is in flight and for 2 s after a tap.
class PingCircle extends StatefulWidget {
  final AppState state;
  final PingDebounce debounce;
  final Future<void> Function()? onPing;
  const PingCircle({super.key, required this.state, required this.debounce, this.onPing});
  @override
  State<PingCircle> createState() => _PingCircleState();
}

class _PingCircleState extends State<PingCircle> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && TickerMode.valuesOf(context).enabled) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  void _tap() {
    final s = widget.state;
    if (!widget.debounce.accept(s.services.clock(), inFlight: s.pinging || s.busy)) return;
    final f = widget.onPing;
    if (f != null) {
      f();
    } else {
      s.pingNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final t = Theme.of(context);
    final c = AppColors.fromTheme(t);
    final st = s.status;
    final interval = s.settings.intervalSec;
    final now = s.services.clock();
    int? secs;
    var distanceWait = false;
    if (st.waitingFor == PingWait.gps || (st.waitingFor == PingWait.distance && (st.metresToGo ?? 0) > 0)) {
      distanceWait = true;
    } else if (st.nextPingAt != null) {
      final v = (st.nextPingAt!.difference(now).inMilliseconds / 1000).ceil();
      if (v > 0) secs = v.clamp(0, 999);
    }
    final frac = secs == null || interval <= 0 ? 0.0 : (secs / interval).clamp(0.0, 1.0);
    final canPing = !s.pinging && !s.busy;
    final label = distanceWait
        ? 'Ping now. Next automatic ping waits for ${st.waitingFor == PingWait.gps ? 'GPS' : 'distance'}'
        : (secs == null ? 'Ping now' : 'Ping now. Next automatic ping in $secs seconds');
    return Semantics(
      button: true,
      enabled: canPing,
      label: label,
      excludeSemantics: true,
      onTap: canPing ? _tap : null,
      child: GestureDetector(
        key: const Key('ping-now'),
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        child: SizedBox(
          width: 64,
          height: 64,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CustomPaint(size: const Size(64, 64), painter: _RingPainter(frac: s.pinging ? 1.0 : frac, color: canPing ? c.accent : c.outline, track: c.outline.withValues(alpha: 0.3))),
              s.pinging
                  ? SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: c.accent))
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.wifi_tethering, size: 20, color: canPing ? c.accent : c.textMuted),
                        SizedBox(
                          width: 28,
                          height: 16,
                          child: Center(
                            child: Text(
                              distanceWait ? '' : (secs?.toString() ?? ''),
                              key: const Key('next-ping-seconds'),
                              maxLines: 1,
                              textScaler: TextScaler.noScaling,
                              style: TextStyle(fontSize: 13, color: c.textMuted, fontFeatures: const [FontFeature.tabularFigures()]),
                            ),
                          ),
                        ),
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double frac;
  final Color color, track;
  _RingPainter({required this.frac, required this.color, required this.track});
  @override
  void paint(Canvas canvas, Size size) {
    const w = 4.0;
    final rect = (Offset.zero & size).deflate(w / 2);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, p..color = track);
    if (frac > 0) canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * frac, false, p..color = color);
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.frac != frac || o.color != color || o.track != track;
}
