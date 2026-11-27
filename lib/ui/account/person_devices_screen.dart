// More > Devices when the server offers ID step 3 (`capabilities.radioProof`): the person's devices as a list (name, model,
// build, last used, Rename, Remove), the notices about them (a device joined, a radio moved, a device asks to join) and the
// "ask me first" switch. No key is shown, copied, pasted or rotated here. Without the capability DevicesScreen keeps the old
// driver-key page and this widget is never built.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/time_format.dart' as tf;
import '../../app/messages.dart';
import '../../core/person_identity.dart';
import '../app.dart';
import '../design/app_surfaces.dart';
import '../settings/confirm_sheet.dart';
import '../widgets.dart';

/// Notices shown before "Show all": the newest few, so the device list stays within a thumb's reach.
const int noticesShownFirst = 3;

const _tap = Size(48, 48);

class PersonDevicesScreen extends StatefulWidget {
  const PersonDevicesScreen({super.key});
  @override
  State<PersonDevicesScreen> createState() => _PersonDevicesScreenState();
}

class _PersonDevicesScreenState extends State<PersonDevicesScreen> {
  bool _started = false;
  bool _allNotices = false;
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
    final name = await showAppSheet<String>(
      context,
      detents: [MediaQuery.textScalerOf(context).scale(10) > 13 ? 0.92 : 0.5], // large text needs the room for both buttons
      builder: (ctx, controller) => _RenameSheet(initial: d.nameSet ? d.name : '', controller: controller),
    );
    if (name == null) return;
    await _guard(() => c.rename(d.id, name), 'Renaming the device');
  }

  Future<void> _remove(PersonDevice d) async {
    final c = AppScope.read(context).personDevices;
    final ok = await showConfirmSheet(
      context,
      sheetKey: const Key('device-remove-sheet'),
      title: 'Remove ${d.name}?',
      body: 'It stops uploading as you. Its drives stay on your account. To bring it back, connect your radio on it again.',
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
    // Things that wait for an answer come first; the rest are news and can be folded away.
    final notices = [...c.notices.where((n) => n.isOpenRequest), ...c.notices.where((n) => !n.isOpenRequest)];
    final open = notices.where((n) => n.isOpenRequest).length;
    final first = open > noticesShownFirst ? open : noticesShownFirst;
    final visible = _allNotices ? notices : notices.take(first).toList();
    final fresh = notices.where((n) => n.isOpenRequest || !n.read).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: c.refresh,
          child: ListView(
            key: const Key('person-devices-screen'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(Gap.l),
            children: [
              Text(
                'Phones and tablets on your account. No key to copy.',
                key: const Key('person-devices-intro'),
                style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: Gap.s),
              if (_msg != null) ErrorBanner(_msg!),
              if (c.error != null) ...[
                ErrorBanner(c.error!),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonalIcon(
                    key: const Key('person-devices-retry'),
                    style: FilledButton.styleFrom(minimumSize: _tap),
                    onPressed: c.refresh,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ),
              ],
              if (notices.isNotEmpty) ...[
                const SizedBox(height: Gap.s),
                Text(fresh == 0 ? 'Notices' : 'Notices ($fresh new)', key: const Key('person-notices-title'), style: t.textTheme.titleMedium),
                for (final n in visible) _NoticeTile(n, onAct: (a) => _guard(() => c.noticeAct(n.id, a), 'Answering the notice')),
                if (notices.length > visible.length)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      key: const Key('person-notices-all'),
                      style: TextButton.styleFrom(minimumSize: _tap),
                      onPressed: () => setState(() => _allNotices = true),
                      child: Text('Show all ${notices.length} notices'),
                    ),
                  ),
              ],
              const SizedBox(height: Gap.m),
              Text('Your devices', style: t.textTheme.titleMedium),
              if (c.loading && !c.loadedOnce)
                const Padding(
                  key: Key('person-devices-loading'),
                  padding: EdgeInsets.all(Gap.l),
                  child: Column(children: [CircularProgressIndicator(), SizedBox(height: Gap.s), Text('Loading your devices…')]),
                )
              else if (shown.isEmpty && c.loadedOnce)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Gap.m),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('No devices yet. Connect your radio on this phone and it shows up here.', key: Key('person-devices-empty')),
                    TextButton.icon(
                      key: const Key('person-devices-empty-refresh'),
                      style: TextButton.styleFrom(minimumSize: _tap),
                      onPressed: c.refresh,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check again'),
                    ),
                  ]),
                )
              else
                for (final d in shown) _DeviceTile(d, onRename: () => _rename(d), onRemove: () => _remove(d)),
              const SizedBox(height: Gap.m),
              // A setting, so it sits under the list it is about (the list and the notices are what people come for).
              SwitchListTile(
                key: const Key('ask-first-switch'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Ask me first'),
                subtitle: const Text('A new device waits for your yes before it joins.'),
                value: c.askFirst,
                onChanged: (v) => _guard(() => c.setAskFirst(v), 'Saving the setting'),
              ),
              const SizedBox(height: Gap.s),
              TextButton.icon(
                key: const Key('person-devices-website'),
                style: TextButton.styleFrom(minimumSize: _tap),
                onPressed: () => s.openWebPage('/me/devices'),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open on the website'),
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
            // Wrap, not Row: at large text the marker drops under the name instead of squeezing it.
            Wrap(
              spacing: Gap.s,
              runSpacing: Gap.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(d.name, style: t.textTheme.titleMedium),
                if (d.current)
                  Chip(key: Key('device-current-${d.id}'), label: const Text('This phone'), visualDensity: VisualDensity.compact),
              ],
            ),
            if (detail.isNotEmpty) Text(detail, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            Text(d.lastSeenAt == null ? 'Not used yet' : 'Last used ${tf.dateTime(d.lastSeenAt!)}',
                key: Key('device-used-${d.id}'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            const SizedBox(height: Gap.xs),
            Wrap(
              spacing: Gap.s,
              children: [
                OutlinedButton.icon(
                  key: Key('device-rename-${d.id}'),
                  style: OutlinedButton.styleFrom(minimumSize: _tap),
                  onPressed: onRename,
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Rename'),
                ),
                if (!d.current)
                  OutlinedButton.icon(
                    key: Key('device-remove-${d.id}'),
                    style: OutlinedButton.styleFrom(minimumSize: _tap, foregroundColor: t.colorScheme.error),
                    onPressed: onRemove,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Remove'),
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
            if (n.createdAt != null) Text(tf.dateTime(n.createdAt!), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            if (n.isOpenRequest || !n.read) const SizedBox(height: Gap.xs),
            // Wrap, not Row: two buttons side by side do not fit at 375 pt with large text.
            Wrap(
              spacing: Gap.s,
              children: [
                if (n.isOpenRequest) ...[
                  FilledButton(
                    key: Key('notice-approve-${n.id}'),
                    style: FilledButton.styleFrom(minimumSize: _tap),
                    onPressed: () => onAct('approve'),
                    child: const Text('Yes, add it'),
                  ),
                  OutlinedButton(
                    key: Key('notice-deny-${n.id}'),
                    style: OutlinedButton.styleFrom(minimumSize: _tap),
                    onPressed: () => onAct('deny'),
                    child: const Text('No'),
                  ),
                ] else if (!n.read)
                  TextButton(
                    key: Key('notice-read-${n.id}'),
                    style: TextButton.styleFrom(minimumSize: _tap),
                    onPressed: () => onAct('read'),
                    child: const Text('Got it'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Owns its text controller, so it is disposed with the sheet (not while the sheet is still animating out).
class _RenameSheet extends StatefulWidget {
  final String initial;
  final ScrollController controller;
  const _RenameSheet({required this.initial, required this.controller});
  @override
  State<_RenameSheet> createState() => _RenameSheetState();
}

class _RenameSheetState extends State<_RenameSheet> {
  late final TextEditingController _ctl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  // Trimmed, so a stray space from the keyboard's autocomplete is not saved as part of the name.
  void _save() => Navigator.pop(context, _ctl.text.trim());

  @override
  Widget build(BuildContext context) => AppSheetScaffold(
        controller: widget.controller,
        title: 'Rename device',
        primaryAction: FilledButton(key: const Key('device-rename-save'), onPressed: _save, child: const Text('Save')),
        secondaryAction: TextButton(key: const Key('device-rename-cancel'), onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        children: [
          TextField(
            key: const Key('device-rename-field'),
            controller: _ctl,
            autofocus: true,
            maxLength: 40,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(), // Done on the keyboard saves: no reach for the button
            decoration: InputDecoration(
              labelText: 'Device name',
              helperText: 'Empty uses the default name.',
              suffixIcon: IconButton(key: const Key('device-rename-clear'), tooltip: 'Clear', icon: const Icon(Icons.clear), onPressed: _ctl.clear),
            ),
          ),
        ],
      );
}
