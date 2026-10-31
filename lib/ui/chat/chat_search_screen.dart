// Global search across every conversation (FTS5 in the chat database). Results show where each message is from.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/models.dart';
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
          onChanged: (v) => setState(() => _results = v.trim().isEmpty ? const [] : widget.controller.service.search(v.trim(), limit: 100)),
        ),
      ),
      body: SafeArea(
        child: q.isEmpty
            ? const EmptyState(icon: Icons.search_rounded, title: 'Search all messages', body: 'Find a word in any channel or conversation. Only messages kept on this phone are searched.')
            : _results.isEmpty
                ? EmptyState(icon: Icons.search_off_rounded, title: 'Nothing found', body: 'No message contains "$q". Check the spelling or try a shorter word.')
                : ListView.separated(
                    key: const Key('global-search-results'),
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final m = _results[i];
                      return ListTile(
                        minTileHeight: 64,
                        title: Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${_where(m)}, ${m.isOutgoing ? 'you' : (m.senderName ?? 'unknown')}, ${dayLabel(context, m.tsLocalMs)}', style: t.textTheme.labelMedium),
                        onTap: () => ConversationScreen.open(context, controller: widget.controller, convKey: m.convKey),
                      );
                    },
                  ),
      ),
    );
  }
}
