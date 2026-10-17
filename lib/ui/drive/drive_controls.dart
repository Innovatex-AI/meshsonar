// Drive-screen parts below (and on) the map: the stats strip, the status line with the next-ping indicator, the
// antenna chip, the log button, the drive-report card, the Start/Stop + Ping now buttons, the empty-map hint and
// the ping result flash. Shared by the Drive screen and the full-screen map.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/antenna_profile.dart';
import '../../core/model.dart';
import '../../radio/radio_api.dart';
import '../antenna_sheet.dart';
import '../connect_screen.dart';
import '../ping_log_screen.dart' show openPingLog;
import '../report/drive_report_screen.dart';
import '../theme.dart';
import '../widgets.dart';

void openConnect(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ConnectScreen()));
}

void openDriveReport(BuildContext context, String sessionId) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DriveReportScreen(sessionId: sessionId)));
}

// ------------------------------------------------------------------------------------------------ stats

class DriveStatsStrip extends StatelessWidget {
  final AppState state;
  const DriveStatsStrip({super.key, required this.state});

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

// ------------------------------------------------------------------------------------------------ status

class DriveStatusRow extends StatelessWidget {
  final AppState state;
  final EdgeInsets padding;
  const DriveStatusRow({
    super.key,
    required this.state,
    this.padding = const EdgeInsets.fromLTRB(Gap.l + 2, Gap.s, Gap.l, Gap.xs),
  });

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final st = s.status;
    final listening = st.state == EngineState.pinging || s.pinging;
    final error = st.state == EngineState.error;

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
      lead = LiveDot(color: t.colorScheme.primary);
    } else {
      lead = Icon(Icons.radio_button_unchecked, color: t.colorScheme.outline, size: 22);
    }

    return Padding(
      padding: padding,
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
          if (s.driving && !listening) NextPingIndicator(state: s),
        ],
      ),
    );
  }
}

/// What the next auto-ping is waiting for: "Next ping 12" with an emptying ring (time), "Move 40 m" (distance)
/// or "Waiting for GPS". Ticks itself once a second, so nothing else rebuilds for the countdown.
class NextPingIndicator extends StatefulWidget {
  final AppState state;
  const NextPingIndicator({super.key, required this.state});
  @override
  State<NextPingIndicator> createState() => _NextPingIndicatorState();
}

class _NextPingIndicatorState extends State<NextPingIndicator> {
  Timer? _tick;

  /// Ticks once a second only while a countdown is on screen (and the screen is visible).
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
    final s = widget.state;
    final t = Theme.of(context);
    final st = s.status;
    final next = st.nextPingAt;
    final interval = s.settings.intervalSec;
    _wantTick(next != null && TickerMode.valuesOf(context).enabled && next.isAfter(s.services.clock()));

    if (st.waitingFor == PingWait.gps) {
      return _Badge(key: const Key('next-ping-gps'), icon: Icons.gps_not_fixed_rounded, text: 'Waiting for GPS');
    }
    if (st.waitingFor == PingWait.distance && st.metresToGo != null && st.metresToGo! > 0) {
      return _Badge(
        key: const Key('next-ping-move'),
        icon: Icons.directions_car_rounded,
        text: 'Move ${st.metresToGo!.ceil()} m',
      );
    }
    if (next == null) return const SizedBox.shrink();
    var secs = (next.difference(s.services.clock()).inMilliseconds / 1000).ceil();
    if (secs <= 0) {
      if (st.waitingFor == PingWait.distance) {
        return _Badge(key: const Key('next-ping-move'), icon: Icons.directions_car_rounded, text: 'Keep moving');
      }
      return const SizedBox.shrink();
    }
    secs = secs.clamp(0, 9999);
    final frac = interval <= 0 ? 0.0 : (secs / interval).clamp(0.0, 1.0);
    return Row(
      key: const Key('next-ping-countdown'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Next ping', style: t.textTheme.labelMedium),
        const SizedBox(width: Gap.s),
        SizedBox(
          width: 40,
          height: 40,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                value: frac,
                strokeWidth: 3,
                backgroundColor: t.colorScheme.surfaceContainerHighest,
              ),
              Text('$secs', key: const Key('next-ping-seconds'), style: numberStyle(context, size: 18)),
            ],
          ),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Badge({super.key, required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: t.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(Corners.small),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: t.colorScheme.onPrimaryContainer),
          const SizedBox(width: 6),
          Text(text, style: numberStyle(context, size: 17, color: t.colorScheme.onPrimaryContainer)),
        ],
      ),
    );
  }
}

class LiveDot extends StatelessWidget {
  final Color color;
  const LiveDot({super.key, required this.color});
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

// ------------------------------------------------------------------------------------------------ antenna + log

/// The connected radio's antenna ("Roof mag-mount · 5.8 dBi · 1.8 m"); tap to change it before a drive. While driving
/// it is locked and shows what the drive records ("External · 5.8 dBi · 1.8 m"). A radio that hasn't been set up
/// shows [AntennaSetupHint] instead, and Start drive waits for it.
class AntennaChip extends StatelessWidget {
  final AppState state;
  const AntennaChip({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final s = state;
    final recorded = s.currentSession?.antenna;
    final profile = s.antennaProfile;
    final String text;
    if (recorded != null) {
      text = recordedAntennaSummary(recorded);
    } else if (profile != null) {
      text = profile.summary;
    } else {
      return s.needsAntennaSetup ? const AntennaSetupHint() : const SizedBox.shrink();
    }
    final locked = recorded != null;
    final t = Theme.of(context);
    return ActionChip(
      key: const Key('antenna-chip'),
      tooltip: locked ? 'Antenna, locked while driving' : 'Change this radio\'s antenna',
      avatar: Icon(
        locked ? Icons.lock_rounded : Icons.settings_input_antenna_rounded,
        size: 18,
        color: t.colorScheme.onSurfaceVariant,
      ),
      label: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      onPressed: locked ? null : () => showAntennaSheet(context),
    );
  }
}

/// "External · 5.8 dBi · 1.8 m": the Drive Format v1 antenna a drive records (the mount itself isn't recorded).
String recordedAntennaSummary(Antenna a) => [
  a.type == 'external' ? 'External' : 'Internal',
  if (a.gainDbi != null) '${formatAntennaNumber(a.gainDbi!)} dBi',
  if (a.heightM != null) '${formatAntennaNumber(a.heightM!)} m',
].join(' · ');

/// "Set up this radio's antenna": shown where Start drive is, while it waits for the connected radio's antenna.
class AntennaSetupHint extends StatelessWidget {
  const AntennaSetupHint({super.key = const Key('antenna-setup')});

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () => showAntennaSheet(context),
      icon: const Icon(Icons.warning_amber_rounded),
      label: const Text('Set up this radio\'s antenna'),
    );
  }
}

/// Opens the live ping log of this drive; shows how many pings it holds.
class LogButton extends StatelessWidget {
  final AppState state;
  const LogButton({super.key = const Key('open-log'), required this.state});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final n = state.pingCount;
    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          visualDensity: VisualDensity.compact,
          side: BorderSide(color: t.colorScheme.outlineVariant, width: 1.5),
          textStyle: t.textTheme.labelLarge,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Corners.small)),
        ),
        onPressed: () => openPingLog(context),
        icon: const Icon(Icons.receipt_long_rounded, size: 20),
        label: Text(n > 0 ? 'Log · $n' : 'Log'),
      ),
    );
  }
}

/// After Stop: the drive is saved; one tap to its report.
class DriveReportCard extends StatelessWidget {
  final String sessionId;
  final VoidCallback onDismiss;
  const DriveReportCard({super.key = const Key('drive-report-card'), required this.sessionId, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Material(
      color: t.colorScheme.primaryContainer,
      borderRadius: BorderRadius.circular(Corners.chip),
      child: InkWell(
        key: const Key('view-report'),
        borderRadius: BorderRadius.circular(Corners.chip),
        onTap: () => openDriveReport(context, sessionId),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.xs, Gap.s),
          child: Row(
            children: [
              Icon(Icons.assessment_rounded, color: t.colorScheme.onPrimaryContainer),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('View drive report', style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onPrimaryContainer)),
                    Text(
                      'Coverage, repeaters heard and the best spots.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onPrimaryContainer.withValues(alpha: 0.8)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: t.colorScheme.onPrimaryContainer),
              IconButton(
                key: const Key('dismiss-report'),
                tooltip: 'Dismiss',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: Icon(Icons.close_rounded, size: 20, color: t.colorScheme.onPrimaryContainer.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ buttons

class DriveActionButtons extends StatelessWidget {
  final AppState state;

  /// Shorter buttons (the full-screen map).
  final bool compact;
  final EdgeInsets padding;
  const DriveActionButtons({
    super.key,
    required this.state,
    this.compact = false,
    this.padding = const EdgeInsets.fromLTRB(Gap.m, Gap.s, Gap.m, Gap.m),
  });

  @override
  Widget build(BuildContext context) {
    final s = state;
    final t = Theme.of(context);
    final driving = s.driving;
    final canPing = driving && !s.pinging && !s.busy;
    final h = compact ? 56.0 : 68.0;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: SizedBox(
              height: h,
              child: FilledButton.icon(
                key: const Key('start-stop'),
                style: FilledButton.styleFrom(
                  backgroundColor: driving ? t.colorScheme.error : null,
                  foregroundColor: driving ? t.colorScheme.onError : null,
                  textStyle: TextStyle(fontFamily: 'Barlow', fontSize: compact ? 19 : 22, fontWeight: FontWeight.w700),
                ),
                // A radio not set up yet waits for its antenna (the hint above opens the setup).
                onPressed: s.busy || (!driving && s.needsAntennaSetup)
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
                  size: compact ? 28 : 32,
                ),
                label: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(driving ? 'Stop drive' : (s.connected ? 'Start drive' : 'Connect radio'), maxLines: 1),
                ),
              ),
            ),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            flex: 2,
            child: SizedBox(
              height: h,
              child: OutlinedButton.icon(
                key: const Key('ping-now'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: canPing ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: 2),
                  foregroundColor: t.colorScheme.primary,
                  backgroundColor: compact ? t.colorScheme.surface.withValues(alpha: 0.92) : null,
                ),
                onPressed: canPing ? () => s.pingNow() : null,
                icon: s.pinging
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))
                    : const Icon(Icons.wifi_tethering, size: 28),
                // one line at every phone width: scale down rather than wrap
                label: const FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text('Ping now', maxLines: 1, softWrap: false, style: TextStyle(fontSize: 18)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ on the map

/// What to do next, floated over the map while there are no pings.
class MapHint extends StatelessWidget {
  final AppState state;
  const MapHint({super.key, required this.state});
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
        margin: const EdgeInsets.symmetric(horizontal: Gap.s),
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

/// A short-lived result badge on the map when a ping finishes (the visual half of the ping feedback).
class PingResultFlash extends StatelessWidget {
  final DrivePing ping;
  final String Function(String prefix) label;
  const PingResultFlash({super.key, required this.ping, required this.label});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final heard = repeatersHeard(ping);
    final snr = bestSnr(ping);
    final color = mc.forPing(heard: heard.isNotEmpty, snr: snr);
    final text = heard.isEmpty
        ? 'No repeaters heard'
        : 'Heard by ${heard.length == 1 ? label(heard.single) : '${heard.length}'} · '
              '${snr == null ? 'SNR —' : '${snr > 0 ? '+' : ''}${snr.toStringAsFixed(1)} dB'}';
    return TweenAnimationBuilder<double>(
      key: ValueKey('flash-${ping.id}'),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 4000),
      builder: (context, v, child) {
        // In fast, hold, then fade away.
        final o = v < 0.08 ? v / 0.08 : (v > 0.75 ? (1 - v) / 0.25 : 1.0);
        return Opacity(
          opacity: o.clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(0, 8 * (1 - (v < 0.08 ? v / 0.08 : 1))), child: child),
        );
      },
      child: Container(
        key: const Key('ping-flash'),
        constraints: const BoxConstraints(maxWidth: 300),
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
            Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall)),
          ],
        ),
      ),
    );
  }
}

/// Square icon button floated on the map (full screen, layers, close).
class MapIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final bool active;
  const MapIconButton({super.key, required this.icon, required this.tooltip, required this.onPressed, this.active = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: active ? t.colorScheme.primaryContainer : t.colorScheme.surface.withValues(alpha: 0.93),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Corners.small + 2),
          side: BorderSide(color: t.colorScheme.outlineVariant),
        ),
        elevation: 2,
        shadowColor: Colors.black54,
        child: InkWell(
          borderRadius: BorderRadius.circular(Corners.small + 2),
          onTap: onPressed,
          child: SizedBox(
            width: 46,
            height: 46,
            child: Icon(icon, size: 24, color: active ? t.colorScheme.onPrimaryContainer : t.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
