// Bottom sheet with everything about one ping: when, where (and how accurately), speed, noise floor, every echo
// (EchoTile), the neighbour exchange, and "Copy as text".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/heard.dart';
import '../core/model.dart';
import '../core/units.dart';
import 'app.dart' show AppScope;
import 'repeater_widgets.dart';
import 'theme.dart';
import 'widgets.dart';

/// Opens the ping detail sheet. [onRepeaterTap] (optional) is called with an echo's repeater id.
Future<void> showPingDetail(
  BuildContext context, {
  required DrivePing ping,
  required RepeaterLookup lookup,
  void Function(String repeaterId)? onRepeaterTap,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) =>
          PingDetailSheet(ping: ping, lookup: lookup, scrollController: scroll, onRepeaterTap: onRepeaterTap),
    ),
  );
}

String _ll(double v) => v.toStringAsFixed(5);

String _result(DrivePing p) {
  if (p.kind == PingKind.rx) return 'Heard a packet';
  if (p.heardNothing) return 'Heard nothing';
  final n = repeatersHeard(p).length;
  return 'Heard $n repeater${n == 1 ? '' : 's'}';
}

/// Plain-text version of a ping (for "Copy as text"). Unmeasured values are left out, never guessed.
String pingAsText(DrivePing p, RepeaterLookup lookup, [Units units = Units.metric]) {
  final b = StringBuffer()
    ..writeln('MeshSonar ping ${formatDateTime(p.ts)} (${formatTime(p.ts)})')
    ..writeln('Result: ${_result(p)}')
    ..writeln('Position: ${_ll(p.lat)}, ${_ll(p.lon)}${p.gpsAccuracyM == null ? '' : ' ±${units.shortLength(p.gpsAccuracyM!)}'}');
  if (p.speedMps != null) b.writeln('Speed: ${units.speed(p.speedMps!)}');
  if (p.noiseFloorDbm != null) b.writeln('Noise floor: ${p.noiseFloorDbm!.round()} dBm');
  for (final e in p.echoes) {
    final m = lookup.resolve(e.repeater);
    final d = m.distanceFrom(p.lat, p.lon);
    final parts = <String>[
      '${m.label} [${e.repeater.toUpperCase()}]',
      if (e.snrDb != null) 'SNR ${formatSnrShort(e.snrDb!)}',
      if (e.rssiDbm != null) 'RSSI ${e.rssiDbm!.round()} dBm',
      ?hopsLabel(e.hops),
      if (e.delayMs != null) '${e.delayMs} ms',
      if (d != null) formatDistanceBearing(units, d, m.bearingFrom(p.lat, p.lon)),
      if (e.path != null && e.path!.length > 1) 'path ${e.path!.map((x) => x.toUpperCase()).join('>')}',
      if (m.ref != null) 'key ${m.ref!.key}',
    ];
    b.writeln('Echo: ${parts.join(', ')}');
  }
  final n = p.neighbor;
  if (n != null) {
    final parts = <String>[
      '${lookup.resolve(n.repeater).label} [${n.repeater.toUpperCase()}]',
      if (n.localSnrDb != null) 'we heard ${formatSnrShort(n.localSnrDb!)}',
      if (n.localRssiDbm != null) 'RSSI ${n.localRssiDbm!.round()} dBm',
      if (n.remoteSnrDb != null) 'it heard us ${formatSnrShort(n.remoteSnrDb!)}',
    ];
    b.writeln('Neighbour: ${parts.join(', ')}');
  }
  b.write('Ping id: ${p.id}');
  return b.toString();
}

class PingDetailSheet extends StatelessWidget {
  final DrivePing ping;
  final RepeaterLookup lookup;
  final ScrollController? scrollController;
  final void Function(String repeaterId)? onRepeaterTap;
  const PingDetailSheet({super.key, required this.ping, required this.lookup, this.scrollController, this.onRepeaterTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final p = ping;
    final units = AppScope.unitsOf(context);
    final snr = bestSnr(p);
    final color = mc.forPing(heard: !p.heardNothing, snr: snr);
    final facts = <(String, String)>[
      ('Position', '${_ll(p.lat)}, ${_ll(p.lon)}'),
      ('GPS accuracy', p.gpsAccuracyM == null ? '—' : '±${units.shortLength(p.gpsAccuracyM!)}'),
      ('Speed', p.speedMps == null ? '—' : units.speed(p.speedMps!)),
      ('Noise floor', p.noiseFloorDbm == null ? '—' : '${p.noiseFloorDbm!.round()} dBm'),
    ];
    return ListView(
      key: const Key('ping-detail'),
      controller: scrollController,
      padding: const EdgeInsets.only(bottom: Gap.xl),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
          child: Row(children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_result(p), style: t.textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(formatDateTime(p.ts).replaceFirst(RegExp(r'\d\d:\d\d$'), formatTime(p.ts)), style: t.textTheme.bodySmall),
              ]),
            ),
            if (snr != null) SnrPill(snr),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
            decoration: BoxDecoration(
              color: t.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(Corners.chip),
            ),
            child: Column(children: [
              for (final (k, v) in facts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(children: [
                    SizedBox(width: 110, child: Text(k, style: t.textTheme.labelMedium)),
                    Expanded(
                      child: Text(v,
                          style: t.textTheme.bodyMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
                    ),
                  ]),
                ),
            ]),
          ),
        ),
        if (p.echoes.isNotEmpty) ...[
          _Heading('Echoes', '${p.echoes.length}'),
          for (final e in p.echoes) ...[
            EchoTile(
              echo: e,
              lookup: lookup,
              fromLat: p.lat,
              fromLon: p.lon,
              onTap: onRepeaterTap == null ? null : () => onRepeaterTap!(e.repeater),
            ),
            if (lookup.resolve(e.repeater).ambiguous) _Candidates(match: lookup.resolve(e.repeater), lat: p.lat, lon: p.lon),
          ],
        ],
        if (p.neighbor != null) ...[
          const _Heading('Neighbour exchange', null),
          _NeighborRow(n: p.neighbor!, lookup: lookup),
        ],
        if (p.heardNothing)
          Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Text(
              'No repeater answered this ping. It still counts: it shows where there is no coverage.',
              style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, 0),
          child: OutlinedButton.icon(
            key: const Key('ping-copy'),
            onPressed: () async {
              final messenger = ScaffoldMessenger.maybeOf(context);
              await Clipboard.setData(ClipboardData(text: pingAsText(p, lookup, AppScope.read(context).units)));
              messenger?.showSnackBar(const SnackBar(content: Text('Ping copied as text.')));
            },
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy as text'),
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  final String? trailing;
  const _Heading(this.text, this.trailing);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.xs),
      child: Row(children: [
        Text(text, style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
        if (trailing != null) ...[
          const SizedBox(width: Gap.s),
          Text(trailing!, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

/// For a short prefix that matches several known repeaters: the nearest few, so the user can judge.
class _Candidates extends StatelessWidget {
  final RepeaterMatch match;
  final double lat, lon;
  const _Candidates({required this.match, required this.lat, required this.lon});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = [for (final r in match.candidates) (r, haversineM(lat, lon, r.lat, r.lon))]..sort((a, b) => a.$2.compareTo(b.$2));
    final shown = c.take(3).map((x) => '${x.$1.name.isEmpty ? x.$1.key.substring(0, 8).toUpperCase() : x.$1.name} (${AppScope.unitsOf(context).distance(x.$2)})');
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.l + 32, 0, Gap.l, Gap.s),
      child: Text(
        'Short id shared by ${match.candidates.length} known repeaters. Nearest: ${shown.join(', ')}',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

class _NeighborRow extends StatelessWidget {
  final Neighbor n;
  final RepeaterLookup lookup;
  const _NeighborRow({required this.n, required this.lookup});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = lookup.resolve(n.repeater);
    final facts = <String>[
      if (n.localSnrDb != null) 'we heard it ${formatSnrShort(n.localSnrDb!)}',
      if (n.remoteSnrDb != null) 'it heard us ${formatSnrShort(n.remoteSnrDb!)}',
      if (n.localRssiDbm != null) 'RSSI ${n.localRssiDbm!.round()} dBm',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
      child: Row(children: [
        Icon(Icons.swap_horiz, size: 20, color: t.colorScheme.onSurfaceVariant),
        const SizedBox(width: Gap.m),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(repeaterTitle(m), maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall)),
              const SizedBox(width: Gap.s),
              RepeaterIdChip(n.repeater),
            ]),
            if (facts.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(facts.join(' · '), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            ],
          ]),
        ),
      ]),
    );
  }
}
