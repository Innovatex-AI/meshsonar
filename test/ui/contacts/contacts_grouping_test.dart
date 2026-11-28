import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/contacts/contacts_controller.dart';
import 'package:meshsonar/ui/contacts/contacts_grouping.dart';

import '../../chat/contact_support.dart';

ContactRow row(int n, String name, {ContactType type = ContactType.companion, bool fav = false}) =>
    ContactRow(radioContact(n, type: type).copyWith(customName: name, favourite: fav));

void main() {
  test('people only, favourites first, A-Z letters, # last, case-insensitive', () {
    final g = groupContacts([
      row(1, 'zed'),
      row(2, 'Alex'),
      row(3, 'alice'),
      row(4, '7-Eleven'),
      row(5, 'Hilltop', type: ContactType.repeater),
      row(6, 'Maya', fav: true),
      row(7, 'Bob', fav: true),
      row(8, 'Élan'),
    ]);
    expect(g.favourites.map((r) => r.contact.displayName), ['Bob', 'Maya']);
    expect(g.letters.map((l) => l.letter), ['A', 'Z', 'É', '#']);
    expect(g.letters.first.rows.map((r) => r.contact.displayName), ['Alex', 'alice']);
    expect(g.count, 7);
    expect(g.letters.expand((l) => l.rows).any((r) => r.contact.type != ContactType.companion), isFalse);
  });

  test('empty in, empty out; no people means isEmpty', () {
    expect(groupContacts(const []).isEmpty, isTrue);
    expect(groupContacts([row(1, 'Tower', type: ContactType.repeater)]).isEmpty, isTrue);
  });

  test('letterOf', () {
    expect(letterOf('  maya'), 'M');
    expect(letterOf(''), '#');
    expect(letterOf('9lives'), '#');
  });

  test('heardWords: how recently heard, in words (C-V2; was a signal-bars glyph)', () {
    final now = 1000000000000;
    Contact c(int? ago) => radioContact(1).copyWith(lastHeardMs: ago == null ? null : now - ago, lastAdvertTs: null);
    expect(heardWords(c(10000), now), 'just now');
    expect(heardWords(c(5 * 60000), now), '5 min ago');
    expect(heardWords(c(4 * 3600000), now), '4 h ago');
    expect(heardWords(c(3 * 86400000), now), '3 d ago');
    expect(heardWords(c(null), now), 'Not heard yet');
  });
}
