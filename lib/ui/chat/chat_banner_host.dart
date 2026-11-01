// In-app banner for a new message that deserves attention (the notify rules of ChatService: not muted, not the
// conversation on screen). It never takes focus or blocks the drive controls: it slides in at the top, a tap opens the
// conversation, it goes away by itself. Screen readers get it as a live announcement. System (wardrive) traffic never
// produces one.
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../alerts/alerts_runtime.dart' show AlertsHost;
import '../../app/chat_controller.dart';
import '../../app/chat_wiring.dart';
import '../../chat/models.dart';
import '../theme.dart';
import 'conversation_screen.dart';

class ChatBannerHost extends StatefulWidget {
  final Widget child;

  /// Overrides the wiring (tests).
  final ValueListenable<ChatController?>? controllerListenable;
  final Duration visibleFor;
  const ChatBannerHost({super.key, required this.child, this.controllerListenable, this.visibleFor = const Duration(seconds: 6)});

  @override
  State<ChatBannerHost> createState() => _ChatBannerHostState();
}

class _ChatBannerHostState extends State<ChatBannerHost> {
  StreamSubscription<ChatMessage>? _sub;
  ChatController? _ctl;
  ChatMessage? _shown;
  Timer? _timer;

  ValueListenable<ChatController?> get _source => widget.controllerListenable ?? ChatWiring.controller;

  @override
  void initState() {
    super.initState();
    _source.addListener(_rebind);
    _rebind();
  }

  void _rebind() {
    final c = _source.value;
    if (identical(c, _ctl)) return;
    _sub?.cancel();
    _ctl = c;
    _sub = c?.incoming.listen(_onMessage);
  }

  void _onMessage(ChatMessage m) {
    if (!mounted) return;
    // One banner per message: when the alerts layer is running it owns the in-app banner (it honours the Notifications
    // settings: off, muted, quiet hours, privacy). This one is the fallback for a build without it.
    if (widget.controllerListenable == null && AlertsHost.runtime.value != null) return;
    _timer?.cancel();
    setState(() => _shown = m);
    _timer = Timer(widget.visibleFor, () {
      if (mounted) setState(() => _shown = null);
    });
  }

  @override
  void dispose() {
    _source.removeListener(_rebind);
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  String _title(ChatMessage m) {
    final c = _ctl;
    final conv = c?.service.conversation(m.convKey)?.title ?? 'New message';
    if (m.convKind == ConvKind.channel && m.senderName != null) return '${m.senderName} in $conv';
    return m.senderName ?? conv;
  }

  @override
  Widget build(BuildContext context) {
    final m = _shown;
    return Stack(
      children: [
        widget.child,
        if (m != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.all(Gap.s),
                child: Dismissible(
                  key: ValueKey('banner-${m.id}'),
                  direction: DismissDirection.up,
                  onDismissed: (_) => setState(() => _shown = null),
                  child: Semantics(
                  liveRegion: true,
                  container: true,
                  label: 'New message from ${_title(m)}: ${m.text}',
                  child: Material(
                    key: const Key('chat-banner'),
                    elevation: 6,
                    borderRadius: BorderRadius.circular(Corners.card),
                    color: Theme.of(context).colorScheme.inverseSurface,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Corners.card),
                      onTap: () {
                        final c = _ctl;
                        setState(() => _shown = null);
                        if (c != null) ConversationScreen.open(context, controller: c, convKey: m.convKey);
                      },
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 56),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
                          child: ExcludeSemantics(
                            child: Row(children: [
                              Icon(Icons.chat_bubble_rounded, color: Theme.of(context).colorScheme.onInverseSurface),
                              const SizedBox(width: Gap.m),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                                  Text(_title(m), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface, fontWeight: FontWeight.w700)),
                                  Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: Theme.of(context).colorScheme.onInverseSurface)),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
