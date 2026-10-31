// The Chat tab's content, from the chat controller. Set into ChatTabHost.provider by lib/app/chat_wiring.dart.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../shell/chat_tab_host.dart';
import 'channels_view.dart';
import 'chat_search_screen.dart';
import 'contacts_view.dart';

/// The Contacts segment builder. The contacts screens replace this (agent 2B: `ChatTabProviderImpl.contactsBuilder = ...`);
/// the default is the read-only [ContactsView] over the real contacts.
typedef ContactsBuilder = Widget Function(BuildContext context, ChatController controller);

class ChatTabProviderImpl implements ChatTabProvider {
  final ChatController controller;
  ChatTabProviderImpl(this.controller);

  static ContactsBuilder? contactsBuilder;

  @override
  Listenable get changes => controller;

  @override
  int get unreadConversations => controller.unreadConversations;

  @override
  bool get isEmpty => controller.isEmpty;

  @override
  Widget contactsView(BuildContext context) => (contactsBuilder ?? (c, ctl) => ContactsView(controller: ctl))(context, controller);

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
}
