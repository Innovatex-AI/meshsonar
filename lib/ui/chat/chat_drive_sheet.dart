// Chat-in-Drive: a half-height sheet over the Map tab's drive controls. It lists the conversations with unread messages
// (else the latest ones) and opens one with a quick composer. The composer follows the passenger rule (design 1.3):
// while the car is moving it is replaced by "I'm a passenger". The sheet never blocks pings.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/models.dart';
import '../theme.dart';
import '../widgets.dart' show EmptyState;
import 'chat_row.dart';
import 'conversation_screen.dart';
import 'message_format.dart';

Future<void> showChatDriveSheet(BuildContext context, ChatController controller) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (ctx) => FractionallySizedBox(heightFactor: 0.55, child: ChatDriveSheet(controller: controller)),
  );
}

class ChatDriveSheet extends StatefulWidget {
  final ChatController controller;
  const ChatDriveSheet({super.key, required this.controller});
  @override
  State<ChatDriveSheet> createState() => _ChatDriveSheetState();
}

class _ChatDriveSheetState extends State<ChatDriveSheet> {
  ConversationSummary? _open;

  ChatController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final open = _open;
    if (open != null) {
      return Column(
        key: const Key('drive-chat-conversation'),
        children: [
          Row(children: [
            IconButton(
              key: const Key('drive-chat-back'),
              tooltip: 'Back to messages',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => setState(() => _open = null),
            ),
            Expanded(child: Text(open.title, style: t.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
          Expanded(child: ConversationScreen(controller: c, convKey: open.key, title: open.title, embedded: true)),
        ],
      );
    }
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final all = c.service.conversations();
        final unread = all.where((s) => s.unread > 0).toList();
        final shown = unread.isNotEmpty ? unread : all.take(4).toList();
        return Column(
          key: const Key('drive-chat-sheet'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
              child: Text(unread.isNotEmpty ? 'Unread messages' : 'Messages', style: t.textTheme.titleLarge),
            ),
            if (c.driving && c.composerLocked)
              Padding(
                padding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.s),
                child: Text('Typing is off while the car is moving. Reading is fine.', key: const Key('drive-chat-locked'), style: t.textTheme.bodyMedium),
              ),
            Expanded(
              child: shown.isEmpty
                  ? const EmptyState(icon: Icons.chat_bubble_outline_rounded, title: 'No messages yet', body: 'Messages from your channels and contacts show up here while you drive.')
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final s = shown[i];
                        return Semantics(
                          container: true,
                          button: true,
                          label: '${s.title}${s.unread > 0 ? ', ${s.unread} unread' : ''}. ${s.lastPreview ?? ''}',
                          child: ExcludeSemantics(
                            child: ChatRow(
                              key: Key('drive-chat-row-${s.key}'),
                              leading: Icon(s.kind == ConvKind.channel ? Icons.tag_rounded : Icons.person_outline_rounded),
                              title: Text(s.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: s.unread > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null),
                              subtitle: Text(s.lastPreview ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                              stamp: listStamp(context, s.lastTsMs, now: c.now()),
                              badge: s.unread > 0 ? Badge(label: Text('${s.unread}')) : null,
                              onTap: () => setState(() => _open = s),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
