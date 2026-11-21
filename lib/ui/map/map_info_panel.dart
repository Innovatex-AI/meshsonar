// The map's inspector for a tapped cell, ping or repeater: the transient MapPanel `drive.inspect` (design/map_panel.dart),
// sitting directly above the map's persistent panel. It opens COLLAPSED to its header (what was tapped and what the link
// lines found) so the map stays the focus, and the person opens it for the figures. Fit and Close live in its header.
//
// Driving safety (one of the two automatic moves allowed, see rule 1 in map_panel.dart): while the car moves it is locked
// at its header, and it clears itself [MapInfoPanel.autoClear] after the last touch.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/map_links.dart';
import '../../core/repeater_reach.dart';
import '../design/map_panel.dart';
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

  /// A small marker next to the title (the "Owned by you" chip), shown even while the panel is collapsed.
  final Widget? badge;

  /// While the car moves (driving, not Passenger) the panel stays at its one-line peek: tapping it does not expand, Details-style
  /// content reads "Open when stopped" (Drive plan 4.9, R16, D41).
  final bool locked;

  /// Clears itself this long after the last touch (12 s while driving); null = stays until closed.
  final Duration? autoClear;

  /// False when the panel sits on top of another panel that already clears the tab bar and the home indicator.
  final bool bottomSafe;
  const MapInfoPanel({
    super.key,
    required this.title,
    required this.summary,
    required this.busy,
    required this.body,
    required this.onClose,
    this.onFit,
    this.badge,
    this.locked = false,
    this.autoClear,
    this.bottomSafe = true,
  });

  @override
  State<MapInfoPanel> createState() => _MapInfoPanelState();
}

class _MapInfoPanelState extends State<MapInfoPanel> {
  Timer? _clear;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(MapInfoPanel old) {
    super.didUpdateWidget(old);
    if (old.autoClear != widget.autoClear) _arm();
  }

  void _arm() {
    _clear?.cancel();
    final d = widget.autoClear;
    _clear = d == null ? null : Timer(d, () {
      if (mounted) widget.onClose();
    });
  }

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => _arm(), child: _panel(context));
  }

  Widget _panel(BuildContext context) {
    final t = Theme.of(context);
    final dim = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return MapPanel(
      id: kInspectPanelId,
      title: widget.title,
      badge: widget.badge,
      leading: widget.busy
          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(Icons.share_location_rounded, size: 18, color: MeshSonarColors.of(context).linkLine),
      status: widget.locked
          ? const Text('Open when stopped', key: Key('info-panel-locked'), style: TextStyle(fontWeight: FontWeight.w600))
          : Text(widget.summary, key: const Key('info-panel-summary')),
      action: widget.onFit == null
          ? null
          : IconButton(
              key: const Key('link-fit'),
              tooltip: 'Show all links',
              constraints: const BoxConstraints(minWidth: kMapPanelRow, minHeight: kMapPanelRow),
              icon: const Icon(Icons.fit_screen_rounded, size: 20),
              onPressed: widget.onFit,
            ),
      onClose: widget.onClose,
      initialState: MapPanelState.collapsed,
      locked: widget.locked,
      bottomSafe: widget.bottomSafe,
      headerKey: const Key('info-panel-header'),
      bodyKey: const Key('info-panel-body'),
      closeKey: const Key('link-clear'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The header's one line in full.
          Padding(padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.xs), child: Text(widget.summary, style: dim)),
          Flexible(child: widget.body),
        ],
      ),
    );
  }
}

/// The transient panel id of the map inspector.
const String kInspectPanelId = 'drive.inspect';

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
