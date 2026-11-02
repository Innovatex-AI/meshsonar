// Lint ban (WP0, chat plan 2.6 and Drive plan WP0): popups go through the four helpers in lib/ui/design/app_surfaces.dart,
// and the Chat area uses Cupertino widgets and AppSymbols, not Material ones.
//
//   * everywhere in lib/: AlertDialog(, showDialog(, PopupMenuButton, showSnackBar(, showModalBottomSheet(
//   * in lib/ui/chat, lib/ui/contacts, lib/ui/radios: the Material widgets of chat plan 2.6 "Never" column, `Icons.` and
//     `CupertinoIcons.`
//
// Current offenders are an allow-list that may only SHRINK: test/lint/widget_ban_allowlist.txt, one `path|pattern|count`
// per line. A new use fails the test; fixing a use makes the list stale, which also fails (so the list stays exact and
// the owning work package deletes its lines). Regenerate with `UPDATE_WIDGET_BAN=1 flutter test test/lint/widget_ban_test.dart`
// ONLY to record a deletion, never to admit a new offender.
//
// The Android branches of the helpers (app_surfaces.dart) and the symbol table (app_symbols.dart) are exempt.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _exempt = {'lib/ui/design/app_surfaces.dart', 'lib/ui/design/app_symbols.dart'};

final _global = <String, RegExp>{
  'AlertDialog(': RegExp(r'\bAlertDialog\('),
  'showDialog(': RegExp(r'\bshowDialog\s*[<(]'),
  'PopupMenuButton': RegExp(r'\bPopupMenuButton\b'),
  'showSnackBar(': RegExp(r'\bshowSnackBar\('),
  'showModalBottomSheet(': RegExp(r'\bshowModalBottomSheet\s*[<(]'),
};

const _chatDirs = ['lib/ui/chat/', 'lib/ui/contacts/', 'lib/ui/radios/'];
final _chatOnly = <String, RegExp>{
  'ListTile(': RegExp(r'\bListTile\('),
  'Card(': RegExp(r'\bCard\('),
  'Divider(': RegExp(r'\bDivider\('),
  'ElevatedButton': RegExp(r'\bElevatedButton\b'),
  'FilledButton': RegExp(r'\bFilledButton\b'),
  'TextButton': RegExp(r'\bTextButton\b'),
  'InkWell(': RegExp(r'\bInkWell\('),
  'TextField(': RegExp(r'\bTextField\('),
  'SwitchListTile(': RegExp(r'\bSwitchListTile\('),
  'SegmentedButton': RegExp(r'\bSegmentedButton\b'),
  'CircularProgressIndicator': RegExp(r'\bCircularProgressIndicator\b'),
  'Chip(': RegExp(r'\bChip\('),
  'FilterChip(': RegExp(r'\bFilterChip\('),
  'Icons.': RegExp(r'\bIcons\.'),
  'CupertinoIcons.': RegExp(r'\bCupertinoIcons\.'),
};

Map<String, int> scan() {
  final out = <String, int>{};
  final root = Directory('lib');
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    final path = f.path.replaceAll('\\', '/');
    if (!path.endsWith('.dart') || _exempt.contains(path)) continue;
    final chat = _chatDirs.any(path.startsWith);
    final pats = {..._global, if (chat) ..._chatOnly};
    final lines = f.readAsLinesSync();
    for (final line in lines) {
      final t = line.trimLeft();
      if (t.startsWith('//')) continue; // comments and doc comments
      final code = t.contains(' //') ? t.substring(0, t.indexOf(' //')) : t;
      for (final e in pats.entries) {
        final n = e.value.allMatches(code).length;
        if (n > 0) out['$path|${e.key}'] = (out['$path|${e.key}'] ?? 0) + n;
      }
    }
  }
  return out;
}

Map<String, int> readAllow() {
  final f = File('test/lint/widget_ban_allowlist.txt');
  final out = <String, int>{};
  if (!f.existsSync()) return out;
  for (final l in f.readAsLinesSync()) {
    if (l.trim().isEmpty || l.startsWith('#')) continue;
    final i = l.lastIndexOf('|');
    out[l.substring(0, i)] = int.parse(l.substring(i + 1));
  }
  return out;
}

void main() {
  test('banned popup and Material widgets stay within the shrinking allow-list', () {
    final actual = scan();
    if (Platform.environment['UPDATE_WIDGET_BAN'] == '1') {
      final keys = actual.keys.toList()..sort();
      File('test/lint/widget_ban_allowlist.txt').writeAsStringSync(
        '# Allow-list of current offenders (see widget_ban_test.dart). It may only shrink. Format: path|pattern|count\n'
        '${keys.map((k) => '$k|${actual[k]}').join('\n')}\n',
      );
      return;
    }
    final allow = readAllow();
    final added = <String>[], stale = <String>[];
    for (final e in actual.entries) {
      final a = allow[e.key] ?? 0;
      if (e.value > a) added.add('${e.key}: ${e.value} (allowed $a)');
    }
    for (final e in allow.entries) {
      final n = actual[e.key] ?? 0;
      if (n < e.value) stale.add('${e.key}: now $n, list says ${e.value}');
    }
    expect(added, isEmpty, reason: 'New banned usage: use showAppSheet / showAppAlert / showAppActionSheet / showAppToast and Cupertino widgets + AppSymbols.');
    expect(stale, isEmpty, reason: 'Allow-list is stale (good news): regenerate with UPDATE_WIDGET_BAN=1 to record the deletion.');
  });

  test('helpers and symbols are the only files outside the ban that name the Android branches', () {
    for (final p in _exempt) {
      expect(File(p).existsSync(), isTrue, reason: '$p is exempt but missing');
    }
  });

  test('Barlow appears in lib/ only in the PDF export, the web glyph constants and the document asset paths', () {
    const allowed = {
      'lib/ui/design/app_type.dart', // documentRegular / documentBold asset paths (PDF only)
      'lib/ui/report/pdf_export.dart', // PDF export
      'lib/core/report_pdf.dart', // PDF renderer
      'lib/core/offline_style.dart', // web glyph stacks (MapLibre on the website), never loaded by the app
    };
    final hits = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || allowed.contains(path)) continue;
      if (f.readAsStringSync().contains('Barlow')) hits.add(path);
    }
    expect(hits, isEmpty);
  });
}
