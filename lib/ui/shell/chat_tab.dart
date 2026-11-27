// The Chat tab shell (chat plan 3 and 4.1): large title "Chat" with the New button, a pinned sliding segmented control
// Chats | Contacts | Channels (build 71: the Radio segment moved to More > Radio), a collapsing search field, a status banner only when something is wrong, and the segment's
// content as slivers under them. Chats is the default segment and a cold launch always opens it; the chosen segment is
// remembered for the session only.
//
// Wide screens (>= 900 dp of tab width, Split View and Stage Manager included) keep the two-column layout: this shell in a
// 380 dp sidebar and the open conversation in a detail column ([ConversationPaneScope]).
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../chat/chat_list_extras.dart';
import '../chat/conversation_screen.dart' show ConversationPaneScope;
import '../design/app_surfaces.dart' show showAppToast;
import '../design/app_haptics.dart';
import '../design/app_symbols.dart';
import '../design/app_widgets.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../drive/drive_controls.dart' show openConnect;
import 'chat_tab_host.dart';

/// The radio's own network (its card, nodes heard nearby, and the repeaters, rooms and sensors in its contact book with
/// the radio tools) was a fourth segment, "Radio", until build 71; it is More > Radio now (more_radio_screen.dart).
enum ChatShellSegment { chats, contacts, channels }

class ChatTab extends StatelessWidget {
  const ChatTab({super.key});
  @override
  Widget build(BuildContext context) => const RedesignedChatTab();
}

class RedesignedChatTab extends StatefulWidget {
  const RedesignedChatTab({super.key});
  @override
  State<RedesignedChatTab> createState() => RedesignedChatTabState();
}

class RedesignedChatTabState extends State<RedesignedChatTab> {
  /// Remembered for the session (process), never saved: a cold launch starts on Chats.
  static ChatShellSegment _sessionSegment = ChatShellSegment.chats;

  /// Back to a cold launch (tests).
  @visibleForTesting
  static void resetSession() => _sessionSegment = ChatShellSegment.chats;

  /// From this tab width the Chat tab is two columns.
  static const double splitWidth = 900;
  static const double sidebarWidth = 380;

  final _scroll = ScrollController();
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _fixture = DebugFixtureChat();
  Widget? _pane;
  ShellController? _shell;
  int _seenReselect = 0;

  ChatShellSegment get _segment => _sessionSegment;

  ChatTabProvider? get _provider =>
      ChatTabHost.provider.value ?? (chatFixturesAllowed && ChatTabHost.debugFixtures.value ? _fixture : null);

  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = ShellScope.maybeOf(context);
    if (!identical(shell, _shell)) {
      _shell = shell;
      _seenReselect = shell?.reselectCount ?? 0;
    }
    if (shell != null && shell.reselectCount != _seenReselect) {
      _seenReselect = shell.reselectCount;
      // Tapping the Chat tab again: back to the top of the list.
      if (shell.tab == AppTab.chat && _scroll.hasClients && _scroll.offset > 0) {
        _scroll.animateTo(0, duration: Motion.of(context, Motion.sheet), curve: Curves.easeOut);
      }
    }
  }

  void _select(ChatShellSegment s) {
    if (s == _sessionSegment) return;
    AppHaptics.selection(); // segment change (plan 2.2)
    setState(() {
      _sessionSegment = s;
      _search.clear();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([ChatTabHost.provider, ChatTabHost.debugFixtures]),
      builder: (context, _) {
        final p = _provider;
        final c = AppColors.of(context);
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () => _select(ChatShellSegment.chats),
            const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () => _select(ChatShellSegment.contacts),
            const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () => _select(ChatShellSegment.channels),
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () => _searchFocus.requestFocus(),
            if (p != null) SingleActivator(LogicalKeyboardKey.keyN, meta: true): () => _new(context, p),
            // Quick switcher: iPad width only (the split layout), like the other desktop-style shortcuts.
            if (p != null && MediaQuery.sizeOf(context).width >= splitWidth) SingleActivator(LogicalKeyboardKey.keyK, meta: true): () => p.quickSwitch(context),
          },
          child: Focus(
            autofocus: true,
            child: ColoredBox(
              color: c.bg,
              child: p == null ? _noChatYet(context) : _withProvider(context, p),
            ),
          ),
        );
      },
    );
  }

  Widget _noChatYet(BuildContext context) {
    final s = AppScope.of(context);
    return SafeArea(
      child: AppEmptyView(
        key: const Key('chat-empty'),
        symbol: AppSymbols.message,
        // Build 76: the same words as the Chats list's own empty state.
        title: s.connected ? 'Chat is getting ready' : 'Connect a radio to start chatting',
        message: s.connected ? 'Your radio is connected. Chats appear here in a moment.' : 'Messages go out over your MeshCore radio.',
        actionLabel: s.connected ? 'Open Drive' : 'Connect radio',
        onAction: s.connected ? () => ShellScope.maybeRead(context)?.select(AppTab.drive) : () => openConnect(context),
      ),
    );
  }

  Widget _withProvider(BuildContext context, ChatTabProvider p) {
    return ListenableBuilder(
      listenable: p.changes,
      builder: (context, _) => LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < splitWidth) {
            if (_pane != null) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _pane = null);
              });
            }
            return _scrollView(context, p);
          }
          final selected = switch (_pane?.key) {
            ValueKey<String>(value: final v) when v.startsWith('pane-') => v.substring(5),
            _ => null,
          };
          return ConversationPaneScope(
            show: (w) => setState(() => _pane = w),
            child: Row(
              children: [
                SizedBox(width: sidebarWidth, child: _scrollView(context, p, selectedKey: selected)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _pane ??
                      const AppEmptyView(
                        key: Key('chat-pane-empty'),
                        symbol: AppSymbols.message,
                        title: 'Select a conversation',
                        message: 'Pick one on the left, or start a new one.',
                      ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// C-U5: "Mark all read" says what it did and can be undone ("12 marked read · Undo").
  void _markAllRead(BuildContext context, ChatTabProvider p) {
    AppHaptics.light();
    final n = p.unreadMessages;
    final extras = p is ChatListExtras ? p as ChatListExtras : null;
    if (extras == null) {
      p.markAllRead();
      return;
    }
    final undo = extras.markAllReadWithUndo();
    if (undo == null) return;
    showAppToast(context, '$n marked read', actionLabel: 'Undo', onAction: undo);
  }

  /// C-U5: the "Unread 4" chip beside search. Shown while something is unread (or while the filter is on).
  Widget _searchRow(BuildContext context, ChatTabProvider p, ChatShellSegment seg) {
    final field = CupertinoSearchTextField(
      key: const Key('chat-search-field'),
      controller: _search,
      focusNode: _searchFocus,
      placeholder: switch (seg) {
        ChatShellSegment.channels => 'Search channels',
        _ => 'Search chats and messages',
      },
      onChanged: (_) => setState(() {}),
      onSuffixTap: () => setState(_search.clear),
    );
    final extras = p is ChatListExtras ? p as ChatListExtras : null;
    if (seg != ChatShellSegment.chats || extras == null) return field;
    return ValueListenableBuilder<bool>(
      valueListenable: extras.unreadOnly,
      builder: (context, on, _) {
        final n = p.unreadMessages;
        if (n == 0 && !on) return field;
        final c = AppColors.of(context);
        return Row(children: [
          Expanded(child: field),
          const SizedBox(width: Gap.s),
          // The chip keeps to about one and a third of its size at the largest text sizes (like the segment labels), so
          // the search field beside it keeps its room.
          MediaQuery.withClampedTextScaling(
            maxScaleFactor: 1.35,
            child: Semantics(
            button: true,
            selected: on,
            label: on ? 'Showing unread chats only. Show all' : 'Show unread chats only, $n unread',
            excludeSemantics: true,
            onTap: () => _toggleUnread(extras),
            child: CupertinoButton(
              key: const Key('chat-unread-filter'),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m),
              minimumSize: const Size(Hit.min, Hit.min),
              color: on ? c.selected : c.textMuted.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Hit.min / 2),
              onPressed: () => _toggleUnread(extras),
              child: Text(n > 0 ? 'Unread $n' : 'Unread',
                  style: TextStyle(color: on ? c.onSelected : c.textPrimary, fontWeight: FontWeight.w600, fontSize: 15)),
            ),
          ),
          ),
        ]);
      },
    );
  }

  void _toggleUnread(ChatListExtras extras) {
    AppHaptics.selection();
    extras.unreadOnly.value = !extras.unreadOnly.value;
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Future<void> _new(BuildContext context, ChatTabProvider p) => p.newChat(context, showContacts: () => _select(ChatShellSegment.contacts));

  Widget _scrollView(BuildContext context, ChatTabProvider p, {String? selectedKey}) {
    final c = AppColors.of(context);
    final seg = _segment;
    final args = ChatTabArgs(
      query: _search.text,
      selectedKey: selectedKey,
      onConnect: () => openConnect(context),
      onNew: () => _new(context, p),
      onOpened: () {
        if (_search.text.isNotEmpty) setState(_search.clear);
      },
    );
    final translucent = !Blur.opaque(context);
    return CustomScrollView(
      key: const Key('chat-scroll'),
      controller: _scroll,
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      slivers: [
        CupertinoSliverNavigationBar(
          largeTitle: const Text('Chat'),
          transitionBetweenRoutes: false,
          automaticallyImplyLeading: false,
          backgroundColor: translucent ? c.bg.withValues(alpha: Blur.backgroundOpacity) : c.bg,
          enableBackgroundFilterBlur: translucent,
          border: Border(bottom: BorderSide(color: c.outline.withValues(alpha: 0.35), width: 0.5)),
          // Bar buttons keep their size at every text size, as iOS bar buttons do (iOS shows them large in the Large Content
          // Viewer instead): "Mark all read" and "New" then fit beside the large title on every width, the iPad sidebar too.
          trailing: MediaQuery.withNoTextScaling(
            child: Row(mainAxisSize: MainAxisSize.min, children: [
            // C-U5: a labelled action, not a bare check-circle that read as a status light.
            if (seg == ChatShellSegment.chats && p.unreadMessages > 0)
              Semantics(
                label: 'Mark all read',
                button: true,
                excludeSemantics: true,
                onTap: () => _markAllRead(context, p),
                child: CupertinoButton(
                  key: const Key('chat-mark-all-read'),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                  minimumSize: const Size(Hit.min, Hit.min),
                  onPressed: () => _markAllRead(context, p),
                  child: Text('Mark all read', style: TextStyle(color: c.accent, fontWeight: FontWeight.w600, fontSize: 15)),
                ),
              ),
            if (seg == ChatShellSegment.contacts && p.addContactAction(context) != null)
              Semantics(
                label: 'Add contact',
                button: true,
                excludeSemantics: true,
                onTap: p.addContactAction(context),
                child: CupertinoButton(
                  key: const Key('chat-add-contact'),
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(Hit.min, Hit.min),
                  onPressed: p.addContactAction(context),
                  child: AppSymbolIcon(AppSymbols.personBadgePlus, size: 22, color: c.accent),
                ),
              ),
            // Build 76: a labelled pill ("New"), not a bare pencil: starting a message is one obvious tap.
            Semantics(
              label: 'New chat',
              button: true,
              excludeSemantics: true,
              onTap: () => _new(context, p),
              child: Tooltip(
                message: 'New chat',
                child: CupertinoButton(
                  key: const Key('chat-new'),
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m),
                  minimumSize: const Size(Hit.min, Hit.min),
                  color: c.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(Hit.min / 2),
                  onPressed: () => _new(context, p),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    AppSymbolIcon(AppSymbols.squareAndPencil, size: 18, color: c.accent),
                    const SizedBox(width: Gap.xs),
                    Text('New', style: TextStyle(color: c.accent, fontWeight: FontWeight.w600, fontSize: 15)),
                  ]),
                ),
              ),
            ),
          ]),
          ),
        ),
        if (seg != ChatShellSegment.contacts) CupertinoSliverRefreshControl(onRefresh: p.refresh),
        SliverPersistentHeader(
          pinned: true,
          delegate: _SegmentHeader(selected: seg, onChanged: _select, translucent: translucent, colors: c),
        ),
        SliverToBoxAdapter(child: _StatusBanner(onConnect: () => openConnect(context))),
        if (seg != ChatShellSegment.contacts)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
              child: _searchRow(context, p, seg),
            ),
          ),
        // Two one-time tips, one at a time: the swipe tip first (only once there is a conversation to swipe), then where the radio's lists are.
        if (seg == ChatShellSegment.chats && _search.text.isEmpty && !p.isEmpty && !appTipStore.seen('chat-swipe-tip'))
          SliverToBoxAdapter(
            child: TipCard(
              tipId: 'chat-swipe-tip',
              symbol: AppSymbols.message,
              title: 'Swipe a chat for quick actions',
              message: 'Swipe a chat to pin, mute or delete, or press and hold it.',
              onDismissed: () => setState(() {}),
            ),
          )
        else if (seg == ChatShellSegment.chats && _search.text.isEmpty)
          const SliverToBoxAdapter(
            child: TipCard(
              tipId: 'chat-network-tip',
              symbol: AppSymbols.antenna,
              title: 'Repeaters, rooms and your radio',
              message: 'They live in More, under Radio.',
            ),
          ),
        switch (seg) {
          ChatShellSegment.chats => p.chatsSliver(context, args),
          ChatShellSegment.channels => p.channelsSliver(context, args),
          ChatShellSegment.contacts => SliverFillRemaining(
              hasScrollBody: true, child: p.contactsSegment(context, seeNearby: () => ShellScope.maybeRead(context)?.openMore(MoreItem.radio))),
        },
      ],
    );
  }
}

/// The pinned segment control: 32 pt visual, 44 pt tall hit area, its own blur and hairline once content scrolls under it.
class _SegmentHeader extends SliverPersistentHeaderDelegate {
  final ChatShellSegment selected;
  final ValueChanged<ChatShellSegment> onChanged;
  final bool translucent;

  /// The theme's colours: a light / dark switch redraws the header (the selected segment is teal in both).
  final AppColors colors;
  const _SegmentHeader({required this.selected, required this.onChanged, required this.translucent, required this.colors});

  static const double extent = 60;
  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final c = AppColors.of(context);
    final bar = Container(
      height: extent,
      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: 4),
      decoration: BoxDecoration(
        color: translucent && overlapsContent ? c.bg.withValues(alpha: Blur.backgroundOpacity) : c.bg,
        border: overlapsContent ? Border(bottom: BorderSide(color: c.outline.withValues(alpha: 0.35), width: 0.5)) : null,
      ),
      child: MediaQuery(
        // A segmented control keeps its 13 pt labels at every text size, as UIKit's does; the rest of the tab scales.
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: Semantics(
          container: true,
          label: 'Chat sections',
          child: CupertinoSlidingSegmentedControl<ChatShellSegment>(
            key: const Key('chat-segments'),
            groupValue: selected,
            // C-V1: the selected segment is the app's teal selected style (it was a grey nearly the colour of its track).
            thumbColor: c.selected,
            backgroundColor: c.textMuted.withValues(alpha: 0.16),
            padding: const EdgeInsets.all(2),
            children: {
              ChatShellSegment.chats: _SegmentLabel('Chats', selected: selected == ChatShellSegment.chats, key: const Key('segment-chats')),
              ChatShellSegment.contacts: _SegmentLabel('Contacts', selected: selected == ChatShellSegment.contacts, key: const Key('segment-contacts')),
              ChatShellSegment.channels: _SegmentLabel('Channels', selected: selected == ChatShellSegment.channels, key: const Key('segment-channels')),
            },
            onValueChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      ),
    );
    if (translucent && overlapsContent) {
      return ClipRect(child: BackdropFilter(filter: ImageFilter.blur(sigmaX: Blur.sigma, sigmaY: Blur.sigma), child: bar));
    }
    return bar;
  }

  @override
  bool shouldRebuild(_SegmentHeader old) => old.selected != selected || old.translucent != translucent || !identical(old.colors, colors);
}

/// One banner for every offline wording (audit 2.2): shown only when the radio is not connected.
class _StatusBanner extends StatelessWidget {
  final VoidCallback onConnect;
  const _StatusBanner({required this.onConnect});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    if (s.connected) return const SizedBox.shrink();
    final trying = s.connecting || s.reconnecting;
    return ChatStatusBanner(
      key: const Key('chat-status-banner'),
      kind: StatusBannerKind.warning,
      // At large text sizes the short wording keeps the banner from eating the screen.
      message: trying
          ? 'Reconnecting to your radio…'
          : (MediaQuery.textScalerOf(context).scale(17) > 17 * 1.5 ? 'Radio not connected' : 'Radio not connected. Messages will send when it reconnects.'),
      actionLabel: trying ? null : 'Connect',
      onAction: onConnect,
    );
  }
}

/// One segment label: at least 44 pt tall so the segment is a full-size target (the label stays 13 pt).
class _SegmentLabel extends StatelessWidget {
  final String label;
  final bool selected;
  const _SegmentLabel(this.label, {this.selected = false, super.key});
  @override
  // Three segments on a 320-375 pt phone leave about 100 pt each: one line, shrunk to fit rather than wrapped.
  Widget build(BuildContext context) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: Hit.min),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  softWrap: false,
                  style: selected ? TextStyle(color: AppColors.of(context).onSelected, fontWeight: FontWeight.w600) : null),
            ),
          ),
        ),
      );
}
