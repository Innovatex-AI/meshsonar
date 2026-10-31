// Chat > Contacts, the default content until the contacts screens (agent 2B) replace it through
// [ChatTabProviderImpl.contactsBuilder]: the real contacts from the chat database with their last message, search, and a
// tap that opens the conversation. No add flow here. People and room servers only: repeaters and sensors are not chat partners.
import 'package:flutter/material.dart';

import '../../app/chat_controller.dart';
import '../../chat/models.dart';
import '../theme.dart';
import '../widgets.dart' show EmptyState;
import 'conversation_screen.dart';
import '../radios/rooms/room_join_header.dart';
import 'message_format.dart';

class ContactsView extends StatefulWidget {
  final ChatController controller;
  const ContactsView({super.key, required this.controller});
  @override
  State<ContactsView> createState() => _ContactsViewState();
}

class _ContactsViewState extends State<ContactsView> {
  final TextEditingController _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  String _convKeyFor(Contact c) => c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix);

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final id = c.radioId;
        final all = id == null
            ? <Contact>[]
            : c.store.contacts.list(id, includeBlocked: false).where((x) => x.type == ContactType.companion || x.type == ContactType.room).toList();
        final q = _q.text.trim().toLowerCase();
        final shown = q.isEmpty ? all : all.where((x) => x.displayName.toLowerCase().contains(q)).toList();
        final summaries = {for (final s in c.service.conversations(includeEmpty: true)) s.key: s};
        shown.sort((a, b) {
          final sa = summaries[_convKeyFor(a)], sb = summaries[_convKeyFor(b)];
          final ta = sa?.lastTsMs ?? 0, tb = sb?.lastTsMs ?? 0;
          if (ta != tb) return tb.compareTo(ta);
          if (a.favourite != b.favourite) return a.favourite ? -1 : 1;
          return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
        });
        if (all.isEmpty) {
          return RefreshIndicator(
            onRefresh: c.refreshFromRadio,
            child: ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
              EmptyState(
                key: const Key('contacts-empty'),
                icon: Icons.people_outline_rounded,
                title: 'No contacts yet',
                body: c.radioConnected
                    ? 'People appear here when your radio hears them advertise, or when you add them. Pull down to ask the radio again.'
                    : 'Contacts come from your radio. Connect it and the people it knows appear here.',
              ),
            ]),
          );
        }
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.l, Gap.xs, Gap.l, Gap.s),
              child: TextField(
                key: const Key('contacts-search'),
                controller: _q,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search contacts',
                  prefixIcon: const Icon(Icons.search_rounded),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(Corners.card)),
                ),
              ),
            ),
            Expanded(
              child: shown.isEmpty
                  ? EmptyState(icon: Icons.search_off_rounded, title: 'No match', body: 'Nobody in your contacts matches "${_q.text.trim()}".')
                  : RefreshIndicator(
                      onRefresh: c.refreshFromRadio,
                      child: ListView.builder(
                        key: const Key('contacts-list'),
                        physics: const AlwaysScrollableScrollPhysics(),
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final x = shown[i];
                          final s = summaries[_convKeyFor(x)];
                          final unread = s?.unread ?? 0;
                          return Semantics(
                            container: true,
                            button: true,
                            label: '${x.displayName}${x.type == ContactType.room ? ', room' : ''}${unread > 0 ? ', $unread unread' : ''}. ${s?.lastPreview ?? 'No messages yet'}',
                            child: ExcludeSemantics(
                              child: ListTile(
                                key: Key('contact-row-${x.prefix}'),
                                minTileHeight: 64,
                                leading: CircleAvatar(child: Icon(x.type == ContactType.room ? Icons.forum_outlined : Icons.person_outline_rounded)),
                                title: Text(x.displayName, maxLines: 1, overflow: TextOverflow.ellipsis, style: unread > 0 ? const TextStyle(fontWeight: FontWeight.w700) : null),
                                subtitle: Text(s?.lastPreview ?? 'No messages yet', maxLines: 1, overflow: TextOverflow.ellipsis),
                                trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                                  Text(listStamp(context, s?.lastTsMs, now: c.now()), style: Theme.of(context).textTheme.labelSmall),
                                  if (unread > 0) Padding(padding: const EdgeInsets.only(top: 2), child: Badge(label: Text(unread > 99 ? '99+' : '$unread'))),
                                ]),
                                onTap: () => ConversationScreen.open(context,
                                    controller: c,
                                    convKey: _convKeyFor(x),
                                    title: x.displayName,
                                    // A room only pushes its posts to radios that joined it (lib/ui/radios/rooms).
                                    header: x.type == ContactType.room ? RoomJoinHeader(keyHex: x.publicKey, name: x.displayName) : null),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}
