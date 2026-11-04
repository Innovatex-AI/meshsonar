// Quick replies: the chip strip above the composer (chat plan 4.3). Stored in the chat `settings` table under
// `quick_replies` as a JSON list. Pure Dart.
import 'dart:convert';

import 'store.dart';

const List<String> defaultQuickReplies = ['On my way', 'OK', "Can't talk, driving", 'Need help', 'Arrived', 'Call me'];

const String quickRepliesKey = 'quick_replies';

List<String> loadQuickReplies(ChatStore store) {
  final raw = store.db.setting(quickRepliesKey);
  if (raw == null) return defaultQuickReplies;
  try {
    final v = jsonDecode(raw);
    if (v is List) {
      final out = [for (final e in v) if (e is String && e.trim().isNotEmpty) e.trim()];
      return out;
    }
  } catch (_) {}
  return defaultQuickReplies;
}

/// Saves [replies]; the defaults are stored as "unset" so a future change to them reaches everyone who never edited.
void saveQuickReplies(ChatStore store, List<String> replies) {
  final clean = [for (final r in replies) if (r.trim().isNotEmpty) r.trim()];
  final same = clean.length == defaultQuickReplies.length && [for (var i = 0; i < clean.length; i++) clean[i] == defaultQuickReplies[i]].every((b) => b);
  store.db.putSetting(quickRepliesKey, same ? null : jsonEncode(clean));
}

/// "Return sends" (More > Chat): with a hardware keyboard Return sends and Shift-Return starts a new line. Off by default
/// (Cmd-Return always sends). Stored in the chat `settings` table.
const String returnSendsKey = 'return_sends';

bool loadReturnSends(ChatStore store) => store.db.setting(returnSendsKey) == '1';

void saveReturnSends(ChatStore store, bool on) => store.db.putSetting(returnSendsKey, on ? '1' : null);
