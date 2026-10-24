// Tap a network-coverage cell: a bottom sheet with what the network measured there (the website's cell popup).
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/api.dart' show CoverageCell;
import '../../core/network_coverage.dart';
import '../theme.dart';
import 'coverage_map.dart' show networkLevelColor;
import 'map_layers.dart' show formatSnrShort;

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

/// "3 min ago", "5 h ago", "2 d ago", or the date for older; '-' when unparseable.
String lastSeenText(String iso, {DateTime? now}) {
  final t = DateTime.tryParse(iso);
  if (t == null) return '-';
  final d = (now ?? DateTime.now()).toUtc().difference(t.toUtc());
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 48) return '${d.inHours} h ago';
  if (d.inDays < 60) return '${d.inDays} d ago';
  final l = t.toLocal();
  return '${l.year}-${l.month.toString().padLeft(2, '0')}-${l.day.toString().padLeft(2, '0')}';
}

Future<void> showCellSheet(BuildContext context, NetworkCell n) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(child: CellSheet(cell: n)),
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
          Text(
            value,
            style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
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
              Text('Coverage cell', style: t.textTheme.titleLarge),
            ],
          ),
          const SizedBox(height: Gap.s),
          stat('Pings', '${c.pings}'),
          stat(
            'Heard by a repeater',
            c.pings <= 0
                ? '-'
                : '${c.heard} of ${c.pings} (${heardPercent(c)})',
          ),
          stat(
            'Best SNR',
            c.bestSnr == null ? '-' : '${formatSnrShort(c.bestSnr!)} dB',
          ),
          stat(
            'Median SNR',
            c.medianSnr == null ? '-' : '${formatSnrShort(c.medianSnr!)} dB',
          ),
          stat('Repeaters heard', '${c.repeaters}'),
          stat(
            'Noise floor',
            c.noiseFloor == null ? '-' : '${c.noiseFloor!.round()} dBm',
          ),
          stat('Last measured', lastSeenText(c.lastAt)),
        ],
      ),
    );
  }
}
