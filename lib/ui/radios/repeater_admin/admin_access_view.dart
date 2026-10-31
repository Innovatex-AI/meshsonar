// Access: who may log in to this repeater (the access list, admin only), and the guest and admin passwords. Passwords are set
// with masked entry and a typed confirmation, are never shown again, and are never logged.
import 'package:flutter/material.dart';

import '../../../radio/repeater_admin.dart';
import '../../../radio/repeater_settings.dart';
import '../../../radio/repeater_wire.dart';
import '../../theme.dart';
import 'admin_common.dart';
import 'admin_controller.dart';
import 'setting_editor_sheet.dart';

class AdminAccessView extends StatefulWidget {
  final RepeaterAdminController controller;
  const AdminAccessView({super.key, required this.controller});
  @override
  State<AdminAccessView> createState() => _AdminAccessViewState();
}

class _AdminAccessViewState extends State<AdminAccessView> {
  RepeaterAdminController get c => widget.controller;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && c.acl == null) c.loadAcl();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        if (!c.isAdmin) {
          return const Padding(
            padding: EdgeInsets.all(Gap.xl),
            child: Center(child: Text('The access list and passwords need the admin password.', key: Key('access-guest'), textAlign: TextAlign.center)),
          );
        }
        final acl = c.acl;
        final me = c.session.selfKey?.toLowerCase();
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: RefreshIndicator(
              onRefresh: c.loadAcl,
              child: ListView(
                key: const Key('admin-access'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
                children: [
                  if (c.notices['access'] != null) NoticeBanner(c.notices['access']!, bannerKey: const Key('access-notice')),
                  AdminCard(
                    cardKey: const Key('card-acl'),
                    title: 'Who is on the access list',
                    icon: Icons.group_outlined,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                          'Radios that logged in as admin stay on this list. Changing the admin password does not remove them. To take someone\'s access away, remove them here.',
                          key: const Key('acl-warning'), style: t.textTheme.bodyMedium?.copyWith(height: 1.35)),
                      const SizedBox(height: Gap.s),
                      if (c.loadingAcl && acl == null)
                        const Center(child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator(key: Key('acl-loading'))))
                      else if (acl != null && acl.isEmpty)
                        const Text('Nobody is on the list.', key: Key('acl-empty'))
                      else if (acl != null)
                        for (final e in acl) _entry(context, e, me),
                    ]),
                  ),
                  AdminCard(
                    cardKey: const Key('card-passwords'),
                    title: 'Passwords',
                    icon: Icons.key_outlined,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Passwords are typed twice, never shown again and never written to any log.', style: t.textTheme.bodyMedium),
                      const SizedBox(height: Gap.xs),
                      ListTile(
                        key: const Key('set-guest-password'),
                        contentPadding: EdgeInsets.zero,
                        minVerticalPadding: Gap.s,
                        title: Text(c.isRoom ? 'Room password' : 'Guest password'),
                        subtitle: Text(c.isRoom ? 'Lets people read and post in this room.' : 'Lets someone read status and telemetry without being an admin.'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showSettingEditor(context, c, settingFor('guest.password')!),
                      ),
                      ListTile(
                        key: const Key('set-admin-password'),
                        contentPadding: EdgeInsets.zero,
                        minVerticalPadding: Gap.s,
                        title: const Text('Admin password'),
                        subtitle: const Text('If you lose the new one the only way back is a cable at the repeater.'),
                        trailing: Icon(Icons.dangerous_outlined, color: t.colorScheme.error),
                        onTap: () => showSettingEditor(context, c, settingFor('password')!),
                      ),
                      ListTile(
                        key: const Key('test-password'),
                        contentPadding: EdgeInsets.zero,
                        minVerticalPadding: Gap.s,
                        leading: const Icon(Icons.verified_outlined),
                        title: const Text('Test a password'),
                        subtitle: const Text('Logs in again with it. The only sure proof a changed password works.'),
                        onTap: () => _test(context),
                      ),
                      if (c.isRoom)
                        ListTile(
                          key: const Key('set-read-only'),
                          contentPadding: EdgeInsets.zero,
                          minVerticalPadding: Gap.s,
                          title: const Text('Let anyone read without a password'),
                          subtitle: Text('Now: ${settingFor('allow.read.only')!.display(c.settings['allow.read.only']?.value)}'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => showSettingEditor(context, c, settingFor('allow.read.only')!),
                        ),
                    ]),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _entry(BuildContext context, AclEntry e, String? me) {
    final t = Theme.of(context);
    final mine = me != null && me.startsWith(e.prefixHex);
    final name = c.nameFor(e.prefixHex);
    final full = c.fullKeyForPrefix?.call(e.prefixHex);
    return Semantics(
      container: true,
      label: '${name ?? 'Unknown radio'}, ${e.role.label}${mine ? ', this is your radio' : ''}',
      child: Container(
        key: Key('acl-${e.prefixHex}'),
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(mine ? 'Your radio' : (name ?? 'Unknown radio'), style: t.textTheme.titleSmall),
              Text('${e.role.label}  -  key starts ${e.prefixHex.substring(0, 8)}', style: t.textTheme.bodySmall),
            ]),
          ),
          if (!mine && full != null)
            IconButton(
              key: Key('role-${e.prefixHex}'),
              tooltip: 'Change role',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.manage_accounts_outlined),
              onPressed: _busy ? null : () => _role(context, e, full),
            ),
          if (!mine)
            IconButton(
              key: Key('remove-${e.prefixHex}'),
              tooltip: 'Remove from the list',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: Icon(Icons.person_remove_outlined, color: t.colorScheme.error),
              onPressed: _busy ? null : () => _remove(context, e, name),
            ),
        ]),
      ),
    );
  }

  Future<void> _remove(BuildContext context, AclEntry e, String? name) async {
    final ok = await confirmAction(context,
        title: 'Remove ${name ?? 'this radio'}?',
        body: 'It can no longer log in as ${e.role.label.toLowerCase()} without the password. The list is read back afterwards. You can add it again by giving it the password.',
        confirmLabel: 'Remove',
        danger: true,
        confirmKey: const Key('remove-confirm'));
    if (!ok || !context.mounted) return;
    await _run(context, () => c.removeAcl(e.prefixHex));
  }

  Future<void> _role(BuildContext context, AclEntry e, String full) async {
    final role = await showDialog<AclRole>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Change role'),
        children: [
          for (final r in [AclRole.readOnly, AclRole.readWrite, AclRole.admin])
            SimpleDialogOption(key: Key('pick-${r.name}'), onPressed: () => Navigator.of(ctx).pop(r), child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(r.label))),
        ],
      ),
    );
    if (role == null || !context.mounted) return;
    var typed = '';
    if (role == AclRole.admin) {
      final t = await typedConfirm(context,
          title: 'Make this radio an admin?',
          body: 'An admin can change every setting and password of this repeater, and remove you. Only do this for someone you trust with it.',
          phrase: 'GRANT ADMIN',
          confirmLabel: 'Grant admin');
      if (t == null || !context.mounted) return;
      typed = t;
    } else {
      final ok = await confirmAction(context,
          title: 'Change to ${role.label}?', body: 'The list is read back afterwards to check it.', confirmLabel: 'Change', confirmKey: const Key('role-confirm'));
      if (!ok || !context.mounted) return;
    }
    await _run(context, () => c.setAclRole(full, role, typed: typed));
  }

  Future<void> _run(BuildContext context, Future<AppliedChange> Function() f) async {
    setState(() => _busy = true);
    try {
      final r = await f();
      if (!context.mounted) return;
      showSnack(
          context,
          switch (r.outcome) {
            ApplyOutcome.verified => 'Verified: the list shows the change.',
            ApplyOutcome.unverified => 'Could not verify. Pull down to read the list again.',
            ApplyOutcome.notApplied => 'Not applied: the repeater kept the old entry.',
            ApplyOutcome.rejected => 'The repeater refused: ${r.replyText ?? 'error'}',
            ApplyOutcome.mismatch => 'The list shows something different. Read it again.',
          });
    } on AdminException catch (e) {
      if (context.mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test(BuildContext context) async {
    final ctl = TextEditingController();
    final pw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Test a password'),
        content: TextField(key: const Key('test-password-field'), controller: ctl, obscureText: true, autocorrect: false, enableSuggestions: false, maxLength: 15, decoration: const InputDecoration(labelText: 'Password to test')),
        actions: [
          TextButton(style: TextButton.styleFrom(minimumSize: kTarget), onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(key: const Key('test-password-go'), style: FilledButton.styleFrom(minimumSize: kTarget), onPressed: () => Navigator.of(ctx).pop(ctl.text), child: const Text('Test')),
        ],
      ),
    );
    ctl.clear();
    ctl.dispose();
    if (pw == null || pw.isEmpty || !context.mounted) return;
    final ok = await c.testPassword(pw);
    if (context.mounted) showSnack(context, ok ? 'That password works as admin.' : 'No admin login with that password (or no answer). Try again.');
  }
}
