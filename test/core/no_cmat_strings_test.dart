// 0.5.0 brand (docs/specs/app-0.5.0.md §3): the website is "MeshSonar" everywhere the user can see. After comments
// are stripped, no whole-word all-caps CMAT may remain anywhere in lib/**/*.dart: not in code, not in any string
// literal (escapes decoded, interpolation bodies included, adjacent or `+`-joined literals concatenated, multi-line
// strings included). Identifiers use Cmat/cmat (CmatClient, RepeaterSource.cmat), so they are unaffected. The same
// rule covers the Android resources, the iOS/macOS Info.plists and the pubspec description.
//
// Wire/contract values that must stay "CMAT" go in [allowedWireValues] with a reason; there are none today (the
// app's problem reports and uploads send app.name "MeshSonar").
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `path` → the exact decoded literal allowed to contain CMAT there, because another system expects that value.
const Map<String, Set<String>> allowedWireValues = {};

final _cmat = RegExp(r'\bCMAT\b');

/// A Dart file with its comments removed: [code] (string contents decoded in place) and [literals] (each run of
/// adjacent or `+`-joined string literals, decoded and concatenated, interpolations removed).
class DartText {
  final String code;
  final List<String> literals;
  DartText(this.code, this.literals);
}

DartText lexDart(String src) => (_DartLexer(src)..lexCode()).result;

class _DartLexer {
  final String s;
  int i = 0;
  final code = StringBuffer();
  final literals = <String>[];

  /// True right after a literal while only whitespace, `+` or comments follow: the next literal joins its run.
  bool joinable = false;

  _DartLexer(this.s);

  DartText get result => DartText(code.toString(), literals);

  String? _at(int k) => i + k < s.length ? s[i + k] : null;
  static bool _ident(String? c) => c != null && RegExp(r'[A-Za-z0-9_$]').hasMatch(c);

  void lexCode({bool untilBrace = false}) {
    var depth = 0;
    while (i < s.length) {
      final c = s[i];
      if (c == '/' && _at(1) == '/') {
        while (i < s.length && s[i] != '\n') {
          i++;
        }
        continue;
      }
      if (c == '/' && _at(1) == '*') {
        _skipBlockComment();
        code.write(' ');
        continue;
      }
      if (c == 'r' && (_at(1) == "'" || _at(1) == '"') && !_ident(i > 0 ? s[i - 1] : null)) {
        i++;
        _lexString(raw: true);
        continue;
      }
      if (c == "'" || c == '"') {
        _lexString(raw: false);
        continue;
      }
      if (untilBrace) {
        if (c == '{') {
          depth++;
        } else if (c == '}') {
          if (depth == 0) {
            i++;
            return;
          }
          depth--;
        }
      }
      if (!(c.trim().isEmpty || c == '+')) joinable = false;
      code.write(c);
      i++;
    }
  }

  void _skipBlockComment() {
    var depth = 0;
    while (i < s.length) {
      if (s.startsWith('/*', i)) {
        depth++;
        i += 2;
      } else if (s.startsWith('*/', i)) {
        depth--;
        i += 2;
        if (depth == 0) return;
      } else {
        i++;
      }
    }
  }

  void _lexString({required bool raw}) {
    final joinAtStart = joinable;
    final q = s[i];
    final triple = s.startsWith(q * 3, i);
    i += triple ? 3 : 1;
    final value = StringBuffer();
    code.write(q);
    while (i < s.length) {
      if (triple ? s.startsWith(q * 3, i) : s[i] == q) {
        i += triple ? 3 : 1;
        break;
      }
      if (!triple && s[i] == '\n') break; // unterminated: stop at the line end
      final c = s[i];
      if (!raw && c == r'\' && i + 1 < s.length) {
        final d = _escape();
        value.write(d);
        code.write(d);
        continue;
      }
      if (!raw && c == r'$') {
        if (_at(1) == '{') {
          i += 2;
          joinable = false;
          code.write(' ');
          lexCode(untilBrace: true); // the interpolation is code: its own literals and tokens are checked too
          code.write(' ');
          continue;
        }
        i++;
        final start = i;
        while (i < s.length && RegExp(r'[A-Za-z0-9_]').hasMatch(s[i])) {
          i++;
        }
        code.write(' ${s.substring(start, i)} ');
        continue;
      }
      value.write(c);
      code.write(c);
      i++;
    }
    code.write(q);
    if (joinAtStart && literals.isNotEmpty) {
      literals[literals.length - 1] += value.toString();
    } else {
      literals.add(value.toString());
    }
    joinable = true;
  }

  /// Decodes the escape at [i] (a backslash) and moves past it.
  String _escape() {
    final n = s[i + 1];
    String hex(int from, int to) => String.fromCharCode(int.parse(s.substring(from, to), radix: 16));
    try {
      switch (n) {
        case 'n':
          i += 2;
          return '\n';
        case 't':
          i += 2;
          return '\t';
        case 'r':
          i += 2;
          return '\r';
        case 'b':
          i += 2;
          return '\b';
        case 'f':
          i += 2;
          return '\f';
        case 'v':
          i += 2;
          return '\v';
        case 'x':
          final r = hex(i + 2, i + 4);
          i += 4;
          return r;
        case 'u':
          if (_at(2) == '{') {
            final end = s.indexOf('}', i + 3);
            final r = hex(i + 3, end);
            i = end + 1;
            return r;
          }
          final r = hex(i + 2, i + 6);
          i += 6;
          return r;
      }
    } catch (_) {}
    i += 2;
    return n; // \' \" \\ \$ and any other escaped character stand for themselves
  }
}

/// CMAT findings in Dart source: whole-word tokens in the comment-free code and in joined literal runs.
List<String> cmatInDart(String src, {Set<String> allowed = const {}}) {
  final t = lexDart(src);
  final out = <String>[];
  for (final lit in t.literals) {
    if (_cmat.hasMatch(lit) && !allowed.contains(lit)) out.add('literal "$lit"');
  }
  var code = t.code;
  for (final a in allowed) {
    code = code.replaceAll(a, '');
  }
  for (final line in code.split('\n')) {
    if (_cmat.hasMatch(line)) out.add('code: ${line.trim()}');
  }
  return out;
}

/// XML/plist/YAML text: XML comments removed, `&#…;` entities and `\uXXXX` escapes decoded.
String decodeMarkup(String src) => src
    .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), ' ')
    .replaceAllMapped(RegExp(r'&#[xX]([0-9A-Fa-f]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
    .replaceAllMapped(RegExp(r'&#([0-9]+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
    .replaceAllMapped(RegExp(r'\\u([0-9A-Fa-f]{4})'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)));

void main() {
  group('the Dart scan catches every way CMAT can reach the screen', () {
    const caught = {
      'plain literal': "final a = 'CMAT';",
      'double quotes': 'final a = "on CMAT";',
      'raw string': "final a = r'CMAT';",
      'ternary inside interpolation': r"""final a = 'Name from ${x ? 'CMAT' : 'map'}';""",
      'interpolation with nested braces': r"""final a = '${{1: 'CMAT'}[1]}';""",
      'multi-line string body': "final a = '''\nfirst line\nnot on CMAT yet\n''';",
      'multi-line double-quoted': 'final a = """\nCMAT\n""";',
      'unicode escape of C': r"final a = 'CMAT';",
      'braced unicode escape': r"final a = '\u{43}MAT';",
      'hex escape': r"final a = '\x43\x4d\x41\x54';",
      'escaped plain letter': r"final a = '\CMAT';",
      'adjacent literals': "final a = 'CM' 'AT';",
      'adjacent across lines': "final a = 'CM'\n    'AT';",
      'joined with +': "final a = 'CM' + 'AT';",
      'adjacent around a comment': "final a = 'CM' /* x */ 'AT';",
      'split around interpolation': r"final a = 'CM${''}AT';",
      'split with \$identifier then adjacent': r"final a = 'C$x' 'MAT';",
      'after a string holding //': "final a = 'https://x' + ' CMAT';",
      'bare code token': 'const CMAT = 1;',
    };
    caught.forEach((name, src) {
      test(name, () => expect(cmatInDart(src), isNotEmpty, reason: src));
    });

    const clean = {
      'line comment': "final a = 'x'; // CMAT's list",
      'doc comment': '/// From CMAT\'s list.\nfinal a = 1;',
      'block comment': "/* CMAT */ final a = 'x';",
      'nested block comment': "/* a /* CMAT */ CMAT */ final a = 'x';",
      'identifiers': 'final c = CmatClient(); final s = RepeaterSource.cmat; final u = unknownToCmat;',
      'lower case / longer word': "final a = 'cmat'; final b = 'CMATS'; final c = 'XCMAT';",
      'separate literals': "f('CM', 'AT');",
      'url with //': "final a = 'https://meshsonar.com'; // not CMAT",
    };
    clean.forEach((name, src) {
      test('not flagged: $name', () => expect(cmatInDart(src), isEmpty, reason: src));
    });

    test('markup: comments stripped, entities and \\u escapes decoded', () {
      expect(_cmat.hasMatch(decodeMarkup('<string>&#67;MAT</string>')), isTrue);
      expect(_cmat.hasMatch(decodeMarkup('<string>&#x43;MAT</string>')), isTrue);
      expect(_cmat.hasMatch(decodeMarkup(r'<string>CMAT</string>')), isTrue);
      expect(_cmat.hasMatch(decodeMarkup('<!-- CMAT --><string>MeshSonar</string>')), isFalse);
    });
  });

  test('no CMAT in lib/**/*.dart after comments are stripped (outside the wire allow-list)', () {
    final found = <String>[];
    final files =
        Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();
    expect(files.length, greaterThan(20), reason: 'the scan itself works');
    for (final f in files) {
      final path = f.path.replaceAll(r'\', '/');
      for (final hit in cmatInDart(f.readAsStringSync(), allowed: allowedWireValues[path] ?? const {})) {
        found.add('$path: $hit');
      }
    }
    expect(found, isEmpty, reason: 'user-visible text calls the website "MeshSonar"; a wire value goes in the allow-list');
  });

  test('no CMAT in Android resources, iOS/macOS Info.plists or the pubspec description', () {
    final files = <File>[
      ...Directory('android/app/src/main/res').listSync(recursive: true).whereType<File>().where(
          (f) => !RegExp(r'\.(png|jpg|jpeg|webp|gif)$').hasMatch(f.path)),
      ...Directory('ios/Runner').listSync().whereType<File>().where((f) => f.path.endsWith('.plist')),
      if (Directory('macos/Runner').existsSync())
        ...Directory('macos/Runner').listSync().whereType<File>().where((f) => f.path.endsWith('.plist')),
    ];
    expect(files.where((f) => f.path.endsWith('Info.plist')), isNotEmpty, reason: 'the scan itself works');
    final found = [
      for (final f in files)
        if (_cmat.hasMatch(decodeMarkup(f.readAsStringSync()))) f.path,
    ];
    final description = RegExp(r'^description:\s*(.*)$', multiLine: true).firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(description, isNotNull);
    if (_cmat.hasMatch(decodeMarkup(description!.group(1)!))) found.add('pubspec.yaml description');
    expect(found, isEmpty);
  });

  test('the app identifies itself as MeshSonar on the wire (problem reports, uploads, companion)', () {
    for (final path in ['lib/platform/app_version.dart', 'lib/app/services.dart', 'lib/core/sync_service.dart']) {
      expect(File(path).readAsStringSync(), contains("AppInfo(name: 'MeshSonar'"), reason: path);
    }
  });
}
