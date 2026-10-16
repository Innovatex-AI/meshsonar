// Home screen, built for one hand in a moving car: live coverage map on top, a compact stats strip, the status line
// with the next auto-ping countdown, the latest ping (tap to see them all), and the big Start/Stop and Ping now
// buttons at the bottom, in thumb reach. The screen stays awake while driving.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../app/app_state.dart';
import '../core/model.dart';
import '../radio/radio_api.dart';
import 'app.dart';
import 'connect_screen.dart';
import 'device_feedback.dart';
import 'map/coverage_map.dart';
import 'widgets.dart';

class DriveScreen extends StatefulWidget {
  const DriveScreen({super.key});
  @override
  State<DriveScreen> createState() => _DriveScreenState();
}

class _DriveScreenState extends State<DriveScreen> {
  AppState? _state;
  DeviceFeedback? _feedback;

  // Every ping of the drive on screen (AppState keeps only the most recent 50 for the list).
  String? _sessionId;
  final Map<String, DrivePing> _drivePings = {};
  List<DrivePing> _mapPings = const [];
  String? _lastPingId;

  bool _awake = false;
  bool _listOpen = false;

  StreamSubscription<GeoFix>? _fixSub;
  LocationSource? _fixSource;
  GeoFix? _fix;

  Timer? _ticker;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _feedback = DeviceFeedbackScope.of(context);
    final s = AppScope.read(context);
    if (!identical(s, _state)) {
      _state?.removeListener(_onState);
      _state = s;
      s.addListener(_onState);
      _onState();
    }
  }

  void _onState() {
    final s = _state;
    if (s == null) return;

    // Track the drive's pings.
    final sid = s.currentSession?.id ?? s.lastSession?.id;
    if (sid != _sessionId) {
      _sessionId = sid;
      _drivePings.clear();
      _lastPingId = null;
    }
    final recent = s.recentPings;
    if (recent.isEmpty && !s.driving) _drivePings.clear();
    var added = false;
    for (final p in recent) {
      if (_drivePings.containsKey(p.id)) continue;
      _drivePings[p.id] = p;
      added = true;
    }
    if (added || _mapPings.length != _drivePings.length) _mapPings = List.unmodifiable(_drivePings.values);

    // Feedback on a newly finished ping (not for pings already there when the screen opened).
    final newest = recent.isEmpty ? null : recent.first;
    if (newest != null && newest.id != _lastPingId) {
      if (_lastPingId != null || s.driving) {
        if (s.driving) unawaited(_feedback?.pingResult(heard: !newest.heardNothing));
      }
      _lastPingId = newest.id;
    }

    // Keep the screen on while driving.
    if (s.driving != _awake) {
      _awake = s.driving;
      unawaited(_feedback?.keepAwake(_awake));
    }

    // Live position while driving (permission was granted by Start drive).
    final wantFixes = s.driving;
    final src = wantFixes ? s.activeLocation : null;
    if (!identical(src, _fixSource)) {
      unawaited(_fixSub?.cancel());
      _fixSub = null;
      _fixSource = src;
      if (src == null) {
        _fix = null;
      } else {
        try {
          _fixSub = src.fixes.listen((f) {
            if (mounted) setState(() => _fix = f);
          }, onError: (Object _) {});
        } catch (_) {}
      }
    }

    // One-second ticker for the countdown, only while a next ping is scheduled.
    final needTick = s.driving && s.status.nextPingAt != null;
    if (needTick && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!needTick && _ticker != null) {
      _ticker!.cancel();
      _ticker = null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _state?.removeListener(_onState);
    _ticker?.cancel();
    unawaited(_fixSub?.cancel());
    if (_awake) unawaited(_feedback?.keepAwake(false));
    super.dispose();
  }

  LatLng? _position(AppState s) {
    final f = _fix ?? (s.driving ? s.status.lastFix : null);
    return f == null ? null : LatLng(f.lat, f.lon);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final pings = s.recentPings;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: Gap.l,
        title: Row(
          children: [
            Icon(Icons.radar, color: t.colorScheme.primary, size: 26),
            const SizedBox(width: Gap.s),
            const Flexible(child: Text('MeshSonar', maxLines: 1, overflow: TextOverflow.fade, softWrap: false)),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: Gap.m),
            child: ConnectionChip(state: s, onPressed: () => openConnect(context)),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, box) {
            final listHeight = (box.maxHeight * 0.40).clamp(160.0, 420.0);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, 0),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(Corners.card),
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: CoverageMap(
                              key: const Key('drive-map'),
                              pings: _mapPings,
                              repeaters: s.repeaters,
                              position: _position(s),
                              repeaterLabel: s.repeaterLabel,
                            ),
                          ),
                          if (pings.isEmpty) Positioned(left: 0, right: 0, top: Gap.m, child: _MapHint(state: s)),
                          if (pings.isNotEmpty && s.driving)
                            Positioned(
                              top: Gap.m,
                              left: 0,
                              right: 0,
                              child: Center(child: _ResultFlash(ping: pings.first)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, 0),
                  child: _Stats(state: s),
                ),
                _StatusRow(state: s),
                if (s.unsavedCount > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                    child: ErrorBanner('${s.unsavedCount} ping(s) not yet saved to this device. Retrying.'),
                  ),
                if (pings.isNotEmpty) ...[
                  _RecentHeader(
                    count: pings.length,
                    open: _listOpen,
                    onTap: () => setState(() => _listOpen = !_listOpen),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _listOpen
                        ? SizedBox(
                            height: listHeight,
                            child: ListView.separated(
                              key: const Key('recent-pings'),
                              itemCount: pings.length,
                              separatorBuilder: (_, _) => const Divider(height: 1, indent: Gap.l, endIndent: Gap.l),
                              itemBuilder: (_, i) => PingTile(ping: pings[i], state: s),
                            ),
                          )
                        : PingTile(key: const Key('latest-ping'), ping: pings.first, state: s),
                  ),
                ],
                _ActionButtons(state: s),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Radio connection status; tap to connect or change radio.
class ConnectionChip extends StatelessWidget {
  final AppState state;
  final VoidCallback onPressed;
  const ConnectionChip({super.key = const Key('connection-chip'), required this.state, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final Color dot = s.connecting ? mc.beacon : (s.connected ? t.colorScheme.primary : mc.silent);
    return ActionChip(
      onPressed: onPressed,
      avatar: s.connecting
          ? SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: dot))
          : Icon(
              s.connected
                  ? (s.radioKind == RadioKind.simulator ? Icons.science_rounded : Icons.bluetooth_connected_rounded)
                  : Icons.bluetooth_disabled_rounded,
              size: 20,
              color: dot,
            ),
      label: Text(s.connectionLabel),
      side: BorderSide(color: dot.withValues(alpha: 0.6)),
      backgroundColor: dot.withValues(alpha: 0.10),
    );
  }
}

class _Stats extends StatelessWidget {
  final AppState state;
  const _Stats({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final mc = MeshSonarColors.of(context);
    final pct = s.heardPercent;
    final last = s.recentPings.isEmpty ? null : s.recentPings.first;
    final lastSnr = last == null ? null : bestSnr(last);
    String snrText;
    Color? snrColor;
    if (last == null) {
      snrText = '—';
    } else if (last.heardNothing) {
      snrText = 'none';
      snrColor = mc.silent;
    } else if (lastSnr == null) {
      snrText = '—';
    } else {
      snrText = '${lastSnr > 0 ? '+' : ''}${lastSnr.toStringAsFixed(1)}';
      snrColor = mc.forPing(heard: true, snr: lastSnr);
    }
    return StatStrip(
      tiles: [
        StatTile(label: 'Pings', value: '${s.pingCount}', valueKey: const Key('stat-pings')),
        StatTile(
          label: '${s.heardCount} heard',
          labelKey: const Key('stat-heard'),
          value: pct == null ? '—' : '$pct%',
          valueKey: const Key('stat-pct'),
        ),
        StatTile(label: 'Last SNR dB', value: snrText, valueKey: const Key('stat-snr'), valueColor: snrColor),
        StatTile(label: 'Synced', value: '${s.syncedCount}', valueKey: const Key('stat-synced')),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  final AppState state;
  const _StatusRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final st = s.status;
    final listening = st.state == EngineState.pinging || s.pinging;
    final error = st.state == EngineState.error;
    final next = st.nextPingAt;
    int? secs;
    if (s.driving && next != null && !listening) {
      secs = next.difference(s.services.clock()).inMilliseconds;
      secs = (secs / 1000).ceil().clamp(0, 9999);
    }
    final interval = s.settings.intervalSec;

    Widget lead;
    if (listening || s.busy) {
      lead = SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: t.colorScheme.primary),
      );
    } else if (error) {
      lead = Icon(Icons.error_outline_rounded, color: t.colorScheme.error, size: 24);
    } else if (s.driving) {
      lead = _LiveDot(color: t.colorScheme.primary);
    } else {
      lead = Icon(Icons.radio_button_unchecked, color: t.colorScheme.outline, size: 22);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l + 2, Gap.s, Gap.l, Gap.xs),
      child: Row(
        children: [
          SizedBox(width: 26, child: Center(child: lead)),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(
              s.statusLine,
              key: const Key('status-line'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.textTheme.titleMedium?.copyWith(color: error ? t.colorScheme.error : null),
            ),
          ),
          if (secs != null) _Countdown(seconds: secs, interval: interval),
        ],
      ),
    );
  }
}

/// "Next ping 23 s" with a ring that empties as the auto-ping approaches.
class _Countdown extends StatelessWidget {
  final int seconds;
  final int interval;
  const _Countdown({required this.seconds, required this.interval});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final frac = interval <= 0 ? 0.0 : (seconds / interval).clamp(0.0, 1.0);
    return Row(
      key: const Key('next-ping-countdown'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Next ping', style: t.textTheme.labelMedium),
        const SizedBox(width: Gap.s),
        SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: frac,
                strokeWidth: 3,
                backgroundColor: t.colorScheme.surfaceContainerHighest,
              ),
              Text('$seconds', key: const Key('next-ping-seconds'), style: numberStyle(context, size: 19)),
            ],
          ),
        ),
      ],
    );
  }
}

class _LiveDot extends StatelessWidget {
  final Color color;
  const _LiveDot({required this.color});
  @override
  Widget build(BuildContext context) => Container(
    width: 14,
    height: 14,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1)],
    ),
  );
}

class _RecentHeader extends StatelessWidget {
  final int count;
  final bool open;
  final VoidCallback onTap;
  const _RecentHeader({required this.count, required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      key: const Key('recent-toggle'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l + 2, Gap.s, Gap.m, 0),
        child: Row(
          children: [
            Text(
              open ? 'Recent pings' : 'Latest ping',
              style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
            const Spacer(),
            Text(
              open ? 'Hide' : 'Show all $count',
              style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary),
            ),
            Icon(open ? Icons.expand_more_rounded : Icons.expand_less_rounded, color: t.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  final AppState state;
  const _ActionButtons({required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final driving = s.driving;
    final canPing = driving && !s.pinging && !s.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, Gap.m),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 76,
              child: FilledButton.icon(
                key: const Key('start-stop'),
                style: FilledButton.styleFrom(
                  backgroundColor: driving ? t.colorScheme.error : null,
                  foregroundColor: driving ? t.colorScheme.onError : null,
                  textStyle: const TextStyle(fontFamily: 'Barlow', fontSize: 22, fontWeight: FontWeight.w700),
                ),
                onPressed: s.busy
                    ? null
                    : () {
                        if (driving) {
                          s.stopDrive();
                        } else if (!s.connected) {
                          openConnect(context);
                        } else {
                          s.startDrive();
                        }
                      },
                icon: Icon(
                  driving
                      ? Icons.stop_rounded
                      : (s.connected ? Icons.play_arrow_rounded : Icons.bluetooth_searching_rounded),
                  size: 32,
                ),
                label: Text(driving ? 'Stop drive' : (s.connected ? 'Start drive' : 'Connect radio')),
              ),
            ),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: 76,
              child: OutlinedButton.icon(
                key: const Key('ping-now'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: canPing ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: 2),
                  foregroundColor: t.colorScheme.primary,
                ),
                onPressed: canPing ? () => s.pingNow() : null,
                icon: s.pinging
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Icon(Icons.wifi_tethering, size: 28),
                label: const Text('Ping now', style: TextStyle(fontSize: 18)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What to do next, floated over the map while there are no pings.
class _MapHint extends StatelessWidget {
  final AppState state;
  const _MapHint({required this.state});
  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final title = s.driving ? 'Waiting for the first ping' : 'No pings yet';
    final body = s.driving
        ? 'Each ping lands on the map when its listen window closes.'
        : s.connected
        ? 'Press Start drive. Every ping is saved on this phone right away.'
        : 'Tap Connect radio to pick your MeshCore companion radio, or try the Simulator.';
    return Center(
      child: Container(
        key: const Key('map-hint'),
        constraints: const BoxConstraints(maxWidth: 360),
        margin: const EdgeInsets.symmetric(horizontal: Gap.l),
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.m),
        decoration: BoxDecoration(
          color: t.colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(Corners.chip),
          border: Border.all(color: t.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(s.driving ? Icons.hearing_rounded : Icons.radar, color: t.colorScheme.primary, size: 28),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title, style: t.textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(body, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A short-lived result badge at the top of the map when a ping finishes (the visual half of the ping feedback).
class _ResultFlash extends StatelessWidget {
  final DrivePing ping;
  const _ResultFlash({required this.ping});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final heard = repeatersHeard(ping);
    final snr = bestSnr(ping);
    final color = mc.forPing(heard: heard.isNotEmpty, snr: snr);
    final text = heard.isEmpty
        ? 'No repeaters heard'
        : 'Heard by ${heard.length} · ${snr == null ? 'SNR —' : '${snr > 0 ? '+' : ''}${snr.toStringAsFixed(1)} dB'}';
    return TweenAnimationBuilder<double>(
      key: ValueKey('flash-${ping.id}'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 4000),
      builder: (context, v, child) {
        // In fast, hold, then fade away.
        final o = v < 0.08 ? v / 0.08 : (v > 0.75 ? (1 - v) / 0.25 : 1.0);
        return Opacity(
          opacity: o.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, -8 * (1 - (v < 0.08 ? v / 0.08 : 1))), child: child),
        );
      },
      child: Container(
        key: const Key('ping-flash'),
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
        decoration: BoxDecoration(
          color: t.colorScheme.surface.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(Corners.chip),
          border: Border.all(color: color, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: Gap.s),
            Text(text, style: t.textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

void openConnect(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
}
