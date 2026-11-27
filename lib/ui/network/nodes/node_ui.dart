// Shared bits of the Nodes screens (AZ-3.4): the favourite star, the status dot, a section card, key-value rows, the
// "Updated X ago · pull to refresh" line, and plain value formatting (distance through Units, volts, clock offsets).
// The bell (Watch) was removed in build 77 (Round 2 N-U9): it saved a watch that never alerted. Watches already saved
// stay on the phone (lib/core/v1/favourites_store.dart) and are simply not shown.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../../../core/time_format.dart';
import '../../../core/v1/nodes_api.dart';
import '../../app.dart';
import '../../design/app_surfaces.dart' show showAppToast;
import '../network_context.dart';

/// The colour of a node or observer status.
Color nodeStatusColor(BuildContext context, String status) {
  final cs = Theme.of(context).colorScheme;
  final m = MeshSonarColors.of(context);
  return switch (status) {
    'active' || 'online' => m.snrStrong,
    // Amber is the warning colour: heard less often than usual, or a report that is late.
    'degraded' || 'stale' => m.warning,
    'silent' || 'offline' => cs.error,
    _ => cs.outline,
  };
}

/// An observer's status in a word. [label] is the server's own wording, used when it sent one.
String observerStatusLabel(String s, {String? label}) =>
    label ??
    switch (s) {
      'online' => 'Online',
      'stale' => 'Stale',
      'offline' => 'Offline',
      _ => 'Not known',
    };

String observerKindLabel(String k) => switch (k) {
      'fixed' => 'MeshSonar observer',
      'phone' => 'Phone observer',
      'outside' => 'Outside feed',
      _ => 'Observer',
    };

/// What an observer is, with what the server adds (Round 2 N-U4): a phone that moves or stays put, and a station
/// MeshSonar itself runs. Each addition shows only when the server sent it.
String observerKindWords(ObserverRow r) {
  if (r.kind == 'phone') {
    return switch (r.phoneKind) { 'mobile' => 'Phone observer, moving', 'fixed' => 'Phone observer, fixed', _ => 'Phone observer' };
  }
  if (r.kind == 'fixed' && r.operatedByMeshsonar == true) return 'MeshSonar observer, run by MeshSonar';
  return observerKindLabel(r.kind);
}

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
/// A [collapsible] section is one row (title, a one-line [summary], a chevron) that opens with a tap: the long and the
/// rarely read parts of a page start closed, so the page is a few screens and not twenty.
class NodeSection extends StatelessWidget {
  final String title;
  final String? id;
  final List<Widget> children;
  final bool collapsible, initiallyOpen;

  /// What the closed row says under its title (the headline figure, or what the section is in plain words).
  final String? summary;
  final Key? summaryKey;

  /// Opens a [collapsible] section from outside (a link on the page that jumps to it).
  final ExpansibleController? controller;
  const NodeSection(
      {super.key, required this.title, required this.children, this.id, this.collapsible = false, this.initiallyOpen = false, this.summary, this.summaryKey, this.controller});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final head = Semantics(header: true, child: Text(title, style: t.textTheme.titleMedium));
    if (collapsible) {
      return Padding(
        key: id == null ? null : Key('node-section-$id'),
        padding: const EdgeInsets.only(top: Gap.xs),
        child: Theme(
          data: t.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: PageStorageKey('node-${id ?? title}-tile'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: Gap.s),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            initiallyExpanded: initiallyOpen,
            controller: controller,
            title: head,
            subtitle: summary == null
                ? null
                : Text(summary!, key: summaryKey, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            children: children,
          ),
        ),
      );
    }
    return Padding(
      key: id == null ? null : Key('node-section-$id'),
      padding: const EdgeInsets.only(top: Gap.l),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        head,
        const SizedBox(height: Gap.xs),
        ...children,
      ]),
    );
  }
}

/// A long list inside a section: the first [first] rows, then one "Show all N" button (44 pt) for the rest.
class NodeMoreList extends StatefulWidget {
  final String id;
  final List<Widget> children;
  final int first;
  const NodeMoreList({super.key, required this.id, required this.children, this.first = 5});
  @override
  State<NodeMoreList> createState() => _NodeMoreListState();
}

class _NodeMoreListState extends State<NodeMoreList> {
  bool _all = false;
  @override
  Widget build(BuildContext context) {
    final rows = widget.children;
    final cut = !_all && rows.length > widget.first + 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...(cut ? rows.take(widget.first) : rows),
      if (cut)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: Key('node-more-${widget.id}'),
            style: TextButton.styleFrom(minimumSize: const Size(44, 44)),
            onPressed: () => setState(() => _all = true),
            child: Text('Show all ${rows.length}'),
          ),
        ),
    ]);
  }
}

final RegExp _hexName = RegExp(r'^[0-9a-fA-F]{24,}$');

/// A name people can read: an observer or node that has no name arrives as its 64-character key, which wraps over two
/// lines and says nothing. That becomes "Unnamed 212de2ca…"; a real name is returned as it came.
String readableName(String name) => _hexName.hasMatch(name) ? 'Unnamed ${name.substring(0, 8).toLowerCase()}…' : name;

/// "d03dac1d…46d3e1": a 64-character key on one line.
String shortKey(String key) => key.length <= 20 ? key : '${key.substring(0, 8)}…${key.substring(key.length - 6)}';

/// The public key on one line with a Copy button (the whole key goes to the clipboard).
class NodeKeyRow extends StatelessWidget {
  final String nodeKey;
  final String label;
  const NodeKeyRow(this.nodeKey, {super.key, this.label = 'Key'});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    void copy() {
      Clipboard.setData(ClipboardData(text: nodeKey));
      showAppToast(context, 'Key copied');
    }

    return InkWell(
      key: const Key('node-key-copy'),
      onTap: copy,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Row(children: [
          Text('$label  ', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          Expanded(
            child: Text(shortKey(nodeKey),
                key: const Key('node-key'), maxLines: 1, overflow: TextOverflow.ellipsis, semanticsLabel: 'Key $nodeKey', style: t.textTheme.bodyMedium),
          ),
          Icon(Icons.copy, size: 18, color: t.colorScheme.primary, semanticLabel: 'Copy the key'),
          const SizedBox(width: Gap.xs),
          Text('Copy', style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary)),
        ]),
      ),
    );
  }
}

/// Clock drift people can read: a small drift in seconds per day; a huge figure (a clock that jumps, or two radios on
/// one key) is said in words, not as "-67263900.0 s per day".
String driftText(double sPerDay) {
  final a = sPerDay.abs();
  if (a >= 3600) return 'Jumps around (not a steady drift)';
  final side = sPerDay >= 0 ? 'fast' : 'slow';
  return a < 0.05 ? 'None measured' : '${a.toStringAsFixed(1)} s per day $side';
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
          // The star is a choice, not a warning: the accent, never amber.
          icon: Icon(on ? Icons.star : Icons.star_border, color: on ? Theme.of(context).colorScheme.primary : null),
          onPressed: () => store.toggleFavourite(kind, id, name: name, region: region),
        );
      });
}

/// "Updated 5 min ago · pull to refresh" at the top of a list that loads once and does not poll (Round 2 N-U11):
/// the rows say "heard 22 min ago" as of the load, so a list left open says how old it is. Ticks on its own.
class UpdatedLine extends StatefulWidget {
  /// When the list was loaded; null shows nothing.
  final DateTime? at;
  final DateTime Function() clock;
  final EdgeInsetsGeometry padding;
  const UpdatedLine({super.key, required this.at, this.clock = DateTime.now, this.padding = const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0)});

  static String textOf(DateTime at, DateTime now) {
    final ago = relativeTime(at, now: now);
    return 'Updated $ago \u00B7 pull to refresh';
  }

  @override
  State<UpdatedLine> createState() => _UpdatedLineState();
}

class _UpdatedLineState extends State<UpdatedLine> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final at = widget.at;
    if (at == null) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      padding: widget.padding,
      child: Text(UpdatedLine.textOf(at, widget.clock()), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}

/// A plain link row on a page: "Packets it heard  ›" (at least 44 pt). Find it by `link-<id>`.
class PageLink extends StatelessWidget {
  final String id, label;
  final String? detail;
  final IconData icon;
  final VoidCallback onTap;
  const PageLink({super.key, required this.id, required this.label, required this.onTap, this.detail, this.icon = Icons.chevron_right});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      button: true,
      child: InkWell(
        key: Key('link-$id'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.primary)),
                  if (detail != null) Text(detail!, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ]),
              ),
            ),
            Icon(icon, color: t.colorScheme.primary, size: 20),
          ]),
        ),
      ),
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
