// The saved-plans sheet (release 0.38 A11, moved here from planner_screen.dart): every plan on this phone, most recent
// first, with Open, Rename, Duplicate and Delete, plus Import (a pasted link, code or contacts list; plan_share.dart). The
// plan open in the planner is changed through its PlanController (so the autosave never writes an old name back) and is
// never deleted from under it. Loading, empty and error states from the kit; plans live in SavedPlans (core).
import 'package:flutter/material.dart';

import '../../core/plan/plan_controller.dart';
import '../../core/plan/plan_model.dart';
import '../../core/plan/saved_plans.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/sheet_detents.dart' show formSheetDetents;
import '../design/state_views.dart';
import '../design/tokens.dart';

/// What the person picked in the sheet: a plan to open, or Import.
class SavedPlansChoice {
  final String? openId;
  final bool import;
  const SavedPlansChoice.open(String this.openId) : import = false;
  const SavedPlansChoice.import() : openId = null, import = true;
}

Future<SavedPlansChoice?> showSavedPlans(BuildContext context, {required SavedPlans saved, PlanController? current}) =>
    showAppSheet<SavedPlansChoice>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => SavedPlansSheet(saved: saved, current: current, scroll: scroll),
    );

/// Asks for a plan name; null when the person cancels or leaves it empty.
Future<String?> promptPlanName(BuildContext context, {required String initial, String title = 'Rename the plan', String action = 'Save'}) async {
  final name = await showAppSheet<String>(
    context,
    detents: formSheetDetents(context),
    builder: (ctx, scroll) => _PlanNameSheet(initial: initial, title: title, action: action, scroll: scroll),
  );
  final t = name?.trim();
  return t == null || t.isEmpty ? null : t;
}

/// Owns its text controller, so it lives as long as the sheet (also while it animates away).
class _PlanNameSheet extends StatefulWidget {
  final String initial, title, action;
  final ScrollController scroll;
  const _PlanNameSheet({required this.initial, required this.title, required this.action, required this.scroll});
  @override
  State<_PlanNameSheet> createState() => _PlanNameSheetState();
}

class _PlanNameSheetState extends State<_PlanNameSheet> {
  late final TextEditingController _field = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppSheetScaffold(
        controller: widget.scroll,
        title: widget.title,
        primaryAction: FilledButton(
          key: const Key('saved-plan-name-save'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
          // Off while the name is empty (build 76): an empty name used to be accepted.
          onPressed: _field.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_field.text),
          child: Text(widget.action),
        ),
        children: [
          TextField(
            key: const Key('saved-plan-name-field'),
            controller: _field,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Plan name',
              border: const OutlineInputBorder(),
              suffixIcon: _field.text.isEmpty
                  ? null
                  : IconButton(
                      key: const Key('saved-plan-name-clear'),
                      tooltip: 'Clear the name',
                      constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
                      onPressed: () => setState(_field.clear),
                      icon: const AppSymbolIcon(AppSymbols.xmarkCircleFill, size: 18),
                    ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) Navigator.of(context).pop(v);
            },
          ),
        ],
      );
}

/// A copy of [p] under a new id, named [name], created now.
Plan duplicatePlan(Plan p, {required String name, required DateTime now}) => Plan(
      id: newPlanId(now: now),
      name: name,
      region: p.region,
      radio: p.radio,
      clutter: p.clutter,
      goal: p.goal,
      receiverM: p.receiverM,
      nodes: p.nodes,
      createdAt: now.toUtc(),
    );

class SavedPlansSheet extends StatefulWidget {
  final SavedPlans saved;
  final PlanController? current;
  final ScrollController scroll;
  const SavedPlansSheet({super.key, required this.saved, this.current, required this.scroll});
  @override
  State<SavedPlansSheet> createState() => _SavedPlansSheetState();
}

class _SavedPlansSheetState extends State<SavedPlansSheet> {
  late Future<List<SavedPlanSummary>> _list = _read();

  /// The filter box (shown from six plans up).
  final TextEditingController _find = TextEditingController();

  @override
  void dispose() {
    _find.dispose();
    super.dispose();
  }

  String? get _currentId => widget.current?.plan.id;

  Future<List<SavedPlanSummary>> _read() async {
    final c = widget.current;
    // The list shows the open plan as it is now.
    if (c != null && c.dirty) await c.save();
    final l = await widget.saved.list();
    l.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return l;
  }

  List<SavedPlanSummary> _shown(List<SavedPlanSummary> all) {
    final q = _find.text.trim().toLowerCase();
    return q.isEmpty || all.length < 6 ? all : [for (final p in all) if (p.name.toLowerCase().contains(q)) p];
  }

  void _refresh() {
    final next = _read();
    setState(() {
      _list = next;
    });
  }

  Future<void> _more(SavedPlanSummary p) async {
    final isCurrent = p.id == _currentId;
    final pick = await showAppActionSheet<String>(
      context,
      title: p.name,
      sheetKey: Key('saved-plan-menu-${p.id}'),
      actions: [
        if (!isCurrent) AppAction('Open', 'open', symbol: AppSymbols.map, isDefault: true, key: Key('saved-plan-open-${p.id}')),
        AppAction('Rename', 'rename', symbol: AppSymbols.squareAndPencil, key: Key('saved-plan-rename-${p.id}')),
        AppAction('Duplicate', 'duplicate', symbol: AppSymbols.docOnDoc, key: Key('saved-plan-duplicate-${p.id}')),
        if (!isCurrent) AppAction('Delete', 'delete', symbol: AppSymbols.trash, destructive: true, key: Key('saved-plan-delete-${p.id}')),
      ],
    );
    if (!mounted) return;
    switch (pick) {
      case 'open':
        Navigator.of(context).pop(SavedPlansChoice.open(p.id));
      case 'rename':
        await _rename(p);
      case 'duplicate':
        await _duplicate(p);
      case 'delete':
        await _delete(p);
    }
  }

  Future<void> _rename(SavedPlanSummary p) async {
    final name = await promptPlanName(context, initial: p.name);
    if (name == null || name == p.name || !mounted) return;
    try {
      final c = widget.current;
      if (c != null && p.id == c.plan.id) {
        c.rename(name);
        await c.save();
      } else {
        final plan = await widget.saved.load(p.id);
        if (plan == null) throw StateError('gone');
        await widget.saved.save(plan.copyWith(name: name));
      }
      if (mounted) showAppToast(context, 'Renamed to "$name".', kind: AppToastKind.success);
    } catch (_) {
      if (mounted) showAppToast(context, 'That plan could not be renamed. It may no longer be on this phone.', kind: AppToastKind.error);
    }
    if (mounted) _refresh();
  }

  Future<void> _duplicate(SavedPlanSummary p) async {
    try {
      final c = widget.current;
      final plan = c != null && p.id == c.plan.id ? c.plan : await widget.saved.load(p.id);
      if (plan == null) throw StateError('gone');
      final copy = await widget.saved.save(duplicatePlan(plan, name: 'Copy of ${plan.name}', now: widget.saved.clock()));
      if (mounted) showAppToast(context, 'Saved a copy: "${copy.name}".', kind: AppToastKind.success);
    } catch (_) {
      if (mounted) showAppToast(context, 'That plan could not be copied. Try again.', kind: AppToastKind.error);
    }
    if (mounted) _refresh();
  }

  Future<void> _delete(SavedPlanSummary p) async {
    final ok = await showAppConfirm(
      context,
      title: 'Delete "${p.name}"?',
      message: 'Removed from this phone. Links you already shared keep working.',
      confirmLabel: 'Delete plan',
      destructive: true,
      confirmKey: Key('saved-plan-delete-confirm-${p.id}'),
    );
    if (!ok) return;
    try {
      await widget.saved.delete(p.id);
    } catch (_) {
      if (mounted) showAppToast(context, 'That plan could not be deleted. Try again.', kind: AppToastKind.error);
    }
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return FutureBuilder<List<SavedPlanSummary>>(
      future: _list,
      builder: (context, snap) => AppSheetScaffold(
        key: const Key('saved-plans'),
        controller: widget.scroll,
        title: 'Saved plans',
        children: [
          ListTile(
            key: const Key('saved-plans-import'),
            contentPadding: EdgeInsets.zero,
            minTileHeight: Hit.min + 8,
            leading: const AppSymbolIcon(AppSymbols.squareAndArrowDown),
            title: const Text('Import a plan or contacts'),
            subtitle: const Text('Paste a link, a code or a contacts list'),
            onTap: () => Navigator.of(context).pop(const SavedPlansChoice.import()),
          ),
          const SizedBox(height: Gap.s),
          if (snap.connectionState != ConnectionState.done)
            ConstrainedBox(constraints: const BoxConstraints(minHeight: 160), child: const AppLoadingView(label: 'Reading your plans…')),
          if (snap.connectionState == ConnectionState.done && snap.hasError)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 200),
              child: AppErrorView(key: const Key('saved-plans-error'), title: 'Could not read your plans', message: 'They are still on this phone. Try again.', onRetry: _refresh),
            ),
          if (snap.hasData && snap.data!.isEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 200),
              // Build 76: the empty state has the button that gets a plan in here.
              child: AppEmptyView(
                key: const Key('saved-plans-empty'),
                symbol: AppSymbols.tray,
                title: 'No saved plans yet',
                message: 'A plan is saved here by itself as soon as you add to it.',
                actionLabel: 'Import a plan',
                onAction: () => Navigator.of(context).pop(const SavedPlansChoice.import()),
              ),
            ),
          // A filter box once the list is long enough to need one.
          if (snap.hasData && snap.data!.length >= 6)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.s),
              child: TextField(
                key: const Key('saved-plans-find'),
                controller: _find,
                autocorrect: false,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  prefixIcon: const AppSymbolIcon(AppSymbols.magnifyingglass, size: 18),
                  hintText: 'Find a plan',
                  border: const OutlineInputBorder(),
                  suffixIcon: _find.text.isEmpty
                      ? null
                      : IconButton(
                          key: const Key('saved-plans-find-clear'),
                          tooltip: 'Clear',
                          constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
                          onPressed: () => setState(_find.clear),
                          icon: const AppSymbolIcon(AppSymbols.xmarkCircleFill, size: 18),
                        ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          if (snap.hasData && snap.data!.isNotEmpty && _shown(snap.data!).isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.m),
              child: Text('No plan is called "${_find.text.trim()}".', key: const Key('saved-plans-no-match'), style: t.textTheme.bodyMedium),
            ),
          if (snap.hasData)
            for (final p in _shown(snap.data!))
              ListTile(
                key: Key('saved-plan-${p.id}'),
                contentPadding: EdgeInsets.zero,
                minTileHeight: Hit.min + 8,
                leading: AppSymbolIcon(p.id == _currentId ? AppSymbols.checkmarkCircleFill : AppSymbols.map, color: p.id == _currentId ? t.colorScheme.primary : null),
                title: Text(p.name),
                subtitle: Text('${p.nodeCount} ${p.nodeCount == 1 ? 'node' : 'nodes'} · saved ${savedWhen(p.updatedAt, widget.saved.clock())}${p.id == _currentId ? ' · open now' : ''}'),
                onTap: () => Navigator.of(context).pop(SavedPlansChoice.open(p.id)),
                trailing: IconButton(
                  key: Key('saved-plan-more-${p.id}'),
                  tooltip: 'More for ${p.name}',
                  constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
                  onPressed: () => _more(p),
                  icon: const AppSymbolIcon(AppSymbols.ellipsisCircle),
                ),
              ),
          const SizedBox(height: Gap.l),
        ],
      ),
    );
  }
}

String _two(int v) => v.toString().padLeft(2, '0');
/// "today 14:05", "yesterday 09:12" or "2026-11-20" (build 76: the full date and time on every row was hard to scan).
String savedWhen(DateTime t, DateTime now) {
  final l = t.toLocal(), n = now.toLocal();
  final days = DateTime(n.year, n.month, n.day).difference(DateTime(l.year, l.month, l.day)).inDays;
  final hm = '${_two(l.hour)}:${_two(l.minute)}';
  if (days == 0) return 'today $hm';
  if (days == 1) return 'yesterday $hm';
  return '${l.year}-${_two(l.month)}-${_two(l.day)}';
}
