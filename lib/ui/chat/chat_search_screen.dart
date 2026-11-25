// Global search across every conversation (FTS5 in the chat database). Results show where each message is from.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/chat_copy.dart';
import '../../chat/models.dart';
import '../design/app_symbols.dart';
import '../widgets.dart' show EmptyState;
import 'conversation_screen.dart';
import 'message_format.dart';

class ChatSearchScreen extends StatefulWidget {
  final ChatController controller;
  const ChatSearchScreen({super.key, required this.controller});

  static Future<void> open(BuildContext context, ChatController controller) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChatSearchScreen(controller: controller)));

  @override
  State<ChatSearchScreen> createState() => _ChatSearchScreenState();
}

class _ChatSearchScreenState extends State<ChatSearchScreen> {
  final TextEditingController _q = TextEditingController();
  List<ChatMessage> _results = const [];

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  static const int _limit = 100;

  void _run(String v) => setState(() => _results = v.trim().isEmpty ? const [] : widget.controller.service.search(v.trim(), limit: _limit));

  String _where(ChatMessage m) {
    final c = widget.controller;
    final s = c.service.conversation(m.convKey);
    if (s != null && s.title.isNotEmpty) return s.title;
    return 'Conversation';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final q = _q.text.trim();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          key: const Key('global-search-field'),
          controller: _q,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(hintText: 'Search all messages', border: InputBorder.none),
          onChanged: _run,
        ),
        actions: [
          // One tap empties the field (the keyboard's backspace is slow for a long word).
          if (q.isNotEmpty)
            IconButton(
              key: const Key('global-search-clear'),
              tooltip: 'Clear',
              icon: const AppSymbolIcon(AppSymbols.xmarkCircleFill, size: 20),
              onPressed: () {
                _q.clear();
                _run('');
              },
            ),
        ],
      ),
      body: SafeArea(
        child: q.isEmpty
            ? const EmptyState(icon: Icons.search_rounded, title: 'Search all messages', body: 'Type a word. Messages on this phone are searched.')
            : _results.isEmpty
                ? EmptyState(icon: Icons.search_off_rounded, title: noMatchesTitle(q), body: noMatchesTextBody)
                : ListView.separated(
                    key: const Key('global-search-results'),
                    // Dragging the list puts the keyboard away, so the results get the whole screen.
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _results.length + 1,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      if (i == 0) {
                        final n = _results.length;
                        return Padding(
                          key: const Key('global-search-count'),
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                          child: Text(n >= _limit ? 'First $_limit matches. Type more to narrow it.' : (n == 1 ? '1 match' : '$n matches'), style: t.textTheme.labelMedium),
                        );
                      }
                      final m = _results[i - 1];
                      return ListTile(
                        minTileHeight: 64,
                        title: Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${_where(m)} · ${m.isOutgoing ? 'You' : (m.senderName ?? 'Unknown')} · ${dayLabel(context, m.tsLocalMs)} ${timeLabel(context, m.tsLocalMs)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.labelMedium,
                        ),
                        trailing: const AppSymbolIcon(AppSymbols.chevronRight, size: 14),
                        onTap: () => ConversationScreen.open(context, controller: widget.controller, convKey: m.convKey, anchorMessageId: m.id),
                      );
                    },
                  ),
      ),
    );
  }
}
