// One wording per condition across the Chat UI (chat plan 2.1 and 4.16). Strings that appear in more than one place live
// here; test/ui/copy_consistency_test.dart keeps the protocol words (Path, hops, hash, flood, Advert, "slot N") out of the
// primary screens.

/// Title of an empty search result, wherever the search is (chats, a conversation, the network).
String noMatchesTitle(String query) => 'No matches for “${query.trim()}”';

/// Body under [noMatchesTitle] when the search was over message text.
const String noMatchesTextBody = 'Try a shorter word, or check the spelling.';

/// The button and menu entry that sends the radio's own advert (Network, Contacts empty state, Chats empty state).
const String announceMyself = 'Announce myself';

/// Said when something needs the radio and it is not connected.
const String connectRadioFirst = 'Connect your radio first.';
