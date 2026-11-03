// The Chat tab's content, from the chat controller. Set into ChatTabHost.provider by lib/app/chat_wiring.dart.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../contacts/contacts_tab.dart';
import '../shell/chat_tab_host.dart';
import 'channel_flows.dart';
import 'channels_view.dart';
import 'chat_navigation.dart';
import 'chat_search_screen.dart';
import 'chats_list_view.dart';
import 'network_view.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';

enum _NewChoice { message, channel }

class ChatTabProviderImpl implements ChatTabProvider {
  final ChatController controller;
  late final ChatNavigator navigator = ChatNavigator(controller);
  ChatTabProviderImpl(this.controller);

  void dispose() => navigator.dispose();

  @override
  Listenable get changes => controller;

  @override
  int get unreadMessages => controller.unreadMessages;

  @override
  bool get isEmpty => controller.isEmpty;

  // ---- old tab (flag off)
  @override
  Widget contactsView(BuildContext context) => ContactsTab(chat: controller);

  @override
  Widget channelsView(BuildContext context) => ChannelsView(controller: controller);

  @override
  List<Widget> appBarActions(BuildContext context) => [
        IconButton(
          key: const Key('chat-search'),
          tooltip: 'Search all messages',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.search_rounded),
          onPressed: () => ChatSearchScreen.open(context, controller),
        ),
      ];

  // ---- redesigned tab (flag on)
  @override
  Widget chatsSliver(BuildContext context, ChatTabArgs args) => ChatsListView(
        controller: controller,
        navigator: navigator,
        query: args.query,
        selectedKey: args.selectedKey,
        onConnect: args.onConnect,
        onOpened: args.onOpened,
      );

  @override
  Widget networkSliver(BuildContext context, ChatTabArgs args) =>
      NetworkView(controller: controller, navigator: navigator, query: args.query, onConnect: args.onConnect);

  @override
  Widget contactsSegment(BuildContext context) => ContactsTab(chat: controller);

  @override
  Future<void> refresh() => controller.refreshFromRadio();

  /// Stub for WP3's New chat sheet: the two things it will offer, as an action sheet.
  @override
  Future<void> newChat(BuildContext context, {required VoidCallback showContacts}) async {
    final choice = await showAppActionSheet<_NewChoice>(
      context,
      title: 'New',
      actions: const [
        AppAction('New message', _NewChoice.message, symbol: AppSymbols.squareAndPencil, key: Key('new-message')),
        AppAction('Join or create a channel', _NewChoice.channel, symbol: AppSymbols.numberSign, key: Key('new-channel')),
      ],
    );
    if (!context.mounted) return;
    switch (choice) {
      case _NewChoice.message:
        showContacts();
      case _NewChoice.channel:
        await showAddChannelSheet(context, controller);
      case null:
        break;
    }
  }

  @override
  void openMessageSearch(BuildContext context) => ChatSearchScreen.open(context, controller);
}
