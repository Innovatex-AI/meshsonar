// Regions (flood scopes): the tree, which regions allow flooding, and the default scope. Changes are confirmed, saved and read
// back. "Deny everything" needs a typed phrase. Creating regions is not offered: it is done once, on the repeater itself.
import 'package:flutter/material.dart';

import '../../../radio/repeater_admin.dart';
import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';

class AdminRegionsView extends StatefulWidget {
  final RepeaterAdminController controller;
  const AdminRegionsView({super.key, required this.controller});
  @override
  State<AdminRegionsView> createState() => _AdminRegionsViewState();
}

class _AdminRegionsViewState extends State<AdminRegionsView> {
  RepeaterAdminController get c => widget.controller;
  String? _busy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && c.regions == null) c.loadRegions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final r = c.regions;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: RefreshIndicator(
              onRefresh: c.loadRegions,
              child: ListView(
                key: const Key('admin-regions'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: [
                  if (c.notices['regions'] != null) NoticeBanner(c.notices['regions']!, bannerKey: const Key('regions-notice')),
                  Text(
                      'A region is a named flood scope, such as a city. A repeater only passes on floods for regions it allows. Turning flooding off for a region stops this repeater passing that region\'s floods on.',
                      style: t.textTheme.bodyMedium?.copyWith(height: 1.35)),
                  const SizedBox(height: Gap.m),
                  if (c.loadingRegions && r == null)
                    const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator(key: Key('regions-loading'))))
                  else if (r != null) ...[
                    if (!c.isAdmin) NoticeBanner(const AdminNotice('Without the admin password you can see which regions are allowed, not change them.', error: false)),
                    if (r.truncated && c.isAdmin) NoticeBanner(const AdminNotice('The region list is long, so the repeater could only send names, not the tree.', error: false)),
                    AdminCard(
                      cardKey: const Key('card-default-region'),
                      title: 'Default region',
                      icon: Icons.flag_outlined,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        KeyValueRow('Used for this repeater\'s own adverts', r.defaultScope ?? 'none (unscoped)', valueKey: const Key('v-default-region')),
                        if (r.home != null) KeyValueRow('Home region', r.home!),
                      ]),
                    ),
                    AdminCard(
                      cardKey: const Key('card-region-tree'),
                      title: 'Regions',
                      icon: Icons.account_tree_outlined,
                      child: Column(children: [for (final n in r.nodes) _node(context, r, n)]),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _node(BuildContext context, RepeaterRegions r, RepeaterRegionNode n) {
    final t = Theme.of(context);
    final isDefault = r.defaultScope == n.name;
    final canEdit = c.isAdmin && _busy == null;
    return Padding(
      padding: EdgeInsets.only(left: (n.depth.clamp(0, 4)) * 16.0),
      child: Container(
        key: Key('region-${n.name}'),
        constraints: const BoxConstraints(minHeight: 56),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(n.name == '*' ? '* (everything)' : n.name, style: t.textTheme.titleSmall),
              Text(n.floodAllowed ? 'Flooding allowed' : 'Flooding stopped', style: t.textTheme.bodySmall),
              if (isDefault) Text('Default', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary)),
            ]),
          ),
          if (c.isAdmin && n.name != '*' && !isDefault)
            TextButton(key: Key('default-${n.name}'), style: TextButton.styleFrom(minimumSize: kTarget), onPressed: canEdit ? () => _setDefault(context, n.name) : null, child: const Text('Make default')),
          Semantics(
            label: 'Flooding for ${n.name}',
            child: Switch(key: Key('flood-${n.name}'), value: n.floodAllowed, onChanged: canEdit ? (v) => _flood(context, n, v) : null),
          ),
        ]),
      ),
    );
  }

  Future<void> _show(BuildContext context, AppliedChange r) async {
    final msg = switch (r.outcome) {
      ApplyOutcome.verified => 'Verified: the repeater reports the change.',
      ApplyOutcome.unverified => 'Could not verify. Pull down to read the regions again.',
      ApplyOutcome.notApplied => 'Not applied: the repeater kept its old setting.',
      ApplyOutcome.rejected => 'The repeater refused: ${r.replyText ?? 'error'}',
      ApplyOutcome.mismatch => 'The repeater reports something different. Read the regions again.',
    };
    showSnack(context, msg);
  }

  Future<void> _setDefault(BuildContext context, String name) async {
    final ok = await confirmAction(context,
        title: 'Make $name the default region?',
        body: 'This repeater\'s own flood adverts will carry the $name scope, and the setting is saved at once. Only change this if the other repeaters around you use the same scope.',
        confirmLabel: 'Make default',
        confirmKey: const Key('default-confirm'));
    if (!ok || !context.mounted) return;
    setState(() => _busy = name);
    try {
      final r = await c.setDefaultRegion(name);
      if (context.mounted) await _show(context, r);
    } on AdminException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _flood(BuildContext context, RepeaterRegionNode n, bool allow) async {
    String typed = '';
    if (!allow && n.name == '*') {
      final t = await typedConfirm(context,
          title: 'Stop ALL flooding?',
          body: 'This repeater would stop passing on floods for every region, including un-scoped ones. Nearly everything that reaches the mesh through it stops.',
          phrase: 'DENY ALL',
          confirmLabel: 'Stop flooding');
      if (t == null || !context.mounted) return;
      typed = t;
    } else {
      final ok = await confirmAction(context,
          title: allow ? 'Allow flooding for ${n.name}?' : 'Stop flooding for ${n.name}?',
          body: allow ? 'This repeater will pass on floods for ${n.name} again. The change is saved and read back.' : 'This repeater will stop passing on floods for ${n.name}. The change is saved and read back, and you can turn it back on.',
          confirmLabel: allow ? 'Allow' : 'Stop',
          danger: !allow,
          confirmKey: const Key('flood-confirm'));
      if (!ok || !context.mounted) return;
    }
    setState(() => _busy = n.name);
    try {
      final r = await c.setRegionFlood(n.name, allow: allow, typed: typed);
      if (context.mounted) await _show(context, r);
    } on AdminException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }
}
