// Tap a network-coverage cell: a bottom sheet with what the network measured there (the website's cell popup).
import '../../core/time_format.dart' as tf;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api.dart' show CoverageCell;
import '../../core/network_coverage.dart';
import '../theme.dart';
import 'coverage_map.dart' show networkLevelColor;
import 'map_layers.dart' show formatSnrShort;
import '../design/app_surfaces.dart';

/// The cell under [p], if any (point-in-polygon over the drawn cells; smallest cell wins when layers overlap).
NetworkCell? networkCellAt(List<NetworkCell> cells, LatLng p) {
  NetworkCell? best;
  var bestArea = double.infinity;
  for (final n in cells) {
    if (n.cell == null || n.boundary.length < 3) continue;
    var inside = false;
    var area = 0.0;
    for (var i = 0, j = n.boundary.length - 1; i < n.boundary.length; j = i++) {
      final a = n.boundary[i], b = n.boundary[j];
      if ((a.lat > p.latitude) != (b.lat > p.latitude) &&
          p.longitude <
              (b.lon - a.lon) * (p.latitude - a.lat) / (b.lat - a.lat) +
                  a.lon) {
        inside = !inside;
      }
      area += a.lon * b.lat - b.lon * a.lat;
    }
    if (inside && area.abs() < bestArea) {
      best = n;
      bestArea = area.abs();
    }
  }
  return best;
}

/// "heard 62%" etc. Null-safe formatting shared by the sheet and its tests.
String heardPercent(CoverageCell c) =>
    c.pings <= 0 ? '-' : '${(100 * c.heard / c.pings).round()}%';

/// "3 min ago", "5 h ago", "2 d ago", or the date for older (the one time formatter, core/time_format.dart); '-' when unparseable.
String lastSeenText(String iso, {DateTime? now}) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '-';
  final d = (now ?? DateTime.now()).toUtc().difference(t.toUtc());
  if (d.inDays < 60) return tf.relativeTime(t, now: now);
  return tf.dateOnly(t);
}

Future<void> showCellSheet(BuildContext context, NetworkCell n) {
  return showAppSheet<void>(
    context,
    detents: const [0.5],
    builder: (context, c) => SafeArea(child: SingleChildScrollView(controller: c, child: CellSheet(cell: n))),
  );
}

class CellSheet extends StatelessWidget {
  final NetworkCell cell;
  const CellSheet({super.key, required this.cell});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = cell.cell!;
    Widget stat(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: t.textTheme.bodyMedium?.copyWith(
                color: t.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          // Flexible with a gap, as the repeater sheet's rows (build 77 AX fix): at the largest text sizes a long value wraps
          // instead of running off the right edge.
          const SizedBox(width: Gap.s),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    return Padding(
      key: const Key('cell-sheet'),
      padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: networkLevelColor(context, cell.level),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: Gap.s),
              Flexible(child: Text('Coverage cell', style: t.textTheme.titleLarge)),
            ],
          ),
          const SizedBox(height: Gap.s),
          stat('Pings', '${c.pings}'),
          stat(
            'Heard by a repeater',
            c.pings <= 0 ? 'No pings yet' : '${c.heard} of ${c.pings} (${heardPercent(c)})',
          ),
          // Build 76: a figure nobody measured is left out (it was a row with a dash), and the two SNR rows say which is which.
          if (c.bestSnr != null) stat('Best signal (SNR)', '${formatSnrShort(c.bestSnr!)} dB'),
          if (c.medianSnr != null) stat('Typical signal (SNR)', '${formatSnrShort(c.medianSnr!)} dB'),
          stat('Repeaters heard', '${c.repeaters}'),
          if (c.noiseFloor != null) stat('Noise floor', '${c.noiseFloor!.round()} dBm'),
          stat('Last measured', lastSeenText(c.lastAt)),
        ],
      ),
    );
  }
}
