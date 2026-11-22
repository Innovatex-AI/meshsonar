// More > Devices when the server offers ID step 3 (`capabilities.radioProof`): the person's devices as a list (name, model,
// build, last used, Rename, Remove), the notices about them (a device joined, a radio moved, a device asks to join) and the
// "ask me first" switch. No key is shown, copied, pasted or rotated here. Without the capability DevicesScreen keeps the old
// driver-key page and this widget is never built.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/messages.dart';
import '../../core/person_identity.dart';
import '../app.dart';
import '../settings/confirm_sheet.dart';
import '../widgets.dart';

String _when(DateTime? t) {
  if (t == null) return 'not yet';
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class PersonDevicesScreen extends StatefulWidget {
  const PersonDevicesScreen({super.key});
  @override
  State<PersonDevicesScreen> createState() => _PersonDevicesScreenState();
}

class _PersonDevicesScreenState extends State<PersonDevicesScreen> {
  bool _started = false;
  String? _msg;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(AppScope.read(context).personDevices.refresh());
  }

  Future<void> _guard(Future<void> Function() f, String action) async {
    try {
      await f();
      if (mounted) setState(() => _msg = null);
    } catch (e) {
      if (mounted) setState(() => _msg = friendlyError(e, action: action));
    }
  }

  Future<void> _rename(PersonDevice d) async {
    final c = AppScope.read(context).personDevices;
    final name = await showDialog<String>(context: context, builder: (ctx) => _RenameDialog(initial: d.nameSet ? d.name : ''));
    if (name == null) return;
    await _guard(() => c.rename(d.id, name), 'Renaming the device');
  }

  Future<void> _remove(PersonDevice d) async {
    final c = AppScope.read(context).personDevices;
    final ok = await showConfirmSheet(
      context,
      sheetKey: const Key('device-remove-sheet'),
      title: 'Remove ${d.name}?',
      body:
          'This device will stop uploading and signing in as you. The drives it already recorded stay on your account. '
          'If it is yours, connect your radio on it again to bring it back.',
      confirmLabel: 'Remove device',
      confirmKey: const Key('device-remove-confirm'),
      cancelKey: const Key('device-remove-cancel'),
      destructive: true,
    );
    if (!ok) return;
    await _guard(() => c.remove(d.id), 'Removing the device');
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final c = s.personDevices;
    final t = Theme.of(context);
    final shown = [
      for (final d in c.devices)
        if (!d.removed) d,
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: c.refresh,
          child: ListView(
            key: const Key('person-devices-screen'),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Text(
                'The phones and tablets on your MeshSonar account. There is no key to copy or paste: a device is yours because its radio proved it.',
                key: const Key('person-devices-intro'),
                style: t.textTheme.bodyMedium,
              ),
              const SizedBox(height: Gap.m),
              if (_msg != null) ErrorBanner(_msg!),
              if (c.error != null) ...[
                ErrorBanner(c.error!),
                TextButton(key: const Key('person-devices-retry'), onPressed: c.refresh, child: const Text('Try again')),
              ],
              SwitchListTile(
                key: const Key('ask-first-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Ask me first'),
                subtitle: const Text('When a device connects a radio that is yours, wait for your approval before it joins your account.'),
                value: c.askFirst,
                onChanged: (v) => _guard(() => c.setAskFirst(v), 'Saving the setting'),
              ),
              if (c.notices.isNotEmpty) ...[
                const SizedBox(height: Gap.m),
                Text('Notices', style: t.textTheme.titleMedium),
                for (final n in c.notices.take(10))
                  _NoticeTile(n, onAct: (a) => _guard(() => c.noticeAct(n.id, a), 'Answering the notice')),
              ],
              const SizedBox(height: Gap.m),
              Text('Your devices', style: t.textTheme.titleMedium),
              if (c.loading && !c.loadedOnce)
                const Center(
                  child: Padding(padding: EdgeInsets.all(Gap.l), child: CircularProgressIndicator()),
                )
              else if (shown.isEmpty && c.loadedOnce)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: Gap.m),
                  child: Text('No devices listed yet.', key: Key('person-devices-empty')),
                )
              else
                for (final d in shown) _DeviceTile(d, onRename: () => _rename(d), onRemove: () => _remove(d)),
              const SizedBox(height: Gap.l),
              TextButton.icon(
                key: const Key('person-devices-website'),
                onPressed: () => s.openWebPage('/me/devices'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('View this page on the website'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final PersonDevice d;
  final VoidCallback onRename, onRemove;
  const _DeviceTile(this.d, {required this.onRename, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final detail = d.detail;
    return Card(
      key: Key('device-${d.id}'),
      margin: const EdgeInsets.only(top: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(d.name, style: t.textTheme.titleSmall)),
                if (d.current)
                  Chip(key: Key('device-current-${d.id}'), label: const Text('This phone'), visualDensity: VisualDensity.compact),
              ],
            ),
            if (detail.isNotEmpty) Text(detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            Text('Last used ${_when(d.lastSeenAt)}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            Row(
              children: [
                TextButton(key: Key('device-rename-${d.id}'), onPressed: onRename, child: const Text('Rename')),
                if (!d.current)
                  TextButton(
                    key: Key('device-remove-${d.id}'),
                    onPressed: onRemove,
                    child: Text('Remove', style: TextStyle(color: t.colorScheme.error)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeTile extends StatelessWidget {
  final PersonNotice n;
  final void Function(String action) onAct;
  const _NoticeTile(this.n, {required this.onAct});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      key: Key('notice-${n.id}'),
      margin: const EdgeInsets.only(top: Gap.s),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              n.words,
              style: n.read && !n.isOpenRequest ? t.textTheme.bodyMedium : t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(_when(n.createdAt), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            Row(
              children: [
                if (n.isOpenRequest) ...[
                  FilledButton(key: Key('notice-approve-${n.id}'), onPressed: () => onAct('approve'), child: const Text('Approve')),
                  const SizedBox(width: Gap.s),
                  TextButton(key: Key('notice-deny-${n.id}'), onPressed: () => onAct('deny'), child: const Text('Turn down')),
                ] else if (!n.read)
                  TextButton(key: Key('notice-read-${n.id}'), onPressed: () => onAct('read'), child: const Text('Got it')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Owns its text controller, so it is disposed with the dialog (not while the dialog is still animating out).
class _RenameDialog extends StatefulWidget {
  final String initial;
  const _RenameDialog({required this.initial});
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(
          key: const Key('device-rename-field'),
          controller: _ctl,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(hintText: 'Leave empty for the default name'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(key: const Key('device-rename-save'), onPressed: () => Navigator.pop(context, _ctl.text), child: const Text('Save')),
        ],
      );
}
