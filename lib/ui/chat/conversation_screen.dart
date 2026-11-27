// ConversationScreen: one conversation (a channel, a direct message or a room), shared by every chat entry point.
//
//   ConversationScreen.open(context, controller: chat, convKey: ConvKey.channel(3));
//   ConversationScreen.open(context, controller: chat, convKey: ConvKey.dm(prefix12), title: contact.displayName,
//       anchorMessageId: hit.id);                          // a search hit: lands on that message and flashes it
//
// It reads and writes only through [ChatController] (so: the local chat database and the radio, never the network). The
// title is looked up from the conversation when not given.
//
// Chat plan 4.2: navigation bar with ONE 44 pt title block (avatar, name, route text) that opens the profile / Channel info
// and an ellipsis menu (Search, Route, Mute, Info); grouped bubbles with the time under the last bubble of a run; five
// delivery states as glyph + word; tap a bubble for the info strip; long-press for the context menu; a jump-to-latest capsule;
// a "Retry all" banner for two or more failed; and the composer.
//
// Build 77 (round 3): the status line counts "try n of m" from the delivery engine's own progress and has a Cancel while a
// message is still being tried; a thread with someone who has never confirmed a message says "They need to add you as a
// contact before they can receive this" (rule 16); a full radio contact list is said, with a way to manage it (D1); a
// thread with unread messages opens AT the first unread with the true count (C-U4); a MeshTrack group's thread has a
// people button to its group (C-U7); friends' position updates in a channel that is not a group are one line and an
// offer, never a bubble each (C-U2).
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
import '../../alerts/alert_coordinator.dart' show alertPreviewText, isPositionUpdate;
import '../../core/meshtrack/meshtrack_service.dart' show MeshTrackService, MtStrayShare;
import '../contacts/radio_list_sheet.dart' show showRadioListSheet;
import '../meshtrack/group_sheet.dart' show showGroupSheet;
import '../meshtrack/meshtrack_binding.dart' show MeshTrackUi, MtGroupOpResult;
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
import '../design/app_widgets.dart' show TipCard, appTipStore;
import 'composer.dart';
import '../../core/photo_api.dart' show anyPhotoIdOf;
import 'photo_widgets.dart';
import '../../app/photo_controller.dart';
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

  /// Open scrolled to this message and flash it (search hits).
  final String? anchorMessageId;

  /// Photo messages; null = [PhotoWiring.controller] (tests inject one).
  final PhotoController? photos;

  const ConversationScreen({
    super.key,
    required this.controller,
    required this.convKey,
    this.title,
    this.subtitle,
    this.actions = const [],
    this.header,
    this.anchorMessageId,
    this.photos,
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
  GlobalKey? _unreadKey;

  /// Runs of friends' position updates stored as chat by an older build (C-U2): the newest of a run draws ONE line with
  /// the count, the rest of the run draws nothing.
  Map<String, int> _positionRunHead = const {};
  Set<String> _positionRunHidden = const {};
  MeshTrackService? _mt;
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

  /// Wakes the screen once when a visible message's status changes by the clock alone (Waiting for confirmation gains its try count; No repeater heard it).
  Timer? _deliveryTick;
  int? _deliveryTickAt;
  GlobalKey? _anchorKey;
  List<String> _failedIds = const [];
  // Hop names (CR4): the radio's repeaters and rooms, then the network roster. Rebuilt when either changes.
  List<RosterNode> _roster = const [];
  HopResolver? _resolverCache;
  HopResolver get _resolver => _resolverCache ??= hopResolverFor(c.store, c.radioId, _roster);
  ChatNavigator? _navigator;
  final Map<String, MessageBubble> _bubbles = {};

  ChatController get c => widget.controller;
  PhotoController? _photosBound;
  PhotoController? get _photos => widget.photos ?? PhotoWiring.controller.value;

  void _onPhotos() {
    if (!mounted) return;
    _bubbles.clear(); // the auto-load switch and own ids change what bubbles show
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _photosBound = _photos?..addListener(_onPhotos);
    unawaited(_photosBound?.refreshConfig());
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
      var toUnread = false;
      if (around != null) {
        _setWindow(around.page, hasNewer: around.hasNewer);
        _highlight(anchor!);
      } else {
        // C-U4: with unread messages the thread opens AT the first unread, with the true count. (Build 76 opened at the
        // bottom and counted only the unread among the 40 loaded, so 63 unread read "40 new messages".)
        final first = unread > 0 ? _findFirstUnread(unread) : null;
        final win = first == null ? null : c.service.pageAround(widget.convKey, first.id, before: _unreadContext, after: _pageSize);
        if (first != null && win != null) {
          _setWindow(win.page, hasNewer: win.hasNewer);
          _unreadFromId = first.id;
          _unreadCount = first.count;
          _unreadKey = GlobalKey();
          toUnread = true;
        } else {
          _reload(initial: true);
        }
      }
      c.setActiveConversation(widget.convKey);
      c.service.markRead(widget.convKey);
      if (around != null) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToAnchor(0));
      if (toUnread) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToUnread(0));
    } catch (e) {
      _error = e;
      _loading = false;
    }
  }

  /// Read messages shown above the "new messages" line, for context.
  static const int _unreadContext = 8;

  /// The oldest unread incoming message of this conversation and how many unread there are, found by walking back from
  /// the newest message ([unread] is the conversation's own count, so the walk stops as soon as all are seen). Null when
  /// none is found (the conversation was only marked unread by hand).
  ({String id, int count})? _findFirstUnread(int unread) {
    String? oldest;
    var seen = 0;
    MessageCursor? cursor;
    for (var pages = 0; pages < 60; pages++) {
      final page = c.service.page(widget.convKey, before: cursor, limit: 200);
      for (final m in page.messages) {
        if (!m.isOutgoing && !m.read) {
          oldest = m.id;
          seen++;
        }
      }
      cursor = page.next;
      if (seen >= unread || cursor == null) break;
    }
    return oldest == null ? null : (id: oldest, count: seen);
  }

  /// Lands on the "new messages" line: it sits near the top of the screen with the unread messages under it.
  void _scrollToUnread(int attempt) {
    if (!mounted) return;
    final ctx = _unreadKey?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.9, duration: Duration.zero);
      return;
    }
    if (attempt > 8 || !_scroll.hasClients) return;
    final id = _unreadFromId;
    final idx = id == null ? -1 : _slots.indexWhere((s) => s.message.id == id);
    if (idx < 0) return;
    // The row is not built yet (the list is lazy): jump near it, then look again next frame.
    _scroll.jumpTo((idx * 84.0).clamp(0.0, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToUnread(attempt + 1));
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
    _groupPositionRuns();
  }

  /// C-U2: consecutive position updates from one friend become one line. (Since build 77 such updates are not stored as
  /// chat at all; this folds the ones an older build stored.)
  void _groupPositionRuns() {
    if (_kind != ConvKind.channel) return;
    final head = <String, int>{};
    final hidden = <String>{};
    var i = 0;
    while (i < _msgs.length) {
      final m = _msgs[i];
      if (m.isOutgoing || !isPositionUpdate(m.text)) {
        i++;
        continue;
      }
      var n = 1;
      while (i + n < _msgs.length && !_msgs[i + n].isOutgoing && _msgs[i + n].senderName == m.senderName && isPositionUpdate(_msgs[i + n].text)) {
        hidden.add(_msgs[i + n].id);
        n++;
      }
      head[m.id] = n;
      i += n;
    }
    _positionRunHead = head;
    _positionRunHidden = hidden;
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
    // MeshTrack (when it is in this build): the people button of a group's thread and the one line for friends' position
    // updates follow the service.
    final mt = MeshTrackUi.of(context)?.service;
    if (!identical(mt, _mt)) {
      _mt?.removeListener(_onMeshTrack);
      _mt = mt;
      mt?.addListener(_onMeshTrack);
    }
  }

  void _onMeshTrack() {
    if (mounted) setState(() {});
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
        setState(_refreshRepeaters);
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
      SemanticsService.sendAnnouncement(View.of(context), '${m.senderName ?? 'New message'}: ${alertPreviewText(m.text)}', Directionality.of(context));
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
    _deliveryTick?.cancel();
    c.removeListener(_onController);
    _mt?.removeListener(_onMeshTrack);
    _photosBound?.removeListener(_onPhotos);
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
        // Pin and delete used to need a swipe or a long-press in the list: here they are one tap away.
        if (row != null && !row.isSystem)
          AppAction(row.pinned ? 'Unpin' : 'Pin to top', _Menu.pin, symbol: row.pinned ? AppSymbols.pinFill : AppSymbols.pin, key: const Key('menu-pin')),
        if (_channel != null || contact != null)
          AppAction(_kind == ConvKind.channel ? 'Channel info' : 'Contact info', _Menu.info, symbol: AppSymbols.infoCircle, key: const Key('menu-info')),
        if (row != null && !row.isSystem && (row.isChannel || row.hasHistory))
          AppAction(row.isChannel ? 'Delete channel' : 'Clear messages', _Menu.delete, destructive: true, symbol: AppSymbols.trash, key: const Key('menu-delete')),
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
      case _Menu.pin:
        if (row != null) ChatListActions(c, navigator: _nav).togglePin(row);
      case _Menu.info:
        _openInfo();
      case _Menu.delete:
        if (row == null) return;
        final gone = await ChatListActions(c, navigator: _nav).delete(context, row);
        // A deleted channel has nothing left to show: back to the list.
        if (gone && row.isChannel && mounted && Navigator.canPop(context)) Navigator.of(context).pop();
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

  void _openPhoto(String url) {
    final p = _photos;
    if (p != null) unawaited(PhotoViewerScreen.open(context, url: url, photos: p));
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
      case MessageMenuId.resend:
        _resend(m.id);
      case MessageMenuId.cancel:
        _cancel(m.id);
      case MessageMenuId.delete:
        deleteMessageWithUndo(context, c.service, m.id);
      case MessageMenuId.details:
        await _details(m.id);
      case MessageMenuId.pathMap:
        await _openPathMap(m);
      case MessageMenuId.viewPhoto:
      case MessageMenuId.savePhoto:
      case MessageMenuId.sharePhoto:
      case MessageMenuId.reportPhoto:
      case MessageMenuId.deletePhoto:
        final l = e.link;
        final p = _photos;
        if (l == null || p == null) return;
        switch (e.id) {
          case MessageMenuId.viewPhoto:
            await PhotoViewerScreen.open(context, url: l, photos: p);
          case MessageMenuId.savePhoto:
            await savePhotoFlow(context, p.source, l);
          case MessageMenuId.sharePhoto:
            await sharePhotoFlow(context, p.source, l);
          case MessageMenuId.reportPhoto:
            await reportPhotoFlow(context, p, l);
          default:
            await deletePhotoFlow(context, p, l);
        }
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
    final canResend = deliveryUi(m, radioConnected: c.radioConnected, nowMs: c.now().millisecondsSinceEpoch).canResend;
    final p = _photos;
    final r = await MessageMenu.showSheet(context, m,
        hasMap: _hasMap(m, messageInfo(m, resolver: _resolver, contact: _kind == ConvKind.dm ? _contact : null)),
        canResend: canResend,
        canCancel: _canCancel(m),
        photos: p != null,
        isOwnPhoto: (u) => p?.isOwn(anyPhotoIdOf(u) ?? '') ?? false);
    if (r != null && mounted) await _perform(id, r);
  }

  /// A message that is still being tried can be stopped: waiting to go, or (a direct message) sent and waiting for its
  /// confirmation with tries left. The engine says which ([ChatService.deliveryProgress]).
  bool _canCancel(ChatMessage m) {
    if (!m.isOutgoing) return false;
    if (m.isPending) return true;
    return m.convKind != ConvKind.channel && m.state == MessageState.sent && c.service.deliveryProgress(m.id).active;
  }

  void _cancel(String id) {
    AppHaptics.light();
    if (c.service.cancel(id)) showAppToast(context, 'Stopped. It is not sent again.');
  }

  /// D1: the radio's own contact list, where the person chooses what to remove.
  void _manageRadioContacts() => unawaited(showRadioListSheet(context, _nav.contacts));

  /// C-U7: a MeshTrack group's thread opens its group (send my position, where are you) in one tap.
  void _openGroup(int channelId) => unawaited(showGroupSheet(context, channelId: channelId));

  Future<void> _useForMeshTrack(int channelId) async {
    final ops = MeshTrackUi.read(context)?.ops;
    if (ops == null) return;
    final MtGroupOpResult r = await ops.useExistingChannel(channelId);
    if (!mounted) return;
    if (r.ok) {
      showAppToast(context, 'This channel is now a MeshTrack group.', kind: AppToastKind.success);
    } else {
      showAppToast(context, r.message ?? 'Could not use this channel for MeshTrack. Try again.', kind: AppToastKind.error);
    }
  }

  Future<void> _failedTap(String id) async {
    final choice = await showFailedSheet(context);
    if (choice == null || !mounted) return;
    switch (choice) {
      case FailedChoice.retry:
        AppHaptics.light();
        c.service.retryFailed(id);
      case FailedChoice.details:
        await _details(id);
      case FailedChoice.delete:
        deleteMessageWithUndo(context, c.service, id);
    }
  }

  /// Full details of one message. A named repeater of its route opens that repeater (C-U8): its profile here when it is
  /// on the radio.
  Future<void> _details(String id) =>
      details.showMessageDetails(context,
          chat: c.service, messageId: id, onOpenContact: (contact) => _nav.openProfile(context, contact), onManageRadioContacts: _manageRadioContacts);

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

  /// Schedules one redraw at the next moment a loaded message's status words change by the clock (nothing else would
  /// redraw a quiet conversation). Only the newest 50 messages are looked at.
  void _armDeliveryTick() {
    final now = c.now().millisecondsSinceEpoch;
    int? next;
    for (final m in _msgs.take(50)) {
      final t = nextDeliveryChangeMs(m);
      if (t != null && t > now && (next == null || t < next)) next = t;
    }
    if (next == _deliveryTickAt) return;
    _deliveryTick?.cancel();
    _deliveryTickAt = next;
    if (next == null) return;
    _deliveryTick = Timer(Duration(milliseconds: next - now + 50), () {
      _deliveryTickAt = null;
      if (mounted) setState(() {});
    });
  }

  void _resend(String id) {
    AppHaptics.light();
    c.service.resendChannel(id);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _armDeliveryTick();
    });
    final colors = AppColors.of(context);
    // CupertinoPageScaffold gives no Material text style: without this, every Text in the thread fell back to Flutter's
    // debug style (yellow double underline), in release builds too.
    final body = Material(type: MaterialType.transparency, child: _searching ? _searchBody(context, colors) : _chatBody(context));
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
          // Same seed as the Chats list row (conversation_row.dart avatarSeed), so a conversation has one colour everywhere.
          seed: ch != null ? '${ch.id}' : (_contact?.publicKey ?? ConvKey.body(widget.convKey)),
          square: _kind != ConvKind.dm,
          subtitle: _subtitle(),
          onTap: hasInfo ? _openInfo : null,
        ),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        ...widget.actions,
        if (ch?.id != null && (_mt?.state.group(ch!.id!) != null))
          CupertinoButton(
            key: const Key('conv-mt-group'),
            padding: EdgeInsets.zero,
            minimumSize: Size.square(Hit.of(context)),
            onPressed: () => _openGroup(ch!.id!),
            child: Semantics(label: 'MeshTrack group', child: const AppSymbolIcon(AppSymbols.person2Fill, size: 22)),
          ),
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
      return _Empty(symbol: AppSymbols.magnifyingglass, title: 'Search this conversation', body: 'Type a word.');
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
                  key: Key('conv-result-time-${m.id}'),
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
        ..._notes(context, colors, ch),
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
          photos: _photos,
          peerName: _kind == ConvKind.dm ? (_contact?.displayName ?? _title) : null,
        ),
      ],
    );
  }

  /// The notes between the messages and the composer, each only when it applies.
  List<Widget> _notes(BuildContext context, AppColors colors, Channel? ch) {
    final out = <Widget>[];
    // C-U2: friends' position updates in a channel that is not a MeshTrack group here: one line, and the offer once.
    final id = ch?.id;
    final stray = id == null ? const <MtStrayShare>[] : (_mt?.strayShares(id) ?? const <MtStrayShare>[]);
    if (stray.isNotEmpty) {
      out.add(_ThreadNote(
        key: const Key('stray-positions'),
        symbol: AppSymbols.location,
        text: strayPositionsLine(stray),
      ));
      final tip = 'mt-offer-$id';
      if (!appTipStore.seen(tip)) {
        final canBeGroup = ch!.kind == ChannelKind.private && ch.slot != null;
        out.add(_ThreadNote(
          key: const Key('stray-offer'),
          symbol: AppSymbols.person2Fill,
          text: canBeGroup
              ? 'Friends are sharing positions here. Use this channel for MeshTrack to see them on the map.'
              : 'Friends are sharing positions here. MeshTrack shows friends on the map in a private channel.',
          actionKey: const Key('stray-offer-use'),
          actionLabel: canBeGroup ? 'Use for MeshTrack' : null,
          onAction: canBeGroup
              ? () {
                  appTipStore.markSeen(tip);
                  unawaited(_useForMeshTrack(id!));
                }
              : null,
          onDismiss: () => setState(() => appTipStore.markSeen(tip)),
        ));
      }
    }
    if (_kind == ConvKind.dm) {
      // D1: the radio refused a contact because its list is full. Nothing is removed to make room; the person chooses.
      if (c.radioContactListFull) {
        out.add(_ThreadNote(
          key: const Key('radio-list-full'),
          symbol: AppSymbols.exclamationTriangle,
          warning: true,
          text: '$radioContactListFullText. A message to someone who is not on it cannot be sent until you remove a contact from the radio.',
          actionKey: const Key('radio-list-manage'),
          actionLabel: 'Manage radio contacts',
          onAction: _manageRadioContacts,
        ));
      }
      // Rule 16: they have never confirmed a message from us. Their radio can only read and confirm our messages once
      // it has us as a contact. Gone for good after the first confirmation.
      if (c.needsToAddYou(widget.convKey)) {
        out.add(const _ThreadNote(key: Key('needs-add-you'), symbol: AppSymbols.personBadgePlus, text: '$needsToAddYouText.'));
      }
    }
    return out;
  }

  Widget _list(BuildContext context) {
    if (_loading) return const LoadingState(message: 'Opening the conversation');
    if (_error != null) {
      return ErrorState(
        title: 'Could not open this conversation',
        message: 'Your messages are not lost. Try again.',
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
            if (_positionRunHidden.contains(m.id)) return SizedBox.shrink(key: ValueKey(m.id));
            final run = _positionRunHead[m.id];
            if (run != null) return _PositionRunLine(key: ValueKey(m.id), name: m.senderName, updates: run);
            DeliveryUi? d;
            var cancellable = false;
            if (m.isOutgoing) {
              // "Try n of m" is read from the delivery engine (the plan the message started with: direct tries, then the
              // flood tries), never worked out here.
              final trying = m.convKind != ConvKind.channel && (m.state == MessageState.sent || m.state == MessageState.retrying || m.state == MessageState.sending);
              final progress = trying ? c.service.deliveryProgress(m.id) : null;
              final maxAttempts = progress?.tryCount;
              cancellable = m.isPending || (progress?.active ?? false);
              d = deliveryUi(m,
                  radioConnected: c.radioConnected,
                  maxAttempts: maxAttempts,
                  nowMs: now.millisecondsSinceEpoch,
                      // How it went is what the radio reported for the try that got through (rule 11).
                  viaText: m.state == MessageState.acked && m.convKind != ConvKind.channel
                      ? (m.route == models.Route.flood ? 'by flood' : (contact != null && contact.hasPath ? dmRouteText(contact).toLowerCase() : null))
                      : null);
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
              stamp: expanded ? '${m.isOutgoing ? 'Sent' : 'Received'} ${messageStamp(m.tsLocalMs, now: now)}' : null,
              onCancel: cancellable ? _cancel : null,
              hasMap: _hasMap(m, info),
              infoCard: () => _infoCard(m, info, peerName),
              onResend: _resend,
              highlighted: _highlightId == m.id,
              separatorText: slot.separatorAbove ? separatorLabel(context, m.tsLocalMs, now: now) : '',
              onUrl: _openUrl,
              onMeshLink: (l) => handleMeshLink(context, c, l),
              onTap: _toggleInfo,
              onFailedTap: _failedTap,
              onMenu: _perform,
              onLongPress: _longPressSheet,
              onDetails: _details,
              photos: _photos,
              onPhoto: _openPhoto,
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
                if (marked) _UnreadMarker(key: _unreadKey, count: _unreadCount),
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
              ? 'This channel is not on your radio, so nothing can be sent or received. Use the button below to put it back.'
              : 'Everyone on this channel in range will see what you write. Say hello.',
        );
      case ConvKind.room:
        return _Empty(key: const Key('conv-empty'), symbol: AppSymbols.bubbles, title: 'No posts in $_title yet', body: 'The room keeps posts for people who join later. Write the first one.');
      case ConvKind.dm:
        return _Empty(key: const Key('conv-empty'), symbol: AppSymbols.message, title: 'No messages with $_title yet', body: 'Say hello. It shows Delivered when their radio gets it.');
    }
  }
}

enum _Menu { search, route, mute, pin, info, delete }

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
  const _UnreadMarker({super.key, required this.count});
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
          // The label takes only its own width (capped, and wrapping at large text sizes), so the two lines share the rest equally
          // and the label sits centred (a loose Flexible slot used to leave its unused width on the right).
          child: LayoutBuilder(
            builder: (context, box) => Row(children: [
              Expanded(child: Container(height: 1, color: c.accent)),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth * 0.7),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                  child: Text(count == 1 ? '1 new message' : '$count new messages',
                      textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.accent, fontWeight: FontWeight.w700)),
                ),
              ),
              Expanded(child: Container(height: 1, color: c.accent)),
            ]),
          ),
        ),
      ),
    );
  }
}


/// "Jo shared their position · 6 updates" / "Jo and Sam shared their positions · 9 updates" for friends heard in a
/// channel that is not a MeshTrack group on this phone (C-U2).
String strayPositionsLine(List<MtStrayShare> shares) {
  if (shares.isEmpty) return '';
  final total = shares.fold<int>(0, (n, s) => n + s.updates);
  final names = [for (final s in shares) s.name];
  final who = switch (names.length) {
    1 => names.first,
    2 => '${names[0]} and ${names[1]}',
    _ => '${names[0]}, ${names[1]} and ${names.length - 2} ${names.length - 2 == 1 ? 'other' : 'others'}',
  };
  final what = names.length == 1 ? 'shared their position' : 'shared their positions';
  return total == 1 ? '$who $what' : '$who $what · $total updates';
}

/// One centred line for a run of position updates that an older build stored as chat (C-U2).
class _PositionRunLine extends StatelessWidget {
  final String? name;
  final int updates;
  const _PositionRunLine({super.key, required this.name, required this.updates});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final who = name ?? 'Someone';
    final text = updates == 1 ? '$who shared their position' : '$who shared their position · $updates updates';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.xs),
      child: Center(
        child: Text(text, key: const Key('position-run'), textAlign: TextAlign.center, style: AppType.footnote.copyWith(color: c.textMuted)),
      ),
    );
  }
}

/// A one-line note between the messages and the composer, with at most one button and an optional dismiss.
class _ThreadNote extends StatelessWidget {
  final AppSymbol symbol;
  final String text;
  final bool warning;
  final Key? actionKey;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback? onDismiss;
  const _ThreadNote({super.key, required this.symbol, required this.text, this.warning = false, this.actionKey, this.actionLabel, this.onAction, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      width: double.infinity,
      color: c.surfaceHigh,
      padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.s, Gap.xs, Gap.s),
      constraints: BoxConstraints(minHeight: Hit.of(context)),
      child: Row(children: [
        ExcludeSemantics(child: AppSymbolIcon(symbol, size: 18, color: warning ? c.warning : c.textMuted)),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: AppType.footnote.copyWith(color: c.textPrimary))),
        if (actionLabel != null)
          CupertinoButton(
            key: actionKey,
            padding: const EdgeInsets.symmetric(horizontal: Gap.s),
            minimumSize: Size.square(Hit.of(context)),
            onPressed: onAction,
            child: Text(actionLabel!, style: AppType.footnote.copyWith(color: c.accent, fontWeight: FontWeight.w600)),
          ),
        if (onDismiss != null)
          CupertinoButton(
            padding: EdgeInsets.zero,
            minimumSize: Size.square(Hit.of(context)),
            onPressed: onDismiss,
            child: Semantics(label: 'Dismiss', child: AppSymbolIcon(AppSymbols.xmark, size: 16, color: c.textMuted)),
          ),
        if (actionLabel == null && onDismiss == null) const SizedBox(width: Gap.s),
      ]),
    );
  }
}
