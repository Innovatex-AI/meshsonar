// ChatController: the one object chat screens talk to. It owns the ChatService for the open chat store, follows the radio
// session (bind on connect, unbind on drop; the outbox keeps queued messages until the radio is back), and tells
// widgets when something changed. No widgets in here (lib/ui/chat has those).
//
// Chat only uses the local database and the radio: nothing in this file touches the network or the MeshSonar server.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat/channel_admin.dart';
import '../chat/conversation_row.dart';
import '../chat/chat_service.dart';
import '../chat/delivery_settings.dart';
import '../chat/events.dart';
import '../chat/models.dart';
import '../chat/radio_bridge.dart';
import '../chat/session_adapter.dart';
import '../chat/store.dart';
import '../radio/session.dart' as r;
import '../radio/tx_arbiter.dart';

/// The sink ChatService sends through. It exists before any radio does: messages sent offline wait in the outbox and go
/// when a session binds. Swapping the adapter is the only thing a reconnect changes.
class SwitchableSink implements OutboundMessageSink, DeliveryRadioControl {
  RadioSessionChatAdapter? adapter;

  @override
  Future<bool> resetPath({required String radioId, required String contactPublicKey}) {
    final a = adapter;
    if (a == null) throw const RadioNotConnected();
    return a.resetPath(radioId: radioId, contactPublicKey: contactPublicKey);
  }

  @override
  Future<void> addContactToRadio({required String radioId, required String contactPublicKey}) {
    final a = adapter;
    if (a == null) throw const RadioNotConnected();
    return a.addContactToRadio(radioId: radioId, contactPublicKey: contactPublicKey);
  }

  @override
  bool get canSend => adapter?.canSend ?? false;

  @override
  Future<SendReceipt> sendDirect(
      {required String radioId, required String contactPublicKey, required String text, required int timestamp, required int attempt, required bool forceFlood}) {
    final a = adapter;
    if (a == null) throw const RadioNotConnected();
    return a.sendDirect(radioId: radioId, contactPublicKey: contactPublicKey, text: text, timestamp: timestamp, attempt: attempt, forceFlood: forceFlood);
  }

  @override
  Future<int> sendChannel({required String radioId, required int slot, required String text, required int timestamp, int priority = CommandPriority.user}) {
    final a = adapter;
    if (a == null) throw const RadioNotConnected();
    return a.sendChannel(radioId: radioId, slot: slot, text: text, timestamp: timestamp, priority: priority);
  }
}

/// Result of [ChatController.send] for the composer.
class SendAttempt {
  final ChatMessage? message;

  /// Plain-language reason when nothing was queued.
  final String? error;
  const SendAttempt.ok(ChatMessage this.message) : error = null;
  const SendAttempt.failed(String this.error) : message = null;
  bool get ok => message != null;
}

class ChatController extends ChangeNotifier {
  static const String _lastRadioKey = ChatService.lastRadioSetting;

  final ChatStore store;
  final ChatService service;
  final SwitchableSink sink;
  final DateTime Function() now;
  late final ChannelAdmin admin;

  /// Non-null while a radio session is bound.
  r.RadioSession? _session;
  RadioSessionChatAdapter? _adapter;
  TxArbiter? _arbiter;
  String? _radioId;
  StreamSubscription<ChatEvent>? _sub;
  StreamSubscription<r.LinkState>? _linkSub;
  int _unread = 0;
  String? _activeConv;
  bool _disposed = false;

  /// Messages that arrived while the person was not looking at their conversation, newest last, for in-app banners.
  final StreamController<ChatMessage> _incoming = StreamController<ChatMessage>.broadcast();

  ChatController({required this.store, required this.service, required this.sink, required String Function() wardriveChannelName, DateTime Function()? now})
      : now = now ?? DateTime.now {
    admin = ChannelAdmin(
      store: store,
      radio: () => _session == null || !_session!.isConnected ? null : SessionChannelRadio(_session!),
      wardriveChannelName: wardriveChannelName,
      onChanged: _changed,
    );
    _radioId = store.db.setting(_lastRadioKey);
    _unread = service.unreadMessages();
    _sub = service.events.listen(_onEvent);
  }

  // ------------------------------------------------------------------ state

  /// The radio chat is about: the connected one, else the last one used (history stays readable without a radio).
  String? get radioId => _radioId;
  bool get hasRadioIdentity => _radioId != null;
  bool get radioConnected => sink.canSend;
  /// THE unread count (D19, docs/FEATURES.md "Unread count"): unread MESSAGES in non-muted, non-system conversations. The Chat tab
  /// badge, the Chats "Mark all as read" control, the app-icon badge and the sum of the row pills all come from this one rule;
  /// show it with [unreadCountLabel] so every badge caps the same way.
  int get unreadMessages => _unread;
  Stream<ChatEvent> get events => service.events;

  /// New incoming messages that deserve attention (the notify rules of ChatService applied).
  Stream<ChatMessage> get incoming => _incoming.stream;

  /// The conversation on screen now: no banner for it, and its messages count as read.
  String? get activeConversation => _activeConv;
  void setActiveConversation(String? convKey) {
    _activeConv = convKey;
    onActiveConversationChanged?.call(convKey);
  }

  /// Told whenever the conversation on screen changes (the alerts layer uses it to not banner what is already visible).
  void Function(String? convKey)? onActiveConversationChanged;

  /// Name of the connected radio as other people see it (the prefix of channel messages).
  String? get selfName => _session?.selfInfo?.name;

  /// The airtime budget is what holds the wardrive pings back right now (System channel row).
  bool get pingsPausedByBudget => _arbiter?.pausedByBudget() ?? false;

  bool get isEmpty => service.conversations(includeEmpty: true).isEmpty && (_radioId == null || store.channels.list(_radioId!, includeSystem: true).isEmpty);

  /// The merged Chats list (DMs, channels, rooms; System last), computed from the store. Cheap enough to call per rebuild:
  /// four queries, one pass.
  List<ConversationRow> conversationRows() {
    final id = _radioId;
    return buildConversationRows(
      summaries: service.conversations(radioId: id, includeEmpty: true),
      channels: id == null ? const [] : store.channels.list(id, includeSystem: true),
      contacts: id == null ? const [] : store.contacts.list(id, includeBlocked: false),
      lastMessages: {
        for (final e in store.messages.lastMessages().entries)
          e.key: LastMessageInfo(direction: e.value.direction, state: e.value.state, senderName: e.value.senderName),
      },
      drafts: store.drafts.all(),
      nowMs: now().millisecondsSinceEpoch,
    );
  }

  // ------------------------------------------------------------------ session

  /// Call when the radio session changes (connect, reconnect: a new session object; null: dropped). Safe to call often.
  Future<void> onSession(r.RadioSession? session, {TxArbiter? arbiter}) async {
    if (identical(session, _session)) return;
    await _unbind();
    if (session == null) {
      _changed();
      return;
    }
    _session = session;
    _arbiter = arbiter;
    final id = session.selfPublicKey;
    if (id != null) {
      _radioId = id;
      store.db.putSetting(_lastRadioKey, id);
    }
    final adapter = RadioSessionChatAdapter(
      session,
      lookupContact: (k) => id == null ? null : store.contacts.get(id, k),
      regionScopeForSlot: (slot) => id == null ? null : store.channels.bySlot(id, slot)?.regionScope,
    );
    _adapter = adapter;
    sink.adapter = adapter;
    adapter.bind(service);
    _linkSub = session.linkStates.listen((s) {
      if (s != r.LinkState.connected) _changed();
    });
    if (id != null) await admin.syncFromRadio(id);
    service.notifyRadioReady();
    _changed();
  }

  Future<void> _unbind() async {
    // Not awaited: cancelling a stream subscription never completes under fake async (same reason as RadioSessionImpl.close).
    unawaited(_linkSub?.cancel());
    _linkSub = null;
    final a = _adapter;
    _adapter = null;
    sink.adapter = null;
    _session = null;
    _arbiter = null;
    if (a != null) {
      try {
        await a.dispose();
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------------ delivery (build 77, round 3)

  /// Direct tries 1-4, flood tries 0-4, flood fallback on/off. Setting it saves it and tells listeners.
  DeliverySettings get deliverySettings => service.deliverySettings;
  set deliverySettings(DeliverySettings v) {
    service.deliverySettings = v;
    _changed();
  }

  /// The message log as text to share (no message text, no secrets): one message's lines with [messageId], else the
  /// newest lines. For a failed message's details and Settings > Storage & diagnostics.
  String exportMessageLog({String? messageId, String Function(int ms)? formatTime, List<String> header = const []}) =>
      service.exportMessageLog(messageId: messageId, formatTime: formatTime, header: header);

  /// The thread should show "They need to add you as a contact before they can receive this" (they have never confirmed
  /// a message from us).
  bool needsToAddYou(String convKey) {
    final id = _radioId;
    return id != null && service.needsToAddYou(id, convKey);
  }

  /// "Your radio's contact list is full" (the radio refused a contact; nothing is removed to make room).
  bool get radioContactListFull => service.radioContactListFull;

  /// Pull to refresh: drain the radio's offline queue now and re-read its channel slots.
  Future<void> refreshFromRadio() async {
    final s = _session;
    final id = _radioId;
    if (s == null || !s.isConnected) return;
    try {
      await s.syncMessagesNow();
    } catch (_) {}
    if (id != null) await admin.syncFromRadio(id);
    unawaited(_adapter?.syncContacts());
    _changed();
  }

  // ------------------------------------------------------------------ sending

  /// Queues [text] in [convKey]. Never throws; the composer shows [SendAttempt.error]. [forceFlood]: long-press Send,
  /// flood chosen for this one direct message (one reset path, then the normal send).
  SendAttempt send(String convKey, String text, {bool forceFlood = false}) {
    final id = _radioId;
    if (id == null) {
      return const SendAttempt.failed('Connect your radio once so MeshSonar knows which radio these messages belong to.');
    }
    try {
      return SendAttempt.ok(service.send(radioId: id, convKey: convKey, text: text, forceFlood: forceFlood));
    } on MessageTooLong catch (e) {
      return SendAttempt.failed('That message is ${e.actualBytes} bytes; one message can carry ${e.maxBytes}. Shorten it or split it in two.');
    } on ArgumentError catch (e) {
      final m = e.message.toString();
      if (m.contains('empty')) return const SendAttempt.failed('Type a message first.');
      if (m.contains('unknown contact')) return const SendAttempt.failed('This contact is no longer on the radio. Add it again from Contacts.');
      if (m.contains('unknown channel')) return const SendAttempt.failed('This channel was deleted.');
      return SendAttempt.failed('Could not send: $m');
    } catch (e) {
      return SendAttempt.failed('Could not queue the message: $e');
    }
  }

  // ------------------------------------------------------------------ events

  /// Demo and screenshot tooling only: pretend this radio is the current one.
  @visibleForTesting
  void debugUseRadio(String id) {
    _radioId = id;
    _changed();
  }

  /// Tells listeners to rebuild (after a change made outside the controller, such as an imported contact).
  void refresh() => _changed();

  void _changed() {
    if (_disposed) return;
    _unread = service.unreadMessages();
    notifyListeners();
  }

  void _onEvent(ChatEvent e) {
    if (_disposed) return;
    if (e.kind == ChatEventKind.messageAdded && e.message != null && !e.message!.isOutgoing) {
      final m = e.message!;
      if (_activeConv == m.convKey) {
        // The person is looking at it: it counts as read right away.
        service.markRead(m.convKey);
      } else if (e.notify) {
        _incoming.add(m);
      }
    }
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    unawaited(_linkSub?.cancel());
    unawaited(_incoming.close());
    super.dispose();
  }
}
