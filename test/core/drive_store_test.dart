import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

void main() {
  group('long drives', longDriveTests);
  late Directory tmp;
  late JsonlDriveStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshsonar_store_');
    store = await JsonlDriveStore.open(tmp);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File sessionFile(String id, String name) => File(p.join(tmp.path, 'sessions', id, name));

  test('start, append, read back round-trips every field, nulls stay null', () async {
    final s = makeSession();
    await store.startSession(s);
    final pings = [for (var i = 0; i < 8; i++) makePing(i)];
    for (final ping in pings) {
      await store.appendPing(s.id, ping);
    }
    final back = await store.pings(s.id);
    expect(back.map((e) => jsonEncode(e.toJson())), pings.map((e) => jsonEncode(e.toJson())));
    expect(back[2].echoes[0].rssiDbm, isNull);
    expect(back[3].neighbor!.remoteSnrDb, isNull);
    expect((await store.session(s.id))!.toJson(), s.toJson());
  });

  test('files on disk: session.json, one JSON line per ping', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendPing(s.id, makePing(0));
    await store.appendPing(s.id, makePing(1));
    final lines = await sessionFile(s.id, 'pings.jsonl').readAsLines();
    expect(lines, hasLength(2));
    for (final l in lines) {
      expect(jsonDecode(l), isA<Map>());
    }
    expect(jsonDecode(await sessionFile(s.id, 'session.json').readAsString())['id'], s.id);
    expect(await File('${sessionFile(s.id, 'session.json').path}.tmp').exists(), isFalse);
  });

  test('heard-nothing pings are preserved with empty echoes', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendPing(s.id, makePing(0));
    final back = (await store.pings(s.id)).single;
    expect(back.heardNothing, isTrue);
    expect(back.echoes, isEmpty);
    expect(back.toJson()['echoes'], <Object>[]);
    expect((await store.sessions()).single.heardCount, 0);
  });

  test('crash-truncated last line is skipped, not fatal; next append starts a fresh line', () async {
    final s = makeSession();
    await store.startSession(s);
    final a = makePing(1), b = makePing(2);
    await store.appendPing(s.id, a);
    await store.appendPing(s.id, b);
    // Simulate a crash mid-write: half a JSON line with no newline.
    final f = sessionFile(s.id, 'pings.jsonl');
    final partial = jsonEncode(makePing(3).toJson());
    await f.writeAsString(partial.substring(0, partial.length ~/ 2), mode: FileMode.append, flush: true);

    // A fresh store (app restart) reads what survived.
    final reopened = await JsonlDriveStore.open(tmp);
    expect((await reopened.pings(s.id)).map((e) => e.id), [a.id, b.id]);
    expect((await reopened.sessions()).single.pingCount, 2);

    // Appending after the crash must not glue onto the broken line.
    final c = makePing(0);
    await reopened.appendPing(s.id, c);
    expect((await reopened.pings(s.id)).map((e) => e.id), [a.id, b.id, c.id]);
    final lines = await f.readAsLines();
    expect(lines, hasLength(3));
    for (final l in lines) {
      expect(() => jsonDecode(l), returnsNormally);
    }
  });

  test('garbage line in the middle is skipped, rest kept', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendPing(s.id, makePing(0));
    await sessionFile(s.id, 'pings.jsonl').writeAsString('{"id": broken\n\n', mode: FileMode.append);
    final reopened = await JsonlDriveStore.open(tmp);
    await reopened.appendPing(s.id, makePing(1));
    expect(await reopened.pings(s.id), hasLength(2));
  });

  test('session.json lost mid-rename falls back to the temp file', () async {
    final s = makeSession();
    await store.startSession(s);
    final f = sessionFile(s.id, 'session.json');
    await f.rename('${f.path}.tmp');
    final reopened = await JsonlDriveStore.open(tmp);
    expect((await reopened.session(s.id))!.id, s.id);
  });

  test('endSession rewrites session.json with ended_at', () async {
    final s = makeSession();
    await store.startSession(s);
    final end = s.startedAt.add(const Duration(minutes: 30));
    await store.endSession(s.id, end);
    expect((await store.session(s.id))!.endedAt, end);
    expect(jsonDecode(await sessionFile(s.id, 'session.json').readAsString())['ended_at'], end.toIso8601String());
  });

  test('sessions(): newest first with ping, heard and synced counts', () async {
    final older = makeSession(startedAt: DateTime.utc(2026, 10, 1, 12));
    final newer = makeSession(startedAt: DateTime.utc(2026, 10, 2, 12));
    await store.startSession(older);
    await store.startSession(newer);
    final pings = [for (var i = 0; i < 8; i++) makePing(i)];
    for (final ping in pings) {
      await store.appendPing(newer.id, ping);
    }
    // An rx ping with echoes doesn't count as "heard" (that's for tx pings).
    final rx = DrivePing(
        id: newId(), ts: DateTime.now().toUtc(), lat: 40.1, lon: -82.9, kind: PingKind.rx,
        echoes: const [Echo(repeater: 'aa')]);
    await store.appendPing(newer.id, rx);
    await store.markSynced(newer.id, [pings[0].id, pings[1].id, 'not-a-ping']);

    final list = await store.sessions();
    expect(list.map((e) => e.session.id), [newer.id, older.id]);
    expect(list[0].pingCount, 9);
    expect(list[0].heardCount, 6); // i%4 in {1,2,3} for i<8 → 6
    expect(list[0].syncedCount, 2);
    expect(list[0].unsyncedCount, 7);
    expect(list[1].pingCount, 0);
  });

  test('unsyncedPings excludes synced and rejected pings', () async {
    final s = makeSession();
    await store.startSession(s);
    final pings = [for (var i = 0; i < 5; i++) makePing(i)];
    for (final ping in pings) {
      await store.appendPing(s.id, ping);
    }
    await store.markSynced(s.id, [pings[0].id]);
    await store.markRejected(s.id, [pings[1].id]);
    expect((await store.unsyncedPings(s.id)).map((e) => e.id), [pings[2].id, pings[3].id, pings[4].id]);
    expect(await store.rejectedIds(s.id), {pings[1].id});
    // Rejected pings are still kept locally.
    expect(await store.pings(s.id), hasLength(5));
  });

  test('end-reported marker round-trips', () async {
    final s = makeSession();
    await store.startSession(s);
    expect(await store.endReported(s.id), isNull);
    final end = DateTime.utc(2026, 10, 15, 22);
    await store.markEndReported(s.id, end);
    expect(await store.endReported(s.id), end);
  });

  test('concurrent appends to one session do not interleave or lose pings', () async {
    final s = makeSession();
    await store.startSession(s);
    final pings = [for (var i = 0; i < 300; i++) makePing(i)];
    await Future.wait([for (final ping in pings) store.appendPing(s.id, ping)]);
    final back = await store.pings(s.id);
    expect(back.map((e) => e.id), pings.map((e) => e.id));
    final lines = await sessionFile(s.id, 'pings.jsonl').readAsLines();
    expect(lines, hasLength(300));
  });

  test('append to an unknown session fails loudly', () async {
    expect(store.appendPing(newId(), makePing(0)), throwsStateError);
  });

  test('path-like session ids are refused', () async {
    expect(() => store.session('../etc'), throwsArgumentError);
  });

  test('deleteSession removes the directory', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendPing(s.id, makePing(0));
    await store.deleteSession(s.id);
    expect(await Directory(p.join(tmp.path, 'sessions', s.id)).exists(), isFalse);
    expect(await store.sessions(), isEmpty);
    expect(await store.session(s.id), isNull);
  });

  test('exportSession writes exactly one Drive Format v1 file that passes the shape rules', () async {
    final s = makeSession(
        id: '3f2a9c1e-1111-4222-8333-944445555666', startedAt: DateTime.utc(2026, 10, 15, 21, 7, 33));
    await store.startSession(s);
    for (var i = 0; i < 12; i++) {
      await store.appendPing(s.id, makePing(i));
    }
    await store.endSession(s.id, DateTime.utc(2026, 10, 15, 22));
    final out = Directory(p.join(tmp.path, 'exports'));
    final f = await store.exportSession(s.id, const AppInfo(name: 'MeshSonar', version: '0.1.0', platform: 'linux'), out);
    expect(p.basename(f.path), 'meshsonar-20261015-2107-3f2a9c1e.json');
    expect(out.listSync().whereType<File>().map((e) => p.basename(e.path)), [p.basename(f.path)]);
    final body = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    expect(shapeProblems(body), isEmpty);
    expect(body['format'], 'meshsonar.drive.v1');
    expect(body.keys.toSet(), {'format', 'app', 'session', 'pings'});
    expect((body['pings'] as List), hasLength(12));
    expect((body['pings'] as List)[0]['echoes'], isEmpty);
    expect((body['pings'] as List)[0]['neighbor'], isNull);
    expect(body['session']['ended_at'], '2026-10-15T22:00:00.000Z');
  });

  test('export of an unknown session throws', () async {
    expect(store.exportSession(newId(), const AppInfo(), tmp), throwsStateError);
  });

  test('duplicate ping ids in the file are read once', () async {
    final s = makeSession();
    await store.startSession(s);
    final a = makePing(1);
    await store.appendPing(s.id, a);
    await store.appendPing(s.id, a);
    expect(await store.pings(s.id), hasLength(1));
  });


  test('sessions(): rejected pings are counted apart and are not "unsynced"', () async {
    final s = makeSession();
    await store.startSession(s);
    final pings = [for (var i = 0; i < 6; i++) makePing(i)];
    for (final ping in pings) {
      await store.appendPing(s.id, ping);
    }
    await store.markSynced(s.id, [pings[0].id, pings[1].id, pings[2].id]);
    await store.markRejected(s.id, [pings[3].id, pings[4].id, 'not-a-ping']);
    final x = (await store.sessions()).single;
    expect(x.syncedCount, 3);
    expect(x.rejectedCount, 2);
    expect(x.unsyncedCount, 1);
    expect(x.hasSomethingToSync, isTrue);
    await store.markSynced(s.id, [pings[5].id]);
    final y = (await store.sessions()).single;
    expect(y.unsyncedCount, 0);
    expect(y.rejectedCount, 2);
    expect(y.hasSomethingToSync, isFalse, reason: 'rejected pings are never re-sent, so Sync has nothing to do');
  });

  test('renameSession rewrites session.json, keeps everything else, and marks the session for re-send', () async {
    final s = makeSession(endedAt: DateTime.utc(2026, 10, 16, 12));
    await store.startSession(s);
    await store.appendPing(s.id, makePing(0));
    expect(await store.sessionResendToken(s.id), isNull);
    expect((await store.sessions()).single.sessionResendPending, isFalse);

    await store.renameSession(s.id, '  Route 3 north ');
    final back = (await store.session(s.id))!;
    expect(back.label, 'Route 3 north');
    final want = s.toJson()..['label'] = 'Route 3 north';
    expect(back.toJson(), want);
    expect(jsonDecode(await sessionFile(s.id, 'session.json').readAsString())['label'], 'Route 3 north');
    final token = await store.sessionResendToken(s.id);
    expect(token, isNotNull);
    expect((await store.sessions()).single.sessionResendPending, isTrue);
    expect((await store.sessions()).single.hasSomethingToSync, isTrue);

    // A newer rename isn't cleared by an upload that started before it.
    await store.renameSession(s.id, 'Route 3');
    await store.clearSessionResend(s.id, token!);
    expect(await store.sessionResendToken(s.id), isNotNull);
    await store.clearSessionResend(s.id, (await store.sessionResendToken(s.id))!);
    expect(await store.sessionResendToken(s.id), isNull);

    // Blank clears the name; exports carry whatever the drive is called now.
    await store.renameSession(s.id, '   ');
    expect((await store.session(s.id))!.label, isNull);
    await store.renameSession(s.id, 'Final name');
    final out = await store.exportSession(s.id, const AppInfo(name: 'MeshSonar', version: '0.3.0'), Directory(p.join(tmp.path, 'out')));
    expect(jsonDecode(await out.readAsString())['session']['label'], 'Final name');
    expect(() => store.renameSession(newId(), 'x'), throwsStateError);
  });

  test('closeOrphanedSessions closes open drives at their last ping (or start) and leaves the rest', () async {
    final start = DateTime.utc(2026, 10, 16, 9);
    final withPings = makeSession(startedAt: start);
    final empty = makeSession(startedAt: start.add(const Duration(hours: 1)));
    final done = makeSession(startedAt: start.add(const Duration(hours: 2)), endedAt: start.add(const Duration(hours: 3)));
    final live = makeSession(startedAt: start.add(const Duration(hours: 4)));
    for (final s in [withPings, empty, done, live]) {
      await store.startSession(s);
    }
    // Out of order on purpose: the latest ping time wins, not the last line.
    await store.appendPing(withPings.id, makePing(0, ts: start.add(const Duration(minutes: 5))));
    await store.appendPing(withPings.id, makePing(1, ts: start.add(const Duration(minutes: 42))));
    await store.appendPing(withPings.id, makePing(2, ts: start.add(const Duration(minutes: 30))));

    final closed = await closeOrphanedSessions(store, except: {live.id});
    expect(closed.toSet(), {withPings.id, empty.id});
    expect((await store.session(withPings.id))!.endedAt, start.add(const Duration(minutes: 42)));
    expect((await store.session(empty.id))!.endedAt, empty.startedAt);
    expect((await store.session(done.id))!.endedAt, done.endedAt);
    expect((await store.session(live.id))!.endedAt, isNull);
    expect(await closeOrphanedSessions(store, except: {live.id}), isEmpty);
  });
}

// Long drives (ROADMAP P2 "Exports aren't chunked"): the server takes at most 5,000 pings per upload body.
void longDriveTests() {
  late Directory tmp;
  late JsonlDriveStore store;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshsonar_long_');
    store = await JsonlDriveStore.open(tmp);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<DriveSession> seed(int n) async {
    final s = makeSession(id: '3f2a9c1e-1111-4222-8333-944445555666', startedAt: DateTime.utc(2026, 10, 15, 21, 7, 33));
    await store.startSession(s);
    final lines = StringBuffer();
    final base = DateTime.utc(2026, 10, 15, 21, 8);
    for (var i = 0; i < n; i++) {
      lines.writeln(jsonEncode(makePing(i, ts: base.add(Duration(seconds: i))).toJson()));
    }
    await File(p.join(tmp.path, 'sessions', s.id, 'pings.jsonl')).writeAsString(lines.toString());
    await store.endSession(s.id, DateTime.utc(2026, 10, 16));
    return s;
  }

  const app = AppInfo(name: 'MeshSonar', version: '0.1.0', platform: 'linux');

  test('12,001 pings export as 3 files of at most 5,000, each a valid upload, every ping exactly once', () async {
    final s = await seed(12001);
    final out = Directory(p.join(tmp.path, 'exports'));
    final files = await store.exportSessionParts(s.id, app, out);
    expect(files.map((f) => p.basename(f.path)), [
      'meshsonar-20261015-2107-3f2a9c1e-part1of3.json',
      'meshsonar-20261015-2107-3f2a9c1e-part2of3.json',
      'meshsonar-20261015-2107-3f2a9c1e-part3of3.json',
    ]);
    final ids = <String>[];
    for (final f in files) {
      final body = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      expect(shapeProblems(body), isEmpty);
      final pings = (body['pings'] as List).cast<Map<String, dynamic>>();
      expect(pings.length, lessThanOrEqualTo(5000));
      expect(body['session']['id'], s.id);
      expect(body['session']['ended_at'], '2026-10-16T00:00:00.000Z');
      ids.addAll(pings.map((e) => e['id'] as String));
    }
    expect(ids, hasLength(12001));
    expect(ids.toSet(), hasLength(12001));
    expect(ids, (await store.pings(s.id)).map((e) => e.id).toList(), reason: 'file order is drive order');
  });

  test('exactly 5,000 pings stay one file with the usual name; 5,001 make two', () async {
    final s = await seed(5000);
    var files = await store.exportSessionParts(s.id, app, Directory(p.join(tmp.path, 'a')));
    expect(files.map((f) => p.basename(f.path)), ['meshsonar-20261015-2107-3f2a9c1e.json']);
    expect(await files.single.readAsString(),
        await (await store.exportSession(s.id, app, Directory(p.join(tmp.path, 'b')))).readAsString(),
        reason: 'a drive that fits is byte-identical to the plain export');
    await store.appendPing(s.id, makePing(5000));
    files = await store.exportSessionParts(s.id, app, Directory(p.join(tmp.path, 'c')));
    expect(files, hasLength(2));
  });

  test('a drive with no pings still exports one file', () async {
    final s = await seed(0);
    final files = await store.exportSessionParts(s.id, app, Directory(p.join(tmp.path, 'e')));
    expect(files, hasLength(1));
    expect((jsonDecode(await files.single.readAsString())['pings'] as List), isEmpty);
  });

  test('sessions() of a 6,000-ping drive is parsed once; a change to the files refreshes the summary', () async {
    final s = await seed(6000);
    final sw = Stopwatch()..start();
    final first = (await store.sessions()).single;
    final firstMs = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    for (var i = 0; i < 20; i++) {
      await store.sessions();
    }
    final repeatMs = sw.elapsedMilliseconds;
    expect(first.pingCount, 6000);
    expect(repeatMs, lessThan(firstMs * 20 + 1), reason: 'cached reads are far cheaper than parsing (first $firstMs ms, 20 more $repeatMs ms)');
    await store.markSynced(s.id, (await store.pings(s.id)).take(100).map((e) => e.id));
    expect((await store.sessions()).single.syncedCount, 100, reason: 'a changed ledger invalidates the cache');
    await store.appendPing(s.id, makePing(6000));
    expect((await store.sessions()).single.pingCount, 6001);
    await store.renameSession(s.id, 'new name');
    final renamed = (await store.sessions()).single;
    expect(renamed.session.label, 'new name');
    expect(renamed.sessionResendPending, isTrue);
    await store.deleteSession(s.id);
    expect(await store.sessions(), isEmpty);
  });

  test('a long drive survives an app kill: orphan is closed at its last ping with every ping intact', () async {
    final s = makeSession(id: 'orphan-long', startedAt: DateTime.utc(2026, 10, 15, 21));
    await store.startSession(s);
    final lines = StringBuffer();
    for (var i = 0; i < 5200; i++) {
      lines.writeln(jsonEncode(makePing(i, ts: DateTime.utc(2026, 10, 15, 21, 1).add(Duration(seconds: i))).toJson()));
    }
    // The kill cut the last line in half.
    final half = jsonEncode(makePing(5200, ts: DateTime.utc(2026, 10, 16)).toJson());
    await File(p.join(tmp.path, 'sessions', s.id, 'pings.jsonl')).writeAsString(lines.toString() + half.substring(0, half.length ~/ 2));
    final closed = await closeOrphanedSessions(store);
    expect(closed, [s.id]);
    expect((await store.pings(s.id)), hasLength(5200));
    expect((await store.session(s.id))!.endedAt, DateTime.utc(2026, 10, 15, 21, 1).add(const Duration(seconds: 5199)));
    // A ping recorded afterwards is not glued onto the broken line.
    await store.appendPing(s.id, makePing(9));
    expect(await store.pings(s.id), hasLength(5201));
  });
}
