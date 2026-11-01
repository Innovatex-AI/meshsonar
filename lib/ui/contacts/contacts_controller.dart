// ContactsController: what the Contacts screens read and call. One per Chat tab. It owns no state the store does not have
// (search text and the filter chip aside); every list is computed from ChatStore through ChatService.contacts.
import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../chat/chat_service.dart';
import '../../chat/contact_manager.dart';
import '../../chat/events.dart';
import '../../chat/models.dart';

/// Opens the conversation for [contact] (agent 2A's shared conversation screen). A DM contact opens `ConvKey.dm(prefix)`, a
/// room `ConvKey.room(prefix)`. Wired once where the Chat tab provider is built.
typedef OpenConversation = void Function(BuildContext context, Contact contact);

/// Opens the remote-admin screen of a repeater or room server (agent 2D). Null = the button is not shown.
typedef OpenAdmin = void Function(BuildContext context, Contact contact);

enum ContactFilter { all, favourites, recent, people, repeaters, rooms, sensors }

extension ContactFilterLabel on ContactFilter {
  String get label => switch (this) {
        ContactFilter.all => 'All',
        ContactFilter.favourites => 'Favourites',
        ContactFilter.recent => 'Recent',
        ContactFilter.people => 'People',
        ContactFilter.repeaters => 'Repeaters',
        ContactFilter.rooms => 'Rooms',
        ContactFilter.sensors => 'Sensors',
      };
}

/// One line of the contact list.
class ContactRow {
  final Contact contact;

  /// Last message of the conversation with this contact (DM or room), if any.
  final String? preview;
  final int? lastMessageMs;
  final int unread;
  const ContactRow(this.contact, {this.preview, this.lastMessageMs, this.unread = 0});
}

class ContactsController extends ChangeNotifier {
  final ChatService chat;
  final OpenConversation? openConversation;
  final OpenAdmin? openAdmin;

  /// A room server can be opened as a conversation. Off until room login exists in the conversation screen (a post to a room
  /// you have not logged in to goes nowhere); then ContactsTab turns it on.
  final bool canOpenRooms;
  final int Function() nowMs;

  ContactFilter _filter = ContactFilter.all;
  String _query = '';
  StreamSubscription<ChatEvent>? _evSub;
  StreamSubscription<ContactSyncState>? _stSub;
  bool _dirty = true;
  bool _scheduled = false;
  List<ContactRow> _rows = const [];
  List<AdvertSeen> _nearby = const [];
  int _total = 0;
  bool _disposed = false;

  ContactsController({required this.chat, this.openConversation, this.openAdmin, this.canOpenRooms = false, int Function()? nowMs})
      : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch) {
    _evSub = chat.events.listen((e) {
      switch (e.kind) {
        case ChatEventKind.contactsChanged:
        case ChatEventKind.messageAdded:
        case ChatEventKind.messageUpdated:
        case ChatEventKind.conversationChanged:
        case ChatEventKind.historyDeleted:
          _invalidate();
        case ChatEventKind.channelsChanged:
        case ChatEventKind.systemChanged:
          break;
      }
    });
    _stSub = manager.states.listen((_) => _invalidate());
  }

  ContactManager get manager => chat.contacts;
  ContactSyncState get sync => manager.state;
  bool get connected => manager.connected;

  ContactFilter get filter => _filter;
  String get query => _query;

  void setFilter(ContactFilter f) {
    if (f == _filter) return;
    _filter = f;
    _invalidate();
  }

  void setQuery(String q) {
    if (q == _query) return;
    _query = q;
    _invalidate();
  }

  /// Contacts after the filter chip and the search text.
  List<ContactRow> get rows {
    _recompute();
    return _rows;
  }

  /// Contacts in the book whatever the filter says (0 = show the "no contacts yet" state, not "nothing matches").
  int get totalContacts {
    _recompute();
    return _total;
  }

  /// "New nodes nearby".
  List<AdvertSeen> get nearby {
    _recompute();
    return _nearby;
  }

  Contact? contact(String publicKey) {
    final id = manager.radioId;
    return id == null ? null : chat.store.contacts.get(id, publicKey);
  }

  /// How the DM conversation with [c] stands, for the detail screen.
  ConversationSummary? conversationOf(Contact c) =>
      chat.conversation(c.type == ContactType.room ? ConvKey.room(c.prefix) : ConvKey.dm(c.prefix));

  void _invalidate() {
    _dirty = true;
    if (_disposed || _scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  void _recompute() {
    if (!_dirty) return;
    _dirty = false;
    final id = manager.radioId;
    if (id == null) {
      _rows = const [];
      _nearby = const [];
      _total = 0;
      return;
    }
    final all = chat.store.contacts.list(id, includeBlocked: false);
    _total = all.length;
    final convs = <String, ConversationSummary>{
      for (final s in chat.conversations(radioId: id))
        if (s.key.startsWith('d:') || s.key.startsWith('r:')) ConvKey.body(s.key): s,
    };
    final q = _query.trim().toLowerCase();
    bool matches(Contact c) {
      if (q.isEmpty) return true;
      return c.displayName.toLowerCase().contains(q) || c.name.toLowerCase().contains(q) || c.publicKey.startsWith(q) || c.notes.toLowerCase().contains(q);
    }

    bool inFilter(Contact c) => switch (_filter) {
          ContactFilter.all => true,
          ContactFilter.favourites => c.favourite,
          ContactFilter.recent => convs.containsKey(c.prefix),
          ContactFilter.people => c.type == ContactType.companion,
          ContactFilter.repeaters => c.type == ContactType.repeater,
          ContactFilter.rooms => c.type == ContactType.room,
          ContactFilter.sensors => c.type == ContactType.sensor,
        };
    final rows = [
      for (final c in all)
        if (inFilter(c) && matches(c))
          ContactRow(c, preview: convs[c.prefix]?.lastPreview, lastMessageMs: convs[c.prefix]?.lastTsMs, unread: convs[c.prefix]?.unread ?? 0),
    ];
    if (_filter == ContactFilter.recent) {
      rows.sort((a, b) => (b.lastMessageMs ?? 0).compareTo(a.lastMessageMs ?? 0));
    }
    _rows = rows;
    _nearby = q.isEmpty
        ? manager.nearby()
        : [
            for (final a in manager.nearby())
              if (a.name.toLowerCase().contains(q) || a.publicKey.startsWith(q)) a
          ];
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_evSub?.cancel());
    unawaited(_stSub?.cancel());
    super.dispose();
  }
}
