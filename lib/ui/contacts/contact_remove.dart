// Removing a contact, shared by the Edit sheet and the Contacts list swipe: the action sheet (never a bare confirm), the
// optional "and delete the conversation", the toast with Undo, and the restore.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../chat/contact_manager.dart';
import '../../chat/models.dart';
import '../design/app_surfaces.dart';
import 'contacts_controller.dart';

/// Asks, then removes [c] from the phone and the radio. Returns true when it was removed. [context] must stay mounted.
Future<bool> removeContactFlow(BuildContext context, ContactsController controller, Contact c) async {
  final conv = c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix);
  final hasMessages = controller.chat.page(conv, limit: 1).messages.isNotEmpty;
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
  if (choice == null || !context.mounted) return false;
  final manager = controller.manager;
  final deleted = choice == 2;
  if (deleted) controller.chat.deleteHistory(conv);
  unawaited(manager.remove(c.publicKey));
  showAppToast(
    context,
    deleted ? '${c.displayName} and the conversation were removed.' : '${c.displayName} was removed.',
    actionLabel: deleted ? null : 'Undo',
    onAction: deleted ? null : () => unawaited(restoreContact(manager, c)),
  );
  return true;
}

/// Undo of a remove: the contact comes back with its name, notes, favourite and last position (the conversation was kept).
Future<void> restoreContact(ContactManager m, Contact s) async {
  await m.addByKey(s.publicKey, name: s.name, type: s.type);
  final cur = m.store.contacts.get(s.radioId, s.publicKey);
  if (cur == null) return;
  m.store.contacts.upsert(cur.copyWith(
    customName: s.customName,
    notes: s.notes,
    favourite: s.favourite,
    blocked: s.blocked,
    forceFlood: s.forceFlood,
    lat: s.lat,
    lon: s.lon,
    lastAdvertTs: s.lastAdvertTs,
  ));
  m.setNotes(s.publicKey, s.notes); // fires the change notification the upsert alone does not
}
