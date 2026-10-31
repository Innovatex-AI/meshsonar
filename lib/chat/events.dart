import 'models.dart';

enum ChatEventKind {
  /// A new message was stored (incoming or outgoing). [ChatEvent.message] is set. [ChatEvent.notify] says if it deserves a notification.
  messageAdded,

  /// Delivery state of a message changed.
  messageUpdated,

  /// Unread count, mute, pin, draft or last-message of a conversation changed.
  conversationChanged,
  contactsChanged,
  channelsChanged,

  /// Wardrive (system) channel traffic or counters changed. Never chat: no unread, no notification.
  systemChanged,
  historyDeleted,
}

class ChatEvent {
  final ChatEventKind kind;
  final String? convKey;
  final String? messageId;
  final ChatMessage? message;
  final bool notify;
  const ChatEvent._(this.kind, {this.convKey, this.messageId, this.message, this.notify = false});

  factory ChatEvent.added(ChatMessage m, {required bool notify}) => ChatEvent._(ChatEventKind.messageAdded, convKey: m.convKey, messageId: m.id, message: m, notify: notify);
  factory ChatEvent.updated(String convKey, String messageId) => ChatEvent._(ChatEventKind.messageUpdated, convKey: convKey, messageId: messageId);
  factory ChatEvent.conversation(String convKey) => ChatEvent._(ChatEventKind.conversationChanged, convKey: convKey);
  const ChatEvent.contacts() : this._(ChatEventKind.contactsChanged);
  const ChatEvent.channels() : this._(ChatEventKind.channelsChanged);
  factory ChatEvent.system(String? convKey) => ChatEvent._(ChatEventKind.systemChanged, convKey: convKey);
  factory ChatEvent.deleted(String? convKey) => ChatEvent._(ChatEventKind.historyDeleted, convKey: convKey);

  @override
  String toString() => 'ChatEvent($kind, $convKey, $messageId, notify=$notify)';
}
