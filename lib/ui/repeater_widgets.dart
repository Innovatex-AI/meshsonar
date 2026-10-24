// Reusable, uncluttered repeater widgets for the ping log, the Drive screen and drive details.
//
// Public API (keep stable; other screens use these):
//
//   EchoTile(echo: e, lookup: state.lookup, fromLat: ping.lat, fromLon: ping.lon, onTap: …)
//     One echo of one ping: repeater name (or "Unknown repeater" / "3 possible repeaters"), id chip, SNR pill coloured on the theme's SNR
//     scale, then one muted line: direct / N hops · RSSI · delay · "2.4 km NE" · source badge (MeshSonar / map), and a
//     "via A → B" line for multi-hop echoes when a path was reported. fromLat/fromLon are the ping's position; omit
//     them to hide distance.
//
//   HeardRepeaterTile(h, onTap: …)
//     One repeater from HeardTracker (AppState.heard.repeaters): name, id chip, last/best SNR, times heard, last
//     distance; greyed out when stale.
//
//   RepeaterIdChip('df01')     small monospace chip with the hex id as heard.
//   SnrPill(snr)               "+6.5 dB" pill coloured by SNR (or "—").
//   SourceBadge(source)        "MeshSonar" / "map" badge (nothing for unknown).
//   formatDistanceBearing(units, m, deg) → "2.4 km NE";  hopsLabel(hops) → "direct" / "2 hops" / null.
import 'package:flutter/material.dart';

import '../core/heard.dart';
import '../core/model.dart';
import 'app.dart' show AppScope;
import '../core/units.dart';
import 'theme.dart';

/// "direct" for 1 hop, "N hops" otherwise, null when unknown.
String? hopsLabel(int? hops) => hops == null ? null : (hops <= 1 ? 'direct' : '$hops hops');

/// "2.4 km NE" / "1.5 mi NE" (bearing optional).
String formatDistanceBearing(Units u, double m, [double? bearing]) =>
    bearing == null ? u.distance(m) : '${u.distance(m)} ${compass(bearing)}';

/// "+6.5 dB" / "-3.0 dB".
String formatSnrShort(double snr) => '${snr > 0 ? '+' : ''}${snr.toStringAsFixed(1)} dB';

/// Title for a repeater next to its id chip: its name, "2 possible repeaters" for an ambiguous short id, else
/// "Unknown repeater" (the chip already shows the hex id).
String repeaterTitle(RepeaterMatch m) {
  if (m.ref?.name.isNotEmpty == true) return m.ref!.name;
  if (m.ref != null) return 'Unnamed repeater';
  if (m.ambiguous) return '${m.candidates.length} possible repeaters';
  return 'Unknown repeater';
}

/// Short display name for chips: name when known, else the hex id upper-cased.
String shortRepeaterLabel(RepeaterMatch m) => m.ref?.name.isNotEmpty == true ? m.ref!.name : m.id.toUpperCase();

class RepeaterIdChip extends StatelessWidget {
  final String id;
  final bool muted;
  const RepeaterIdChip(this.id, {super.key, this.muted = false});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        id.toUpperCase(),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
          color: muted ? c.onSurfaceVariant : c.onSurface,
        ),
      ),
    );
  }
}

class SnrPill extends StatelessWidget {
  final double? snr;
  final bool muted;
  const SnrPill(this.snr, {super.key, this.muted = false});
  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    final c = Theme.of(context).colorScheme;
    final col = muted ? c.onSurfaceVariant : mc.forPing(heard: true, snr: snr);
    return Container(
      constraints: const BoxConstraints(minWidth: 64),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: col.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(Corners.small),
        border: Border.all(color: col.withValues(alpha: 0.6)),
      ),
      child: Text(
        snr == null ? 'SNR —' : formatSnrShort(snr!),
        textAlign: TextAlign.center,
        style: numberStyle(context, size: 16, color: col, weight: FontWeight.w700),
      ),
    );
  }
}

class SourceBadge extends StatelessWidget {
  final RepeaterSource source;
  const SourceBadge(this.source, {super.key});
  @override
  Widget build(BuildContext context) {
    if (source == RepeaterSource.none) return const SizedBox.shrink();
    final c = Theme.of(context).colorScheme;
    final label = source == RepeaterSource.cmat ? 'MeshSonar' : 'map';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.outline),
      ),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c.onSurfaceVariant)),
    );
  }
}

/// One echo of one ping.
class EchoTile extends StatelessWidget {
  final Echo echo;
  final RepeaterLookup lookup;

  /// Where the ping was sent from (for distance/bearing to the repeater).
  final double? fromLat;
  final double? fromLon;
  final VoidCallback? onTap;
  const EchoTile({super.key, required this.echo, required this.lookup, this.fromLat, this.fromLon, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final m = lookup.resolve(echo.repeater);
    double? dist, brg;
    if (fromLat != null && fromLon != null) {
      dist = m.distanceFrom(fromLat!, fromLon!);
      brg = m.bearingFrom(fromLat!, fromLon!);
    }
    final facts = <String>[
      ?hopsLabel(echo.hops),
      if (echo.rssiDbm != null) 'RSSI ${echo.rssiDbm!.round()} dBm',
      if (echo.delayMs != null) '${echo.delayMs} ms',
      if (dist != null) formatDistanceBearing(AppScope.unitsOf(context), dist, brg),
    ];
    final path = echo.path;
    final showPath = path != null && path.length > 1;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return InkWell(
      key: ValueKey('echo-${echo.repeater}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s + 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(Icons.cell_tower, size: 20, color: m.known ? mc.beacon : t.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Flexible(
                      child: Text(
                        repeaterTitle(m),
                        key: ValueKey('echo-name-${echo.repeater}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.textTheme.titleSmall?.copyWith(
                          fontStyle: m.known ? FontStyle.normal : FontStyle.italic,
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.s),
                    RepeaterIdChip(echo.repeater),
                  ]),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: Gap.s,
                    runSpacing: 2,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (facts.isNotEmpty) Text(facts.join(' · '), key: ValueKey('echo-facts-${echo.repeater}'), style: muted),
                      SourceBadge(m.source),
                    ],
                  ),
                  if (showPath) ...[
                    const SizedBox(height: 2),
                    Text(
                      'via ${path.map((p) => shortRepeaterLabel(lookup.resolve(p))).join(' → ')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: Gap.s),
            SnrPill(echo.snrDb),
          ],
        ),
      ),
    );
  }
}

/// One repeater in the "heard" list (current drive or a saved drive).
class HeardRepeaterTile extends StatelessWidget {
  final HeardRepeater h;
  final VoidCallback? onTap;
  const HeardRepeaterTile(this.h, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mc = MeshSonarColors.of(context);
    final stale = h.state == HeardState.stale;
    final m = h.match;
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final facts = <String>[
      if (h.bestSnrDb != null) 'best ${formatSnrShort(h.bestSnrDb!)}',
      '${h.timesHeard}× heard',
      if (h.lastDistanceM != null) AppScope.unitsOf(context).distance(h.lastDistanceM!),
      ?hopsLabel(h.lastHops),
    ];
    return Opacity(
      opacity: stale ? 0.55 : 1,
      child: InkWell(
        key: ValueKey('heard-${h.id}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s + 2),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (stale ? t.colorScheme.onSurfaceVariant : mc.beacon).withValues(alpha: 0.16),
                ),
                child: Icon(Icons.cell_tower, size: 19, color: stale ? t.colorScheme.onSurfaceVariant : mc.beacon),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Flexible(
                        child: Text(repeaterTitle(m),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.titleSmall?.copyWith(
                              fontStyle: m.known ? FontStyle.normal : FontStyle.italic,
                            )),
                      ),
                      const SizedBox(width: Gap.s),
                      RepeaterIdChip(h.id, muted: stale),
                    ]),
                    const SizedBox(height: 3),
                    Text(
                      facts.join(' · ') + (stale ? ' · not heard lately' : ''),
                      key: ValueKey('heard-facts-${h.id}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: muted,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Gap.s),
              SnrPill(h.lastSnrDb, muted: stale),
            ],
          ),
        ),
      ),
    );
  }
}
