// Bottom sheet for one repeater heard on a drive: name, full key, position, distance from the latest position,
// times heard, last/best SNR, an SNR-over-the-drive sparkline and when it was last heard.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/heard.dart';
import '../core/model.dart';
import 'repeater_widgets.dart';
import 'theme.dart';
import 'widgets.dart';

/// One hearing of a repeater on a ping (echo or neighbour exchange).
class RepeaterHearing {
  final DateTime ts;
  final double? snrDb;
  final int? hops;
  final double lat, lon;
  const RepeaterHearing({required this.ts, required this.snrDb, required this.hops, required this.lat, required this.lon});
}

/// Every time [id] was heard in [pings], oldest first. Echoes and neighbour exchanges both count (once per ping;
/// the best SNR of that ping is kept).
List<RepeaterHearing> hearingsOf(String id, List<DrivePing> pings) {
  final k = id.toLowerCase();
  final sorted = List.of(pings)..sort((a, b) => a.ts.compareTo(b.ts));
  final out = <RepeaterHearing>[];
  for (final p in sorted) {
    double? best;
    int? hops;
    var hit = false;
    for (final e in p.echoes) {
      if (e.repeater.toLowerCase() != k) continue;
      hit = true;
      hops ??= e.hops;
      if (e.snrDb != null && (best == null || e.snrDb! > best)) {
        best = e.snrDb;
        hops = e.hops;
      }
    }
    final n = p.neighbor;
    if (n != null && n.repeater.toLowerCase() == k) {
      hit = true;
      if (n.localSnrDb != null && (best == null || n.localSnrDb! > best)) best = n.localSnrDb;
    }
    if (hit) out.add(RepeaterHearing(ts: p.ts, snrDb: best, hops: hops, lat: p.lat, lon: p.lon));
  }
  return out;
}

Future<void> showRepeaterDetail(
  BuildContext context, {
  required String id,
  required RepeaterLookup lookup,
  required List<DrivePing> pings,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scroll) =>
          RepeaterDetailSheet(id: id, lookup: lookup, pings: pings, scrollController: scroll),
    ),
  );
}

class RepeaterDetailSheet extends StatelessWidget {
  final String id;
  final RepeaterLookup lookup;
  final List<DrivePing> pings;
  final ScrollController? scrollController;
  const RepeaterDetailSheet({super.key, required this.id, required this.lookup, required this.pings, this.scrollController});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final m = lookup.resolve(id);
    final hs = hearingsOf(id, pings);
    final snrs = [for (final h in hs) h.snrDb];
    final measured = snrs.whereType<double>().toList();
    final best = measured.isEmpty ? null : measured.reduce(math.max);
    final last = hs.isEmpty ? null : hs.last;
    // "Now" = the newest ping position (the phone's latest known position on this drive).
    DrivePing? newest;
    for (final p in pings) {
      if (newest == null || p.ts.isAfter(newest.ts)) newest = p;
    }
    final ref = m.ref;
    final distNow = (ref != null && newest != null) ? m.distanceFrom(newest.lat, newest.lon) : null;
    final brgNow = (ref != null && newest != null) ? m.bearingFrom(newest.lat, newest.lon) : null;

    final facts = <(String, String)>[
      ('Id as heard', id.toUpperCase()),
      ('Full key', ref?.key ?? (m.ambiguous ? '${m.candidates.length} known repeaters share this id' : 'Not in any repeater list')),
      if (ref != null) ('Position', '${ref.lat.toStringAsFixed(5)}, ${ref.lon.toStringAsFixed(5)}'),
      if (distNow != null) ('Distance now', formatDistanceBearing(distNow, brgNow)),
      ('Times heard', '${hs.length}'),
      ('Last SNR', last?.snrDb == null ? '—' : formatSnrShort(last!.snrDb!)),
      ('Best SNR', best == null ? '—' : formatSnrShort(best)),
      if (last != null) ('Last heard', '${formatTime(last.ts)}${last.hops == null ? '' : ' · ${hopsLabel(last.hops)}'}'),
      if (m.source != RepeaterSource.none) ('Name from', m.source == RepeaterSource.cmat ? 'CMAT' : 'map.meshcore.io'),
    ];

    return ListView(
      key: const Key('repeater-detail'),
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xl),
      children: [
        Row(children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(shape: BoxShape.circle, color: mc.beacon.withValues(alpha: 0.16)),
            child: Icon(Icons.cell_tower, color: mc.beacon),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Text(repeaterTitle(m), style: t.textTheme.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: Gap.s),
          RepeaterIdChip(id),
        ]),
        const SizedBox(height: Gap.l),
        Text('SNR each time it was heard', style: t.textTheme.labelLarge),
        const SizedBox(height: Gap.s),
        Container(
          height: 84,
          padding: const EdgeInsets.all(Gap.s),
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(Corners.chip),
          ),
          child: measured.isEmpty
              ? Center(child: Text('No SNR measured', style: t.textTheme.bodySmall))
              : SnrSparkline(key: const Key('snr-sparkline'), values: snrs),
        ),
        const SizedBox(height: Gap.m),
        for (final (k, v) in facts)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 110, child: Text(k, style: t.textTheme.labelMedium)),
              Expanded(
                child: SelectableText(
                  v,
                  style: k == 'Full key'
                      ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
                      : t.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ]),
          ),
        if (ref == null && !m.ambiguous)
          Padding(
            padding: const EdgeInsets.only(top: Gap.s),
            child: Text(
              'Its name and position will show once CMAT or the public node map knows this repeater.',
              style: t.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// A small SNR line chart. Nulls (heard, SNR not measured) are drawn as gaps. A dashed line marks 0 dB.
class SnrSparkline extends StatelessWidget {
  final List<double?> values;
  const SnrSparkline({super.key, required this.values});
  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    return CustomPaint(
      size: Size.infinite,
      painter: _SparkPainter(values, mc, Theme.of(context).colorScheme.outline),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double?> v;
  final MeshSonarColors mc;
  final Color zero;
  _SparkPainter(this.v, this.mc, this.zero);

  @override
  void paint(Canvas canvas, Size size) {
    final nums = v.whereType<double>();
    if (nums.isEmpty) return;
    var lo = math.min(nums.reduce(math.min), -5.0), hi = math.max(nums.reduce(math.max), 5.0);
    if (hi - lo < 1) hi = lo + 1;
    double y(double s) => size.height - (s - lo) / (hi - lo) * size.height;
    double x(int i) => v.length == 1 ? size.width / 2 : i * size.width / (v.length - 1);

    // 0 dB reference
    final zp = Paint()
      ..color = zero.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var dx = 0.0; dx < size.width; dx += 8) {
      canvas.drawLine(Offset(dx, y(0)), Offset(math.min(dx + 4, size.width), y(0)), zp);
    }

    final line = Paint()
      ..color = mc.snrMid
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round;
    Path? path;
    for (var i = 0; i < v.length; i++) {
      final s = v[i];
      if (s == null) {
        if (path != null) canvas.drawPath(path, line);
        path = null;
        continue;
      }
      final o = Offset(x(i), y(s));
      if (path == null) {
        path = Path()..moveTo(o.dx, o.dy);
      } else {
        path.lineTo(o.dx, o.dy);
      }
    }
    if (path != null) canvas.drawPath(path, line);
    for (var i = 0; i < v.length; i++) {
      final s = v[i];
      if (s == null) continue;
      canvas.drawCircle(Offset(x(i), y(s)), 3, Paint()..color = mc.forPing(heard: true, snr: s));
    }
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.v != v || old.mc != mc;
}
