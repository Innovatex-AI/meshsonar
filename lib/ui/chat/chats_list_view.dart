// The Chats segment (plan 4.1): one merged list of direct messages, channels and rooms, pinned first then newest, with the
// System (wardrive) group last. It is a SLIVER so the Chat tab shell can scroll it under the large title, the pinned
// segment control and the collapsing search field.
//
// Swipe (flutter_slidable): trailing Mute and Delete, leading Pin. Long-press: the iOS context menu with the last two
// messages as the preview. Screen readers get the same three actions. States: no radio, nothing yet, reading from the radio,
// no search results, populated (offline shows the list; the shell shows the banner).
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

import '../../app/chat_controller.dart';
import '../../chat/contact_manager.dart' show SyncPhase;
import '../../chat/conversation_row.dart';
import '../../chat/models.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/app_type.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../tools/adverts_screen.dart';
import 'channel_flows.dart';
import 'chat_list_actions.dart';
import 'chat_navigation.dart';
import 'chat_search_screen.dart';
import 'conversation_tile.dart';
import 'message_bubble.dart';
import 'message_format.dart';

class ChatsListView extends StatefulWidget {
  final ChatController controller;
  final ChatNavigator navigator;

  /// Search text from the shell; empty = the whole list.
  final String query;

  /// The conversation open in the detail pane on a wide screen (highlighted).
  final String? selectedKey;

  /// "Connect radio" in the no-radio state.
  final VoidCallback? onConnect;

  /// Called after the person opens a conversation (the shell clears its search).
  final VoidCallback? onOpened;
  const ChatsListView({
    super.key,
    required this.controller,
    required this.navigator,
    this.query = '',
    this.selectedKey,
    this.onConnect,
    this.onOpened,
  });

  @override
  State<ChatsListView> createState() => _ChatsListViewState();
}

class _ChatsListViewState extends State<ChatsListView> {
  late final ChatListActions _actions = ChatListActions(widget.controller);
  StreamSubscription<dynamic>? _sync;
  SyncPhase _phase = SyncPhase.offline;

  @override
  void initState() {
    super.initState();
    final cm = widget.controller.service.contacts;
    _phase = cm.state.phase;
    _sync = cm.states.listen((s) {
      if (s.phase != _phase && mounted) setState(() => _phase = s.phase);
    });
  }

  @override
  void dispose() {
    unawaited(_sync?.cancel());
    super.dispose();
  }

  ChatController get _c => widget.controller;

  void _open(ConversationRow r) {
    widget.navigator.openRow(context, r);
    widget.onOpened?.call();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final all = _c.conversationRows();
        final q = widget.query.trim().toLowerCase();
        final rows = q.isEmpty ? all : all.where((r) => _matches(r, q)).toList();
        if (all.isEmpty) return _emptyState();
        if (q.isNotEmpty) return _searchResults(rows, all, q);
        return _list(rows);
      },
    );
  }

  bool _matches(ConversationRow r, String q) =>
      r.title.toLowerCase().contains(q) || r.preview.toLowerCase().contains(q) || (r.contactKey ?? '').toLowerCase().startsWith(q);

  // ------------------------------------------------------------------ states

  Widget _emptyState() {
    final connected = _c.radioConnected;
    if (connected && _phase == SyncPhase.syncing) return const SliverToBoxAdapter(child: ChatsSkeleton());
    if (!connected && _c.radioId == null) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: AppEmptyView(
          key: const Key('chats-empty-no-radio'),
          symbol: AppSymbols.antenna,
          title: 'Connect a radio to start chatting',
          message: 'Messages travel over your MeshCore radio. Once it is connected, people and channels nearby appear here.',
          actionLabel: 'Connect radio',
          onAction: widget.onConnect,
        ),
      );
    }
    return SliverFillRemaining(
      hasScrollBody: false,
      child: _NothingYet(controller: _c, connected: connected),
    );
  }

  Widget _searchResults(List<ConversationRow> rows, List<ConversationRow> all, String q) {
    final hits = q.length >= 2 ? _c.service.search(widget.query.trim(), limit: 20) : const <ChatMessage>[];
    final byKey = {for (final r in all) r.key: r};
    if (rows.isEmpty && hits.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: AppEmptyView(
          key: const Key('chats-no-results'),
          symbol: AppSymbols.magnifyingglass,
          title: 'No matches for “${widget.query.trim()}”',
          message: 'Try a shorter name, or search the text of every message.',
          actionLabel: 'Search messages instead',
          onAction: () => ChatSearchScreen.open(context, _c),
        ),
      );
    }
    return SliverMainAxisGroup(
      slivers: [
        if (rows.isNotEmpty) ...[
          const SliverToBoxAdapter(child: _SectionHeader('Conversations')),
          SliverList.builder(
            itemCount: rows.length,
            itemBuilder: (context, i) => Column(children: [_tile(rows[i]), const RowDivider()]),
          ),
        ],
        if (hits.isNotEmpty) ...[
          const SliverToBoxAdapter(child: _SectionHeader('Messages')),
          SliverList.builder(
            key: const Key('chats-message-hits'),
            itemCount: hits.length,
            itemBuilder: (context, i) {
              final m = hits[i];
              final row = byKey[m.convKey];
              return Column(
                children: [
                  _MessageHit(
                    message: m,
                    title: row?.title ?? _c.service.conversation(m.convKey)?.title ?? 'Conversation',
                    now: _c.now(),
                    onTap: () {
                      if (row != null) {
                        _open(row);
                      } else {
                        ChatSearchScreen.open(context, _c);
                      }
                    },
                  ),
                  const RowDivider(),
                ],
              );
            },
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------------ the list

  Widget _list(List<ConversationRow> rows) {
    final normal = rows.where((r) => !r.isSystem).toList();
    final system = rows.where((r) => r.isSystem).toList();
    final proto = ConversationRow(
      key: 'proto',
      convKind: ConvKind.dm,
      kind: RowKind.person,
      title: 'Prototype',
      avatarSeed: 'proto',
      preview: 'Prototype',
    );
    return SliverMainAxisGroup(
      slivers: [
        if (normal.isNotEmpty)
          SliverPrototypeExtentList(
            // Every row has the same height (fixed two-line preview slot), so 500 rows cost nothing off screen.
            prototypeItem: Column(children: [ConversationTile(row: proto, stamp: '9:41'), const RowDivider()]),
            delegate: SliverChildBuilderDelegate(
              (context, i) => Column(children: [_tile(normal[i]), const RowDivider()]),
              childCount: normal.length,
              findChildIndexCallback: (key) {
                if (key is ValueKey<String>) {
                  final k = key.value;
                  final i = normal.indexWhere((r) => 'row-${r.key}' == k);
                  return i < 0 ? null : i;
                }
                return null;
              },
            ),
          ),
        if (system.isNotEmpty)
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SectionHeader('System'),
                for (final r in system) ...[_tile(r), const RowDivider()],
              ],
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: Gap.xl)),
      ],
    );
  }

  Widget _tile(ConversationRow r) {
    final stamp = listStamp(context, r.lastTsMs, now: _c.now());
    final actions = {
      CustomSemanticsAction(label: r.pinned ? 'Unpin' : 'Pin'): () => _actions.togglePin(r),
      CustomSemanticsAction(label: r.muted ? 'Unmute' : 'Mute'): () => _actions.mute(context, r),
      if (!r.isSystem) const CustomSemanticsAction(label: 'Delete'): () => _actions.delete(context, r),
    };
    final tile = ConversationTile(
      key: Key('conv-${r.key}'),
      row: r,
      stamp: stamp,
      selected: widget.selectedKey == r.key,
      onTap: () => _open(r),
      actions: actions,
    );
    if (r.isSystem) return tile;
    return KeyedSubtree(
      key: ValueKey('row-${r.key}'),
      child: Slidable(
        key: ValueKey('slide-${r.key}'),
        startActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.24,
          children: [
            _SwipeAction(
              key: Key('swipe-pin-${r.key}'),
              color: AppColors.of(context).accent,
              symbol: r.pinned ? AppSymbols.pin : AppSymbols.pinFill,
              label: r.pinned ? 'Unpin' : 'Pin',
              onTap: () => _actions.togglePin(r),
            ),
          ],
        ),
        endActionPane: ActionPane(
          motion: const DrawerMotion(),
          extentRatio: 0.48,
          children: [
            _SwipeAction(
              key: Key('swipe-mute-${r.key}'),
              color: AppColors.of(context).warning,
              symbol: AppSymbols.bellSlash,
              label: r.muted ? 'Unmute' : 'Mute',
              onTap: () => _actions.mute(context, r),
            ),
            _SwipeAction(
              key: Key('swipe-delete-${r.key}'),
              color: AppColors.of(context).danger,
              symbol: AppSymbols.trash,
              label: 'Delete',
              onTap: () => _actions.delete(context, r),
            ),
          ],
        ),
        child: _contextMenu(r, tile),
      ),
    );
  }

  Widget _contextMenu(ConversationRow r, Widget tile) {
    return CupertinoContextMenu.builder(
      enableHapticFeedback: true,
      actions: [
        CupertinoContextMenuAction(
          key: Key('menu-open-${r.key}'),
          trailingIcon: AppSymbols.message.apple,
          onPressed: () {
            Navigator.of(context, rootNavigator: true).pop();
            _open(r);
          },
          child: const Text('Open'),
        ),
        if (!r.isSystem)
          CupertinoContextMenuAction(
            key: Key('menu-pin-${r.key}'),
            trailingIcon: r.pinned ? AppSymbols.pinFill.apple : AppSymbols.pin.apple,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              _actions.togglePin(r);
            },
            child: Text(r.pinned ? 'Unpin' : 'Pin'),
          ),
        if (!r.isSystem)
          CupertinoContextMenuAction(
            key: Key('menu-mute-${r.key}'),
            trailingIcon: r.muted ? AppSymbols.bell.apple : AppSymbols.bellSlash.apple,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              _actions.mute(context, r);
            },
            child: Text(r.muted ? 'Unmute' : 'Mute'),
          ),
        if (r.contactKey != null)
          CupertinoContextMenuAction(
            key: Key('menu-copykey-${r.key}'),
            trailingIcon: AppSymbols.docOnDoc.apple,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              Clipboard.setData(ClipboardData(text: r.contactKey!));
              showAppToast(context, 'Key copied');
            },
            child: const Text('Copy key'),
          ),
        if (!r.isSystem)
          CupertinoContextMenuAction(
            key: Key('menu-delete-${r.key}'),
            isDestructiveAction: true,
            trailingIcon: AppSymbols.trash.apple,
            onPressed: () {
              Navigator.of(context, rootNavigator: true).pop();
              _actions.delete(context, r);
            },
            child: const Text('Delete'),
          ),
      ],
      // The same builder serves the row in the list (which must keep its height) and the open menu (a PopupRoute): only the
      // menu shows the preview.
      builder: (context, animation) =>
          animation.value >= CupertinoContextMenu.animationOpensAt && ModalRoute.of(context) is PopupRoute ? _Preview(controller: _c, row: r) : tile,
    );
  }
}

class _SwipeAction extends StatelessWidget {
  final Color color;
  final AppSymbol symbol;
  final String label;
  final VoidCallback onTap;
  const _SwipeAction({super.key, required this.color, required this.symbol, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return CustomSlidableAction(
      onPressed: (_) => onTap(),
      backgroundColor: color,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Semantics(
        label: label,
        button: true,
        excludeSemantics: true,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppSymbolIcon(symbol, size: 22, color: Colors.white),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, style: AppType.footnote.copyWith(color: Colors.white, fontWeight: FontWeight.w600), textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3)),
          ],
        ),
      ),
    );
  }
}

/// The long-press preview: the last two messages as static bubbles.
class _Preview extends StatelessWidget {
  final ChatController controller;
  final ConversationRow row;
  const _Preview({required this.controller, required this.row});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final msgs = controller.service.page(row.key, limit: 2).messages.reversed.toList();
    // `CupertinoContextMenu.builder` builds this both in the list slot (tight, one row high) and in the open menu, so the
    // preview takes whatever size it is given (up to 300 x 260 when loose) and clips: a window onto the newest messages.
    final wanted = msgs.isEmpty ? 72.0 : (28.0 + 84.0 * msgs.length).clamp(72.0, 260.0);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.hasTightWidth ? box.maxWidth : box.maxWidth.clamp(0.0, 300.0);
        final h = box.hasTightHeight ? box.maxHeight : (box.hasBoundedHeight ? box.maxHeight.clamp(0.0, wanted) : wanted);
        return SizedBox(
          width: w,
          height: h,
          child: Container(
            key: const Key('chat-preview'),
            clipBehavior: Clip.antiAlias,
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(Corners.card)),
            child: msgs.isEmpty
                ? Center(child: Text('No messages yet', style: AppType.body.copyWith(color: c.textMuted)))
                : ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.bottomCenter,
                      minHeight: 0,
                      maxHeight: double.infinity,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final m in msgs)
                            IgnorePointer(child: MessageBubble(message: m, showSender: row.isChannel || row.kind == RowKind.room, radioConnected: controller.radioConnected)),
                        ],
                      ),
                    ),
                  ),
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, Gap.l, Layout.screenMargin, Gap.xs),
        child: Text(text.toUpperCase(), style: AppType.footnote.copyWith(color: c.textMuted, letterSpacing: 0.4)),
      ),
    );
  }
}

class _MessageHit extends StatelessWidget {
  final ChatMessage message;
  final String title;
  final DateTime now;
  final VoidCallback onTap;
  const _MessageHit({required this.message, required this.title, required this.now, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final stamp = listStamp(context, message.tsLocalMs, now: now);
    return Semantics(
      button: true,
      container: true,
      label: '$title, $stamp. ${message.text}',
      onTap: onTap,
      child: ExcludeSemantics(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: Hit.min),
            padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: Gap.s),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: AppType.headline)),
                  Text(stamp, style: AppType.subhead.copyWith(color: c.textMuted)),
                ]),
                Text(message.text, maxLines: 2, overflow: TextOverflow.ellipsis, style: AppType.subhead.copyWith(color: c.textMuted)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Three static placeholder rows while the radio's contacts and channels are being read (not the empty state).
class ChatsSkeleton extends StatelessWidget {
  const ChatsSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bar = c.textMuted.withValues(alpha: 0.18);
    return Semantics(
      liveRegion: true,
      label: 'Reading channels from your radio',
      child: Column(
        key: const Key('chats-skeleton'),
        children: [
          Padding(
            padding: const EdgeInsets.all(Layout.screenMargin),
            child: Row(children: [
              const CupertinoActivityIndicator(),
              const SizedBox(width: Gap.s),
              Expanded(child: Text('Reading channels from your radio…', style: AppType.subhead.copyWith(color: c.textMuted))),
            ]),
          ),
          for (var i = 0; i < 3; i++)
            ExcludeSemantics(
              child: Container(
                height: kRowMinHeight + 8,
                padding: const EdgeInsets.symmetric(horizontal: Layout.screenMargin, vertical: 10),
                child: Row(children: [
                  Container(width: kAvatarSize, height: kAvatarSize, decoration: BoxDecoration(color: bar, shape: BoxShape.circle)),
                  const SizedBox(width: Gap.m),
                  Expanded(
                    child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      FractionallySizedBox(widthFactor: 0.5, child: Container(height: 14, decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(7)))),
                      const SizedBox(height: 10),
                      FractionallySizedBox(widthFactor: 0.8, child: Container(height: 12, decoration: BoxDecoration(color: bar, borderRadius: BorderRadius.circular(6)))),
                    ]),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}

/// Connected (or at least known) radio, nothing in the list yet.
class _NothingYet extends StatelessWidget {
  final ChatController controller;
  final bool connected;
  const _NothingYet({required this.controller, required this.connected});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final t = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            key: const Key('chats-empty'),
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSymbolIcon(AppSymbols.message, size: 56, color: c.textMuted),
              const SizedBox(height: Gap.m),
              Text('No conversations yet', style: t.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: Gap.xs),
              Text(
                connected
                    ? 'Messages from people nearby appear after they advertise. You can also join the Public channel to talk with everyone in range.'
                    : 'Your radio is not connected. Channels and people appear here when it is, and you can already join a channel.',
                style: t.textTheme.bodyMedium?.copyWith(color: c.textMuted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Gap.l),
              CupertinoButton.filled(
                key: const Key('join-public-empty'),
                minimumSize: const Size(Hit.min, Hit.min),
                onPressed: connected
                    ? () => runChannelAction(context, controller, () => controller.admin.joinPublic(controller.radioId ?? ''), what: 'Public')
                    : () => showAddChannelSheet(context, controller),
                child: Text(connected ? 'Join Public channel' : 'Add a channel'),
              ),
              if (connected)
                CupertinoButton(
                  key: const Key('announce-empty'),
                  minimumSize: const Size(Hit.min, Hit.min),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AdvertsScreen())),
                  child: const Text('Announce myself'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
