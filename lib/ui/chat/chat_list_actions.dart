// What the Chats list can do to a conversation: pin, mute (with durations), delete. Shared by the swipe actions, the
// long-press menu and the screen-reader actions, so all three behave the same.
//
//   * Delete of a DM or room clears its history on this phone; a bottom toast offers Undo and puts the messages back
//     (a snapshot is kept in memory for as long as the toast is up and a little after, never on disk);
//   * Delete of a channel asks first (it also removes the channel from the radio) through the shared action sheet;
//   * every action gives the light haptic.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/conversation_row.dart';
import '../../chat/db/message_repository.dart' show MessageCursor;
import '../../chat/models.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';

enum _MuteChoice { hour, eight, day, forever, mentions }

class ChatListActions {
  final ChatController chat;
  ChatListActions(this.chat);

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
