// Copy that contradicts the automatic driver key or the removal of the Simulator must not come back in a string a
// person can read. Reads every string literal in lib/ui and lib/app/messages.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no stale approval / request-a-key / Lovable wording in user-facing strings', () {
    final banned = RegExp(
      r"approval|admin approves|an admin needs|Request a (new )?(driver )?key|Request one|request a new key|Lovable|THIRD_PARTY_NOTICES|server admin",
      caseSensitive: false,
    );
    final files = [
      ...Directory('lib/ui').listSync(recursive: true).whereType<File>(),
      File('lib/app/messages.dart'),
      File('lib/app/app_state.dart'),
    ].where((f) => f.path.endsWith('.dart'));
    final hits = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].trimLeft();
        if (l.startsWith('//')) continue;
        if (!l.contains("'") && !l.contains('"')) continue;
        if (banned.hasMatch(l)) hits.add('${f.path}:${i + 1}: $l');
      }
    }
    expect(hits, isEmpty, reason: hits.join('\n'));
  });

  // Chat plan 2.1: protocol words appear only in Details sheets, Advanced rows and the Console. A line that is one of those
  // says so with a trailing `// copy-ok: why` comment; everything else in the primary Chat screens must use the plain words.
  test('Chat primary screens use plain words: no Path, hops, hash, flood, Advert or "slot N"', () {
    final banned = RegExp(r'\b(paths?|hops?|hash(es)?|flood(s|ed|ing)?|adverts?|slots?)\b', caseSensitive: false);
    final literal = RegExp(r"'((?:[^'\\\n]|\\.)*)'|" r'"((?:[^"\\\n]|\\.)*)"');
    final files = <File>[
      ...Directory('lib/ui/chat').listSync().whereType<File>(),
      ...Directory('lib/ui/contacts').listSync().whereType<File>(),
      File('lib/ui/shell/chat_tab.dart'),
      File('lib/ui/tools/ping_result_sheet.dart'),
      File('lib/ui/radios/repeater_admin/login_sheet.dart'),
      File('lib/ui/radios/repeater_admin/repeater_dashboard_screen.dart'),
      File('lib/ui/radios/repeater_admin/dashboard_widgets.dart'),
      File('lib/chat/chat_copy.dart'),
      File('lib/chat/delivery_text.dart'),
      File('lib/chat/message_info.dart'),
    ].where((f) => f.path.endsWith('.dart') && f.existsSync());
    final hits = <String>[];
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final l = lines[i].replaceAll(RegExp(r'\$\{[^}]*\}'), ' ');
        final t = lines[i].trimLeft();
        if (t.startsWith('//') || t.startsWith('import ') || t.startsWith('export ') || lines[i].contains('copy-ok') || lines[i].contains('Key(')) continue;
        for (final m in literal.allMatches(l)) {
          var text = m.group(1) ?? m.group(2) ?? '';
          text = text.replaceAll(RegExp(r'\$\{[^}]*\}'), ' ').replaceAll(RegExp(r'\$[A-Za-z_]\w*'), ' ');
          if (text.startsWith('package:') || text.startsWith('dart:')) continue;
          // Keys, symbol names and identifiers are not copy: only strings with a space or a capital/sentence shape count.
          if (!text.contains(' ') && text.toLowerCase() == text) continue;
          if (banned.hasMatch(text)) hits.add('${f.path}:${i + 1}: $text');
        }
      }
    }
    expect(hits, isEmpty, reason: 'Use the plain word (Route, repeaters, Announce myself, searching) or mark the line `// copy-ok: Details/Advanced`:\n${hits.join('\n')}');
  });

  test('empty searches say the same thing everywhere (chat_copy)', () {
    final dirs = [Directory('lib/ui/chat'), Directory('lib/ui/contacts')];
    final hits = <String>[];
    for (final d in dirs) {
      for (final f in d.listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
        final src = f.readAsStringSync();
        if (src.contains("'Nothing found'") || src.contains("'No matches for")) hits.add(f.path);
      }
    }
    expect(hits, isEmpty, reason: 'Use noMatchesTitle() from chat/chat_copy.dart:\n${hits.join('\n')}');
  });
}
