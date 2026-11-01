// One flood packet, drawn: where it went hop by hop (map with a step slider and Play), SNR at each observer, the propagation
// tree and what the bytes are. Data: `tool-routes?action=trace` (lib/core/flood_routes_api.dart). Locations are the server's
// resolved hop positions; an unplaced hop is listed in the tree but not drawn. Last hop into an observer is drawn by signal
// strength, hops inside the path carry no SNR and are dashed (the same rule as the website).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/flood_routes_api.dart';
import '../charts/chart_frame.dart';
import '../map/coverage_map.dart';
import '../theme.dart';
import 'region_common.dart' show groupInt;

String clockUtc(DateTime? t) {
  if (t == null) return 'unknown';
  final u = t.toUtc();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(u.hour)}:${p(u.minute)}:${p(u.second)} UTC';
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String dayUtc(DateTime? t) {
  if (t == null) return 'unknown';
  final u = t.toUtc();
  return '${_months[u.month - 1]} ${u.day} ${clockUtc(u)}';
}

const _confidenceLabel = {
  'okimesh': 'matched to a known repeater',
  'unique': 'unique prefix',
  'geo': 'nearest plausible match',
  'unresolved': 'unresolved prefix',
  'observer': 'observer',
  'origin': 'origin',
};

/// Line width from SNR (website rule: 1.6 .. 6.6 for -15 .. +15 dB; no SNR = thin).
double snrStroke(double? snr) => snr == null ? 1.6 : 1.6 + ((snr.clamp(-15, 15) + 15) / 30) * 5;

class FloodTraceView extends StatefulWidget {
  final FloodTrace trace;
  final bool tiles;
  const FloodTraceView({super.key, required this.trace, this.tiles = true});

  @override
  State<FloodTraceView> createState() => _FloodTraceViewState();
}

class _FloodTraceViewState extends State<FloodTraceView> {
  late int _step = widget.trace.maxDepth;
  Timer? _timer;
  bool _playing = false;

  @override
  void didUpdateWidget(FloodTraceView old) {
    super.didUpdateWidget(old);
    if (old.trace.hash != widget.trace.hash) {
      _stop();
      _step = widget.trace.maxDepth;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _playing = false;
  }

  void _play() {
    final max = widget.trace.maxDepth;
    if (_playing) {
      setState(_stop);
      return;
    }
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _step = max);
      return;
    }
    if (_step >= max) _step = 0;
    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(milliseconds: 750), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        if (_step >= max) {
          _stop();
        } else {
          _step++;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final tr = widget.trace;
    final relays = tr.relays.toList();
    final title = '${floodPayloadName(tr.payloadType)}${tr.origin.name == null ? '' : ' from ${tr.origin.name}'}';
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, key: const Key('trace-title'), style: t.textTheme.titleLarge),
      Text('Packet ${tr.hash}, first heard ${dayUtc(tr.firstSeen ?? tr.observations.firstOrNull?.time)}', style: t.textTheme.bodySmall?.copyWith(color: m.textMuted)),
      const SizedBox(height: Gap.s),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _fig(context, '${tr.maxHops}', tr.maxHops == 1 ? 'hop, deepest path' : 'hops, deepest path'),
        _fig(context, '${relays.length}', 'relays reached'),
        _fig(context, '${tr.observerCount}', 'observers heard it', hint: '${tr.observationCount} observations'),
        _fig(context, relays.isEmpty ? 'none' : '${tr.relaysIdentified} of ${relays.length}', 'relays identified'),
      ]),
      const SizedBox(height: Gap.m),
      Text('Where it went, hop by hop', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      _map(context),
      Row(children: [
        IconButton.filledTonal(
          key: const Key('trace-play'),
          tooltip: _playing ? 'Pause' : 'Play the flood hop by hop',
          icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
          onPressed: tr.maxDepth == 0 ? null : _play,
        ),
        Expanded(
          child: Semantics(
            label: 'Step $_step of ${tr.maxDepth}',
            child: Slider(
              key: const Key('trace-step'),
              min: 0,
              max: tr.maxDepth.toDouble().clamp(1, 1000),
              divisions: tr.maxDepth > 0 ? tr.maxDepth : null,
              value: _step.clamp(0, tr.maxDepth).toDouble(),
              onChanged: tr.maxDepth == 0
                  ? null
                  : (v) => setState(() {
                        _stop();
                        _step = v.round();
                      }),
            ),
          ),
        ),
        Text('Step $_step of ${tr.maxDepth}', style: t.textTheme.labelMedium),
      ]),
      Text(
        'Press play to watch each hop light up. The final hop into each observer is drawn by signal strength; hops inside the path carry no SNR and are dashed.',
        style: t.textTheme.bodySmall?.copyWith(color: m.textMuted),
      ),
      const SizedBox(height: Gap.l),
      _snr(context),
      const SizedBox(height: Gap.l),
      _tree(context),
      if (tr.ranges.isNotEmpty) ...[const SizedBox(height: Gap.l), _bytes(context)],
    ]);
  }

  Widget _fig(BuildContext context, String value, String label, {String? hint}) {
    final t = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value, style: t.textTheme.titleMedium),
        Text(label, style: t.textTheme.labelMedium),
        if (hint != null) Text(hint, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ]),
    );
  }

  Widget _map(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final m = MeshSonarColors.of(context);
    final tr = widget.trace;
    final byId = tr.byId;
    LatLng? at(TraceNode? n) => n != null && n.located ? LatLng(n.lat!, n.lon!) : null;
    final originNode = tr.root;
    final originLl = at(originNode) ?? (tr.origin.lat != null && tr.origin.lon != null && !(tr.origin.lat == 0 && tr.origin.lon == 0) ? LatLng(tr.origin.lat!, tr.origin.lon!) : null);
    final placed = <LatLng>[
      for (final n in tr.nodes)
        if (!n.isOrigin && n.located) LatLng(n.lat!, n.lon!),
      ?originLl,
    ];
    final unplaced = tr.nodes.where((n) => !n.isOrigin && !n.located).length;
    if (placed.isEmpty) {
      return Container(
        key: const Key('trace-nomap'),
        padding: const EdgeInsets.all(Gap.l),
        decoration: BoxDecoration(color: cs.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.card)),
        child: const Text('None of the hops in this packet has a known position, so there is nothing to draw. The tree below still lists every hop.'),
      );
    }
    final polylines = <Polyline>[];
    for (final e in tr.edges) {
      final a = e.from == (originNode?.id) ? originLl : at(byId[e.from]);
      final b = at(byId[e.to]);
      if (a == null || b == null) continue;
      final lit = e.depth <= _step;
      polylines.add(Polyline(
        points: [a, b],
        strokeWidth: lit ? snrStroke(e.snr) : 1.2,
        color: lit ? (e.depth == _step ? cs.primary : cs.onSurface.withValues(alpha: .75)) : cs.outlineVariant,
        pattern: e.snr == null ? StrokePattern.dashed(segments: const [6, 6]) : const StrokePattern.solid(),
      ));
    }
    final markers = <Marker>[];
    for (final n in tr.nodes) {
      final p = n.isOrigin ? originLl : at(n);
      if (p == null) continue;
      final lit = n.depth <= _step;
      final color = n.isOrigin ? cs.primary : (n.isObserver ? m.snrStrong : cs.onSurface);
      markers.add(Marker(
        point: p,
        width: 26,
        height: 26,
        child: Opacity(
          opacity: lit ? 1 : .3,
          child: Tooltip(
            message: '${n.displayName}${n.isOrigin ? '' : n.isObserver ? ', observer' : ', hop ${n.depth}'}',
            child: Container(
              decoration: BoxDecoration(
                color: color,
                shape: n.isObserver ? BoxShape.rectangle : BoxShape.circle,
                borderRadius: n.isObserver ? BorderRadius.circular(4) : null,
                border: Border.all(color: cs.surface, width: 2),
              ),
              alignment: Alignment.center,
              child: n.isRelay ? Text('${n.depth}', style: TextStyle(color: cs.surface, fontSize: 11, fontWeight: FontWeight.w700)) : null,
            ),
          ),
        ),
      ));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(Corners.card),
      child: Column(children: [
        SizedBox(
          height: 280,
          child: FlutterMap(
            key: const Key('trace-map'),
            options: MapOptions(
              initialCenter: placed.first,
              initialZoom: 10,
              initialCameraFit: placed.length == 1 ? null : CameraFit.coordinates(coordinates: placed, padding: const EdgeInsets.all(32), maxZoom: 14),
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
            ),
            children: [
              if (widget.tiles) TileLayer(urlTemplate: CoverageMap.tileUrl, userAgentPackageName: CoverageMap.userAgentPackageName, maxNativeZoom: 19),
              PolylineLayer(polylines: polylines),
              MarkerLayer(markers: markers),
            ],
          ),
        ),
        if (unplaced > 0 || originLl == null)
          Container(
            width: double.infinity,
            color: cs.surfaceContainerHigh,
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6),
            child: Text(
              [
                if (originLl == null) 'The origin\'s location is not in the packet.',
                if (unplaced > 0) '$unplaced hop${unplaced == 1 ? '' : 's'} with no known position ${unplaced == 1 ? 'is' : 'are'} not drawn.',
              ].join(' '),
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
      ]),
    );
  }

  Widget _snr(BuildContext context) {
    final t = Theme.of(context);
    final tr = widget.trace;
    final rows = [for (final o in tr.observations) if (o.snr != null) o]..sort((a, b) => b.snr!.compareTo(a.snr!));
    if (rows.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Signal at each observer', style: t.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('No signal readings were reported for this packet.', style: t.textTheme.bodyMedium),
      ]);
    }
    final best = rows.first;
    return ChartFrame(
      id: 'trace-snr',
      title: 'Signal at each observer, by hops travelled',
      summary: 'Best ${best.snr} dB at ${best.observer} after ${best.path.length} hops. ${rows.length} observations with a reading.',
      height: 190,
      startWithTable: true,
      caption: 'SNR of the final hop, one row per observation, strongest first.',
      table: ChartTable(
        head: const ['Observer', 'Hops', 'SNR (dB)', 'RSSI (dBm)', 'Heard'],
        rows: [for (final o in rows) [o.observer, '${o.path.length}', '${o.snr}', o.rssi == null ? 'n/a' : '${o.rssi}', clockUtc(o.time)]],
      ),
      chart: const SizedBox(),
    );
  }

  Widget _tree(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final tr = widget.trace;
    final byId = tr.byId;
    // Primary parent = earliest-heard edge at the node's minimum depth (the website's rule); other parents are "also via".
    final primary = <String, TraceEdge>{};
    final extra = <String, List<TraceEdge>>{};
    for (final e in tr.edges) {
      final n = byId[e.to];
      if (n == null) continue;
      final cur = primary[e.to];
      final earlier = cur == null || (e.firstHeard != null && cur.firstHeard != null && e.firstHeard!.isBefore(cur.firstHeard!));
      if (e.depth == n.depth && earlier) {
        if (cur != null) (extra[e.to] ??= []).add(cur);
        primary[e.to] = e;
      } else {
        (extra[e.to] ??= []).add(e);
      }
    }
    final kids = <String, List<String>>{};
    primary.forEach((to, e) => (kids[e.from] ??= []).add(to));
    final root = tr.root;
    if (root == null) return Text('No observations to merge.', style: t.textTheme.bodyMedium);
    final rows = <Widget>[];
    final seen = <String>{};
    void walk(String id, int level) {
      final n = byId[id];
      if (n == null || !seen.add(id)) return;
      final e = primary[id];
      final also = [for (final x in extra[id] ?? const <TraceEdge>[]) byId[x.from]?.displayName].whereType<String>().toList();
      final meta = [
        if (n.isOrigin)
          (tr.origin.kind == 'advert' ? 'Advert origin' : tr.origin.kind == 'sender' ? 'Sender key known' : 'Origin')
        else if (n.isObserver)
          'Observer, after ${n.depth - 1} ${n.depth - 1 == 1 ? 'hop' : 'hops'}'
        else
          'Hop ${n.depth}, ${_confidenceLabel[n.confidence] ?? n.confidence}',
        if (e?.snr != null) '${e!.snr} dB',
        if (n.firstHeard != null) clockUtc(n.firstHeard),
        if (n.kind == 'relay+observer') 'also an observer',
        if (also.isNotEmpty) 'also via ${also.join(', ')}',
      ].join('; ');
      final later = n.depth > _step;
      rows.add(Opacity(
        opacity: later ? .45 : 1,
        child: Padding(
          padding: EdgeInsets.only(left: 14.0 * level.clamp(0, 8), top: 3, bottom: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(n.isOrigin ? Icons.cell_tower : n.isObserver ? Icons.visibility_outlined : Icons.subdirectory_arrow_right, size: 16, color: n.isOrigin ? t.colorScheme.primary : m.textMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  '${n.displayName}${n.pubkey != null && !n.isObserver ? '  ${n.pubkey!.substring(0, 8)}' : (n.prefix != null && n.pubkey == null ? '  ${n.prefix}' : '')}',
                  style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(meta, style: t.textTheme.bodySmall?.copyWith(color: m.textMuted)),
              ]),
            ),
          ]),
        ),
      ));
      final ch = [...(kids[id] ?? const <String>[])]..sort((a, b) => (byId[a]!.isObserver ? 1 : 0) - (byId[b]!.isObserver ? 1 : 0));
      for (final c in ch) {
        walk(c, level + 1);
      }
    }

    walk(root.id, 0);
    return Column(key: const Key('trace-tree'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Propagation tree', style: t.textTheme.titleMedium),
      Text('Each branch is one hop; numbers are hops from the origin. Rows past the current step are dimmed.', style: t.textTheme.bodySmall?.copyWith(color: m.textMuted)),
      const SizedBox(height: Gap.xs),
      ...rows,
    ]);
  }

  Widget _bytes(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final tr = widget.trace;
    final total = tr.ranges.last.end;
    Color of(String g) => switch (g) {
          'header' => cs.onSurface,
          'path' => cs.outline,
          _ => cs.primary,
        };
    return Column(key: const Key('trace-bytes'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('What the $total bytes are', style: t.textTheme.titleMedium),
      Text(
        'As heard by ${tr.bytesFromObserver ?? 'the deepest observer'}${tr.payloadVersion != null ? ', payload version ${tr.payloadVersion}' : ''}.',
        style: t.textTheme.bodySmall?.copyWith(color: MeshSonarColors.of(context).textMuted),
      ),
      const SizedBox(height: Gap.s),
      Semantics(
        label: tr.ranges.map((r) => '${r.label}: ${r.length} bytes').join('; '),
        excludeSemantics: true,
        child: Row(children: [
          for (final r in tr.ranges)
            Expanded(flex: r.length < 1 ? 1 : r.length, child: Container(height: 14, margin: const EdgeInsets.only(right: 1), color: of(r.group))),
        ]),
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 12, children: [
        for (final (g, l) in const [('header', 'Header'), ('path', 'Path'), ('payload', 'Payload')])
          Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 10, height: 10, color: of(g)), const SizedBox(width: 4), Text(l, style: t.textTheme.labelSmall)]),
      ]),
      const SizedBox(height: Gap.s),
      for (final r in tr.ranges)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 8, height: 8, margin: const EdgeInsets.only(top: 5, right: 6), color: of(r.group)),
            Expanded(flex: 4, child: Text(r.label)),
            SizedBox(width: 44, child: Text('${groupInt(r.length)} B', textAlign: TextAlign.end)),
            const SizedBox(width: 8),
            Expanded(
              flex: 5,
              child: Text(r.hex.length > 24 ? '${r.hex.substring(0, 24)}…' : r.hex, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
            ),
          ]),
        ),
    ]);
  }
}
