// The sheet a plan node or target opens on a map that has no planner of its own (the Drive map, plan §4.5 J4): what it is,
// how far, Navigate (Apple Maps directions, as the Where-to-drive card does) and Remove from map (clears the overlay).
//
// Keys: 'plan-node-sheet', 'plan-node-sheet-name', 'plan-node-sheet-kind', 'plan-node-sheet-distance',
// 'plan-node-sheet-navigate', 'plan-node-sheet-remove'.
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/drive_next.dart' show appleMapsDirections;
import '../../../core/heard.dart' show haversineM;
import '../../app.dart' show AppScope;
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../theme.dart';
import 'plan_overlay.dart';

Future<void> showPlanNodeSheet(
  BuildContext context,
  PlanOverlayNode node, {
  LatLng? here,
  VoidCallback? onRemove,
  Future<bool> Function(Uri url)? openUrl,
}) {
  final open = openUrl ?? AppScope.maybeOf(context)?.services.openUrl;
  return showAppSheet<void>(
    context,
    detents: const [0.42, 0.7],
    builder: (sheetContext, c) => SafeArea(
      child: PlanNodeSheet(node: node, here: here, scrollController: c, onRemove: onRemove, openUrl: open),
    ),
  );
}

class PlanNodeSheet extends StatelessWidget {
  final PlanOverlayNode node;
  final LatLng? here;
  final ScrollController? scrollController;
  final VoidCallback? onRemove;
  final Future<bool> Function(Uri url)? openUrl;
  const PlanNodeSheet({super.key, required this.node, this.here, this.scrollController, this.onRemove, this.openUrl});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final h = here;
    final distance = h == null ? null : haversineM(h.latitude, h.longitude, node.at.latitude, node.at.longitude);
    return SingleChildScrollView(
      controller: scrollController,
      child: Padding(
        key: const Key('plan-node-sheet'),
        padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppSymbolIcon(node.kind == PlanOverlayNodeKind.target ? AppSymbols.flag : AppSymbols.antenna, color: t.colorScheme.primary),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(node.name, key: const Key('plan-node-sheet-name'), style: t.textTheme.titleLarge, overflow: TextOverflow.ellipsis, maxLines: 2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(node.kindLabel, key: const Key('plan-node-sheet-kind'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.s),
            Text(
              distance == null ? 'Distance from you: no position fix' : 'Distance from you: ${units.distance(distance, approx: true)}',
              key: const Key('plan-node-sheet-distance'),
              style: t.textTheme.bodyLarge,
            ),
            const SizedBox(height: Gap.m),
            if (openUrl != null)
              FilledButton.icon(
                key: const Key('plan-node-sheet-navigate'),
                icon: const AppSymbolIcon(AppSymbols.route, size: 18),
                label: const Text('Navigate'),
                onPressed: () async {
                  final ok = await openUrl!(appleMapsDirections(node.at.latitude, node.at.longitude, label: 'MeshSonar: ${node.name}'));
                  if (!ok && context.mounted) showAppToast(context, 'Could not open Maps.', kind: AppToastKind.error);
                },
              ),
            if (onRemove != null) ...[
              const SizedBox(height: Gap.s),
              OutlinedButton.icon(
                key: const Key('plan-node-sheet-remove'),
                icon: const AppSymbolIcon(AppSymbols.xmark, size: 18),
                label: const Text('Remove plan from map'),
                onPressed: () {
                  onRemove!();
                  Navigator.of(context).maybePop();
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
