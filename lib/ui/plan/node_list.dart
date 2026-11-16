// The planner's nodes (release 0.38, plan §4.1/§4.3 item 1 and 8): the list of the plan's nodes in the sheet, the node
// editor (name, what it is, height, power, gain, cable loss, mount, move, delete) and the existing-node picker (the
// person's own radios first, then repeaters and rooms from the network near the map, nearest first). Built only from the
// design kit: showAppSheet + AppSheetScaffold, settings_kit SliderTile/InfoTile, state_views, AppSymbols, AppHaptics.
//
// Keys: 'plan-node-list', 'plan-list-node-<id>', 'plan-node-edit-<id>'; editor 'node-editor', 'node-name', 'node-status',
// 'node-role', 'node-mine', 'node-height', 'node-tx', 'node-gain', 'node-cable', 'node-mount', 'node-move', 'node-delete';
// picker 'node-picker', 'node-picker-search', 'node-pick-<key>', 'node-picker-empty'.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/network_repeaters.dart' show NetworkRepeater;
import '../../core/plan/link_model.dart' show haversineKm;
import '../../core/plan/plan_controller.dart';
import '../../core/plan/plan_model.dart';
import '../../core/plan_contract.dart';
import '../../core/repeater_sync.dart' show SyncState;
import '../app.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/sheet_detents.dart' show formSheetDetents;
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../settings/settings_kit.dart' show InfoTile, SliderTile;
import '../nodes/node_ref.dart' show nameHidesPosition;
import 'plan_modes.dart' show PlanLine, PlanListenable, symbolData;

/// The words for a node's status (vocabulary table: "Node", "Estimate", "Measured").
String nodeStatusWords(PlanNodeStatus s) => switch (s) {
      PlanNodeStatus.planned => 'Planned',
      PlanNodeStatus.installed => 'Installed',
      PlanNodeStatus.existing => 'On the network',
    };

AppSymbol nodeSymbol(PlanNode n) => n.mine
    ? AppSymbols.personFill
    : switch (n.status) {
        PlanNodeStatus.planned => AppSymbols.pin,
        PlanNodeStatus.installed => AppSymbols.antenna,
        PlanNodeStatus.existing => AppSymbols.antenna,
      };

/// One line under a node's name: what it is, its antenna height, and whether it is the person's.
String nodeSummary(PlanNode n, BuildContext context) {
  final units = AppScope.unitsOf(context);
  return [
    nodeStatusWords(n.status),
    if (n.role == PlanNodeRole.handheld) 'handheld',
    units.height(n.antennaM),
    if (n.mine) 'mine',
    if (n.approximate) 'position about 1 km',
  ].join(' · ');
}

// ------------------------------------------------------------------------------------------------ the list

class NodeList extends StatelessWidget {
  final PlanController controller;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onEdit;
  final VoidCallback onAdd;
  const NodeList({super.key, required this.controller, required this.selectedId, required this.onSelect, required this.onEdit, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final nodes = controller.nodes;
    return Column(key: const Key('plan-node-list'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Semantics(
          header: true,
          child: Text('Nodes (${nodes.length} of ${Plan.maxNodes})', style: t.textTheme.titleSmall),
        ),
        TextButton.icon(
          key: const Key('plan-node-add'),
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: controller.plan.isFull ? null : onAdd,
          icon: const AppSymbolIcon(AppSymbols.plus, size: 18),
          label: const Text('Add from the network'),
        ),
      ]),
      if (nodes.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: PlanLine(AppSymbols.pin, 'No nodes yet. Long-press the map to drop a planned node.',
              key: const Key('plan-node-list-empty'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ),
      for (final n in nodes)
        ListTile(
          key: Key('plan-list-node-${n.id}'),
          contentPadding: EdgeInsets.zero,
          selected: n.id == selectedId,
          leading: AppSymbolIcon(nodeSymbol(n), color: n.id == selectedId ? t.colorScheme.primary : null),
          title: Text(n.name),
          subtitle: Text(nodeSummary(n, context)),
          onTap: () => onSelect(n.id),
          trailing: IconButton(
            key: Key('plan-node-edit-${n.id}'),
            constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
            tooltip: 'Edit ${n.name}',
            onPressed: () => onEdit(n.id),
            icon: const AppSymbolIcon(AppSymbols.squareAndPencil),
          ),
        ),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ the editor

const List<int> _heightStops = [2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 20, 25, 30, 35, 40, 50, 60, 80, 100];
final List<int> _txStops = [for (var i = 0; i <= 30; i++) i];
final List<int> _gainStops = [for (var i = -3; i <= 12; i++) i];
final List<int> _cableStops = [for (var i = 0; i <= 8; i++) i];

/// Opens the editor for node [id]. [onMove] starts "move on the map" for it; the sheet closes first.
Future<void> showNodeEditor(BuildContext context, PlanController controller, String id, {required ValueChanged<String> onMove}) async {
  final moved = await showAppSheet<bool>(
    context,
    detents: formSheetDetents(context),
    builder: (ctx, scroll) => _NodeEditor(controller: controller, id: id, scroll: scroll),
  );
  if (moved == true && context.mounted) onMove(id);
}

class _NodeEditor extends StatefulWidget {
  final PlanController controller;
  final String id;
  final ScrollController scroll;
  const _NodeEditor({required this.controller, required this.id, required this.scroll});
  @override
  State<_NodeEditor> createState() => _NodeEditorState();
}

class _NodeEditorState extends State<_NodeEditor> {
  late final TextEditingController _name = TextEditingController(text: widget.controller.plan.node(widget.id)?.name ?? '');

  @override
  void dispose() {
    // After the tree is unlocked: the rename notifies the planner, which rebuilds.
    final v = _name.text;
    scheduleMicrotask(() => _commit(v));
    _name.dispose();
    super.dispose();
  }

  void _commitName() => _commit(_name.text);

  void _commit(String text) {
    final v = text.trim();
    final n = widget.controller.plan.node(widget.id);
    if (n != null && v.isNotEmpty && v != n.name) widget.controller.updateNode(widget.id, (x) => x.copyWith(name: v));
  }

  void _edit(PlanNode Function(PlanNode n) f) {
    widget.controller.updateNode(widget.id, f);
    unawaited(AppHaptics.selection());
  }

  @override
  Widget build(BuildContext context) {
    final units = AppScope.unitsOf(context);
    return ListenableBuilder(
      listenable: PlanListenable(widget.controller),
      builder: (context, _) {
        final n = widget.controller.plan.node(widget.id);
        if (n == null) {
          return AppEmptyView(key: const Key('node-editor'), symbol: AppSymbols.trash, title: 'This node is no longer in the plan', actionLabel: 'Close', onAction: () => Navigator.of(context).pop());
        }
        final t = Theme.of(context);
        return AppSheetScaffold(
          key: const Key('node-editor'),
          controller: widget.scroll,
          title: 'Edit node',
          primaryAction: FilledButton.icon(
            key: const Key('node-move'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
            onPressed: () {
              _commitName();
              Navigator.of(context).pop(true);
            },
            icon: const AppSymbolIcon(AppSymbols.location, size: 18),
            label: const Text('Move on the map'),
          ),
          secondaryAction: TextButton.icon(
            key: const Key('node-delete'),
            style: TextButton.styleFrom(foregroundColor: t.colorScheme.error, minimumSize: const Size.fromHeight(Hit.min)),
            onPressed: () {
              final name = n.name;
              final nav = Navigator.of(context);
              showAppToast(context, 'Deleted $name.', actionLabel: 'Undo', onAction: widget.controller.undo);
              widget.controller.deleteNode(n.id);
              unawaited(AppHaptics.light());
              nav.pop(false);
            },
            icon: const AppSymbolIcon(AppSymbols.trash, size: 18),
            label: const Text('Delete from the plan'),
          ),
          children: [
            TextField(
              key: const Key('node-name'),
              controller: _name,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
              onSubmitted: (_) => _commitName(),
            ),
            const SizedBox(height: Gap.m),
            Semantics(header: true, child: Text('What it is', style: t.textTheme.titleSmall)),
            const SizedBox(height: Gap.xs),
            SegmentedButton<PlanNodeStatus>(
              key: const Key('node-status'),
              segments: [for (final s in PlanNodeStatus.values) ButtonSegment(value: s, label: Text(nodeStatusWords(s)))],
              selected: {n.status},
              onSelectionChanged: (v) => _edit((x) => x.copyWith(status: v.first)),
            ),
            const SizedBox(height: Gap.s),
            SegmentedButton<PlanNodeRole>(
              key: const Key('node-role'),
              segments: const [ButtonSegment(value: PlanNodeRole.repeater, label: Text('Repeater')), ButtonSegment(value: PlanNodeRole.handheld, label: Text('Handheld'))],
              selected: {n.role},
              onSelectionChanged: (v) => _edit((x) => x.copyWith(role: v.first)),
            ),
            SwitchListTile(
              key: const Key('node-mine'),
              contentPadding: EdgeInsets.zero,
              secondary: AppSymbolIcon(AppSymbols.person),
              title: const Text('This node is mine'),
              subtitle: const Text('Its position is rounded to about 1 km when you share the plan.'),
              value: n.mine,
              onChanged: n.existingKey != null ? null : (v) => _edit((x) => x.copyWith(mine: v)),
            ),
            if (n.existingKey != null)
              Text('A network node is yours when you have claimed it (Settings > Claimed radios).', style: t.textTheme.bodySmall),
            const SizedBox(height: Gap.s),
            Semantics(header: true, child: Text('Mount', style: t.textTheme.titleSmall)),
            const SizedBox(height: Gap.xs),
            SegmentedButton<String>(
              key: const Key('node-mount'),
              segments: const [
                ButtonSegment(value: '', label: Text('Not set')),
                ButtonSegment(value: 'ground', label: Text('Pole')),
                ButtonSegment(value: 'tree', label: Text('Tree')),
                ButtonSegment(value: 'building', label: Text('Roof')),
              ],
              selected: {n.mount?.wire ?? ''},
              onSelectionChanged: (v) => _edit((x) => v.first.isEmpty ? x.copyWith(clearMount: true) : x.copyWith(mount: PlanMount.tryParse(v.first))),
            ),
            SliderTile(
              key: const ValueKey('node-height'),
              sliderKey: const Key('node-height-slider'),
              icon: symbolData(context, AppSymbols.arrowUpCircleFill),
              title: 'Antenna height',
              caption: n.heightM == null ? 'From the mount and what the node is. Move the slider to set your own.' : 'Above the ground at the node.',
              stops: _heightStops,
              value: n.antennaM.round(),
              label: (v) => units.height(v.toDouble()),
              onChanged: (v) => _edit((x) => x.copyWith(heightM: v.toDouble())),
            ),
            SliderTile(
              key: const ValueKey('node-tx'),
              sliderKey: const Key('node-tx-slider'),
              icon: symbolData(context, AppSymbols.bolt),
              title: 'Transmit power',
              stops: _txStops,
              value: n.effectiveTxDbm.round(),
              label: (v) => '$v dBm',
              onChanged: (v) => _edit((x) => x.copyWith(txDbm: v.toDouble())),
            ),
            SliderTile(
              key: const ValueKey('node-gain'),
              sliderKey: const Key('node-gain-slider'),
              icon: symbolData(context, AppSymbols.antenna),
              title: 'Antenna gain',
              stops: _gainStops,
              value: (n.gainDbi ?? (n.role == PlanNodeRole.handheld ? handheldGainDbi : defaultGainDbi)).round(),
              label: (v) => '$v dBi',
              onChanged: (v) => _edit((x) => x.copyWith(gainDbi: v.toDouble())),
            ),
            SliderTile(
              key: const ValueKey('node-cable'),
              sliderKey: const Key('node-cable-slider'),
              icon: symbolData(context, AppSymbols.minus),
              title: 'Cable loss',
              stops: _cableStops,
              value: (n.cableLossDb ?? 0).round(),
              label: (v) => '$v dB',
              onChanged: (v) => _edit((x) => x.copyWith(cableLossDb: v.toDouble())),
            ),
            InfoTile(
              icon: symbolData(context, AppSymbols.location),
              title: n.approximate ? 'About ${n.lat.toStringAsFixed(2)}, ${n.lon.toStringAsFixed(2)}' : '${n.lat.toStringAsFixed(5)}, ${n.lon.toStringAsFixed(5)}',
              subtitle: n.approximate ? 'Shared to about 1 km. Move it to set the exact spot.' : 'Position',
            ),
            const SizedBox(height: Gap.m),
          ],
        );
      },
    );
  }
}

// ------------------------------------------------------------------------------------------------ the existing-node picker

/// A network node the picker offers.
class PickableNode {
  final String key, name;
  final double lat, lon;
  final bool room, mine;
  final double? km;
  const PickableNode({required this.key, required this.name, required this.lat, required this.lon, this.room = false, this.mine = false, this.km});
}

/// The picker's rows: the person's claimed radios with a known position first, then the region's roster and the network
/// list (one row per key), nearest to [near] first. Rows farther than [maxKm] from [near] are left out of the network part.
List<PickableNode> pickableNodes({
  required Iterable<NetworkRepeater> region,
  required Iterable<NetworkRepeater> global,
  required Set<String> claimed,
  PlanPoint? near,
  double maxKm = 80,
}) {
  final seen = <String>{};
  final out = <PickableNode>[];
  for (final r in [...region, ...global]) {
    final k = r.key.toLowerCase();
    if (!seen.add(k) || !r.lat.isFinite || !r.lon.isFinite || (r.lat == 0 && r.lon == 0)) continue;
    // A node whose owner hides its position (the no-position mark in its name) is never offered for a plan (privacy).
    if (nameHidesPosition(r.name)) continue;
    final km = near == null ? null : haversineKm(near.lat, near.lon, r.lat, r.lon);
    final mine = claimed.contains(k);
    if (!mine && km != null && km > maxKm) continue;
    out.add(PickableNode(key: k, name: r.displayName, lat: r.lat, lon: r.lon, room: r.isRoom, mine: mine, km: km));
  }
  out.sort((a, b) {
    if (a.mine != b.mine) return a.mine ? -1 : 1;
    return (a.km ?? 0).compareTo(b.km ?? 0);
  });
  return out;
}

/// Opens the existing-node picker over the plan. [near] is the map's centre; [onAdded] gets each added node.
Future<void> showNodePicker(BuildContext context, PlanController controller, {PlanPoint? near, required ValueChanged<PlanNode> onAdded}) =>
    showAppSheet<void>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => _NodePicker(controller: controller, near: near, scroll: scroll, onAdded: onAdded),
    );

class _NodePicker extends StatefulWidget {
  final PlanController controller;
  final PlanPoint? near;
  final ScrollController scroll;
  final ValueChanged<PlanNode> onAdded;
  const _NodePicker({required this.controller, required this.near, required this.scroll, required this.onAdded});
  @override
  State<_NodePicker> createState() => _NodePickerState();
}

class _NodePickerState extends State<_NodePicker> {
  String _q = '';

  void _add(PickableNode p) {
    try {
      final n = widget.controller.addNode(
        name: p.name,
        lat: p.lat,
        lon: p.lon,
        status: PlanNodeStatus.existing,
        existingKey: p.key,
        mine: p.mine,
      );
      unawaited(AppHaptics.success());
      widget.onAdded(n);
      setState(() {});
    } on PlanFullException catch (e) {
      showAppToast(context, e.toString(), kind: AppToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final units = AppScope.unitsOf(context);
    final t = Theme.of(context);
    final region = s.regionRepeaterSet, global = s.globalRepeaterSet;
    final claimed = {for (final c in s.claims.claims) if (!c.ended) c.pubkey.toLowerCase()};
    final all = pickableNodes(region: region.rows, global: global.rows, claimed: claimed, near: widget.near);
    final q = _q.trim().toLowerCase();
    final rows = q.isEmpty ? all : all.where((p) => p.name.toLowerCase().contains(q) || p.key.startsWith(q)).toList();
    final inPlan = {for (final n in widget.controller.nodes) ?n.existingKey};
    final loading = all.isEmpty && (region.state == SyncState.loading || global.state == SyncState.loading);
    final failed = all.isEmpty && !loading && (region.state == SyncState.failed || global.state == SyncState.failed);
    return AppSheetScaffold(
      key: const Key('node-picker'),
      controller: widget.scroll,
      title: 'Add from the network',
      children: [
        TextField(
          key: const Key('node-picker-search'),
          decoration: InputDecoration(
            prefixIcon: const AppSymbolIcon(AppSymbols.magnifyingglass, size: 18),
            hintText: 'Search by name or key',
            border: const OutlineInputBorder(),
            suffixText: '${rows.length}',
          ),
          onChanged: (v) => setState(() => _q = v),
        ),
        const SizedBox(height: Gap.s),
        Text('Your radios first, then repeaters and rooms with a public position, nearest to the map first.', style: t.textTheme.bodySmall),
        if (loading) ConstrainedBox(constraints: const BoxConstraints(minHeight: 160), child: AppLoadingView(label: 'Loading the network\'s repeaters…')),
        if (failed)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 200),
            child: AppErrorView(title: 'Could not load the repeaters', message: 'Check your connection and try again.', onRetry: () => unawaited(s.refreshRepeaters())),
          ),
        if (!loading && !failed && rows.isEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 200),
            child: AppEmptyView(
              key: const Key('node-picker-empty'),
              symbol: AppSymbols.antenna,
              title: q.isEmpty ? 'No repeaters near here' : 'Nothing matches "$_q"',
              message: q.isEmpty ? 'Move the map closer to a mesh, or long-press the map to drop a planned node.' : 'Try part of the name or the first characters of the key.',
            ),
          ),
        for (final p in rows.take(200))
          ListTile(
            key: Key('node-pick-${p.key}'),
            contentPadding: EdgeInsets.zero,
            leading: AppSymbolIcon(p.mine ? AppSymbols.personFill : AppSymbols.antenna),
            title: Text(p.name),
            subtitle: Text([
              if (p.mine) 'Claimed',
              p.room ? 'Room' : 'Repeater',
              if (p.km != null) units.distance(p.km! * 1000),
            ].join(' · ')),
            trailing: inPlan.contains(p.key)
                ? const AppSymbolIcon(AppSymbols.checkmarkCircleFill, semanticLabel: 'In the plan')
                : const AppSymbolIcon(AppSymbols.plus, semanticLabel: 'Add'),
            onTap: inPlan.contains(p.key) ? null : () => _add(p),
          ),
      ],
    );
  }
}
