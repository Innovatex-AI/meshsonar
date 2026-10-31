// The map's info panel for a tapped cell or repeater. It replaces the modal bottom sheet: it opens COLLAPSED to one line
// (what was tapped and what the link lines found) so the map stays the focus, and the person expands it for the figures.
// The link-line controls (Fit, Clear) live in its header.
import 'package:flutter/material.dart';

import '../../core/map_links.dart';
import '../../core/repeater_reach.dart';
import '../theme.dart';
import 'cell_sheet.dart' show lastSeenText;
import 'map_layers.dart' show formatSnrShort;

class MapInfoPanel extends StatefulWidget {
  final String title;

  /// One line under the title: the link result, "Finding links…", or the failure.
  final String summary;
  final bool busy;
  final Widget body;
  final VoidCallback? onFit;
  final VoidCallback onClose;
  const MapInfoPanel({
    super.key,
    required this.title,
    required this.summary,
    required this.busy,
    required this.body,
    required this.onClose,
    this.onFit,
  });

  @override
  State<MapInfoPanel> createState() => _MapInfoPanelState();
}

class _MapInfoPanelState extends State<MapInfoPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final maxBody = (MediaQuery.sizeOf(context).height * 0.42).clamp(160.0, 420.0);
    return Material(
      color: t.colorScheme.surface.withValues(alpha: 0.95),
      elevation: 3,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('info-panel-header'),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.only(left: Gap.m),
              child: Row(
                children: [
                  if (widget.busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Icon(Icons.share_location_rounded, size: 18, color: linkLineColor),
                    ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          Text(
                            widget.summary,
                            key: const Key('info-panel-summary'),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (widget.onFit != null)
                    IconButton(
                      key: const Key('link-fit'),
                      tooltip: 'Show all links',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      icon: const Icon(Icons.fit_screen_rounded, size: 20),
                      onPressed: widget.onFit,
                    ),
                  Icon(_open ? Icons.expand_more_rounded : Icons.expand_less_rounded, size: 22),
                  IconButton(
                    key: const Key('link-clear'),
                    tooltip: 'Close',
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: widget.onClose,
                  ),
                ],
              ),
            ),
          ),
          if (_open)
            ConstrainedBox(
              key: const Key('info-panel-body'),
              constraints: BoxConstraints(maxHeight: maxBody),
              child: widget.body,
            ),
        ],
      ),
    );
  }
}

/// What every driver's public data says about one repeater (repeater-reach totals), as plain rows.
class RepeaterReachStats extends StatelessWidget {
  final ReachTotals? totals;
  final int cells;
  final String Function(double km) distance;
  const RepeaterReachStats({super.key, required this.totals, required this.cells, required this.distance});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final tot = totals;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant))),
          Text(value, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        ],
      ),
    );
    if (tot == null || tot.heardPings == 0) {
      return Padding(
        key: const Key('reach-stats'),
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
        child: Text(
          'No MeshSonar drive has heard this repeater yet.',
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return Padding(
      key: const Key('reach-stats'),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Heard by MeshSonar drivers', style: t.textTheme.titleSmall),
          row('Cells heard in', '$cells'),
          row('Pings heard', '${tot.heardPings}'),
          row('Drives / drivers', '${tot.drives} / ${tot.drivers}'),
          row('Best SNR', tot.bestSnr == null ? '-' : '${formatSnrShort(tot.bestSnr!)} dB'),
          row('Median SNR', tot.medianSnr == null ? '-' : '${formatSnrShort(tot.medianSnr!)} dB'),
          if (tot.farthestKm != null) row('Farthest heard', distance(tot.farthestKm!)),
          if (tot.lastHeardAt != null) row('Last heard', lastSeenText(tot.lastHeardAt!.toIso8601String())),
        ],
      ),
    );
  }
}

/// The repeaters heard in a cell, most pings first, each with its SNR (the text twin of the lines on the map).
class CellRepeaterList extends StatelessWidget {
  final List<LinkEnd> ends;
  const CellRepeaterList({super.key, required this.ends});

  @override
  Widget build(BuildContext context) {
    if (ends.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Padding(
      key: const Key('cell-repeater-list'),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Repeaters heard here', style: t.textTheme.titleSmall),
          for (final e in ends)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(child: Text(e.name ?? e.id, maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Text('${e.pings} ping${e.pings == 1 ? '' : 's'}', style: t.textTheme.bodySmall),
                  const SizedBox(width: Gap.s),
                  SizedBox(
                    width: 64,
                    child: Text(
                      linkSnrLabel(e.snr) ?? '-',
                      textAlign: TextAlign.end,
                      style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The colour of every link line and its start ring: orange, not the SNR scale, so lines stand out from the
/// SNR-coloured cells they cross. The SNR is in each label and in the panel.
const Color linkLineColor = Color(0xFFFF6D00);
