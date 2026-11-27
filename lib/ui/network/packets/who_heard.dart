// "Who heard it" (Round 2 N-U1): the receptions of one packet grouped by observer. The packet page and the packet
// list's inline "Heard by" both use it.
//
// Heading "Heard 9 times by 3 observers". One row per observer: name, kind, "heard 4 times", best signal, first time.
// A tap opens that observer's copies. Each copy shows the time, the signal and the whole route with every hop, never
// shortened: Sender › hop › hop › this observer.
//   Known repeater  "Hilltop RPT (5e)"
//   Likely          "North Tower (likely, 80%)"
//   Shared ID       "5e · one of 3 repeaters" (a tap lists the candidates and offers the Prefix Tool)
//   Unknown         "5e · unknown repeater"
//   No resolved path for the copy: the code alone, "5e · not named"
// Each copy has "Replay on map" (Network > Live draws and plays that one reception) and, when a hop is unnamed or
// shared, "Work out the likely route" (Path Inspector with the copy's hops and observer).
// The detail inlines the first 50 receptions only; when more exist, opening an observer fetches that observer's own
// copies (`/v1/packets/{hash}/observations?observer=`).
import 'package:flutter/material.dart';

import '../../../core/time_format.dart';
import '../../../core/v1/packets_api.dart';
import '../../app.dart' show AppScope;
import '../../theme.dart';
import 'packet_ui.dart';

/// Observers listed before "Show all".
const int packetObserversShown = 5;

/// One observer's receptions of a packet.
class ObserverCopies {
  final PacketObserver observer;

  /// Oldest first.
  final List<PacketObservation> copies;
  const ObserverCopies(this.observer, this.copies);

  double? get bestSnr {
    double? best;
    for (final c in copies) {
      if (c.snr != null && (best == null || c.snr! > best)) best = c.snr;
    }
    return best;
  }

  DateTime? get first {
    DateTime? f;
    for (final c in copies) {
      if (c.at != null && (f == null || c.at!.isBefore(f))) f = c.at;
    }
    return f;
  }
}

/// [observations] as one entry per observer, in the order each observer first appears; copies oldest first.
List<ObserverCopies> groupByObserver(List<PacketObservation> observations) {
  final byId = <String, List<PacketObservation>>{};
  final who = <String, PacketObserver>{};
  for (final o in observations) {
    (byId[o.observer.id] ??= []).add(o);
    who.putIfAbsent(o.observer.id, () => o.observer);
  }
  return [
    for (final e in byId.entries)
      ObserverCopies(
          who[e.key]!,
          [...e.value]..sort((a, b) {
              if (a.at == null || b.at == null) return 0;
              return a.at!.compareTo(b.at!);
            })),
  ];
}

/// "MeshSonar observer" / "Phone observer" / "Outside feed".
String copyObserverKind(String kind) => switch (kind) {
      'phone' => 'Phone observer',
      'outside' => 'Outside feed',
      _ => 'MeshSonar observer',
    };

/// "1 time", "4 times".
String timesText(int n) => '$n time${n == 1 ? '' : 's'}';

enum RouteStepKind { sender, known, likely, shared, unknown, raw, observer }

/// One step of a copy's route, as it is read.
class RouteStep {
  final RouteStepKind kind;
  final String text;

  /// The short ID of a hop step (null for the sender and the observer).
  final String? prefix;

  /// The resolved hop, when the server resolved the path.
  final PacketHop? hop;
  const RouteStep(this.kind, this.text, {this.prefix, this.hop});

  /// A hop nobody has pinned to one repeater: Path Inspector can help.
  bool get unsure => kind == RouteStepKind.shared || kind == RouteStepKind.unknown || kind == RouteStepKind.raw;
}

/// The resolved path of [o] among [paths]: the one it names, else the one that lists it. Null when neither does (a
/// `raw:` path id, or a source that resolves nothing).
PacketPath? pathOfCopy(PacketObservation o, List<PacketPath> paths) {
  for (final p in paths) {
    if (o.pathId != null && p.id == o.pathId) return p;
  }
  for (final p in paths) {
    if (p.observationIds.contains(o.id)) return p;
  }
  return null;
}

String _hopText(PacketHop h) {
  switch (h.confidence) {
    case HopConfidence.unique:
      return h.node == null ? '${h.prefix} · one repeater has this ID' : '${h.node!.label} (${h.prefix})';
    case HopConfidence.likely:
      final pct = h.score == null ? '' : ', ${(h.score!.clamp(0.0, 1.0) * 100).round()}%';
      return h.node == null ? '${h.prefix} · unknown repeater' : '${h.node!.label} (likely$pct)';
    case HopConfidence.ambiguous:
      final n = h.candidatesTotal > 0 ? h.candidatesTotal : h.candidates.length;
      return n > 1 ? '${h.prefix} · one of $n repeaters' : '${h.prefix} · one of several repeaters';
    case HopConfidence.unknown:
    case HopConfidence.other:
      return '${h.prefix} · unknown repeater';
  }
}

RouteStepKind _hopKind(PacketHop h) => switch (h.confidence) {
      HopConfidence.unique => h.node == null ? RouteStepKind.unknown : RouteStepKind.known,
      HopConfidence.likely => h.node == null ? RouteStepKind.unknown : RouteStepKind.likely,
      HopConfidence.ambiguous => RouteStepKind.shared,
      _ => RouteStepKind.unknown,
    };

/// The whole route of one copy, every hop, in order. A flood packet: the sender, each hop it crossed, the observer.
/// A direct packet ([PacketPath.direction] `remaining`): only the hops still ahead (see [copyRouteIsAhead]).
List<RouteStep> copyRoute(PacketObservation o, {List<PacketPath> paths = const [], PacketNode? origin}) {
  final p = pathOfCopy(o, paths);
  final hops = <RouteStep>[
    if (p != null && (o.path.isEmpty || p.hops.length == o.path.length))
      for (final h in p.hops) RouteStep(_hopKind(h), _hopText(h), prefix: h.prefix, hop: h)
    else
      for (final c in o.path) RouteStep(RouteStepKind.raw, '$c · not named', prefix: c),
  ];
  if (p?.direction == 'remaining') return hops;
  return [
    RouteStep(RouteStepKind.sender, origin?.name ?? 'Sender'),
    ...hops,
    RouteStep(RouteStepKind.observer, o.observer.name),
  ];
}

/// True when the hops of [o] are the route still ahead of a direct packet, not the hops it crossed.
bool copyRouteIsAhead(PacketObservation o, List<PacketPath> paths) => pathOfCopy(o, paths)?.direction == 'remaining';

/// The route in one line for a screen reader: "Sender, then Hilltop RPT (5e), then INNO-OB-2".
String describeRoute(List<RouteStep> steps) => steps.map((s) => s.text).join(', then ');

class WhoHeard extends StatefulWidget {
  final String hash;
  final List<PacketObservation> observations;

  /// The packet's resolved paths (empty in the packet list, which has none: hops then show as codes).
  final List<PacketPath> paths;
  final PacketNode? origin;

  /// The server's totals for the heading; null = count what is loaded.
  final int? observationCount, observerCount;
  final bool expired;

  /// More receptions exist on the server than are loaded.
  final bool moreOnServer;
  final VoidCallback? onLoadMore;
  final bool loadingMore;

  /// Every copy of one observer, for the copies past the inlined 50. Null = show what is loaded.
  final Future<List<PacketObservation>> Function(String observerId)? fetchObserver;

  /// "Replay on map" on a copy; null hides the button.
  final void Function(PacketObservation copy)? onReplay;

  /// "Work out the likely route" on a copy with an unnamed or shared hop; null hides it.
  final void Function(PacketObservation copy)? onInspectRoute;

  /// "See who shares 5e" on a shared-ID hop; null hides it.
  final void Function(String prefix)? onSharedId;

  /// Small text and no section heading: the packet list's inline "Heard by".
  final bool compact;
  const WhoHeard({
    super.key,
    required this.hash,
    required this.observations,
    this.paths = const [],
    this.origin,
    this.observationCount,
    this.observerCount,
    this.expired = false,
    this.moreOnServer = false,
    this.onLoadMore,
    this.loadingMore = false,
    this.fetchObserver,
    this.onReplay,
    this.onInspectRoute,
    this.onSharedId,
    this.compact = false,
  });

  /// "Heard 9 times by 3 observers".
  static String heading(int times, int observers) => 'Heard ${timesText(times)} by $observers observer${observers == 1 ? '' : 's'}';

  @override
  State<WhoHeard> createState() => _WhoHeardState();
}

class _WhoHeardState extends State<WhoHeard> {
  bool _all = false;
  final Set<String> _open = {};
  final Set<String> _loading = {};

  /// An observer's full list of copies once fetched (replaces the loaded ones).
  final Map<String, List<PacketObservation>> _fetched = {};

  Future<void> _toggle(ObserverCopies g) async {
    final id = g.observer.id;
    if (_open.contains(id)) {
      setState(() => _open.remove(id));
      return;
    }
    setState(() => _open.add(id));
    final fetch = widget.fetchObserver;
    if (fetch == null || !widget.moreOnServer || _fetched.containsKey(id) || _loading.contains(id)) return;
    setState(() => _loading.add(id));
    try {
      final rows = await fetch(id);
      if (!mounted) return;
      // Keep anything already loaded that the answer does not hold (a page limit), so a copy never disappears.
      final ids = {for (final r in rows) r.id};
      final merged = [...rows, for (final c in g.copies) if (!ids.contains(c.id)) c];
      setState(() => _fetched[id] = groupByObserver(merged).firstOrNull?.copies ?? merged);
    } catch (_) {
      // The loaded copies stay; the row keeps saying "or more".
    } finally {
      if (mounted) setState(() => _loading.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final groups = groupByObserver(widget.observations);
    final shown = _all ? groups : groups.take(packetObserversShown).toList();
    final hidden = groups.length - shown.length;
    final times = widget.observationCount ?? widget.observations.length;
    final observers = widget.observerCount ?? groups.length;
    final head = WhoHeard.heading(times < widget.observations.length ? widget.observations.length : times, observers < groups.length ? groups.length : observers);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.compact)
        Text(head, key: const Key('who-heard-heading'), style: t.textTheme.labelMedium)
      else
        Padding(
          padding: const EdgeInsets.only(top: Gap.l, bottom: Gap.xs),
          child: Semantics(header: true, child: Text(head, key: const Key('who-heard-heading'), style: t.textTheme.titleMedium)),
        ),
      if (widget.expired)
        const PacketNote('The per-observer rows of this packet are older than 14 days and were removed; the counts above are kept.'),
      for (final g in shown) _observer(context, g),
      if (hidden > 0)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
              key: const Key('packet-obs-all'), onPressed: () => setState(() => _all = true), child: Text('Show all ${groups.length} observers')),
        ),
      if ((_all || hidden == 0) && widget.moreOnServer && widget.onLoadMore != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const Key('packet-obs-more'),
            onPressed: widget.loadingMore ? null : widget.onLoadMore,
            child: Text(widget.loadingMore ? 'Loading…' : 'Show more observers'),
          ),
        ),
      if (groups.isEmpty && !widget.expired && widget.compact) Text('No record of who heard this packet.', style: muted),
    ]);
  }

  Widget _observer(BuildContext context, ObserverCopies loaded) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final id = loaded.observer.id;
    final g = _fetched[id] == null ? loaded : ObserverCopies(loaded.observer, _fetched[id]!);
    final open = _open.contains(id);
    // Until this observer's own copies are fetched, more may exist past the inlined ones.
    final atLeast = widget.moreOnServer && widget.fetchObserver != null && !_fetched.containsKey(id);
    final count = 'heard ${timesText(g.copies.length)}${atLeast ? ' or more' : ''}';
    final best = g.bestSnr;
    final line = [
      copyObserverKind(g.observer.kind),
      count,
      if (g.first != null) 'first ${timeOfDay(g.first, seconds: true)}',
    ].join(' · ');
    return Container(
      key: ValueKey('packet-observer-$id'),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.colorScheme.outlineVariant.withValues(alpha: 0.5)))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Semantics(
          button: true,
          expanded: open,
          label: '${g.observer.name}, $line${best == null ? '' : ', best signal ${snrText(best)}'}',
          child: InkWell(
            key: ValueKey('packet-observer-row-$id'),
            onTap: () => _toggle(loaded),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: ExcludeSemantics(
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(g.observer.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: (widget.compact ? t.textTheme.bodySmall : t.textTheme.bodyMedium)?.copyWith(fontWeight: FontWeight.w600)),
                        Text(line, style: muted),
                      ]),
                    ),
                    if (best != null)
                      Padding(
                        padding: const EdgeInsets.only(left: Gap.s),
                        child: Text(snrText(best), style: t.textTheme.labelLarge?.copyWith(color: snrColor(context, best))),
                      ),
                    Icon(open ? Icons.expand_less : Icons.expand_more, color: t.colorScheme.onSurfaceVariant),
                  ]),
                ),
              ),
            ),
          ),
        ),
        if (open) ...[
          for (final c in g.copies) _copy(context, c),
          if (_loading.contains(id))
            Padding(
              padding: const EdgeInsets.only(left: Gap.m, bottom: Gap.s),
              child: Text('Loading every time ${g.observer.name} heard it…', key: ValueKey('packet-observer-loading-$id'), style: muted),
            ),
        ],
      ]),
    );
  }

  Widget _copy(BuildContext context, PacketObservation o) {
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final steps = copyRoute(o, paths: widget.paths, origin: widget.origin);
    final ahead = copyRouteIsAhead(o, widget.paths);
    final unsure = steps.any((s) => s.unsure);
    final facts = [
      timeOfDay(o.at, seconds: true, ifNull: 'time not known'),
      snrText(o.snr),
      if (o.rssi != null) '${o.rssi!.round()} dBm',
      if (o.path.isEmpty && !ahead) 'heard direct',
    ].join(' · ');
    return Padding(
      key: ValueKey('packet-obs-${o.id}'),
      padding: const EdgeInsets.only(left: Gap.m, bottom: Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(facts, style: t.textTheme.bodySmall),
        if (ahead) Text(steps.isEmpty ? 'A direct packet: no route is left ahead.' : 'Route still ahead (a direct packet: each hop removes itself)', style: muted),
        if (steps.isNotEmpty)
          Semantics(
            container: true,
            label: '${ahead ? 'Route still ahead' : 'Route'}: ${describeRoute(steps)}',
            child: Wrap(
              key: ValueKey('packet-obs-route-${o.id}'),
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < steps.length; i++) ...[
                  if (i > 0) ExcludeSemantics(child: Text('  ›  ', style: muted)),
                  _step(context, o, i, steps[i]),
                ],
              ],
            ),
          ),
        if (widget.onReplay != null || (unsure && widget.onInspectRoute != null))
          Wrap(spacing: Gap.s, children: [
            if (widget.onReplay != null)
              TextButton.icon(
                key: ValueKey('packet-obs-replay-${o.id}'),
                style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: Gap.s)),
                icon: const Icon(Icons.play_circle_outline, size: 18),
                label: const Text('Replay on map'),
                onPressed: () => widget.onReplay!(o),
              ),
            if (unsure && widget.onInspectRoute != null)
              TextButton.icon(
                key: ValueKey('packet-obs-inspect-${o.id}'),
                style: TextButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: Gap.s)),
                icon: const Icon(Icons.alt_route, size: 18),
                label: const Text('Work out the likely route'),
                onPressed: () => widget.onInspectRoute!(o),
              ),
          ]),
      ]),
    );
  }

  Widget _step(BuildContext context, PacketObservation o, int i, RouteStep s) {
    final t = Theme.of(context);
    final base = t.textTheme.bodySmall;
    final style = switch (s.kind) {
      RouteStepKind.sender || RouteStepKind.observer => base?.copyWith(fontWeight: FontWeight.w600),
      RouteStepKind.known => base,
      _ => base?.copyWith(color: t.colorScheme.onSurfaceVariant),
    };
    final h = s.hop;
    if (s.kind == RouteStepKind.shared && h != null) {
      return Semantics(
        button: true,
        hint: 'Shows the repeaters that share this ID',
        child: InkWell(
          key: ValueKey('packet-hop-shared-${o.id}-${h.index}'),
          onTap: () => showSharedHopSheet(context, h, onSharedId: widget.onSharedId),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Align(
              widthFactor: 1,
              alignment: Alignment.centerLeft,
              child: Text(s.text, style: base?.copyWith(color: t.colorScheme.primary, decoration: TextDecoration.underline, decorationColor: t.colorScheme.primary)),
            ),
          ),
        ),
      );
    }
    return Text(s.text, style: style);
  }
}

/// Repeaters listed in the shared-ID sheet before "and N more".
const int sharedHopCandidatesShown = 8;

/// The repeaters that share a hop's short ID, most likely first, with "See who shares 5e" (the Prefix Tool).
Future<void> showSharedHopSheet(BuildContext context, PacketHop h, {void Function(String prefix)? onSharedId}) {
  final units = AppScope.unitsOf(context);
  final total = h.candidatesTotal > 0 ? h.candidatesTotal : h.candidates.length;
  final list = h.candidates.take(sharedHopCandidatesShown).toList();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheet) {
      final t = Theme.of(sheet);
      final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
      return SafeArea(
        child: SingleChildScrollView(
          key: const Key('hop-candidates-sheet'),
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text('${h.prefix} · one of ${total > 1 ? total : 'several'} repeaters', style: t.textTheme.titleMedium),
            const SizedBox(height: Gap.xs),
            Text('Several repeaters share this short ID, and none is clearly the one this packet went through.', style: muted),
            const SizedBox(height: Gap.s),
            if (list.isEmpty) Text('The server did not list them.', style: t.textTheme.bodyMedium),
            for (final c in list)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c.node.label, style: t.textTheme.bodyMedium),
                  if (c.score != null || c.distanceKm != null)
                    Text(
                      [
                        if (c.score != null) '${(c.score!.clamp(0.0, 1.0) * 100).round()}% likely',
                        if (c.distanceKm != null) '${units.distance(c.distanceKm! * 1000)} away',
                      ].join(' · '),
                      style: muted,
                    ),
                ]),
              ),
            if (total > list.length && list.isNotEmpty) Text('and ${total - list.length} more', style: muted),
            if (onSharedId != null) ...[
              const SizedBox(height: Gap.s),
              FilledButton.tonal(
                key: const Key('hop-see-shares'),
                onPressed: () {
                  Navigator.of(sheet).pop();
                  onSharedId(h.prefix);
                },
                child: Text('See who shares ${h.prefix}'),
              ),
            ],
          ]),
        ),
      );
    },
  );
}
