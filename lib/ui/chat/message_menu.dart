// The per-bubble menu (chat plan 4.2). Long-press opens the iOS context menu with the bubble itself as the preview (spike
// S6); where that is not available (non-Apple platforms, or [MessageMenu.useContextMenu] off) the same entries open as an
// action sheet. Replaces the old message_sheets.dart. Also: the failed-bubble action sheet and the small shared helpers
// (copy, delete confirmation).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chat/models.dart' show ChatMessage, MessageState;
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import 'message_format.dart';

enum MessageMenuId { copy, openLink, details, retry, cancel, delete }

class MessageMenuEntry {
  final MessageMenuId id;
  final String label;
  final AppSymbol symbol;
  final bool destructive;

  /// The link for [MessageMenuId.openLink].
  final String? link;

  /// 0 = actions, 1 = destructive group (the menu draws a divider between groups).
  final int group;
  const MessageMenuEntry(this.id, this.label, this.symbol, {this.destructive = false, this.link, this.group = 0});
}

abstract final class MessageMenu {
  /// Test/escape-hatch seam: false = long-press opens the action-sheet fallback (spike S6).
  static bool useContextMenu = true;

  static bool apple(BuildContext context) {
    final p = Theme.of(context).platform;
    return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
  }

  static List<String> linksOf(ChatMessage m) => [for (final p in splitMessage(m.text)) if (p.kind == PartKind.url || p.kind == PartKind.meshLink) p.text];

  /// Copy, Open link(s), Details, Try Again (failed), Cancel sending (pending), Delete from this phone (last, destructive).
  static List<MessageMenuEntry> entries(ChatMessage m) => [
        const MessageMenuEntry(MessageMenuId.copy, 'Copy', AppSymbols.docOnDoc),
        for (final l in linksOf(m)) MessageMenuEntry(MessageMenuId.openLink, l.length > 36 ? 'Open ${l.substring(0, 33)}…' : 'Open $l', AppSymbols.globe, link: l),
        const MessageMenuEntry(MessageMenuId.details, 'Details', AppSymbols.infoCircle),
        if (m.state == MessageState.failed) const MessageMenuEntry(MessageMenuId.retry, 'Try Again', AppSymbols.arrowUpCircleFill),
        if (m.isPending) const MessageMenuEntry(MessageMenuId.cancel, 'Cancel sending', AppSymbols.xmarkCircleFill),
        if (!m.isPending) const MessageMenuEntry(MessageMenuId.delete, 'Delete from this phone', AppSymbols.trash, destructive: true, group: 1),
      ];

  static String keyName(MessageMenuId id) => id.name;

  /// The action-sheet form of the menu; returns the chosen entry.
  static Future<MessageMenuEntry?> showSheet(BuildContext context, ChatMessage m) {
    return showAppActionSheet<MessageMenuEntry>(
      context,
      actions: [
        for (final e in entries(m))
          AppAction<MessageMenuEntry>(e.label, e, destructive: e.destructive, symbol: e.symbol, key: Key('act-${keyName(e.id)}')),
      ],
    );
  }
}

enum FailedChoice { retry, details, delete }

/// Tap on a failed bubble or its red glyph: Try Again, Details, Delete, Cancel (iMessage pattern).
Future<FailedChoice?> showFailedSheet(BuildContext context) {
  return showAppActionSheet<FailedChoice>(
    context,
    sheetKey: const Key('failed-sheet'),
    actions: const [
      AppAction('Try Again', FailedChoice.retry, key: Key('failed-retry')),
      AppAction('Details', FailedChoice.details, key: Key('failed-details')),
      AppAction('Delete', FailedChoice.delete, destructive: true, key: Key('failed-delete')),
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
