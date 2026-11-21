// Shared bits of the Nodes screens (AZ-3.4): the favourite star, the Watch button and its sheet, the status dot, a
// section card, key-value rows, and plain value formatting (distance through Units, volts, clock offsets).
import 'package:flutter/material.dart';

import '../../../core/v1/nodes_api.dart';
import '../../app.dart';
import '../../design/app_surfaces.dart' show showAppSheet, showAppToast;
import '../network_context.dart';

/// The colour of a node or observer status.
Color nodeStatusColor(BuildContext context, String status) {
  final cs = Theme.of(context).colorScheme;
  final m = MeshSonarColors.of(context);
  return switch (status) {
    'active' || 'online' => m.snrStrong,
    'degraded' || 'stale' => m.beacon,
    'silent' || 'offline' => cs.error,
    _ => cs.outline,
  };
}

String observerStatusLabel(String s) => switch (s) {
      'online' => 'Online',
      'stale' => 'Stale',
      'offline' => 'Offline',
      _ => 'Unknown',
    };

String observerKindLabel(String k) => switch (k) {
      'fixed' => 'MeshSonar observer',
      'phone' => 'Phone observer',
      'outside' => 'Outside feed',
      _ => 'Observer',
    };

class StatusDot extends StatelessWidget {
  final String status;
  final double size;
  const StatusDot(this.status, {super.key, this.size = 10});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: nodeStatusColor(context, status), shape: BoxShape.circle),
      );
}

/// "12 km" (or miles) through the Units setting.
String distanceText(BuildContext context, double km) => AppScope.unitsOf(context).distance(km * 1000);

/// "3.71 V".
String voltsText(int mv) => '${(mv / 1000).toStringAsFixed(2)} V';

/// "2 s ahead", "1 h 31 min behind".
String skewText(double s) {
  final a = s.abs();
  final side = s >= 0 ? 'ahead' : 'behind';
  if (a < 90) return '${a.round()} s $side';
  if (a < 5400) return '${(a / 60).round()} min $side';
  if (a < 172800) return '${(a / 3600).floor()} h ${((a % 3600) / 60).round()} min $side';
  return '${(a / 86400).round()} days $side';
}

String clockSeverityLabel(String s) => switch (s) {
      'ok' => 'Right',
      'warning' => 'A little off',
      'critical' => 'Badly off',
      'absurd' => 'Far off',
      'no_clock' => 'Not set',
      _ => s,
    };

/// A 0..1 share as "98%". A share is never over 100%: the server's 24 h figure counts the hour in progress as a 25th
/// hour over a 24 hour base, so it can arrive as 1.04; that is every hour heard, shown as 100%.
String shareText(double v) => '${(v.clamp(0.0, 1.0) * 100).round()}%';

/// A number with at most [dp] decimals and no trailing zeros: 910.525024 -> "910.525", 62.5 -> "62.5", 7.0 -> "7".
String trimNumber(num v, int dp) {
  final s = v.toStringAsFixed(dp);
  return s.contains('.') ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '') : s;
}

final RegExp _radioPart = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(mhz|khz)?\s*$', caseSensitive: false);

/// Radio settings as people read them: "910.525 MHz · BW 62.5 kHz · SF 7 · CR 5". Accepts what observers report: the raw
/// "910.525024,62.5,7,5" (frequency MHz, bandwidth kHz, spreading factor, coding rate) or the already labelled
/// "910.525024 MHz · 62.5 kHz · SF7 · CR5". Anything else is returned as it came.
String radioText(String raw) {
  final parts = raw.split(RegExp(r'\s*[,·]\s*'));
  if (parts.length != 4) return raw;
  final f = _radioPart.firstMatch(parts[0]), bw = _radioPart.firstMatch(parts[1]);
  final sf = int.tryParse(parts[2].replaceFirst(RegExp(r'^\s*SF\s*', caseSensitive: false), '').trim());
  final cr = int.tryParse(parts[3].replaceFirst(RegExp(r'^\s*CR\s*', caseSensitive: false), '').trim());
  if (f == null || bw == null || sf == null || cr == null) return raw;
  return '${trimNumber(double.parse(f.group(1)!), 3)} MHz · BW ${trimNumber(double.parse(bw.group(1)!), 2)} kHz · SF $sf · CR $cr';
}

/// One titled block of a page. Pages build a section only when it has data (a missing section is hidden).
class NodeSection extends StatelessWidget {
  final String title;
  final String? id;
  final List<Widget> children;
  const NodeSection({super.key, required this.title, required this.children, this.id});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      key: id == null ? null : Key('node-section-$id'),
      padding: const EdgeInsets.only(top: Gap.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium)),
        const SizedBox(height: Gap.xs),
        ...children,
      ]),
    );
  }
}

/// A label and its value; wraps instead of clipping at large text sizes.
class KvRow extends StatelessWidget {
  final String label, value;
  final Key? valueKey;
  const KvRow(this.label, this.value, {super.key, this.valueKey});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final big = MediaQuery.textScalerOf(context).scale(14) > 20;
    final l = Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant));
    final v = Text(value, key: valueKey, style: t.textTheme.bodyMedium);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: big
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [l, v])
          : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 140, child: l), Expanded(child: v)]),
    );
  }
}

/// The favourite star (stored on this phone).
class FavouriteStar extends StatelessWidget {
  final FavouriteKind kind;
  final String id;
  final String? name, region;
  const FavouriteStar({super.key, required this.kind, required this.id, this.name, this.region});

  @override
  Widget build(BuildContext context) => FavouritesListener(builder: (context, store) {
        final on = store.isFavourite(kind, id);
        return IconButton(
          key: Key('fav-${kind.name}-$id'),
          tooltip: on ? 'Remove from favourites' : 'Add to favourites',
          isSelected: on,
          icon: Icon(on ? Icons.star : Icons.star_border, color: on ? MeshSonarColors.of(context).beacon : null),
          onPressed: () => store.toggleFavourite(kind, id, name: name, region: region),
        );
      });
}

/// The Watch button: opens the watch sheet; filled while something is watched.
class WatchButton extends StatelessWidget {
  /// `node` or `observer`.
  final String kind;
  final String target;
  final String? name, region;
  const WatchButton({super.key, required this.kind, required this.target, this.name, this.region});

  @override
  Widget build(BuildContext context) => FavouritesListener(builder: (context, store) {
        final on = store.isWatched(kind, target);
        return IconButton(
          key: const Key('watch-button'),
          tooltip: on ? 'Watching' : 'Watch',
          isSelected: on,
          icon: Icon(on ? Icons.notifications_active : Icons.notifications_none),
          onPressed: () => showWatchSheet(context, store: store, kind: kind, target: target, name: name, region: region),
        );
      });
}

/// The watch sheet: which events, saved on this phone. No alerts yet (AZ-3.8 adds push), and the sheet says so.
Future<void> showWatchSheet(BuildContext context,
    {required NetworkFavouritesStore store, required String kind, required String target, String? name, String? region}) {
  return showAppSheet<void>(context, detents: const [0.6, 0.92], builder: (ctx, c) => _WatchSheet(store: store, kind: kind, target: target, name: name, region: region, controller: c));
}

class _WatchSheet extends StatefulWidget {
  final NetworkFavouritesStore store;
  final String kind, target;
  final String? name, region;
  final ScrollController controller;
  const _WatchSheet({required this.store, required this.kind, required this.target, this.name, this.region, required this.controller});
  @override
  State<_WatchSheet> createState() => _WatchSheetState();
}

class _WatchSheetState extends State<_WatchSheet> {
  late Set<String> _events;
  late final bool _existing;

  @override
  void initState() {
    super.initState();
    final w = widget.store.watchOf(widget.kind, widget.target);
    _existing = w != null;
    _events = {...(w?.events ?? watchEventsByKind[widget.kind]!)};
  }

  Future<void> _save() async {
    final nav = Navigator.of(context);
    try {
      await widget.store.setWatch(widget.kind, widget.target, region: widget.region, name: widget.name, events: _events.toList());
    } on StateError catch (e) {
      if (mounted) showAppToast(context, e.message);
      return;
    }
    nav.pop();
  }

  Future<void> _remove() async {
    final nav = Navigator.of(context);
    await widget.store.removeWatch(widget.kind, widget.target);
    nav.pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final all = watchEventsByKind[widget.kind]!;
    return ListView(
      key: const Key('watch-sheet'),
      controller: widget.controller,
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
      children: [
        Semantics(header: true, child: Text('Watch ${widget.name ?? 'this ${widget.kind}'}', style: t.textTheme.titleLarge)),
        const SizedBox(height: Gap.s),
        Text('Alerts arrive in a later update; the watch is kept on this phone.', key: const Key('watch-note'), style: t.textTheme.bodyMedium),
        const SizedBox(height: Gap.s),
        for (final e in all)
          CheckboxListTile(
            key: Key('watch-event-$e'),
            contentPadding: EdgeInsets.zero,
            value: _events.contains(e),
            title: Text(watchEventLabel(e)),
            onChanged: (v) => setState(() => v == true ? _events.add(e) : _events.remove(e)),
          ),
        const SizedBox(height: Gap.m),
        FilledButton(key: const Key('watch-save'), onPressed: _events.isEmpty ? null : _save, child: Text(_existing ? 'Save' : 'Watch')),
        if (_existing) ...[
          const SizedBox(height: Gap.s),
          OutlinedButton(key: const Key('watch-remove'), onPressed: _remove, child: const Text('Stop watching')),
        ],
      ],
    );
  }
}

/// The "Offline - as of" / not-live note at the top of a Nodes screen.
class SourceNote extends StatelessWidget {
  final NetworkReadSource source;
  final String legacyText;
  const SourceNote({super.key, required this.source, required this.legacyText});
  @override
  Widget build(BuildContext context) {
    if (source != NetworkReadSource.legacy) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Text(legacyText, key: const Key('nodes-legacy-note'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}
