// The seam between the shell's Chat tab and the chat services (lib/chat, wave 1B). Nothing in the shell imports
// lib/chat. When chat lands, its wiring code sets [ChatTabHost.provider] once at startup; until then the Chat tab shows
// the honest "messages arrive once you connect a radio" states (and, in debug builds only, fixtures behind
// [ChatTabHost.debugFixtures]).
//
//   ChatTabHost.provider.value = MyChatTabProvider(chatService);
//
// A provider supplies the lists and the unread count; the host adds the title, the segmented control, search, the New
// button, the status banner, the connect call to action and the empty states around them.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// What the host passes to the segment views of the redesigned tab.
class ChatTabArgs {
  /// Search text (the segment filters its list by it).
  final String query;

  /// The conversation open in the detail pane of the wide layout, if any.
  final String? selectedKey;

  /// "Connect radio".
  final VoidCallback? onConnect;

  /// A conversation was opened from the list (the host clears the search).
  final VoidCallback? onOpened;

  /// Opens the New chat sheet (the empty states offer it).
  final VoidCallback? onNew;
  const ChatTabArgs({this.query = '', this.selectedKey, this.onConnect, this.onOpened, this.onNew});
}

/// What the chat services give the Chat tab. All views are built inside the tab's own scaffold body.
abstract class ChatTabProvider {
  /// Notifies when [unreadMessages] or the lists change (the tab badge and lists listen to it).
  Listenable get changes;

  /// Unread messages (muted and system conversations excluded), shown as the badge on the Chat tab (D19).
  int get unreadMessages;

  /// True when there are no conversations at all (the host then shows its own first-run empty state).
  bool get isEmpty;

  // ---- the tab (Chats | Contacts | Network)
  /// The Chats list, as a sliver.
  Widget chatsSliver(BuildContext context, ChatTabArgs args);

  /// The Network lists, as a sliver.
  Widget networkSliver(BuildContext context, ChatTabArgs args);

  /// The Contacts segment (a box widget with its own scrolling until the contacts rewrite lands).
  /// [seeNearby] opens the Network segment, where the nodes heard nearby (Add / Ignore) now live.
  Widget contactsSegment(BuildContext context, {VoidCallback? seeNearby});

  /// Add contact (QR code, link or key), shown as the nav button on the Contacts segment. Null = no such button.
  VoidCallback? addContactAction(BuildContext context) => null;

  /// Pull to refresh: reads the radio again.
  Future<void> refresh();

  /// The New (compose) button. [showContacts] switches the tab to its Contacts segment.
  Future<void> newChat(BuildContext context, {required VoidCallback showContacts});

  /// Opens the all-messages search.
  void openMessageSearch(BuildContext context);

  /// The Cmd-K quick switcher (iPad). Default: nothing.
  Future<void> quickSwitch(BuildContext context) async {}
}

class ChatTabHost {
  ChatTabHost._();

  /// Set by the chat wiring when lib/chat is available; null means "chat not built into this app yet".
  static final ValueNotifier<ChatTabProvider?> provider = ValueNotifier<ChatTabProvider?>(null);

  /// Opens one conversation full screen from anywhere (a tapped notification or banner). Set by the chat wiring; null before
  /// chat is up, when a tap only brings the Chat tab to the front.
  static void Function(BuildContext context, String convKey)? openConversation;

  /// Debug builds only: show fixture conversations so the structure can be reviewed without a radio.
  static final ValueNotifier<bool> debugFixtures = ValueNotifier<bool>(false);

  static int get unread => provider.value?.unreadMessages ?? 0;
}

/// Fixture provider for the debug flag. Lists are static text; nothing here is stored or sent.
class DebugFixtureChat implements ChatTabProvider {
  @override
  VoidCallback? addContactAction(BuildContext context) => null;
  @override
  Listenable get changes => ChangeNotifier();
  @override
  int get unreadMessages => 2;
  @override
  bool get isEmpty => false;
  @override
  Widget chatsSliver(BuildContext context, ChatTabArgs args) => SliverList(
        delegate: SliverChildListDelegate([
          for (final r in const [('Fixture: Alex', '9:41'), ('Fixture: Public', '9:12')])
            ListTile(title: Text(r.$1), subtitle: const Text('Debug fixture, not a real message'), trailing: Text(r.$2)),
        ]),
      );

  @override
  Widget networkSliver(BuildContext context, ChatTabArgs args) =>
      const SliverToBoxAdapter(child: ListTile(title: Text('Fixture: North Ridge repeater')));

  @override
  Widget contactsSegment(BuildContext context, {VoidCallback? seeNearby}) =>
      const Center(child: ListTile(title: Text('Fixture: Alex'), subtitle: Text('Debug fixture, not a real message')));

  @override
  Future<void> refresh() async {}

  @override
  Future<void> newChat(BuildContext context, {required VoidCallback showContacts}) async => showContacts();

  @override
  Future<void> quickSwitch(BuildContext context) async {}

  @override
  void openMessageSearch(BuildContext context) {}
}

bool get chatFixturesAllowed => kDebugMode;
