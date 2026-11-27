// Pure grouping for the Contacts segment (plan 4.5): people only, Favourites first, then A-Z letter groups. No widgets here
// so the order is easy to test.
import '../../chat/models.dart';
import '../../core/time_format.dart' as tf;
import 'contacts_controller.dart';

/// One sticky letter section ("A", "B", ... and "#" for names that do not start with a letter, last).
class LetterGroup {
  final String letter;
  final List<ContactRow> rows;
  const LetterGroup(this.letter, this.rows);
}

class ContactGroups {
  final List<ContactRow> favourites;
  final List<LetterGroup> letters;
  const ContactGroups(this.favourites, this.letters);
  bool get isEmpty => favourites.isEmpty && letters.isEmpty;
  int get count => favourites.length + letters.fold(0, (n, g) => n + g.rows.length);
}

/// The section letter of [name]: its first character upper-cased when that is a letter, else "#".
String letterOf(String name) {
  final t = name.trim();
  if (t.isEmpty) return '#';
  final ch = String.fromCharCode(t.runes.first).toUpperCase();
  final u = ch.runes.first;
  final isLetter = (u >= 0x41 && u <= 0x5A) || (u >= 0xC0 && u <= 0x24F && u != 0xD7 && u != 0xF7);
  return isLetter ? ch : '#';
}

int _byName(ContactRow a, ContactRow b) {
  final c = a.contact.displayName.toLowerCase().compareTo(b.contact.displayName.toLowerCase());
  return c != 0 ? c : a.contact.publicKey.compareTo(b.contact.publicKey);
}

/// People only (type 1), favourites in their own group, everyone else by letter. Both sorted A-Z, case-insensitive.
ContactGroups groupContacts(Iterable<ContactRow> rows) {
  final people = [for (final r in rows) if (r.contact.type == ContactType.companion) r]..sort(_byName);
  final favs = [for (final r in people) if (r.contact.favourite) r];
  final map = <String, List<ContactRow>>{};
  for (final r in people) {
    if (r.contact.favourite) continue;
    map.putIfAbsent(letterOf(r.contact.displayName), () => []).add(r);
  }
  final keys = map.keys.toList()
    ..sort((a, b) => a == '#' ? 1 : (b == '#' ? -1 : a.compareTo(b)));
  return ContactGroups(favs, [for (final k in keys) LetterGroup(k, map[k]!)]);
}

/// What a row says for a contact never heard.
const String notHeardYet = 'Not heard yet';

/// When [c] was last heard, in words, for the trailing column of a row: "just now", "5 min ago", "4 h ago", "3 d ago", or
/// "Not heard yet". One wording with the rest of the app (lib/core/time_format.dart `relativeTime`). A contact has no
/// stored signal strength (the radio does not keep one per contact), so this is about time, never dBm.
String heardWords(Contact c, int nowMs) {
  final ms = c.lastHeardMs ?? (c.lastAdvertTs == null ? null : c.lastAdvertTs! * 1000);
  if (ms == null || ms <= 0) return notHeardYet;
  return tf.relativeTime(DateTime.fromMillisecondsSinceEpoch(ms), now: DateTime.fromMillisecondsSinceEpoch(nowMs));
}
