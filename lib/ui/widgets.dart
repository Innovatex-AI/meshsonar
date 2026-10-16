// Small shared widgets and formatters.
import 'package:flutter/material.dart';

import '../app/app_state.dart';
import '../core/model.dart';

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
  const StatTile({super.key, required this.label, required this.value, this.valueKey});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Expanded(
      child: Card(
        margin: const EdgeInsets.all(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
          child: Column(
            children: [
              FittedBox(
                child: Text(value, key: valueKey, style: t.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 2),
              Text(label, style: t.textTheme.labelLarge, textAlign: TextAlign.center),
            ],
          ),
        ),
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
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: t.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: t.textTheme.titleMedium, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(body!, style: t.textTheme.bodyMedium, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
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
    return Card(
      color: c.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: c.onErrorContainer),
            const SizedBox(width: 10),
            Expanded(child: Text(message, style: TextStyle(color: c.onErrorContainer))),
          ],
        ),
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
    final heard = repeatersHeard(ping);
    final nothing = heard.isEmpty;
    final names = heard.map(state.repeaterLabel).toList();
    final snr = bestSnr(ping);
    return ListTile(
      key: ValueKey('ping-${ping.id}'),
      leading: CircleAvatar(
        backgroundColor: nothing ? t.colorScheme.surfaceContainerHighest : t.colorScheme.primaryContainer,
        child: Icon(nothing ? Icons.signal_cellular_off : Icons.cell_tower,
            color: nothing ? t.colorScheme.outline : t.colorScheme.onPrimaryContainer),
      ),
      title: Text(
        nothing ? 'Heard nothing' : '${heard.length} repeater${heard.length == 1 ? '' : 's'} heard · ${formatSnr(snr)}',
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        nothing ? formatTime(ping.ts) : '${formatTime(ping.ts)} · ${names.join(', ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
