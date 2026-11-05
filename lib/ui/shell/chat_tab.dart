// The Chat tab shell (chat plan 3 and 4.1): large title "Chat" with the New button, a pinned sliding segmented control
// Chats | Contacts | Network, a collapsing search field, a status banner only when something is wrong, and the segment's
// content as slivers under them. Chats is the default segment and a cold launch always opens it; the chosen segment is
// remembered for the session only.
//
// Behind the `chatRedesign` flag (AppFlags, More > Developer; ON by default, the switch is the escape hatch): with it off the old Contacts | Channels tab
// ([LegacyChatTab]) is shown and nothing here runs.
//
// Wide screens (>= 900 dp of tab width, Split View and Stage Manager included) keep the two-column layout: this shell in a
// 380 dp sidebar and the open conversation in a detail column ([ConversationPaneScope]).
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../chat/conversation_screen.dart' show ConversationPaneScope;
import '../design/app_symbols.dart';
import '../design/app_widgets.dart';
import '../../app/app_flags.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../drive/drive_controls.dart' show openConnect;
import 'chat_tab_host.dart';
import 'chat_tab_legacy.dart';

enum ChatShellSegment { chats, contacts, network }

class ChatTab extends StatelessWidget {
  const ChatTab({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: AppFlags.chatRedesignNotifier,
        builder: (context, on, _) => on ? const RedesignedChatTab() : const LegacyChatTab(),
      );
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
            const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () => _select(ChatShellSegment.network),
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
        title: s.connected ? 'Chat is getting ready' : 'Messages arrive here once you connect a radio',
        message: s.connected
            ? 'Your radio is connected. Conversations appear here in a moment.'
            : 'Connect your MeshCore companion radio over Bluetooth. People and channels show up here; you can map coverage while you wait.',
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
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (seg == ChatShellSegment.contacts && p.addContactAction(context) != null)
              CupertinoButton(
                key: const Key('chat-add-contact'),
                padding: EdgeInsets.zero,
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: p.addContactAction(context),
                child: Semantics(label: 'Add contact', button: true, excludeSemantics: true, child: AppSymbolIcon(AppSymbols.personBadgePlus, size: 22, color: c.accent)),
              ),
            CupertinoButton(
              key: const Key('chat-new'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(Hit.min, Hit.min),
              onPressed: () => _new(context, p),
              child: Semantics(label: 'New message', button: true, excludeSemantics: true, child: AppSymbolIcon(AppSymbols.squareAndPencil, size: 22, color: c.accent)),
            ),
          ]),
        ),
        if (seg != ChatShellSegment.contacts) CupertinoSliverRefreshControl(onRefresh: p.refresh),
        SliverPersistentHeader(
          pinned: true,
          delegate: _SegmentHeader(selected: seg, onChanged: _select, translucent: translucent),
        ),
        SliverToBoxAdapter(child: _StatusBanner(onConnect: () => openConnect(context))),
        if (seg != ChatShellSegment.contacts)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
              child: CupertinoSearchTextField(
                key: const Key('chat-search-field'),
                controller: _search,
                focusNode: _searchFocus,
                placeholder: seg == ChatShellSegment.chats ? 'Search chats and messages' : 'Search the network',
                onChanged: (_) => setState(() {}),
                onSuffixTap: () => setState(_search.clear),
              ),
            ),
          ),
        if (seg == ChatShellSegment.chats && _search.text.isEmpty)
          const SliverToBoxAdapter(
            child: TipCard(
              tipId: 'chat-network-tip',
              symbol: AppSymbols.antenna,
              title: 'Repeaters, rooms and your radio',
              message: 'They live under Network.',
            ),
          ),
        switch (seg) {
          ChatShellSegment.chats => p.chatsSliver(context, args),
          ChatShellSegment.network => p.networkSliver(context, args),
          ChatShellSegment.contacts => SliverFillRemaining(hasScrollBody: true, child: p.contactsSegment(context)),
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
  const _SegmentHeader({required this.selected, required this.onChanged, required this.translucent});

  static const double extent = 56;
  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final c = AppColors.of(context);
    final bar = Container(
      height: extent,
      padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: 6),
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
            thumbColor: c.surfaceHigh,
            backgroundColor: c.textMuted.withValues(alpha: 0.16),
            padding: const EdgeInsets.all(2),
            children: const {
              ChatShellSegment.chats: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Chats', key: Key('segment-chats'))),
              ChatShellSegment.contacts: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Contacts', key: Key('segment-contacts'))),
              ChatShellSegment.network: Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Network', key: Key('segment-network'))),
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
  bool shouldRebuild(_SegmentHeader old) => old.selected != selected || old.translucent != translucent;
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
