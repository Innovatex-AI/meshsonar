// ConversationScreen: one conversation (a channel, a direct message or a room), shared by every chat entry point.
//
//   ConversationScreen.open(context, controller: chat, convKey: ConvKey.channel(3));
//   ConversationScreen.open(context, controller: chat, convKey: ConvKey.dm(prefix12), title: contact.displayName,
//       anchorMessageId: hit.id);                          // a search hit: lands on that message and flashes it
//
// It reads and writes only through [ChatController] (so: the local chat database and the radio, never the network). The
// title is looked up from the conversation when not given. Embedded (`embedded: true`) it has no bar, for the Chat-in-Drive
// sheet.
//
// Chat plan 4.2: navigation bar with ONE 44 pt title block (avatar, name, route text) that opens the profile / Channel info
// and an ellipsis menu (Search, Route, Mute, Info); grouped bubbles with the time under the last bubble of a run; five
// delivery states as glyph + word; tap a bubble for the info strip; long-press for the context menu; a jump-to-latest capsule;
// a "Retry all" banner for two or more failed; and the composer.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsService;

import '../../app/chat_controller.dart';
import '../../chat/bubble_grouping.dart';
import '../../chat/chat_copy.dart';
import '../../chat/db/message_repository.dart';
import '../../chat/delivery_state.dart';
import '../../chat/events.dart';
import '../../chat/message_info.dart';
import '../../chat/models.dart';
import '../../chat/models.dart' as models show Route;
import '../app.dart' show AppScope;
import '../contacts/dm_route_text.dart';
import '../contacts/message_details.dart' as details;
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/avatar_style.dart';
import '../design/tokens.dart';
import '../radios/rooms/room_joins.dart';
import '../state_widgets.dart';
import 'channel_detail_screen.dart';
import 'channel_flows.dart';
import 'chat_list_actions.dart';
import 'chat_navigation.dart';
import '../design/app_widgets.dart' show TipCard;
import 'composer.dart';
import 'route_broken_card.dart';
import '../../chat/route_health.dart';
import 'message_bubble.dart';
import 'message_format.dart';
import 'message_menu.dart';
import 'hop_names.dart';
import 'message_info_card.dart';
import '../../chat/hop_resolver.dart';

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

  /// Shown in the bar. Null: looked up from the conversation (channel name, contact name).
  final String? title;

  /// Under the title. Null: filled in (DM route text, channel kind and region, room joined state).
  final String? subtitle;

  /// Extra bar buttons (kept for callers that add their own).
  final List<Widget> actions;

  /// A widget above the message list (the room screen shows the join bar there).
  final Widget? header;

  /// No bar (Chat-in-Drive sheet).
  final bool embedded;

  /// Open scrolled to this message and flash it (search hits).
  final String? anchorMessageId;

  const ConversationScreen({
    super.key,
    required this.controller,
    required this.convKey,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.header,
    this.embedded = false,
    this.anchorMessageId,
  });

  static Future<void> open(
    BuildContext context, {
    required ChatController controller,
    required String convKey,
    String? title,
    String? subtitle,
    List<Widget> actions = const [],
    Widget? header,
    String? anchorMessageId,
  }) {
    // Two-column Chat on a wide screen: show it in the right-hand pane instead of pushing a page.
    final pane = ConversationPaneScope.maybeOf(context);
    if (pane != null) {
      pane.show(ConversationScreen(
          key: ValueKey('pane-$convKey'),
          controller: controller,
          convKey: convKey,
          title: title,
          subtitle: subtitle,
          actions: actions,
          header: header,
          anchorMessageId: anchorMessageId));
      return Future<void>.value();
    }
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ConversationScreen(
          controller: controller, convKey: convKey, title: title, subtitle: subtitle, actions: actions, header: header, anchorMessageId: anchorMessageId),
    ));
  }

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  static const int _pageSize = 40;
  List<ChatMessage> _msgs = []; // newest first
  List<BubbleSlot> _slots = const [];
  MessageCursor? _next;
  bool _hasNewer = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  String? _unreadFromId;
  int _unreadCount = 0;
  int _newAway = 0;
  StreamSubscription<ChatEvent>? _sub;
  final ScrollController _scroll = ScrollController();
  bool _showJump = false;
  bool _searching = false;
  final TextEditingController _query = TextEditingController();
  List<ChatMessage> _results = const [];
  String? _expandedId;
  String? _highlightId;
  Timer? _flash;
  GlobalKey? _anchorKey;
  List<String> _failedIds = const [];
  bool _routeBroken = false;
  // Hop names (CR4): the radio's repeaters and rooms, then the network roster. Rebuilt when either changes.
  List<RosterNode> _roster = const [];
  HopResolver? _resolverCache;
  HopResolver get _resolver => _resolverCache ??= hopResolverFor(c.store, c.radioId, _roster);
  ChatNavigator? _navigator;
  final Map<String, MessageBubble> _bubbles = {};

  ChatController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    c.addListener(_onController);
    _sub = c.events.listen(_onEvent);
    _refreshRepeaters();
    _initialLoad();
  }

  void _initialLoad() {
    try {
      final unread = c.service.conversation(widget.convKey)?.unread ?? 0;
      final anchor = widget.anchorMessageId;
      final around = anchor == null ? null : c.service.pageAround(widget.convKey, anchor);
      if (around != null) {
        _setWindow(around.page, hasNewer: around.hasNewer);
        _highlight(anchor!);
      } else {
        _reload(initial: true);
      }
      if (unread > 0 && around == null) {
        // The oldest unread message among those loaded: the marker goes above it.
        final incomingUnread = _msgs.where((m) => !m.isOutgoing && !m.read).toList();
        if (incomingUnread.isNotEmpty) {
          _unreadFromId = incomingUnread.last.id; // list is newest first, so last = oldest
          _unreadCount = incomingUnread.length;
        }
      }
      c.setActiveConversation(widget.convKey);
      c.service.markRead(widget.convKey);
      if (around != null) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAnchor(0));
    } catch (e) {
      _error = e;
      _loading = false;
    }
  }

  void _setWindow(MessagePage page, {bool hasNewer = false}) {
    _msgs = List.of(page.messages);
    _next = page.next;
    _hasNewer = hasNewer;
    _error = null;
    _loading = false;
    _regroup();
  }

  void _reload({bool initial = false}) {
    try {
      final want = initial ? _pageSize : (_msgs.length < _pageSize ? _pageSize : (_msgs.length > 500 ? 500 : _msgs.length));
      _setWindow(c.service.page(widget.convKey, limit: want));
    } catch (e) {
      _error = e;
      _loading = false;
    }
  }

  void _regroup() {
    _slots = groupMessages(_msgs, showSenders: _kind != ConvKind.dm);
    _failedIds = [for (final m in c.store.messages.byState(const [MessageState.failed]) .where((m) => m.convKey == widget.convKey)) m.id];
    _refreshRouteHealth();
  }

  void _refreshRouteHealth() {
    final contact = _kind == ConvKind.dm ? _contact : null;
    _routeBroken = contact != null && routeLooksBroken(c.store, contact);
  }

  /// Contacts changed (a repeater named, moved, added): hop names are worked out again.
  void _refreshRepeaters() => _resolverCache = null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final roster = rosterOf(context);
    if (roster.length != _roster.length) {
      _roster = roster;
      _resolverCache = null;
    }
  }

  /// A hop of how [m] travelled has a known position (the menu then offers Path on map).
  bool _hasMap(ChatMessage m, MessageInfo info) {
    if (info.nodes.any((n) => n.known && n.hasPosition)) return true;
    if (m.convKind == ConvKind.channel && m.repeatsHeard > 0) {
      return repeatViews(m, c.store.messages.repeatsFor(m.id), _resolver).any((v) => v.path.any((n) => n.known && n.hasPosition));
    }
    return false;
  }

  /// The card under a long-pressed bubble; repeats are read only now, when the menu opens.
  Widget _infoCard(ChatMessage m, MessageInfo info, String? peerName) {
    final repeats = m.convKind == ConvKind.channel ? repeatViews(m, c.store.messages.repeatsFor(m.id), _resolver) : const <RepeatView>[];
    return MessageInfoCard(message: m, info: info, repeats: repeats, peer: m.isOutgoing ? (peerName ?? 'Them') : (m.senderName ?? peerName ?? 'Them'));
  }

  Future<void> _openPathMap(ChatMessage m) async {
    final info = messageInfo(m, resolver: _resolver, contact: _kind == ConvKind.dm ? _contact : null);
    if (m.convKind == ConvKind.channel && m.isOutgoing) {
      // Each repeater relayed it on its own: show them as points, no line.
      final seen = <String>{};
      final nodes = <HopNode>[
        for (final v in repeatViews(m, c.store.messages.repeatsFor(m.id), _resolver))
          for (final n in v.path)
            if (seen.add(n.hash)) n,
      ];
      await MessagePathMapScreen.open(context, title: 'Repeaters that relayed it', nodes: nodes, connect: false);
      return;
    }
    await MessagePathMapScreen.open(context, title: m.isOutgoing ? 'Route it took' : 'How it reached you', nodes: info.nodes);
  }

  // ------------------------------------------------------------------ events

  void _onEvent(ChatEvent e) {
    if (!mounted) return;
    switch (e.kind) {
      case ChatEventKind.contactsChanged:
      case ChatEventKind.channelsChanged:
        setState(() {
          _refreshRepeaters();
          _refreshRouteHealth();
        });
      case ChatEventKind.messageUpdated:
        if (e.convKey == widget.convKey && e.messageId != null) _onUpdated(e.messageId!);
      case ChatEventKind.messageAdded:
        if (e.convKey == widget.convKey && e.message != null) _onAdded(e.message!);
      case ChatEventKind.historyDeleted:
        if (e.convKey == widget.convKey || e.convKey == null) {
          setState(() {
            _expandedId = null;
            _reload();
          });
        }
      case ChatEventKind.conversationChanged:
      case ChatEventKind.systemChanged:
        break;
    }
  }

  void _onUpdated(String id) {
    final i = _msgs.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final fresh = c.store.messages.get(id);
    if (fresh == null) return;
    final old = _msgs[i];
    setState(() {
      _msgs[i] = fresh;
      _regroup();
    });
    if (old.state != fresh.state && fresh.isOutgoing) {
      final say = switch (fresh.state) {
        MessageState.acked => 'Delivered',
        MessageState.failed => 'Not delivered',
        _ => null,
      };
      if (say != null) {
        if (fresh.state == MessageState.failed) AppHaptics.error();
        SemanticsService.sendAnnouncement(View.of(context), say, Directionality.of(context));
      }
    }
  }

  void _onAdded(ChatMessage m) {
    if (_msgs.any((x) => x.id == m.id)) return;
    if (_hasNewer) {
      // The window sits in the past: the capsule counts what arrived and takes the person back to the latest.
      setState(() => _newAway += m.isOutgoing ? 0 : 1);
      return;
    }
    setState(() {
      _msgs.insert(0, m);
      _regroup();
      if (!m.isOutgoing && _showJump) _newAway++;
    });
    if (!m.isOutgoing && !_showJump) {
      AppHaptics.soft();
      SemanticsService.sendAnnouncement(View.of(context), '${m.senderName ?? 'New message'}: ${m.text}', Directionality.of(context));
    }
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final far = p.pixels > 400;
    if (far != _showJump) setState(() => _showJump = far);
    if (!far && _newAway > 0 && !_hasNewer) setState(() => _newAway = 0);
    if (p.pixels > p.maxScrollExtent - 300) _loadOlder();
    if (_hasNewer && p.pixels < 300) _loadNewer();
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
        _regroup();
      });
    } catch (_) {
      // leave the cursor: the next scroll tries again
    } finally {
      _loadingMore = false;
    }
  }

  void _loadNewer() {
    if (_loadingMore || _msgs.isEmpty) return;
    _loadingMore = true;
    try {
      final r = c.service.pageAround(widget.convKey, _msgs.first.id, before: 0, after: _pageSize);
      if (r == null) return;
      final fresh = [for (final m in r.page.messages) if (m.id != _msgs.first.id) m];
      setState(() {
        _msgs.insertAll(0, fresh);
        _hasNewer = r.hasNewer;
        if (!_hasNewer) _newAway = 0;
        _regroup();
      });
    } finally {
      _loadingMore = false;
    }
  }

  @override
  void didUpdateWidget(ConversationScreen old) {
    super.didUpdateWidget(old);
    // The wide pane re-uses this state when a different search hit of the same conversation is opened.
    final a = widget.anchorMessageId;
    if (a != null && a != old.anchorMessageId) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _focusMessage(a) : null);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _flash?.cancel();
    c.removeListener(_onController);
    if (c.activeConversation == widget.convKey) c.setActiveConversation(null);
    _scroll.dispose();
    _query.dispose();
    _navigator?.dispose();
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

  Contact? get _contact {
    final radio = c.radioId;
    if (_kind == ConvKind.channel || radio == null) return null;
    return c.store.contacts.byPrefix(radio, ConvKey.body(widget.convKey));
  }

  double? get _lastSnr {
    for (final m in _msgs) {
      if (!m.isOutgoing && m.snr != null) return m.snr;
    }
    return null;
  }

  Widget _subtitle() {
    if (widget.subtitle != null) {
      return Text(widget.subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted));
    }
    switch (_kind) {
      case ConvKind.dm:
        return DmRouteText(contact: _contact, lastSnr: _lastSnr);
      case ConvKind.channel:
        return Text(channelSubtitle(_channel), key: const Key('conv-subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted));
      case ConvKind.room:
        final key = _contact?.publicKey;
        final joined = key != null && RoomJoins.of(key) != null;
        return Text(roomSubtitle(joined: joined), key: const Key('conv-subtitle'), maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.footnote.copyWith(color: AppColors.of(context).textMuted));
    }
  }

  List<String> get _mentionNames {
    if (_kind != ConvKind.channel) return const [];
    final seen = <String>{};
    for (final m in _msgs) {
      if (!m.isOutgoing && m.senderName != null) seen.add(m.senderName!);
      if (seen.length >= 8) break;
    }
    return seen.toList();
  }

  // ------------------------------------------------------------------ actions

  ChatNavigator get _nav => _navigator ??= ChatNavigator(c);

  /// Title block tap and the ellipsis "Contact info" / "Channel info".
  void _openInfo() {
    final ch = _channel;
    if (ch != null) {
      ChannelDetailScreen.open(context, controller: c, channelId: ch.id!);
      return;
    }
    final contact = _contact;
    if (contact != null) _nav.openProfile(context, contact);
  }

  Future<void> _ellipsis() async {
    final contact = _contact;
    final row = c.conversationRows().where((r) => r.key == widget.convKey).firstOrNull;
    final muted = row?.muted ?? false;
    final choice = await showAppActionSheet<_Menu>(
      context,
      sheetKey: const Key('conv-menu'),
      actions: [
        const AppAction('Search in conversation', _Menu.search, symbol: AppSymbols.magnifyingglass, key: Key('menu-search')),
        if (_kind == ConvKind.dm && contact != null) const AppAction('Route', _Menu.route, symbol: AppSymbols.route, key: Key('menu-route')),
        AppAction(muted ? 'Unmute' : 'Mute', _Menu.mute, symbol: muted ? AppSymbols.bell : AppSymbols.bellSlash, key: const Key('menu-mute')),
        AppAction(_kind == ConvKind.channel ? 'Channel info' : 'Contact info', _Menu.info, symbol: AppSymbols.infoCircle, key: const Key('menu-info')),
      ],
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case _Menu.search:
        setState(() {
          _searching = true;
          _query.clear();
          _results = const [];
        });
      case _Menu.route:
        await ChatListActions(c, navigator: _nav).openRoute(context, contact?.publicKey);
      case _Menu.mute:
        await ChatListActions(c, navigator: _nav).muteConversation(context, key: widget.convKey, title: _title, muted: muted);
        if (mounted) setState(() {});
      case _Menu.info:
        _openInfo();
    }
  }

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

  ChatMessage? _byId(String id) => _msgs.where((m) => m.id == id).firstOrNull;

  Future<void> _perform(String id, MessageMenuEntry e) async {
    final m = _byId(id) ?? c.store.messages.get(id);
    if (m == null || !mounted) return;
    switch (e.id) {
      case MessageMenuId.copy:
        await copyText(context, m.text);
      case MessageMenuId.retry:
        AppHaptics.light();
        c.service.retryFailed(m.id);
      case MessageMenuId.cancel:
        c.service.cancel(m.id);
      case MessageMenuId.delete:
        if (await confirmDeleteMessage(context)) c.service.deleteMessage(m.id);
      case MessageMenuId.details:
        await details.showMessageDetails(context, chat: c.service, messageId: m.id);
      case MessageMenuId.pathMap:
        await _openPathMap(m);
      case MessageMenuId.openLink:
        final l = e.link;
        if (l == null) return;
        if (l.toLowerCase().startsWith('meshcore://')) {
          await handleMeshLink(context, c, l);
        } else {
          await _openUrl(l);
        }
    }
  }

  /// Long-press without the context menu: the same entries as an action sheet.
  Future<void> _longPressSheet(String id) async {
    final m = _byId(id);
    if (m == null) return;
    final r = await MessageMenu.showSheet(context, m, hasMap: _hasMap(m, messageInfo(m, resolver: _resolver, contact: _kind == ConvKind.dm ? _contact : null)));
    if (r != null && mounted) await _perform(id, r);
  }

  Future<void> _failedTap(String id) async {
    final choice = await showFailedSheet(context);
    if (choice == null || !mounted) return;
    switch (choice) {
      case FailedChoice.retry:
        AppHaptics.light();
        c.service.retryFailed(id);
      case FailedChoice.details:
        await details.showMessageDetails(context, chat: c.service, messageId: id);
      case FailedChoice.delete:
        if (await confirmDeleteMessage(context)) c.service.deleteMessage(id);
    }
  }

  void _toggleInfo(String id) {
    AppHaptics.selection();
    setState(() => _expandedId = _expandedId == id ? null : id);
  }

  void _retryAll() {
    AppHaptics.light();
    for (final id in List.of(_failedIds)) {
      c.service.retryFailed(id);
    }
  }

  void _runSearch(String q) {
    final t = q.trim();
    setState(() => _results = t.isEmpty ? const [] : c.service.search(t, convKey: widget.convKey, limit: 100));
  }

  void _jumpToLatest() {
    AppHaptics.selection();
    if (_hasNewer) {
      setState(() {
        _newAway = 0;
        _reload(initial: true);
      });
    }
    if (_scroll.hasClients) {
      final d = Motion.reduced(context) ? Duration.zero : const Duration(milliseconds: 250);
      if (d == Duration.zero) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(0, duration: d, curve: Curves.easeOut);
      }
    }
  }

  // ------------------------------------------------------------------ anchor

  void _highlight(String id) {
    _highlightId = id;
    _anchorKey = GlobalKey();
    _flash?.cancel();
    _flash = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  /// Lands on [id] in context (search hit): loads the window around it, scrolls there and flashes it.
  void _focusMessage(String id) {
    final r = c.service.pageAround(widget.convKey, id);
    if (r == null) {
      showAppToast(context, 'That message is no longer on this phone.', kind: AppToastKind.error);
      return;
    }
    setState(() {
      _searching = false;
      _setWindow(r.page, hasNewer: r.hasNewer);
      _expandedId = null;
      _highlight(id);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAnchor(0));
  }

  void _scrollToAnchor(int attempt) {
    if (!mounted) return;
    final ctx = _anchorKey?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.5, duration: Duration.zero);
      return;
    }
    if (attempt > 8 || !_scroll.hasClients) return;
    final id = _highlightId;
    final idx = id == null ? -1 : _slots.indexWhere((s) => s.message.id == id);
    if (idx < 0) return;
    // The row is not built yet (the list is lazy): jump near it, then look again next frame.
    _scroll.jumpTo((idx * 84.0).clamp(0.0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAnchor(attempt + 1));
  }

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final body = _searching ? _searchBody(context, colors) : _chatBody(context);
    if (widget.embedded) return ColoredBox(color: colors.surface, child: Column(children: [Expanded(child: body)]));
    return CupertinoPageScaffold(
      backgroundColor: colors.surface,
      navigationBar: _bar(context, colors),
      child: body,
    );
  }

  CupertinoNavigationBar _bar(BuildContext context, AppColors colors) {
    if (_searching) {
      return CupertinoNavigationBar(
        backgroundColor: colors.surface,
        automaticallyImplyLeading: false,
        middle: CupertinoSearchTextField(
          key: const Key('conv-search-field'),
          controller: _query,
          autofocus: true,
          placeholder: 'Search this conversation',
          onChanged: _runSearch,
        ),
        trailing: CupertinoButton(
          key: const Key('conv-search-cancel'),
          padding: EdgeInsets.zero,
          minimumSize: Size.square(Hit.of(context)),
          onPressed: () => setState(() {
            _searching = false;
            _query.clear();
            _results = const [];
          }),
          child: const Text('Cancel'),
        ),
      );
    }
    final ch = _channel;
    final hasInfo = ch != null || _contact != null;
    final canPop = Navigator.canPop(context);
    return CupertinoNavigationBar(
      backgroundColor: colors.surface,
      automaticallyImplyLeading: false,
      leading: canPop
          ? Semantics(
              container: true,
              button: true,
              label: 'Back',
              excludeSemantics: true,
              onTap: () => Navigator.of(context).maybePop(),
              child: CupertinoNavigationBarBackButton(key: const Key('conv-back'), onPressed: () => Navigator.of(context).maybePop()),
            )
          : null,
      border: Border(bottom: BorderSide(color: colors.outline.withValues(alpha: 0.3), width: 0.5)),
      middle: MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.3,
        child: _TitleBlock(
          title: _title,
          seed: ch != null ? 'c:${ch.id}' : (_contact?.publicKey ?? widget.convKey),
          square: _kind != ConvKind.dm,
          subtitle: _subtitle(),
          onTap: hasInfo ? _openInfo : null,
        ),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        ...widget.actions,
        CupertinoButton(
          key: const Key('conv-menu-button'),
          padding: EdgeInsets.zero,
          minimumSize: Size.square(Hit.of(context)),
          onPressed: _ellipsis,
          child: Semantics(label: 'More', child: const AppSymbolIcon(AppSymbols.ellipsisCircle, size: 24)),
        ),
      ]),
    );
  }

  Widget _searchBody(BuildContext context, AppColors colors) {
    if (_query.text.trim().isEmpty) {
      return _Empty(symbol: AppSymbols.magnifyingglass, title: 'Search this conversation', body: 'Type a word to find it in the messages kept on this phone.');
    }
    if (_results.isEmpty) {
      return _Empty(symbol: AppSymbols.magnifyingglass, title: noMatchesTitle(_query.text), body: noMatchesTextBody);
    }
    return ListView.builder(
      key: const Key('conv-search-results'),
      itemCount: _results.length,
      itemBuilder: (context, i) {
        final m = _results[i];
        return GestureDetector(
          key: Key('conv-result-${m.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => _focusMessage(m.id),
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.outline.withValues(alpha: 0.2), width: 0.5))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.body.copyWith(color: colors.textPrimary)),
              const SizedBox(height: 2),
              Text('${m.isOutgoing ? 'You' : (m.senderName ?? 'Unknown')}, ${dayLabel(context, m.tsLocalMs, now: c.now())} ${timeLabel(context, m.tsLocalMs)}',
                  style: AppType.footnote.copyWith(color: colors.textMuted)),
            ]),
          ),
        );
      },
    );
  }

  Widget _chatBody(BuildContext context) {
    // On an iPad the conversation is a readable column, not a wall of full-width bubbles.
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: _chatColumn(context)));
  }

  Widget _chatColumn(BuildContext context) {
    final colors = AppColors.of(context);
    final ch = _channel;
    final offRadio = ch != null && ch.slot == null;
    return Column(
      children: [
        if (widget.header != null) widget.header!,
        // The tip needs room: not at large text sizes or on short screens, where the composer already takes the height.
        if (_msgs.isNotEmpty && MediaQuery.textScalerOf(context).scale(17) <= 17 * 1.3 && MediaQuery.sizeOf(context).height >= 600)
          const TipCard(
            tipId: 'conv-details-tip',
            symbol: AppSymbols.infoCircle,
            title: 'See how a message travelled',
            message: 'Tap a message to see its route, signal and time.',
          ),
        Expanded(child: _list(context)),
        if (_routeBroken && _contact != null)
          RouteBrokenCard(contact: _contact!, manager: c.service.contacts, onChanged: () => mounted ? setState(_refreshRouteHealth) : null),
        if (_failedIds.length >= 2)
          Container(
            key: const Key('retry-all-banner'),
            color: colors.surfaceHigh,
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin),
            constraints: BoxConstraints(minHeight: Hit.of(context)),
            child: Row(children: [
              AppSymbolIcon(AppSymbols.exclamationCircleFill, size: 18, color: colors.danger),
              const SizedBox(width: Gap.s),
              Expanded(child: Text('${_failedIds.length} not delivered', style: AppType.subhead.copyWith(color: colors.textPrimary))),
              CupertinoButton(
                key: const Key('retry-all'),
                padding: EdgeInsets.zero,
                minimumSize: Size.square(Hit.of(context)),
                onPressed: _retryAll,
                child: const Text('Retry all'),
              ),
            ]),
          ),
        Composer(
          controller: c,
          convKey: widget.convKey,
          hint: _kind == ConvKind.channel ? 'Message ${_title.length > 24 ? '${_title.substring(0, 24)}…' : _title}' : 'Message',
          mentionNames: _mentionNames,
          onSent: _jumpToLatest,
          onChannelInfoWhenOffRadio: offRadio ? _openInfo : null,
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

    final wide = MediaQuery.sizeOf(context).width >= 700;
    final now = c.now();
    final avatars = _kind != ConvKind.dm;
    final contact = _contact;
    final peerName = contact?.displayName ?? (_kind == ConvKind.dm ? _title : null);
    final extra = _next != null ? 1 : 0;

    return Stack(
      children: [
        ListView.builder(
          key: const Key('conv-list'),
          controller: _scroll,
          reverse: true,
          padding: const EdgeInsets.only(top: Gap.s, bottom: Gap.s),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          itemCount: _slots.length + extra,
          findChildIndexCallback: (key) {
            if (key is ValueKey<String>) {
              final i = _slots.indexWhere((s) => s.message.id == key.value);
              return i < 0 ? null : i;
            }
            return null;
          },
          itemBuilder: (context, i) {
            if (i >= _slots.length) {
              return const Padding(padding: EdgeInsets.all(Gap.l), child: Center(child: CupertinoActivityIndicator()));
            }
            final slot = _slots[i];
            final m = slot.message;
            DeliveryUi? d;
            if (m.isOutgoing) {
              final maxAttempts = (m.state == MessageState.sent || m.state == MessageState.retrying) && m.convKind != ConvKind.channel ? c.store.outbox.get(m.id)?.maxAttempts : null;
              d = deliveryUi(m,
                  radioConnected: c.radioConnected,
                  maxAttempts: maxAttempts,
                  nowMs: now.millisecondsSinceEpoch,
                  viaText: m.state == MessageState.acked && m.convKind != ConvKind.channel ? (m.route == models.Route.flood ? 'searched' : dmRouteText(contact).toLowerCase()) : null);
            }
            final expanded = _expandedId == m.id;
            final info = messageInfo(m, resolver: _resolver, peer: peerName, contact: contact);
            final bubble = MessageBubble(
              key: ValueKey(m.id),
              slot: slot,
              delivery: d,
              showStatus: m.isOutgoing && d != null && (slot.lastOfRun || d.alwaysVisible),
              selfName: c.selfName,
              radioConnected: c.radioConnected,
              avatars: avatars,
              wide: wide,
              expanded: expanded,
              info: expanded ? info : null,
              hasMap: _hasMap(m, info),
              infoCard: () => _infoCard(m, info, peerName),
              highlighted: _highlightId == m.id,
              separatorText: slot.separatorAbove ? separatorLabel(context, m.tsLocalMs, now: now) : '',
              onUrl: _openUrl,
              onMeshLink: (l) => handleMeshLink(context, c, l),
              onTap: _toggleInfo,
              onFailedTap: _failedTap,
              onMenu: _perform,
              onLongPress: _longPressSheet,
              onDetails: (id) => details.showMessageDetails(context, chat: c.service, messageId: id),
            );
            final cached = _bubbles[m.id];
            final MessageBubble shown = cached != null && cached.signature == bubble.signature ? cached : (_bubbles[m.id] = bubble);
            final marked = m.id == _unreadFromId;
            final anchored = m.id == _highlightId && _anchorKey != null;
            if (!marked && !anchored) return shown;
            return Column(
              key: ValueKey('wrap-${m.id}'),
              mainAxisSize: MainAxisSize.min,
              children: [
                if (marked) _UnreadMarker(count: _unreadCount),
                if (anchored) KeyedSubtree(key: _anchorKey, child: shown) else shown,
              ],
            );
          },
        ),
        if (_showJump || _hasNewer)
          Positioned(
            right: Layout.screenMargin,
            bottom: Gap.m,
            child: _JumpCapsule(count: _newAway, onTap: _jumpToLatest),
          ),
      ],
    );
  }

  Widget _empty(BuildContext context) {
    switch (_kind) {
      case ConvKind.channel:
        final ch = _channel;
        final off = ch != null && ch.slot == null;
        return _Empty(
          key: const Key('conv-empty'),
          symbol: AppSymbols.numberSign,
          title: 'No messages in $_title yet',
          body: off
              ? 'This channel is not on your radio right now, so nothing can arrive or be sent. Open Channel info to put it back on the radio.'
              : 'Everyone who has this channel on their radio and is in range of a repeater will see what you write here. Say hello.',
        );
      case ConvKind.room:
        return _Empty(key: const Key('conv-empty'), symbol: AppSymbols.bubbles, title: 'No posts in $_title yet', body: 'Posts to the room are kept by the room server. Write the first one.');
      case ConvKind.dm:
        return _Empty(key: const Key('conv-empty'), symbol: AppSymbols.message, title: 'No messages with $_title yet', body: 'Say hello. You get a Delivered mark when their radio confirms it arrived.');
    }
  }
}

enum _Menu { search, route, mute, info }

/// Avatar 32 + name (headline) with a small chevron + the subtitle, as ONE 44 pt target.
class _TitleBlock extends StatelessWidget {
  final String title;
  final String seed;
  final bool square;
  final Widget subtitle;
  final VoidCallback? onTap;
  const _TitleBlock({required this.title, required this.seed, required this.square, required this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final style = avatarStyle(seed, c);
    final ch = title.trim().isEmpty ? '?' : String.fromCharCode(title.trim().runes.first).toUpperCase();
    final avatar = Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: style.fill, shape: square ? BoxShape.rectangle : BoxShape.circle, borderRadius: square ? BorderRadius.circular(9) : null),
      child: Text(ch, style: AppType.subhead.copyWith(color: style.initials, fontWeight: FontWeight.w600)),
    );
    final content = ConstrainedBox(
      constraints: BoxConstraints(minHeight: Hit.of(context), maxWidth: 260),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        ExcludeSemantics(child: avatar),
        const SizedBox(width: Gap.s),
        Flexible(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.headline.copyWith(color: c.textPrimary))),
              if (onTap != null) Padding(padding: const EdgeInsets.only(left: 2), child: AppSymbolIcon(AppSymbols.chevronRight, size: 12, color: c.textMuted)),
            ]),
            subtitle,
          ]),
        ),
      ]),
    );
    if (onTap == null) return Semantics(container: true, header: true, child: content);
    return Semantics(
      button: true,
      container: true,
      label: title,
      hint: 'Opens details',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(key: const Key('conv-title'), behavior: HitTestBehavior.opaque, onTap: onTap, child: content),
    );
  }
}

/// The jump-to-latest capsule (44 pt tall) with the count of messages that arrived meanwhile.
class _JumpCapsule extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _JumpCapsule({required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      button: true,
      label: count > 0 ? 'Jump to the latest message, $count new' : 'Jump to the latest message',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: const Key('conv-jump'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: Hit.of(context), minWidth: Hit.of(context)),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: c.surfaceHigh,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: c.outline.withValues(alpha: 0.4), width: 0.5),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            AppSymbolIcon(AppSymbols.chevronDown, size: 16, color: c.accent),
            if (count > 0) ...[
              const SizedBox(width: 6),
              Text(count > 99 ? '99+' : '$count', key: const Key('conv-jump-count'), style: AppType.num(15).copyWith(color: c.textPrimary)),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final AppSymbol symbol;
  final String title;
  final String body;
  const _Empty({super.key, required this.symbol, required this.title, required this.body});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AppSymbolIcon(symbol, size: 48, color: c.textMuted),
            const SizedBox(height: Gap.m),
            Text(title, textAlign: TextAlign.center, style: AppType.headline.copyWith(color: c.textPrimary)),
            const SizedBox(height: Gap.s),
            Text(body, textAlign: TextAlign.center, style: AppType.subhead.copyWith(color: c.textMuted)),
          ]),
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
    final c = AppColors.of(context);
    return Semantics(
      container: true,
      label: count == 1 ? '1 new message below' : '$count new messages below',
      child: ExcludeSemantics(
        child: Padding(
          key: const Key('unread-marker'),
          padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
          child: Row(children: [
            Expanded(child: Container(height: 1, color: c.accent)),
            Flexible(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                child: Text(count == 1 ? '1 new message' : '$count new messages', textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.accent, fontWeight: FontWeight.w700)),
              ),
            ),
            Expanded(child: Container(height: 1, color: c.accent)),
          ]),
        ),
      ),
    );
  }
}
