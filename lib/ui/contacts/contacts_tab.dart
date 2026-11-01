// The Contacts half of the Chat tab, wired to the chat controller: builds the ContactsController, opens a direct message in
// the shared conversation screen (with the route strip on top and a contact-details button), and hosts the list. Set as
// ChatTabProviderImpl.contactsBuilder by lib/app/chat_wiring.dart.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/models.dart';
import '../chat/conversation_screen.dart';
import 'contact_detail_screen.dart';
import 'contacts_controller.dart';
import 'contacts_view.dart';
import 'dm_route_header.dart';

class ContactsTab extends StatefulWidget {
  final ChatController chat;

  /// Remote administration of a repeater (agent 2D's screen); null until it exists, and then the button is simply absent.
  final OpenAdmin? openAdmin;
  const ContactsTab({super.key, required this.chat, this.openAdmin});

  @override
  State<ContactsTab> createState() => _ContactsTabState();
}

class _ContactsTabState extends State<ContactsTab> {
  late final ContactsController _c = ContactsController(
    chat: widget.chat.service,
    openConversation: _openConversation,
    openAdmin: widget.openAdmin,
    canOpenRooms: false, // flips to true when the room login header exists (Wave 2D)
  );

  void _openConversation(BuildContext context, Contact c) {
    if (c.type != ContactType.companion && c.type != ContactType.room) return;
    final room = c.type == ContactType.room;
    ConversationScreen.open(
      context,
      controller: widget.chat,
      convKey: room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix),
      title: c.displayName,
      actions: [
        IconButton(
          key: const Key('dm-contact-info'),
          tooltip: 'Contact details',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.info_outline_rounded),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ContactDetailScreen(controller: _c, publicKey: c.publicKey))),
        ),
      ],
      header: room ? null : DmRouteHeader(controller: _c, publicKey: c.publicKey),
    );
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ContactsView(controller: _c);
}
