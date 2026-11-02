// Where a tap in the new Chat tab goes: one place for "open this row / this contact", shared by the Chats list, the
// Network lists and the context menus. Opens through [ConversationScreen.open], so on a wide screen the conversation lands in
// the right-hand pane (ConversationPaneScope) and on a phone it is pushed.
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/conversation_row.dart';
import '../../chat/models.dart';
import '../contacts/contact_profile_screen.dart';
import '../contacts/contacts_controller.dart';
import '../contacts/dm_route_header.dart';
import '../design/app_symbols.dart';
import '../radios/admin_launcher.dart' show openRepeaterAdmin;
import '../radios/rooms/room_join_header.dart';
import 'channel_detail_screen.dart';
import 'conversation_screen.dart';
import 'system_traffic_screen.dart';

class ChatNavigator {
  final ChatController chat;
  ChatNavigator(this.chat);

  /// Serves the contact profile and route header while the contacts screens keep their own controller type (WP6a/6b
  /// replace these). One per Chat tab.
  late final ContactsController contacts = ContactsController(
    chat: chat.service,
    openConversation: openContact,
    openAdmin: (context, c) => openRepeaterAdmin(context, keyHex: c.publicKey, name: c.displayName, isRoom: c.type == ContactType.room),
    canOpenRooms: true,
  );

  void dispose() => contacts.dispose();

  /// A row of the Chats list.
  void openRow(BuildContext context, ConversationRow r) {
    if (r.isSystem) {
      final ch = r.channelId == null ? null : chat.store.channels.getById(r.channelId!);
      if (ch != null) Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SystemTrafficScreen(controller: chat, channel: ch)));
      return;
    }
    if (r.isChannel) {
      final id = r.channelId;
      ConversationScreen.open(
        context,
        controller: chat,
        convKey: r.key,
        title: r.title,
        actions: [
          if (id != null)
            CupertinoButton(
              key: const Key('channel-info'),
              padding: EdgeInsets.zero,
              minimumSize: const Size(44, 44),
              onPressed: () => ChannelDetailScreen.open(context, controller: chat, channelId: id),
              child: Semantics(label: 'Channel info', child: const AppSymbolIcon(AppSymbols.infoCircle, size: 22)),
            ),
        ],
      );
      return;
    }
    final key = r.contactKey;
    final contact = key == null || chat.radioId == null ? null : chat.store.contacts.get(chat.radioId!, key);
    if (contact != null) {
      openContact(context, contact);
    } else {
      ConversationScreen.open(context, controller: chat, convKey: r.key, title: r.title);
    }
  }

  /// A person or room: its conversation, with the route strip / join header and a way to the profile.
  void openContact(BuildContext context, Contact c) {
    if (c.type != ContactType.companion && c.type != ContactType.room) {
      openProfile(context, c);
      return;
    }
    final room = c.type == ContactType.room;
    ConversationScreen.open(
      context,
      controller: chat,
      convKey: room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix),
      title: c.displayName,
      actions: [
        CupertinoButton(
          key: const Key('dm-contact-info'),
          padding: EdgeInsets.zero,
          minimumSize: const Size(44, 44),
          onPressed: () => openProfile(context, c),
          child: Semantics(label: 'Contact details', child: const AppSymbolIcon(AppSymbols.infoCircle, size: 22)),
        ),
      ],
      header: room ? RoomJoinHeader(keyHex: c.publicKey, name: c.displayName) : DmRouteHeader(controller: contacts, publicKey: c.publicKey),
    );
  }

  void openProfile(BuildContext context, Contact c) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactProfileScreen(controller: contacts, publicKey: c.publicKey)));
  }
}
