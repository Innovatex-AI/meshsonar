// The heard box: a compact "who's in range" card floated over the map (like MeshMapper's live repeater list, but
// with a hold so a repeater doesn't flicker out the moment one ping misses it).
//
//   • Heard on the latest ping: full colour, SNR coloured on the signal scale, distance when its position is known.
//   • Missed the latest ping but still inside the hold: dimmed, with pips showing how many pings it has left.
//   • Not heard for the whole hold (stale): folded into a "+N earlier" line; tap it to see them greyed out.
//
// Tap a repeater to pick it on the map (it's framed with your position and its label opens). Tap the header to
// collapse the box to a single line.
//
// Keys: 'heard-box', 'heard-toggle', 'heard-count', 'heard-row-<id>', 'heard-earlier', 'heard-stale-<id>',
// 'heard-empty'.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/heard.dart' show haversineM;

import '../map/map_layers.dart';
import '../app.dart' show AppScope;
import '../theme.dart';

class HeardBox extends StatefulWidget {
  final List<HeardView> heard;
  final int holdPings;
  final String? selected;
  final ValueChanged<String?> onSelect;
  final bool driving;

  /// Max rows before "+N more".
  final int maxRows;
  final double width;

  /// Where we are now: distances are live from here (else as they were when last heard).
  final LatLng? here;
  const HeardBox({
    super.key = const Key('heard-box'),
    required this.heard,
    required this.holdPings,
    required this.onSelect,
    this.selected,
    this.driving = false,
    this.maxRows = 5,
    this.width = 232,
    this.here,
  });

  @override
  State<HeardBox> createState() => _HeardBoxState();
}

class _HeardBoxState extends State<HeardBox> {
  bool _collapsed = false;
  bool _showEarlier = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final live = [for (final h in widget.heard) if (h.live) h];
    final stale = [for (final h in widget.heard) if (!h.live) h];
    final shown = live.take(widget.maxRows).toList();
    final more = live.length - shown.length;

    final body = <Widget>[];
    if (!_collapsed) {
      if (live.isEmpty) {
        body.add(
          Padding(
            key: const Key('heard-empty'),
            padding: const EdgeInsets.fromLTRB(Gap.m, 2, Gap.m, Gap.s),
            child: Text(
              stale.isEmpty ? (widget.driving ? 'Listening… nothing heard yet' : 'Nothing heard') : 'Nobody in range now',
              style: t.textTheme.bodySmall,
            ),
          ),
        );
      }
      for (final h in shown) {
        body.add(_Row(
          view: h,
          holdPings: widget.holdPings,
          here: widget.here,
          selected: widget.selected != null && widget.selected == h.mapKey,
          onTap: () => widget.onSelect(widget.selected == h.mapKey ? null : h.mapKey),
        ));
      }
      if (more > 0) {
        body.add(Padding(
          padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.xs),
          child: Text('+$more more in range', style: t.textTheme.labelSmall),
        ));
      }
      if (stale.isNotEmpty) {
        body.add(InkWell(
          key: const Key('heard-earlier'),
          onTap: () => setState(() => _showEarlier = !_showEarlier),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(Gap.m, 3, Gap.s, 5),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '+${stale.length} earlier',
                    style: t.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Icon(_showEarlier ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 16, color: t.colorScheme.outline),
              ],
            ),
          ),
        ));
        if (_showEarlier) {
          for (final h in stale.take(8)) {
            body.add(_Row(
              view: h,
              holdPings: widget.holdPings,
              here: widget.here,
              selected: widget.selected != null && widget.selected == h.mapKey,
              onTap: () => widget.onSelect(widget.selected == h.mapKey ? null : h.mapKey),
            ));
          }
        }
      }
    }

    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.93),
        borderRadius: BorderRadius.circular(Corners.chip),
        border: Border.all(color: t.colorScheme.outlineVariant),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 12, offset: const Offset(0, 3))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              live: live.length,
              collapsed: _collapsed,
              preview: _collapsed && live.isNotEmpty ? live.first.label : null,
              onTap: () => setState(() => _collapsed = !_collapsed),
            ),
            ...body,
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final int live;
  final bool collapsed;
  final String? preview;
  final VoidCallback onTap;
  const _Header({required this.live, required this.collapsed, required this.preview, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final on = live > 0;
    return InkWell(
      key: const Key('heard-toggle'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, 7, Gap.s, 6),
        child: Row(
          children: [
            Text(
              'HEARD',
              style: t.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              key: const Key('heard-count'),
              constraints: const BoxConstraints(minWidth: 20),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: on ? t.colorScheme.primary : t.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$live',
                textAlign: TextAlign.center,
                style: numberStyle(context, size: 13, color: on ? t.colorScheme.onPrimary : t.colorScheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: preview == null
                  ? const SizedBox.shrink()
                  : Text(preview!, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelMedium),
            ),
            Icon(collapsed ? Icons.expand_more_rounded : Icons.expand_less_rounded, size: 20, color: t.colorScheme.outline),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final HeardView view;
  final int holdPings;
  final bool selected;
  final VoidCallback onTap;
  final LatLng? here;
  const _Row({required this.view, required this.holdPings, required this.selected, required this.onTap, this.here});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final h = view;
    final fresh = h.phase == HeardPhase.fresh;
    final stale = h.phase == HeardPhase.stale;
    final grey = t.colorScheme.outline;
    final signal = mc.forPing(heard: true, snr: h.snrDb); // no SNR reading: purple (heard, signal unknown), never a strength colour
    final accent = fresh ? signal : (stale ? grey.withValues(alpha: 0.5) : Color.lerp(signal, grey, 0.55)!);

    final ref = h.ref;
    final dist = (here != null && ref != null) ? haversineM(here!.latitude, here!.longitude, ref.lat, ref.lon) : h.distanceM;
    final sub = <String>[
      if (dist != null) AppScope.unitsOf(context).distance(dist) else if (h.ref == null) h.id.toUpperCase(),
      if (stale) '${h.pingsAgo} pings ago' else if (!fresh) 'missed ${h.pingsAgo}' else '×${h.timesHeard}',
    ];

    return Opacity(
      opacity: stale ? 0.5 : 1,
      child: InkWell(
        key: ValueKey(stale ? 'heard-stale-${h.id}' : 'heard-row-${h.id}'),
        onTap: onTap,
        child: Container(
          color: selected ? t.colorScheme.primary.withValues(alpha: 0.14) : null,
          padding: const EdgeInsets.fromLTRB(Gap.s, 4, Gap.s + 2, 4),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 30,
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      h.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.textTheme.titleSmall?.copyWith(
                        fontSize: 14,
                        height: 1.15,
                        color: fresh ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(sub.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.labelSmall?.copyWith(fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: Gap.xs),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    h.snrDb == null ? '—' : formatSnrShort(h.snrDb!),
                    style: numberStyle(context, size: 18, color: fresh ? signal : t.colorScheme.onSurfaceVariant),
                  ),
                  if (!stale) ...[
                    const SizedBox(height: 3),
                    _HoldPips(left: h.holdLeft, total: holdPings, color: fresh ? signal : grey),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How many more pings a repeater stays "live" without being heard.
class _HoldPips extends StatelessWidget {
  final int left;
  final int total;
  final Color color;
  const _HoldPips({required this.left, required this.total, required this.color});
  @override
  Widget build(BuildContext context) {
    final off = Theme.of(context).colorScheme.outlineVariant;
    final n = total.clamp(1, 8);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < n; i++)
          Container(
            width: 5,
            height: 5,
            margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
            decoration: BoxDecoration(shape: BoxShape.circle, color: i < left ? color : off),
          ),
      ],
    );
  }
}
