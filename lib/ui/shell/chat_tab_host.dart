// The seam between the shell's Chat tab and the chat services (lib/chat, wave 1B). Nothing in the shell imports
// lib/chat. When chat lands, its wiring code sets [ChatTabHost.provider] once at startup; until then the Chat tab shows
// the honest "messages arrive once you connect a radio" states (and, in debug builds only, fixtures behind
// [ChatTabHost.debugFixtures]).
//
//   ChatTabHost.provider.value = MyChatTabProvider(chatService);
//
// A provider supplies the two lists and the unread count; the host adds the app bar, the Contacts | Channels
// segmented control, the connect call to action and the empty states around them.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// What the chat services give the Chat tab. All views are built inside the tab's own scaffold body.
abstract class ChatTabProvider {
  /// Notifies when [unreadConversations] or the lists change (the tab badge and lists listen to it).
  Listenable get changes;

  /// Conversations with unread messages, shown as the badge on the Chat tab.
  int get unreadConversations;

  /// Contacts and direct messages. Return an empty-state widget of your own if there are none.
  Widget contactsView(BuildContext context);

  /// Channels (the wardrive channel appears in a pinned System row, per the design doc).
  Widget channelsView(BuildContext context);

  /// True when there are no conversations at all (the host then shows its own first-run empty state).
  bool get isEmpty;

  /// Extra app-bar buttons for the Chat tab (global search).
  List<Widget> appBarActions(BuildContext context) => const [];
}

/// Which half of the Chat tab is showing.
enum ChatSegment { contacts, channels }

class ChatTabHost {
  ChatTabHost._();

  /// Set by the chat wiring when lib/chat is available; null means "chat not built into this app yet".
  static final ValueNotifier<ChatTabProvider?> provider = ValueNotifier<ChatTabProvider?>(null);

  /// Opens one conversation full screen from anywhere (a tapped notification or banner). Set by the chat wiring; null before
  /// chat is up, when a tap only brings the Chat tab to the front.
  static void Function(BuildContext context, String convKey)? openConversation;

  /// Debug builds only: show fixture conversations so the structure can be reviewed without a radio.
  static final ValueNotifier<bool> debugFixtures = ValueNotifier<bool>(false);

  static int get unread => provider.value?.unreadConversations ?? 0;
}

/// Fixture provider for the debug flag. Lists are static text; nothing here is stored or sent.
class DebugFixtureChat implements ChatTabProvider {
  @override
  Listenable get changes => ChangeNotifier();
  @override
  int get unreadConversations => 2;
  @override
  bool get isEmpty => false;
  @override
  List<Widget> appBarActions(BuildContext context) => const [];

  Widget _list(List<(String, String, String)> rows) => ListView(
        children: [
          for (final r in rows)
            ListTile(
              leading: CircleAvatar(child: Text(r.$1.characters.first.toUpperCase())),
              title: Text(r.$1),
              subtitle: Text(r.$2, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Text(r.$3),
            ),
        ],
      );

  @override
  Widget contactsView(BuildContext context) => _list(const [
        ('Fixture: Alex', 'Debug fixture, not a real message', '9:41'),
        ('Fixture: Sam', 'Debug fixture, not a real message', 'Mon'),
      ]);

  @override
  Widget channelsView(BuildContext context) => _list(const [
        ('Fixture: Public', 'Debug fixture, not a real message', '9:12'),
        ('Fixture: #hamradio', 'Debug fixture, not a real message', 'Sun'),
      ]);
}

bool get chatFixturesAllowed => kDebugMode;
