// Chat wiring: the one place that connects the chat layer (lib/chat, lib/app/chat_controller.dart) to AppState and the
// shell. Call [ChatWiring.attach] once at startup (main.dart). Chat uses only the local database and the radio: no key, no
// server.
//
//   * opens the chat store and builds ChatService + ChatController (retention applied at startup);
//   * follows the radio session: on connect it binds the adapter, syncs channel slots, drains the radio's queue; on a drop
//     it unbinds and the outbox keeps waiting; a reconnect (a new session object) binds again and resumes;
//   * feeds the drive facts (driving, speed) to the passenger lock;
//   * counts the pings this phone sent on the System (wardrive) channel row;
//   * publishes the controller in [ChatWiring.controller] and, through lib/ui/chat/chat_tab_provider.dart, the Chat tab
//     in [ChatTabHost.provider].
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../alerts/alerts_runtime.dart';
import '../chat/chat_service.dart';
import '../core/model.dart' show PingKind;
import '../ui/chat/chat_tab_provider.dart';
import '../ui/chat/conversation_screen.dart';
import '../ui/shell/chat_tab_host.dart';
import 'app_state.dart';
import 'chat_controller.dart';

class ChatWiring {
  ChatWiring._();

  /// The live controller; null until the store is open (or when the build has no chat store, as in tests).
  static final ValueNotifier<ChatController?> controller = ValueNotifier<ChatController?>(null);

  static StreamSubscription<dynamic>? _sessions;
  static VoidCallback? _appListener;
  static AppState? _app;

  /// Opens chat for [app]. Safe to call once; returns the controller (null when this build has no chat store).
  static Future<ChatController?> attach(AppState app) async {
    final open = app.services.openChatStore;
    if (open == null) return null;
    if (controller.value != null) return controller.value;
    final store = await open();
    final sink = SwitchableSink();
    late final ChatController ctl;
    final service = ChatService(
      store: store,
      sink: sink,
      selfName: () => ctl.selfName,
      nowMs: () => app.services.clock().millisecondsSinceEpoch,
    );
    ctl = ChatController(
      store: store,
      service: service,
      sink: sink,
      wardriveChannelName: () => app.settings.channel,
      now: app.services.clock,
    );
    service.start();
    service.applyRetention();
    _app = app;

    ctl.updateDrive(driving: app.driving);
    _appListener = () {
      final fix = app.status.lastFix;
      ctl.updateDrive(driving: app.driving, sessionId: app.currentSession?.id, speedMps: fix?.speedMps, fixAt: fix?.at);
    };
    app.addListener(_appListener!);

    app.onTxPing = (ping) {
      if (ping.kind != PingKind.tx) return;
      final id = ctl.radioId;
      if (id == null) return;
      for (final c in store.channels.systemChannels(id)) {
        if (c.slot != null) {
          service.recordOwnPing(id, c.slot!);
          break;
        }
      }
    };

    _sessions = app.radioSessions.sessions.listen((s) => unawaited(ctl.onSession(s, arbiter: app.radioSessions.arbiter)));
    if (app.radioSession != null) unawaited(ctl.onSession(app.radioSession, arbiter: app.radioSessions.arbiter));

    // Alerts (M3): notifications and banners come from this service's events; a tap opens the conversation.
    final alerts = AlertsHost.runtime.value;
    if (alerts != null) {
      alerts.bindChat(service);
      ctl.onActiveConversationChanged = alerts.coordinator.setVisibleConversation;
    }
    ChatTabHost.openConversation = (context, convKey) => ConversationScreen.open(context,
        controller: ctl, convKey: convKey, title: service.conversation(convKey)?.title);

    controller.value = ctl;
    ChatTabHost.provider.value = ChatTabProviderImpl(ctl);
    return ctl;
  }

  /// Tears the wiring down (tests, or a wipe of chat data).
  static Future<void> detach() async {
    await _sessions?.cancel();
    _sessions = null;
    final l = _appListener;
    if (l != null) _app?.removeListener(l);
    _appListener = null;
    _app?.onTxPing = null;
    _app = null;
    ChatTabHost.provider.value = null;
    ChatTabHost.openConversation = null;
    final c = controller.value;
    controller.value = null;
    c?.dispose();
  }
}
