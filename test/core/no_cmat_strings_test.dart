// 0.5.0 brand (docs/specs/app-0.5.0.md §3): the website is "MeshSonar" everywhere the user can see; "CMAT" may stay
// only in comments and identifiers (CmatClient, RepeaterSource.cmat, ...), never in a string literal in lib/.
// Wire/contract values that must stay "CMAT" go in [allowedWireLiterals] with a reason; there are none today (the
// app's problem reports and uploads send app.name "MeshSonar").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `file:literal` pairs allowed to contain CMAT because another system expects the exact value.
const Map<String, String> allowedWireLiterals = {};

final _cmat = RegExp(r'\bCMAT\b');

/// String literals on one line of Dart, with the line's `//` comment (outside any string) removed.
List<String> stringLiterals(String line) {
  final out = <String>[];
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == '/' && i + 1 < line.length && line[i + 1] == '/') break; // comment to end of line
    if (c == "'" || c == '"') {
      final raw = i > 0 && line[i - 1] == 'r';
      final buf = StringBuffer();
      var j = i + 1;
      while (j < line.length && line[j] != c) {
        if (!raw && line[j] == '\\' && j + 1 < line.length) {
          buf.write(line[j + 1]);
          j += 2;
          continue;
        }
        buf.write(line[j]);
        j++;
      }
      out.add(buf.toString());
      i = j + 1;
      continue;
    }
    i++;
  }
  return out;
}

void main() {
  test('the literal scanner finds strings and skips comments', () {
    expect(stringLiterals(r"""final a = 'on CMAT\'s list' + "x"; // 'CMAT' in a comment"""), ["on CMAT's list", 'x']);
    expect(stringLiterals('/// the CMAT list'), isEmpty);
    expect(stringLiterals('final c = CmatClient(); // CMAT'), isEmpty);
  });

  test('no string literal in lib/ shows "CMAT" (outside the wire allow-list)', () {
    final found = <String>[];
    final files = Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    for (final f in files) {
      final lines = f.readAsLinesSync();
      for (var n = 0; n < lines.length; n++) {
        for (final s in stringLiterals(lines[n])) {
          if (!_cmat.hasMatch(s)) continue;
          final id = '${f.path.replaceAll('\\', '/')}:$s';
          if (allowedWireLiterals.containsKey(id)) continue;
          found.add('${f.path}:${n + 1}: "$s"');
        }
      }
    }
    expect(found, isEmpty, reason: 'user-visible text calls the website "MeshSonar"; a wire value goes in the allow-list');
  });

  test('the app identifies itself as MeshSonar on the wire (problem reports, uploads, companion)', () {
    for (final path in ['lib/platform/app_version.dart', 'lib/app/services.dart', 'lib/core/sync_service.dart']) {
      expect(File(path).readAsStringSync(), contains("AppInfo(name: 'MeshSonar'"), reason: path);
    }
  });
}
