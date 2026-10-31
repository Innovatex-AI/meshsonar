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
}
