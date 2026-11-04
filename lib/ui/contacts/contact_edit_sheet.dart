// Edit sheet of the contact profile (chat plan 4.6): Name, Notes, Favourite, Keep on my radio, then the red rows Block and
// Remove. The iOS Contacts pattern: Cancel leading, Done trailing, nothing is saved until Done, a dirty Cancel asks first
// (action sheet, never a barrier tap that loses text, 7.18). Block and Remove act at once, after their own confirmation,
// and both say what happened in a toast with Undo (7.11).
import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoButton, CupertinoTextField;
import 'package:flutter/material.dart';

import '../../chat/contact_manager.dart';
import '../../chat/contact_port.dart';
import '../../chat/models.dart';
import '../design/app_surfaces.dart';
import '../design/app_type.dart';
import '../design/app_widgets.dart';
import '../design/tokens.dart';
import 'contacts_controller.dart';
import 'profile_widgets.dart';

/// What the sheet reports when it closes.
enum ContactEditOutcome { saved, cancelled, removed }

Future<ContactEditOutcome?> showContactEditSheet(BuildContext context, {required ContactsController controller, required String publicKey}) {
  return showAppSheet<ContactEditOutcome>(
    context,
    detents: const [0.95],
    dismissible: false,
    builder: (ctx, scroll) => ContactEditSheet(controller: controller, publicKey: publicKey, scroll: scroll),
  );
}

class ContactEditSheet extends StatefulWidget {
  final ContactsController controller;
  final String publicKey;
  final ScrollController scroll;
  const ContactEditSheet({super.key, required this.controller, required this.publicKey, required this.scroll});

  @override
  State<ContactEditSheet> createState() => _ContactEditSheetState();
}

class _ContactEditSheetState extends State<ContactEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late bool _favourite;
  late bool _keep;
  late final Contact _start;

  ContactsController get _c => widget.controller;
  ContactManager get _m => _c.manager;

  @override
  void initState() {
    super.initState();
    _start = _c.contact(widget.publicKey)!;
    _name = TextEditingController(text: _start.displayName)..addListener(_changed);
    _notes = TextEditingController(text: _start.notes)..addListener(_changed);
    _favourite = _start.favourite;
    _keep = _start.onRadio;
  }

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _changed() => setState(() {});

  bool get _dirty =>
      _name.text.trim() != _start.displayName || _notes.text != _start.notes || _favourite != _start.favourite || _keep != _start.onRadio;

  Future<void> _cancel() async {
    if (_dirty) {
      final discard = await showAppActionSheet<bool>(
        context,
        title: 'Discard your changes?',
        actions: const [AppAction('Discard changes', true, destructive: true, key: Key('edit-discard'))],
        cancelLabel: 'Keep editing',
        cancelKey: const Key('edit-keep-editing'),
      );
      if (discard != true || !mounted) return;
    }
    Navigator.of(context).pop(ContactEditOutcome.cancelled);
  }

  Future<void> _done() async {
    final key = widget.publicKey;
    final typed = _name.text.trim();
    if (typed != _start.displayName) _m.rename(key, typed.isEmpty || typed == _start.name ? null : typed);
    if (_notes.text != _start.notes) _m.setNotes(key, _notes.text);
    if (_favourite != _start.favourite) _m.setFavourite(key, _favourite);
    final nav = Navigator.of(context);
    final keepChanged = _keep != _start.onRadio;
    final msg = keepChanged ? await _applyKeep(key) : null;
    if (msg != null && mounted) showAppToast(context, msg, kind: AppToastKind.error);
    if (nav.mounted) nav.pop(ContactEditOutcome.saved);
  }

  /// Puts the contact on the radio or takes it off. Returns a friendly problem, or null.
  Future<String?> _applyKeep(String key) async {
    try {
      if (_keep) {
        await _m.ensureOnRadio(key, force: true);
      } else {
        await _m.removeFromRadio([key]);
      }
      return null;
    } on ContactTableFull {
      return 'The radio\'s contact list is full and every contact on it is a favourite or in use. Free a slot in Contacts first.';
    } on RadioUnavailable {
      return 'The radio is not connected. Connect it and try again.';
    } catch (_) {
      return 'The radio did not take that. Try again in a moment.';
    }
  }

  // ------------------------------------------------------------------ block / remove

  Future<void> _block(Contact c) async {
    if (c.blocked) {
      _m.setBlocked(c.publicKey, false);
      showAppToast(context, '${c.displayName} is unblocked.');
      return;
    }
    final ok = await showAppConfirm(
      context,
      title: 'Block ${c.displayName}?',
      message: 'Their messages stop alerting you. You can unblock them here at any time.',
      confirmLabel: 'Block',
      destructive: true,
      confirmKey: const Key('block-confirm'),
    );
    if (!ok || !mounted) return;
    _m.setBlocked(c.publicKey, true);
    _c.chat.markRead(c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix));
    final key = c.publicKey;
    showAppToast(context, '${c.displayName} is blocked.', actionLabel: 'Undo', onAction: () => _m.setBlocked(key, false));
  }

  Future<void> _remove(Contact c) async {
    final conv = c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix);
    final hasMessages = _c.chat.page(conv, limit: 1).messages.isNotEmpty;
    final choice = await showAppActionSheet<int>(
      context,
      title: 'Remove ${c.displayName}?',
      message: 'This removes the contact from this phone and from your radio. If you meet them on air again, the radio may offer them as a new node.',
      actions: [
        const AppAction('Remove contact', 1, destructive: true, key: Key('remove-confirm')),
        if (hasMessages) const AppAction('Remove contact and delete conversation', 2, destructive: true, key: Key('remove-delete-messages')),
      ],
      cancelKey: const Key('remove-cancel'),
    );
    if (choice == null || !mounted) return;
    final snapshot = c;
    final manager = _m;
    final deleted = choice == 2;
    if (deleted) _c.chat.deleteHistory(conv);
    unawaited(manager.remove(c.publicKey));
    showAppToast(
      context,
      deleted ? '${c.displayName} and the conversation were removed.' : '${c.displayName} was removed.',
      actionLabel: deleted ? null : 'Undo',
      onAction: deleted ? null : () => unawaited(_restore(manager, snapshot)),
    );
    Navigator.of(context).pop(ContactEditOutcome.removed);
  }

  /// Undo of a remove: the contact comes back with its name, notes, favourite and last position (the conversation was kept).
  static Future<void> _restore(ContactManager m, Contact s) async {
    await m.addByKey(s.publicKey, name: s.name, type: s.type);
    final cur = m.store.contacts.get(s.radioId, s.publicKey);
    if (cur == null) return;
    m.store.contacts.upsert(cur.copyWith(
      customName: s.customName,
      notes: s.notes,
      favourite: s.favourite,
      blocked: s.blocked,
      pathMode: s.pathMode,
      pinnedPath: s.pinnedPath,
      pinnedHashSize: s.pinnedHashSize,
      lat: s.lat,
      lon: s.lon,
      lastAdvertTs: s.lastAdvertTs,
    ));
    m.setNotes(s.publicKey, s.notes); // fires the change notification the upsert alone does not
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final live = _c.contact(widget.publicKey) ?? _start;
        final connected = _m.connected;
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _cancel();
          },
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.xs, Gap.xs, 0),
              child: Row(children: [
                CupertinoButton(
                  key: const Key('edit-cancel'),
                  minimumSize: const Size(Hit.minAndroid, Hit.minAndroid),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                  onPressed: _cancel,
                  child: Text('Cancel', style: AppType.body.copyWith(color: c.accent)),
                ),
                Expanded(child: Semantics(header: true, child: Text('Edit contact', textAlign: TextAlign.center, style: AppType.headline.copyWith(color: c.textPrimary)))),
                CupertinoButton(
                  key: const Key('edit-done'),
                  minimumSize: const Size(Hit.minAndroid, Hit.minAndroid),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                  onPressed: _done,
                  child: Text('Done', style: AppType.headline.copyWith(color: c.accent)),
                ),
              ]),
            ),
            Expanded(
              child: ListView(controller: widget.scroll, padding: const EdgeInsets.only(top: Gap.m, bottom: Gap.xl), children: [
                ProfileGroup(
                  footer: 'Only changes the name on this phone. They still advertise as ${live.name}.',
                  rows: [
                    _field(const Key('rename-field'), _name, 'Name', maxLength: 31),
                    if (_name.text.trim() != live.name)
                      ProfileRow(key: const Key('rename-reset'), label: 'Use advertised name', onTap: () => _name.text = live.name),
                  ],
                ),
                ProfileGroup(rows: [_field(const Key('edit-notes'), _notes, 'Notes', lines: 4)], footer: 'Notes stay on this phone.'),
                ProfileGroup(rows: [
                  AppSwitchTile(switchKey: const Key('edit-favourite'), title: 'Favourite', value: _favourite, onChanged: (v) => setState(() => _favourite = v)),
                  AppSwitchTile(
                    switchKey: const Key('edit-keep-on-radio'),
                    title: 'Keep on my radio',
                    subtitle: connected ? null : 'Connect your radio to change this.',
                    value: _keep,
                    onChanged: connected ? (v) => setState(() => _keep = v) : null,
                  ),
                ]),
                ProfileGroup(rows: [
                  ProfileRow(
                    key: const Key('contact-block'),
                    label: live.blocked ? 'Unblock contact' : 'Block contact',
                    destructive: !live.blocked,
                    onTap: () => _block(live),
                  ),
                  ProfileRow(key: const Key('contact-remove'), label: 'Remove contact', destructive: true, onTap: () => _remove(live)),
                ]),
              ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _field(Key key, TextEditingController ctl, String placeholder, {int lines = 1, int? maxLength}) {
    final c = AppColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Gap.xs, vertical: Gap.xs),
      child: CupertinoTextField(
        key: key,
        controller: ctl,
        placeholder: placeholder,
        minLines: lines,
        maxLines: lines == 1 ? 1 : 8,
        maxLength: maxLength,
        keyboardType: lines == 1 ? TextInputType.text : TextInputType.multiline,
        textCapitalization: TextCapitalization.sentences,
        style: AppType.body.copyWith(color: c.textPrimary),
        placeholderStyle: AppType.body.copyWith(color: c.textMuted),
        decoration: null,
        padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
      ),
    );
  }
}
