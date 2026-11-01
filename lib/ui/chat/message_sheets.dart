// The long-press actions sheet of a message. (Message details live in lib/ui/contacts/message_details.dart.)
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/models.dart' show ChatMessage, MessageState;
import 'message_format.dart';

enum MessageAction { copy, retry, cancel, delete, details, openLink }

/// Shows the actions for [m]; returns the chosen one (and the link for [MessageAction.openLink]).
Future<(MessageAction, String?)?> showMessageActions(BuildContext context, ChatMessage m) {
  final links = [for (final p in splitMessage(m.text)) if (p.kind == PartKind.url || p.kind == PartKind.meshLink) p.text];
  final failed = m.state == MessageState.failed;
  return showModalBottomSheet<(MessageAction, String?)>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) {
      Widget tile(IconData icon, String label, MessageAction a, {String? link, Color? color, Key? key}) => ListTile(
            key: key,
            minTileHeight: 48,
            leading: Icon(icon, color: color),
            title: Text(label, style: color == null ? null : TextStyle(color: color)),
            onTap: () => Navigator.pop(ctx, (a, link)),
          );
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            tile(Icons.copy_rounded, 'Copy text', MessageAction.copy, key: const Key('act-copy')),
            for (final l in links)
              tile(Icons.link_rounded, l.length > 40 ? 'Open ${l.substring(0, 37)}…' : 'Open $l', MessageAction.openLink, link: l, key: const Key('act-link')),
            if (failed) tile(Icons.refresh_rounded, 'Try sending again', MessageAction.retry, key: const Key('act-retry')),
            if (m.isPending) tile(Icons.cancel_outlined, 'Cancel sending', MessageAction.cancel, key: const Key('act-cancel')),
            tile(Icons.info_outline_rounded, 'Message details', MessageAction.details, key: const Key('act-details')),
            if (!m.isPending)
              tile(Icons.delete_outline_rounded, 'Delete from this phone', MessageAction.delete, color: Theme.of(ctx).colorScheme.error, key: const Key('act-delete')),
          ]),
        ),
      );
    },
  );
}

Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied')));
  }
}

/// Asks before deleting; returns true to delete.
Future<bool> confirmDeleteMessage(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Delete this message?'),
      content: const Text('It is removed from this phone only. People you sent it to keep their copy.'),
      actions: [
        TextButton(style: TextButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
        FilledButton(key: const Key('confirm-delete-message'), style: FilledButton.styleFrom(minimumSize: const Size(48, 48)), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
      ],
    ),
  );
  return ok == true;
}
