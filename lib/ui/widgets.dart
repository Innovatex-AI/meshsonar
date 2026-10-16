// Small shared widgets and formatters. Public names here are used by other screens: keep them stable.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/model.dart';
import 'theme.dart';

String two(int n) => n.toString().padLeft(2, '0');

/// Local time, HH:MM:SS.
String formatTime(DateTime t) {
  final l = t.toLocal();
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// e.g. "Fri 16 Oct 2026, 14:05".
String formatDateTime(DateTime t) {
  final l = t.toLocal();
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${days[l.weekday - 1]} ${l.day} ${_months[l.month - 1]} ${l.year}, ${two(l.hour)}:${two(l.minute)}';
}

String formatSnr(double? snr) => snr == null ? 'SNR —' : 'SNR ${snr.toStringAsFixed(1)} dB';

/// Best (highest) SNR among a ping's echoes, or null if none were measured.
double? bestSnr(DrivePing p) {
  double? best;
  for (final e in p.echoes) {
    final s = e.snrDb;
    if (s != null && (best == null || s > best)) best = s;
  }
  final n = p.neighbor?.localSnrDb;
  if (n != null && (best == null || n > best)) best = n;
  return best;
}

/// Distinct repeaters heard on a ping (echoes and neighbor), in first-heard order.
List<String> repeatersHeard(DrivePing p) {
  final out = <String>[];
  for (final e in p.echoes) {
    final k = e.repeater.toLowerCase();
    if (!out.contains(k)) out.add(k);
  }
  final n = p.neighbor?.repeater.toLowerCase();
  if (n != null && !out.contains(n)) out.add(n);
  return out;
}

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Key? valueKey;
  final Key? labelKey;

  /// Optional colour for the value (e.g. the accent for a live figure).
  final Color? valueColor;
  const StatTile({super.key, required this.label, required this.value, this.valueKey, this.labelKey, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.s, horizontal: Gap.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              child: Text(
                value,
                key: valueKey,
                style: numberStyle(context, size: 30, color: valueColor),
              ),
            ),
            const SizedBox(height: 4),
            Text(label, key: labelKey, style: t.textTheme.labelMedium, textAlign: TextAlign.center, maxLines: 1),
          ],
        ),
      ),
    );
  }
}

/// A group of [StatTile]s in one rounded strip with hairline dividers.
class StatStrip extends StatelessWidget {
  final List<StatTile> tiles;
  const StatStrip({super.key, required this.tiles});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final children = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      if (i > 0) children.add(Container(width: 1, height: 36, color: c.outlineVariant));
      children.add(tiles[i]);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(Corners.card),
        border: Border.all(color: c.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Row(children: children),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, shape: BoxShape.circle),
              child: Icon(icon, size: 30, color: t.colorScheme.primary),
            ),
            const SizedBox(height: Gap.m),
            Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Text(
                  body!,
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: Gap.l), action!],
          ],
        ),
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  final String message;
  const ErrorBanner(this.message, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: Gap.xs),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: c.errorContainer,
        borderRadius: BorderRadius.circular(Corners.chip),
        border: Border(left: BorderSide(color: c.error, width: 4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: c.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(color: c.onErrorContainer, fontSize: 15, height: 1.3)),
          ),
        ],
      ),
    );
  }
}

/// Small section heading for lists ("Nearby radios", "No radio?").
class SectionLabel extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionLabel(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.l, Gap.xs, Gap.s),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: t.textTheme.titleMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Four signal bars for a Bluetooth RSSI (dBm). Null = unknown (all bars dim).
class SignalBars extends StatelessWidget {
  final int? rssi;
  final double height;
  const SignalBars({super.key, required this.rssi, this.height = 22});

  /// 0–4 bars: ≥ -60 strong (4), ≥ -70 (3), ≥ -80 (2), ≥ -90 (1), else 0.
  static int barsFor(int? rssi) {
    if (rssi == null) return 0;
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    if (rssi >= -90) return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    final n = barsFor(rssi);
    final on = n >= 3 ? c.primary : (n == 2 ? MeshSonarColors.of(context).beacon : c.error);
    return Semantics(
      label: rssi == null ? 'Signal unknown' : 'Signal $n of 4',
      child: SizedBox(
        height: height,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 4; i++)
              Container(
                key: i == 0 ? ValueKey('signal-bars-$n') : null,
                width: height / 4.4,
                height: height * (0.3 + 0.7 * (i + 1) / 4),
                margin: EdgeInsets.only(left: i == 0 ? 0 : 2.5),
                decoration: BoxDecoration(color: i < n ? on : c.outlineVariant, borderRadius: BorderRadius.circular(2)),
              ),
          ],
        ),
      ),
    );
  }
}

/// The coloured result marker used for a ping in lists (same colours as the map).
class ResultDot extends StatelessWidget {
  final DrivePing ping;
  final double size;
  const ResultDot({super.key, required this.ping, this.size = 14});
  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: mc.forPing(heard: !ping.heardNothing, snr: bestSnr(ping)),
      ),
    );
  }
}

/// One line in the recent-pings list.
class PingTile extends StatelessWidget {
  final DrivePing ping;
  final AppState state;
  const PingTile({super.key, required this.ping, required this.state});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final heard = repeatersHeard(ping);
    final nothing = heard.isEmpty;
    final names = heard.map(state.repeaterLabel).toList();
    final snr = bestSnr(ping);
    final color = mc.forPing(heard: !nothing, snr: snr);
    return ListTile(
      key: ValueKey('ping-${ping.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: Gap.l),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.16),
          border: Border.all(color: color, width: 2),
        ),
        child: Icon(nothing ? Icons.signal_cellular_off : Icons.cell_tower, size: 20, color: color),
      ),
      title: Text(
        nothing ? 'Heard nothing' : '${heard.length} repeater${heard.length == 1 ? '' : 's'} heard · ${formatSnr(snr)}',
        style: t.textTheme.titleMedium,
      ),
      subtitle: Text(
        nothing ? formatTime(ping.ts) : '${formatTime(ping.ts)} · ${names.join(', ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
