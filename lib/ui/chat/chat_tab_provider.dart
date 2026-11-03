// The Chat tab's content, from the chat controller. Set into ChatTabHost.provider by lib/app/chat_wiring.dart.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../contacts/contacts_tab.dart';
import '../shell/chat_tab_host.dart';
import 'channels_view.dart';
import 'chat_navigation.dart';
import 'chat_search_screen.dart';
import 'chats_list_view.dart';
import 'network_view.dart';
import 'new_chat_sheet.dart';

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
          key: const Key('add-channel'),
          tooltip: 'Add a channel or contact',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.add_rounded),
          onPressed: () => newChat(context, showContacts: () {}),
        ),
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
        onNew: args.onNew,
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

  /// The New chat sheet (plan 4.13).
  @override
  Future<void> newChat(BuildContext context, {required VoidCallback showContacts}) =>
      showNewChatSheet(context, controller, navigator: navigator, showContacts: showContacts);

  @override
  Future<void> quickSwitch(BuildContext context) => showQuickSwitcher(context, controller, navigator);

  @override
  void openMessageSearch(BuildContext context) => ChatSearchScreen.open(context, controller);
}
