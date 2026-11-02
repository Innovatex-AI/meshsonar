// ConversationScreen: one conversation (a channel, a direct message or a room), shared by every chat entry point.
//
//   ConversationScreen.open(context, controller: chat, convKey: ConvKey.channel(3));
//   ConversationScreen.open(context, controller: chat, convKey: ConvKey.dm(prefix12), title: contact.displayName,
//       actions: [IconButton(...contact info...)]);          // the DM / contacts screens add their own app-bar actions
//
// It reads and writes only through [ChatController] (so: the local chat database and the radio, never the network). The
// title is looked up from the conversation when not given. Embedded (`embedded: true`) it has no app bar, for the
// Chat-in-Drive sheet.
//
// What it shows: pages of messages (newest at the bottom, grouped by day, older ones load as you scroll up), an unread
// marker, delivery state under your own messages with Retry / Cancel, long-press actions, message details, search in
// the conversation, and the composer (byte counter, draft, passenger lock).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/db/message_repository.dart';
import '../../chat/events.dart';
import '../../chat/models.dart';
import '../app.dart' show AppScope;
import '../state_widgets.dart';
import '../design/app_surfaces.dart';
import '../theme.dart';
import '../widgets.dart' show EmptyState;
import 'channel_detail_screen.dart';
import 'channel_flows.dart';
import 'composer.dart';
import 'message_bubble.dart';
import 'message_format.dart';
import '../contacts/message_details.dart' as details;
import 'message_sheets.dart';

/// Wide Chat tab (two columns): lists inside it open conversations in the right-hand pane through this.
class ConversationPaneScope extends InheritedWidget {
  final void Function(Widget conversation) show;
  const ConversationPaneScope({super.key, required this.show, required super.child});
  static ConversationPaneScope? maybeOf(BuildContext context) => context.getInheritedWidgetOfExactType<ConversationPaneScope>();
  @override
  bool updateShouldNotify(ConversationPaneScope old) => false;
}

class ConversationScreen extends StatefulWidget {
  final ChatController controller;
  final String convKey;

  /// Shown in the app bar. Null: looked up from the conversation (channel name, contact name).
  final String? title;
  final String? subtitle;

  /// Extra app-bar buttons (the contacts screens add "contact info").
  final List<Widget> actions;

  /// A widget above the message list (the DM screen shows the route state there).
  final Widget? header;

  /// No Scaffold or app bar (Chat-in-Drive sheet).
  final bool embedded;

  const ConversationScreen({
    super.key,
    required this.controller,
    required this.convKey,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.header,
    this.embedded = false,
  });

  static Future<void> open(
    BuildContext context, {
    required ChatController controller,
    required String convKey,
    String? title,
    String? subtitle,
    List<Widget> actions = const [],
    Widget? header,
  }) {
    // Two-column Chat on a wide screen: show it in the right-hand pane instead of pushing a page.
    final pane = ConversationPaneScope.maybeOf(context);
    if (pane != null) {
      pane.show(ConversationScreen(
          key: ValueKey('pane-$convKey'), controller: controller, convKey: convKey, title: title, subtitle: subtitle, actions: actions, header: header));
      return Future<void>.value();
    }
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConversationScreen(controller: controller, convKey: convKey, title: title, subtitle: subtitle, actions: actions, header: header),
    ));
  }

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  static const int _pageSize = 40;
  final List<ChatMessage> _msgs = []; // newest first
  MessageCursor? _next;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  String? _unreadFromId;
  int _unreadCount = 0;
  StreamSubscription<ChatEvent>? _sub;
  Timer? _ticker;
  final ScrollController _scroll = ScrollController();
  bool _showJump = false;
  bool _searching = false;
  final TextEditingController _query = TextEditingController();
  List<ChatMessage> _results = const [];

  ChatController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    c.addListener(_onController);
    _sub = c.events.listen(_onEvent);
    _initialLoad();
  }

  void _initialLoad() {
    try {
      final unread = c.service.conversation(widget.convKey)?.unread ?? 0;
      _reload(initial: true);
      if (unread > 0) {
        // The oldest unread message among those loaded: the marker goes above it.
        final incomingUnread = _msgs.where((m) => !m.isOutgoing && !m.read).toList();
        if (incomingUnread.isNotEmpty) {
          _unreadFromId = incomingUnread.last.id; // list is newest first, so last = oldest
          _unreadCount = incomingUnread.length;
        }
      }
      c.setActiveConversation(widget.convKey);
      c.service.markRead(widget.convKey);
    } catch (e) {
      _error = e;
      _loading = false;
    }
  }

  void _reload({bool initial = false}) {
    try {
      final want = initial ? _pageSize : (_msgs.length < _pageSize ? _pageSize : (_msgs.length > 500 ? 500 : _msgs.length));
      final page = c.service.page(widget.convKey, limit: want);
      _msgs
        ..clear()
        ..addAll(page.messages);
      _next = page.next;
      _error = null;
      _loading = false;
    } catch (e) {
      _error = e;
      _loading = false;
    }
    _syncTicker();
  }

  void _onEvent(ChatEvent e) {
    if (!mounted) return;
    final mine = e.convKey == widget.convKey || e.kind == ChatEventKind.historyDeleted && e.convKey == null;
    if (!mine) return;
    if (e.kind == ChatEventKind.conversationChanged) return; // unread / draft bookkeeping, not content
    setState(() => _reload());
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  void _syncTicker() {
    final pending = _msgs.any((m) => m.isOutgoing && (m.state == MessageState.queued || m.state == MessageState.retrying));
    if (pending && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!pending) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final far = p.pixels > 400;
    if (far != _showJump) setState(() => _showJump = far);
    if (p.pixels > p.maxScrollExtent - 300) _loadOlder();
  }

  void _loadOlder() {
    final cursor = _next;
    if (cursor == null || _loadingMore) return;
    _loadingMore = true;
    try {
      final page = c.service.page(widget.convKey, before: cursor, limit: _pageSize);
      setState(() {
        _msgs.addAll(page.messages);
        _next = page.next;
      });
    } catch (_) {
      // leave the cursor: the next scroll tries again
    } finally {
      _loadingMore = false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    c.removeListener(_onController);
    if (c.activeConversation == widget.convKey) c.setActiveConversation(null);
    _scroll.dispose();
    _query.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ titles

  String get _title {
    if (widget.title != null) return widget.title!;
    final s = c.service.conversation(widget.convKey);
    if (s != null && s.title.isNotEmpty) return s.title;
    if (ConvKey.kindOf(widget.convKey) == ConvKind.channel) {
      final ch = c.store.channels.getById(int.tryParse(ConvKey.body(widget.convKey)) ?? -1);
      if (ch != null) return ch.name;
    }
    return 'Conversation';
  }

  ConvKind get _kind => ConvKey.kindOf(widget.convKey) ?? ConvKind.dm;

  Channel? get _channel => _kind == ConvKind.channel ? c.store.channels.getById(int.tryParse(ConvKey.body(widget.convKey)) ?? -1) : null;

  List<String> get _mentionNames {
    if (_kind != ConvKind.channel) return const [];
    final seen = <String>{};
    for (final m in _msgs) {
      if (!m.isOutgoing && m.senderName != null) seen.add(m.senderName!);
      if (seen.length >= 12) break;
    }
    return seen.toList();
  }

  // ------------------------------------------------------------------ actions

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final open = AppScope.maybeOf(context)?.services.openUrl;
    if (open == null) return;
    final ok = await open(uri);
    if (!ok && mounted) {
      showAppToast(context, 'Could not open that link. Long-press the message to copy it.', kind: AppToastKind.error);
    }
  }

  Future<void> _actions(ChatMessage m) async {
    final r = await showMessageActions(context, m);
    if (r == null || !mounted) return;
    switch (r.$1) {
      case MessageAction.copy:
        await copyText(context, m.text);
      case MessageAction.retry:
        c.service.retryFailed(m.id);
      case MessageAction.cancel:
        c.service.cancel(m.id);
      case MessageAction.delete:
        if (await confirmDeleteMessage(context)) c.service.deleteMessage(m.id);
      case MessageAction.details:
        await details.showMessageDetails(context, chat: c.service, messageId: m.id);
      case MessageAction.openLink:
        final l = r.$2;
        if (l == null) return;
        if (l.toLowerCase().startsWith('meshcore://')) {
          await handleMeshLink(context, c, l);
        } else {
          await _openUrl(l);
        }
    }
  }

  void _runSearch(String q) {
    final t = q.trim();
    setState(() => _results = t.isEmpty ? const [] : c.service.search(t, convKey: widget.convKey, limit: 100));
  }

  void _jumpToLatest() {
    if (_scroll.hasClients) _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final body = _searching ? _searchBody(context) : _chatBody(context);
    if (widget.embedded) return Material(child: Column(children: [Expanded(child: body)]));
    final ch = _channel;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _searching
            ? TextField(
                key: const Key('conv-search-field'),
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(hintText: 'Search this conversation', border: InputBorder.none),
                onChanged: _runSearch,
              )
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_title, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (widget.subtitle != null)
                  Text(widget.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.labelMedium),
              ]),
        actions: [
          IconButton(
            key: const Key('conv-search'),
            tooltip: _searching ? 'Close search' : 'Search this conversation',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
            onPressed: () => setState(() {
              _searching = !_searching;
              _query.clear();
              _results = const [];
            }),
          ),
          if (!_searching) ...widget.actions,
          if (!_searching && ch != null)
            IconButton(
              key: const Key('conv-channel-info'),
              tooltip: 'Channel info',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: () => ChannelDetailScreen.open(context, controller: c, channelId: ch.id!),
            ),
        ],
      ),
      body: SafeArea(bottom: false, child: body),
    );
  }

  Widget _searchBody(BuildContext context) {
    final t = Theme.of(context);
    if (_query.text.trim().isEmpty) {
      return const EmptyState(icon: Icons.search_rounded, title: 'Search this conversation', body: 'Type a word to find it in the messages kept on this phone.');
    }
    if (_results.isEmpty) {
      return EmptyState(icon: Icons.search_off_rounded, title: 'Nothing found', body: 'No message here contains "${_query.text.trim()}". Check the spelling or try a shorter word.');
    }
    return ListView.separated(
      key: const Key('conv-search-results'),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final m = _results[i];
        return ListTile(
          minTileHeight: 56,
          title: Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text('${m.isOutgoing ? 'You' : (m.senderName ?? 'Unknown')}, ${dayLabel(context, m.tsLocalMs, now: c.now())} ${timeLabel(context, m.tsLocalMs)}', style: t.textTheme.labelMedium),
          onTap: () => details.showMessageDetails(context, chat: c.service, messageId: m.id),
        );
      },
    );
  }

  Widget _chatBody(BuildContext context) {
    // On an iPad the conversation is a readable column, not a wall of full-width bubbles.
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: _chatColumn(context)));
  }

  Widget _chatColumn(BuildContext context) {
    return Column(
      children: [
        if (widget.header != null) widget.header!,
        Expanded(child: _list(context)),
        Composer(
          controller: c,
          convKey: widget.convKey,
          hint: _kind == ConvKind.channel ? 'Message ${_title.length > 24 ? '${_title.substring(0, 24)}…' : _title}' : 'Message',
          mentionNames: _mentionNames,
          onSent: _jumpToLatest,
        ),
      ],
    );
  }

  Widget _list(BuildContext context) {
    if (_loading) return const LoadingState(message: 'Opening the conversation');
    if (_error != null) {
      return ErrorState(
        title: 'Could not open this conversation',
        message: 'The messages on this phone could not be read. Your messages are not lost; close this screen and open it again.',
        onRetry: () => setState(() {
          _loading = true;
          _initialLoad();
        }),
      );
    }
    if (_msgs.isEmpty) {
      // Scrollable: at the largest text size the explanation is taller than the room above the composer.
      return LayoutBuilder(
        builder: (context, box) => SingleChildScrollView(child: ConstrainedBox(constraints: BoxConstraints(minHeight: box.maxHeight), child: _empty(context))),
      );
    }

    final items = <Widget>[];
    final me = c.selfName;
    for (var i = 0; i < _msgs.length; i++) {
      final m = _msgs[i];
      final older = i + 1 < _msgs.length ? _msgs[i + 1] : null;
      final sameDay = older != null && dayOf(older.tsLocalMs) == dayOf(m.tsLocalMs);
      final showSender = !m.isOutgoing &&
          _kind != ConvKind.dm &&
          (older == null || !sameDay || older.isOutgoing || older.senderName != m.senderName);
      final due = m.state == MessageState.queued || m.state == MessageState.retrying ? c.store.outbox.get(m.id)?.dueAtMs : null;
      final dueIn = due == null ? null : due - c.now().millisecondsSinceEpoch;
      items.add(MessageBubble(
        key: ValueKey(m.id),
        message: m,
        showSender: showSender,
        selfName: me,
        radioConnected: c.radioConnected,
        dueInMs: dueIn,
        onUrl: _openUrl,
        onMeshLink: (l) => handleMeshLink(context, c, l),
        onRetry: () => c.service.retryFailed(m.id),
        onCancel: () => m.state == MessageState.failed ? _deleteFailed(m) : c.service.cancel(m.id),
        onLongPress: () => _actions(m),
      ));
      if (m.id == _unreadFromId) items.add(_UnreadMarker(count: _unreadCount));
      if (older == null || !sameDay) items.add(_DayHeader(label: dayLabel(context, m.tsLocalMs, now: c.now())));
    }
    if (_next != null) items.add(const Padding(padding: EdgeInsets.all(Gap.l), child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)))));

    return Stack(
      children: [
        ListView(
          key: const Key('conv-list'),
          controller: _scroll,
          reverse: true,
          padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.s),
          children: items,
        ),
        if (_showJump)
          Positioned(
            right: Gap.m,
            bottom: Gap.m,
            child: FloatingActionButton.small(
              key: const Key('conv-jump'),
              tooltip: 'Jump to the latest message',
              onPressed: _jumpToLatest,
              child: const Icon(Icons.arrow_downward_rounded),
            ),
          ),
      ],
    );
  }

  Future<void> _deleteFailed(ChatMessage m) async {
    if (await confirmDeleteMessage(context)) c.service.deleteMessage(m.id);
  }

  Widget _empty(BuildContext context) {
    switch (_kind) {
      case ConvKind.channel:
        final ch = _channel;
        final off = ch != null && ch.slot == null;
        return EmptyState(
          key: const Key('conv-empty'),
          icon: Icons.tag_rounded,
          title: 'No messages in $_title yet',
          body: off
              ? 'This channel is not on your radio right now, so nothing can arrive or be sent. Open Channel info to put it back on the radio.'
              : 'Everyone who has this channel on their radio and is in range of a repeater will see what you write here. Say hello.',
        );
      case ConvKind.room:
        return EmptyState(key: const Key('conv-empty'), icon: Icons.forum_outlined, title: 'No posts in $_title yet', body: 'Posts to the room are kept by the room server. Write the first one.');
      case ConvKind.dm:
        return EmptyState(key: const Key('conv-empty'), icon: Icons.chat_bubble_outline_rounded, title: 'No messages with $_title yet', body: 'Say hello. You get a Delivered mark when their radio confirms it arrived.');
    }
  }
}

class _DayHeader extends StatelessWidget {
  final String label;
  const _DayHeader({required this.label});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.s),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.xs),
            decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
            child: Text(label, style: t.textTheme.labelMedium),
          ),
        ),
      ),
    );
  }
}

class _UnreadMarker extends StatelessWidget {
  final int count;
  const _UnreadMarker({required this.count});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Semantics(
      container: true,
      label: count == 1 ? '1 new message below' : '$count new messages below',
      child: ExcludeSemantics(
        child: Padding(
          key: const Key('unread-marker'),
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          child: Row(children: [
            Expanded(child: Divider(color: t.colorScheme.primary)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.s),
              child: Text(count == 1 ? '1 new message' : '$count new messages', style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w700)),
            ),
            Expanded(child: Divider(color: t.colorScheme.primary)),
          ]),
        ),
      ),
    );
  }
}
