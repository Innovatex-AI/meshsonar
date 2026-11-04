// What the Chats list can do to a conversation: pin, mute (with durations), delete. Shared by the swipe actions, the
// long-press menu and the screen-reader actions, so all three behave the same.
//
//   * Delete of a DM or room clears its history on this phone; a bottom toast offers Undo and puts the messages back
//     (a snapshot is kept in memory for as long as the toast is up and a little after, never on disk);
//   * Delete of a channel asks first (it also removes the channel from the radio) through the shared action sheet;
//   * every action gives the light haptic.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/chat_controller.dart';
import '../../chat/conversation_row.dart';
import '../../chat/db/message_repository.dart' show MessageCursor;
import '../../chat/models.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../contacts/path_manager_screen.dart' show PathManagerScreen;
import '../design/app_symbols.dart';
import 'channel_detail_screen.dart';
import 'chat_navigation.dart';

/// One entry of a conversation's context menu (the long-press menu and its action-sheet fallback share this list).
enum ChatMenuId { open, pin, mute, markUnread, info, route, copyKey, delete }

class ChatMenuEntry {
  final ChatMenuId id;
  final String label;
  final AppSymbol symbol;
  final bool destructive;

  /// Entries are grouped by plan 4.1: [open, pin, mute, mark unread] [info, route, copy key] [delete].
  final int group;
  const ChatMenuEntry(this.id, this.label, this.symbol, {this.destructive = false, required this.group});
}

enum _MuteChoice { hour, eight, day, forever, mentions }

class ChatListActions {
  /// Test/escape-hatch seam: false = long-press opens the action-sheet fallback instead of the context menu (spike S6).
  static bool useContextMenu = true;

  final ChatController chat;

  /// Needed for "Contact info" / "Route" (opens the profile); null in tests that only exercise the data actions.
  final ChatNavigator? navigator;
  ChatListActions(this.chat, {this.navigator});

  /// "Mark unread" / "Mark read": a conversation that shows unread (real or manual) is marked read; otherwise it is marked
  /// unread (it then shows as one unread until it is opened).
  void toggleUnread(ConversationRow r) {
    final id = chat.radioId;
    if (id == null) return;
    AppHaptics.light();
    if (r.unread > 0 || r.markedUnread) {
      chat.service.markRead(r.key);
    } else {
      chat.service.markUnread(id, r.key);
    }
    chat.refresh();
  }

  static String unreadLabel(ConversationRow r) => (r.unread > 0 || r.markedUnread) ? 'Mark read' : 'Mark unread';

  /// The entries of the context menu for [r], in display order. System rows only get Open.
  List<ChatMenuEntry> menuEntries(ConversationRow r) => [
        const ChatMenuEntry(ChatMenuId.open, 'Open', AppSymbols.message, group: 0),
        if (!r.isSystem) ...[
          ChatMenuEntry(ChatMenuId.pin, r.pinned ? 'Unpin' : 'Pin', r.pinned ? AppSymbols.pinFill : AppSymbols.pin, group: 0),
          ChatMenuEntry(ChatMenuId.mute, r.muted ? 'Unmute' : 'Mute', r.muted ? AppSymbols.bell : AppSymbols.bellSlash, group: 0),
          ChatMenuEntry(ChatMenuId.markUnread, unreadLabel(r), AppSymbols.message, group: 0),
          if (r.isChannel && r.channelId != null) const ChatMenuEntry(ChatMenuId.info, 'Channel info', AppSymbols.infoCircle, group: 1),
          if (!r.isChannel && r.contactKey != null) ...[
            const ChatMenuEntry(ChatMenuId.info, 'Contact info', AppSymbols.infoCircle, group: 1),
            if (r.convKind == ConvKind.dm) const ChatMenuEntry(ChatMenuId.route, 'Route', AppSymbols.route, group: 1),
          ],
        ],
        if (r.contactKey != null) const ChatMenuEntry(ChatMenuId.copyKey, 'Copy key', AppSymbols.docOnDoc, group: 1),
        if (!r.isSystem) const ChatMenuEntry(ChatMenuId.delete, 'Delete', AppSymbols.trash, destructive: true, group: 2),
      ];

  /// Runs one menu entry. [open] opens the conversation (the list owns navigation and the search reset).
  Future<void> perform(BuildContext context, ConversationRow r, ChatMenuId id, {required VoidCallback open}) async {
    switch (id) {
      case ChatMenuId.open:
        open();
      case ChatMenuId.pin:
        togglePin(r);
      case ChatMenuId.mute:
        await mute(context, r);
      case ChatMenuId.markUnread:
        toggleUnread(r);
      case ChatMenuId.info:
        _info(context, r);
      case ChatMenuId.route:
        await _route(context, r);
      case ChatMenuId.copyKey:
        await Clipboard.setData(ClipboardData(text: r.contactKey!));
        if (context.mounted) showAppToast(context, 'Key copied');
      case ChatMenuId.delete:
        await delete(context, r);
    }
  }

  void _info(BuildContext context, ConversationRow r) {
    if (r.isChannel) {
      final id = r.channelId;
      if (id != null) ChannelDetailScreen.open(context, controller: chat, channelId: id);
      return;
    }
    final key = r.contactKey, radio = chat.radioId;
    final c = key == null || radio == null ? null : chat.store.contacts.get(radio, key);
    if (c != null) navigator?.openProfile(context, c);
  }

  Future<void> _route(BuildContext context, ConversationRow r) async {
    final key = r.contactKey, radio = chat.radioId;
    if (key == null || radio == null || chat.store.contacts.get(radio, key) == null) return;
    await PathManagerScreen.open(context, manager: chat.service.contacts, publicKey: key, changes: chat);
  }

  /// The fallback for the long-press menu (Android, or where the context-menu preview is switched off): the same entries as
  /// one action sheet.
  Future<void> showMenuSheet(BuildContext context, ConversationRow r, {required VoidCallback open}) async {
    final entries = menuEntries(r);
    final choice = await showAppActionSheet<ChatMenuId>(
      context,
      title: r.title,
      actions: [
        for (final e in entries) AppAction(e.label, e.id, destructive: e.destructive, symbol: e.symbol, key: Key('sheet-${e.id.name}-${r.key}')),
      ],
    );
    if (choice == null || !context.mounted) return;
    await perform(context, r, choice, open: open);
  }

  void togglePin(ConversationRow r) {
    final id = chat.radioId;
    if (id == null) return;
    AppHaptics.light();
    chat.service.setPinned(id, r.key, !r.pinned);
  }

  /// Muted -> unmute at once; otherwise ask for how long.
  Future<void> mute(BuildContext context, ConversationRow r) async {
    final id = chat.radioId;
    if (id == null) return;
    if (r.muted) {
      AppHaptics.light();
      chat.service.setNotifyMode(id, r.key, NotifyMode.all);
      return;
    }
    final choice = await showAppActionSheet<_MuteChoice>(
      context,
      title: 'Mute ${r.title}',
      message: 'Messages still arrive and are kept. You are just not notified.',
      actions: const [
        AppAction('For 1 hour', _MuteChoice.hour, symbol: AppSymbols.bellSlash),
        AppAction('For 8 hours', _MuteChoice.eight, symbol: AppSymbols.bellSlash),
        AppAction('For 24 hours', _MuteChoice.day, symbol: AppSymbols.bellSlash),
        AppAction('Until I unmute', _MuteChoice.forever, symbol: AppSymbols.bellSlash),
        AppAction('Mentions only', _MuteChoice.mentions, symbol: AppSymbols.bell),
      ],
    );
    if (choice == null) return;
    AppHaptics.light();
    switch (choice) {
      case _MuteChoice.hour:
        chat.service.setNotifyMode(id, r.key, NotifyMode.muted, muteFor: const Duration(hours: 1));
      case _MuteChoice.eight:
        chat.service.setNotifyMode(id, r.key, NotifyMode.muted, muteFor: const Duration(hours: 8));
      case _MuteChoice.day:
        chat.service.setNotifyMode(id, r.key, NotifyMode.muted, muteFor: const Duration(hours: 24));
      case _MuteChoice.forever:
        chat.service.setNotifyMode(id, r.key, NotifyMode.muted);
      case _MuteChoice.mentions:
        chat.service.setNotifyMode(id, r.key, NotifyMode.mentionsOnly);
    }
  }

  /// Returns true when something was deleted.
  Future<bool> delete(BuildContext context, ConversationRow r) async {
    if (r.isSystem) return false;
    if (r.isChannel) {
      final ch = r.channelId == null ? null : chat.store.channels.getById(r.channelId!);
      if (ch == null) return false;
      final ok = await showAppActionSheet<bool>(
        context,
        title: 'Delete ${r.title}?',
        message: 'Removes the channel and its messages from this phone, and from your radio when it is connected.',
        actions: const [AppAction('Delete channel', true, destructive: true, symbol: AppSymbols.trash)],
      );
      if (ok != true) return false;
      AppHaptics.light();
      try {
        await chat.admin.delete(ch);
      } catch (_) {
        if (context.mounted) showAppToast(context, 'Could not delete the channel. Connect your radio and try again.', kind: AppToastKind.error);
        return false;
      }
      chat.refresh();
      return true;
    }
    if (!r.hasHistory) return false;
    final all = <ChatMessage>[];
    MessageCursor? cursor;
    do {
      final page = chat.service.page(r.key, before: cursor, limit: 500);
      all.addAll(page.messages);
      cursor = page.next;
    } while (cursor != null);
    AppHaptics.light();
    chat.service.deleteHistory(r.key);
    chat.refresh();
    if (context.mounted) {
      showAppToast(
        context,
        r.convKind == ConvKind.room ? 'Room history cleared' : 'Conversation cleared',
        actionLabel: 'Undo',
        onAction: () {
          for (final m in all.reversed) {
            chat.store.messages.insert(m);
          }
          chat.refresh();
        },
      );
    }
    return true;
  }
}
