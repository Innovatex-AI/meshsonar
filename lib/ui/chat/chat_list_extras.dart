// Round 3 C-U5: the Chats list's Unread filter and an undoable "Mark all read". The shell's Chat tab (lib/ui/shell/chat_tab.dart)
// finds these on the provider when it has them; a provider without them (the debug fixtures) keeps the plain behaviour.
import 'package:flutter/foundation.dart';

abstract interface class ChatListExtras {
  /// On: the Chats list shows only chats with something unread. For the session only (never saved).
  ValueNotifier<bool> get unreadOnly;

  /// Marks every chat read and returns how to put them back: each chat that was unread is unread again (it counts
  /// one until it is opened). Null when nothing was unread.
  VoidCallback? markAllReadWithUndo();
}
