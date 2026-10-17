// AC-9 storage half (spec m1-app-0.4.0 §3 "Offline"): one saved draft in report_draft.json next to settings,
// written atomically like FileSettingsStore. AppState's use of it is in test/ui/report_problem_test.dart.
//
// API under test (lib/core/report_draft_store.dart): abstract ReportDraftStore { Future<String?> load();
//   Future<void> save(String draft); Future<void> clear(); } and FileReportDraftStore(File).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/report_draft_store.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('meshsonar_draft_'));
  tearDown(() async => tmp.delete(recursive: true));

  test('no file → null; save → load gives the same text; the folder is created; no temp file left', () async {
    final f = File(p.join(tmp.path, 'a', 'report_draft.json'));
    final store = FileReportDraftStore(f);
    expect(await store.load(), isNull);
    const draft = '{"body": "{\\n  \\"category\\": \\"upload\\"\\n}", "form": {"category": "upload"}} 😬';
    await store.save(draft);
    expect(f.existsSync(), isTrue);
    expect(await FileReportDraftStore(f).load(), draft, reason: 'survives an app restart (a new store on the same file)');
    expect(File('${f.path}.tmp').existsSync(), isFalse);
  });

  test('a new save replaces the old draft (only one is kept); clear deletes the file', () async {
    final f = File(p.join(tmp.path, 'report_draft.json'));
    final store = FileReportDraftStore(f);
    await store.save('first');
    await store.save('second');
    expect(await store.load(), 'second');
    expect(tmp.listSync().whereType<File>().map((x) => p.basename(x.path)), ['report_draft.json']);
    await store.clear();
    expect(f.existsSync(), isFalse);
    expect(await store.load(), isNull);
    await store.clear(); // clearing nothing is fine
  });

  test('rapid saves are serialized; the last one wins', () async {
    final store = FileReportDraftStore(File(p.join(tmp.path, 'report_draft.json')));
    await Future.wait(<Future<void>>[for (var i = 0; i < 20; i++) store.save('draft $i')]);
    expect(await store.load(), 'draft 19');
  });

  test('the real app keeps the draft as report_draft.json next to settings.json', () {
    final wiring = File('lib/app/wiring.dart').readAsStringSync();
    expect(wiring, contains('FileReportDraftStore('));
    expect(wiring, contains('report_draft.json'));
  });
}
