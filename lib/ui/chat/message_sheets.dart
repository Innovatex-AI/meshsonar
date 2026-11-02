// The long-press actions sheet of a message. (Message details live in lib/ui/contacts/message_details.dart.)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design/app_surfaces.dart';
import '../../chat/models.dart' show ChatMessage, MessageState;
import 'message_format.dart';

enum MessageAction { copy, retry, cancel, delete, details, openLink }

/// Shows the actions for [m]; returns the chosen one (and the link for [MessageAction.openLink]).
Future<(MessageAction, String?)?> showMessageActions(BuildContext context, ChatMessage m) {
  final links = [for (final p in splitMessage(m.text)) if (p.kind == PartKind.url || p.kind == PartKind.meshLink) p.text];
  final failed = m.state == MessageState.failed;
  return showAppActionSheet<(MessageAction, String?)>(
    context,
    actions: [
      AppAction('Copy text', (MessageAction.copy, null), key: const Key('act-copy')),
      for (final l in links)
        AppAction(l.length > 40 ? 'Open ${l.substring(0, 37)}…' : 'Open $l', (MessageAction.openLink, l), key: const Key('act-link')),
      if (failed) const AppAction('Try sending again', (MessageAction.retry, null), key: Key('act-retry')),
      if (m.isPending) const AppAction('Cancel sending', (MessageAction.cancel, null), key: Key('act-cancel')),
      const AppAction('Message details', (MessageAction.details, null), key: Key('act-details')),
      if (!m.isPending) const AppAction('Delete from this phone', (MessageAction.delete, null), destructive: true, key: Key('act-delete')),
    ],
  );
}

Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    showAppToast(context, 'Copied', kind: AppToastKind.success);
  }
}

/// Asks before deleting; returns true to delete.
Future<bool> confirmDeleteMessage(BuildContext context) async {
  return showAppAlert(
    context,
    title: 'Delete this message?',
    message: 'It is removed from this phone only. People you sent it to keep their copy.',
    confirmLabel: 'Delete',
    cancelLabel: 'Keep',
    destructive: true,
    confirmKey: const Key('confirm-delete-message'),
  ).then((v) => v == true);
}
