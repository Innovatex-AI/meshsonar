// AlertCoordinator: turns chat events into what the person sees: an OS notification, an in-app banner, or nothing.
//
// Rules (all unit-tested with a fake LocalNotifications):
//  * Only `ChatEvent.messageAdded` with `notify == true` and an incoming message alerts. ChatService already applied
//    blocked contacts, per-conversation notify mode (all / mentions only / muted) and mute-until; this class never
//    second-guesses those, it only adds the global ones (switch, permission, quiet hours, previews, foreground).
//  * The wardrive (system) channel NEVER alerts: ChatService does not emit messageAdded for it, and a conversation marked
//    system is refused again here as a belt-and-braces check.
//  * App in front: no OS notification. A banner inside the app, unless that conversation is the one on screen.
//  * App in background: an OS notification if the OS allows it. The notification is built from the row that was already
//    committed to SQLite (ChatService emits after the insert), so a wake that dies right after still has the message.
//  * Notification id = hash of the conversation key: a new message replaces the old banner of that conversation; iOS
//    groups by thread (threadIdentifier = conversation key), Android by group key.
//  * Reading a conversation removes its notification and refreshes the badge.
//  * Never time-sensitive: Focus and Do Not Disturb hold alerts back as the person configured them.
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../chat/chat_service.dart';
import '../chat/events.dart';
import '../chat/models.dart';
import '../platform/local_notifications.dart';
import 'alert_prefs.dart';

/// A banner shown inside the app while it is in front.
class InAppBanner {
  final String convKey;
  final String title;
  final String body;
  const InAppBanner(this.convKey, this.title, this.body);
}

/// What `requestIfNeeded` did.
enum PermissionOutcome { alreadyGranted, granted, deniedNow, notAskedYet, blocked }

class AlertCoordinator extends ChangeNotifier {
  final LocalNotifications notifications;
  final AlertPrefs prefs;
  final DateTime Function() _clock;

  /// Maximum characters of message text in a notification.
  static const int previewChars = 140;

  AlertCoordinator({required this.notifications, required this.prefs, DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  ChatService? _chat;
  StreamSubscription<ChatEvent>? _sub;
  NotificationPermission _permission = NotificationPermission.notDetermined;
  bool _foreground = true;
  bool _inited = false;
  String? _visibleConversation;
  final _banners = StreamController<InAppBanner>.broadcast();

  /// The conversation a person asked to open by tapping a notification. The Chat UI consumes it ([takePendingOpen]).
  final ValueNotifier<String?> pendingOpen = ValueNotifier<String?>(null);

  /// For tests and the debug screen.
  int shown = 0;
  int bannersShown = 0;
  int suppressed = 0;

  /// The chat service alerts are built from; null until the chat wiring calls [attachChat].
  ChatService? get chat => _chat;

  NotificationPermission get permission => _permission;
  bool get foreground => _foreground;
  Stream<InAppBanner> get banners => _banners.stream;

  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    await notifications.init(onTap: _onTap);
    await refreshPermission();
    final launch = await notifications.launchPayload();
    if (launch != null) pendingOpen.value = launch;
  }

  void _onTap(String payload) => pendingOpen.value = payload;

  String? takePendingOpen() {
    final v = pendingOpen.value;
    pendingOpen.value = null;
    return v;
  }

  /// Chat service to listen to. Call again to replace (a new store after a restore).
  void attachChat(ChatService chat) {
    unawaited(_sub?.cancel());
    _chat = chat;
    _sub = chat.events.listen(_onEvent);
    unawaited(_refreshBadge());
  }

  void setForeground(bool fg) {
    if (_foreground == fg) return;
    _foreground = fg;
    if (fg) unawaited(refreshPermission()); // the person may have changed it in system settings
  }

  /// The conversation currently on screen (the chat screen sets it on open and clears it on close).
  void setVisibleConversation(String? convKey) => _visibleConversation = convKey;

  // ------------------------------------------------------------------ permission

  Future<void> refreshPermission() async {
    final raw = await notifications.permission();
    final next = switch (raw) {
      NotificationPermission.granted => NotificationPermission.granted,
      NotificationPermission.restricted => NotificationPermission.restricted,
      _ => prefs.asked ? NotificationPermission.denied : NotificationPermission.notDetermined,
    };
    if (next != _permission) {
      _permission = next;
      notifyListeners();
    }
  }

  /// True when it is worth showing our explanation now (never asked, and the person did not already wave it away).
  bool get shouldOfferPrePrompt => prefs.enabled && _permission == NotificationPermission.notDetermined && !prefs.prePromptSeen;

  /// The one place the system prompt can start from. [prePrompt] shows OUR explanation and returns true when the person
  /// agrees; the system prompt only follows a yes. Returns what happened so the caller can word the next step.
  Future<PermissionOutcome> requestIfNeeded({required Future<bool> Function() prePrompt, bool force = false}) async {
    await refreshPermission();
    switch (_permission) {
      case NotificationPermission.granted:
        return PermissionOutcome.alreadyGranted;
      case NotificationPermission.denied:
      case NotificationPermission.restricted:
        return PermissionOutcome.blocked;
      case NotificationPermission.notDetermined:
        break;
    }
    if (!force && prefs.prePromptSeen) return PermissionOutcome.notAskedYet;
    final yes = await prePrompt();
    if (!yes) {
      await prefs.markPrePromptSeen();
      return PermissionOutcome.notAskedYet;
    }
    await prefs.markPrePromptSeen();
    final result = await notifications.requestPermission();
    await prefs.markAsked();
    _permission = result == NotificationPermission.granted ? NotificationPermission.granted : NotificationPermission.denied;
    notifyListeners();
    return _permission == NotificationPermission.granted ? PermissionOutcome.granted : PermissionOutcome.deniedNow;
  }

  // ------------------------------------------------------------------ events

  Future<void> _onEvent(ChatEvent e) async {
    switch (e.kind) {
      case ChatEventKind.messageAdded:
        if (e.notify) await handleIncoming(e.message);
        await _refreshBadge();
      case ChatEventKind.conversationChanged:
        await _onConversationChanged(e.convKey);
      case ChatEventKind.historyDeleted:
        await _refreshBadge();
      default:
        break;
    }
  }

  Future<void> handleIncoming(ChatMessage? m) async {
    final chat = _chat;
    if (m == null || chat == null) return;
    if (m.direction != Direction.incoming) return;
    if (!prefs.enabled) {
      suppressed++;
      return;
    }
    final cv = chat.conversation(m.convKey);
    if (cv != null && cv.isSystem) {
      suppressed++;
      return;
    }
    final title = cv?.title ?? m.senderName ?? 'MeshSonar';
    final sender = m.senderName;
    if (_foreground) {
      if (_visibleConversation == m.convKey) return; // already looking at it
      final body = m.convKind == ConvKind.channel && sender != null ? '$sender: ${_clip(m.text)}' : _clip(m.text);
      bannersShown++;
      if (!_banners.isClosed) _banners.add(InAppBanner(m.convKey, title, body));
      return;
    }
    if (_permission != NotificationPermission.granted) {
      suppressed++;
      return;
    }
    final unread = cv?.unread ?? 1;
    final String body;
    if (prefs.showText) {
      body = m.convKind == ConvKind.channel && sender != null ? '$sender: ${_clip(m.text)}' : _clip(m.text);
    } else {
      body = unread > 1 ? '$unread new messages' : 'New message';
    }
    final quiet = prefs.quiet.contains(_clock());
    await notifications.show(AlertNotification(
      id: notificationIdFor(m.convKey),
      threadId: m.convKey,
      title: title,
      body: body,
      payload: m.convKey,
      silent: !prefs.sound || quiet,
      vibrate: prefs.vibrate,
      badge: chat.unreadBadge(),
    ));
    shown++;
  }

  Future<void> _onConversationChanged(String? convKey) async {
    final chat = _chat;
    if (chat == null || convKey == null) {
      await _refreshBadge();
      return;
    }
    final cv = chat.conversation(convKey);
    if (cv != null && cv.unread == 0) await notifications.cancelConversation(notificationIdFor(convKey));
    await _refreshBadge();
  }

  Future<void> _refreshBadge() async {
    final chat = _chat;
    if (chat == null) return;
    try {
      await notifications.setBadge(prefs.enabled ? chat.unreadBadge() : 0);
    } catch (_) {}
  }

  /// Settings > "Send a test notification". Goes through the real show path, so it proves permission, sound and
  /// previews. Needs permission; otherwise returns why it could not.
  Future<String?> sendTest() async {
    await refreshPermission();
    if (_permission != NotificationPermission.granted) return 'Notifications are not allowed yet.';
    await notifications.show(AlertNotification(
      id: notificationIdFor('test'),
      threadId: 'test',
      title: 'MeshSonar',
      body: prefs.showText ? 'This is a test notification.' : 'New message',
      payload: '',
      silent: !prefs.sound,
      vibrate: prefs.vibrate,
    ));
    return null;
  }

  static String _clip(String t) => t.length <= previewChars ? t : '${t.substring(0, previewChars)}…';

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(_banners.close());
    pendingOpen.dispose();
    super.dispose();
  }
}
