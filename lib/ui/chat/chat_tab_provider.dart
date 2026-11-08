// The Chat tab's content, from the chat controller. Set into ChatTabHost.provider by lib/app/chat_wiring.dart.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../contacts/add_contact_screen.dart';
import '../contacts/contacts_tab.dart';
import '../shell/chat_tab_host.dart';
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

  // ---- the tab (Chats | Contacts | Channels | Network)
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
  Widget channelsSliver(BuildContext context, ChatTabArgs args) => ChatsListView(
        controller: controller,
        mode: ChatsListMode.channels,
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
  Widget contactsSegment(BuildContext context, {VoidCallback? seeNearby}) => ContactsTab(chat: controller, onSeeAllNearby: seeNearby);

  @override
  VoidCallback? addContactAction(BuildContext context) => () =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => AddContactScreen(controller: navigator.contacts)));

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
