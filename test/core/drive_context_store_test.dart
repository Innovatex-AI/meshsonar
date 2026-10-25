import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/data_categories.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:path/path.dart' as p;

import 'drive_context_test.dart' show fullCtx, fullPhone, fullRadio, fullSession;
import 'helpers.dart';

void main() {
  late Directory tmp;
  late JsonlDriveStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshsonar_ctx_');
    store = await JsonlDriveStore.open(tmp);
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File f(String id, String name) => File(p.join(tmp.path, 'sessions', id, name));
  const app = AppInfo(name: 'MeshSonar', version: '0.19.0', platform: 'ios');

  test('samples, ping contexts and session context round-trip beside the drive', () async {
    final s = makeSession();
    await store.startSession(s);
    final ping = makePing(1);
    await store.appendPing(s.id, ping);
    await store.appendSamples(s.id, [fullRadio(), fullPhone()]);
    await store.appendPingContext(s.id, ping.id, fullCtx());
    await store.writeSessionContext(s.id, fullSession());

    expect((await store.samples(s.id)).map((x) => x.toJson()), [fullRadio().toJson(), fullPhone().toJson()]);
    expect((await store.pingContexts(s.id))[ping.id]!.toJson(), fullCtx().toJson());
    expect((await store.sessionContext(s.id))!.toJson(), fullSession().toJson());

    final lines = const LineSplitter().convert(await f(s.id, 'samples.jsonl').readAsString());
    expect(lines, hasLength(2));
    final ctxLine = jsonDecode(const LineSplitter().convert(await f(s.id, 'ctx.jsonl').readAsString()).single) as Map;
    expect(ctxLine, {'ping': ping.id, 'ctx': fullCtx().toJson()});
  });

  test('upload bytes are identical with or without stored context; export adds only a `context` object', () async {
    final s = makeSession();
    await store.startSession(s);
    final pings = [for (var i = 0; i < 4; i++) makePing(i)];
    for (final x in pings) {
      await store.appendPing(s.id, x);
    }
    final out1 = await Directory.systemTemp.createTemp('meshsonar_exp1_');
    final out2 = await Directory.systemTemp.createTemp('meshsonar_exp2_');
    addTearDown(() async {
      await out1.delete(recursive: true);
      await out2.delete(recursive: true);
    });
    final before = await (await store.exportSession(s.id, app, out1)).readAsString();
    final uploadBefore = jsonEncode(
        DriveBatch(app: app, session: (await store.session(s.id))!, pings: await store.unsyncedPings(s.id)).toJson());

    await store.appendSamples(s.id, [fullRadio(), fullPhone()]);
    for (final x in pings) {
      await store.appendPingContext(s.id, x.id, fullCtx());
    }
    await store.writeSessionContext(s.id, fullSession());

    final after = await (await store.exportSession(s.id, app, out2)).readAsString();
    final uploadAfter = jsonEncode(
        DriveBatch(app: app, session: (await store.session(s.id))!, pings: await store.unsyncedPings(s.id)).toJson());
    expect(uploadAfter, uploadBefore, reason: 'the upload never carries context');
    expect(before, uploadBefore, reason: 'a drive without context exports exactly the upload body, as before');
    final exported = (jsonDecode(after) as Map).cast<String, dynamic>();
    final ctx = (exported.remove('context') as Map).cast<String, dynamic>();
    expect(jsonEncode(exported), before, reason: 'the drive part of the export is byte-identical');
    expect(ctx['format'], exportContextFormat);
    expect(exported['format'], isNot(exportContextFormat), reason: 'the drive keeps its own Drive Format id');
    expect(ctx['session'], fullSession().toJson());
    expect((ctx['pings'] as List).map((e) => (e as Map)['id']), [for (final x in pings) x.id]..sort());
    expect(ctx['samples'], [fullRadio().toJson(), fullPhone().toJson()]);
    for (final sample in ctx['samples'] as List) {
      for (final k in ['lat', 'lon', 'latitude', 'longitude']) {
        expect((sample as Map).containsKey(k), isFalse, reason: 'samples carry no coordinates');
      }
    }
    for (final k in ['ctx', 'samples', 'device', 'companion_ext', 'alt_m', 'batt_mv']) {
      expect(uploadAfter.contains('"$k"'), isFalse, reason: '$k leaked into the upload');
    }
  });

  test('a crash-truncated last line is skipped on read and cut before the next append', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendSamples(s.id, [fullRadio()]);
    await f(s.id, 'samples.jsonl').writeAsString('{"ts":"2026-10-24T20:12:00Z","src":"ra', mode: FileMode.append);
    await f(s.id, 'ctx.jsonl').writeAsString('{"ping":"x","ctx":{"alt', flush: true);

    expect(await store.samples(s.id), hasLength(1));
    expect(await store.pingContexts(s.id), isEmpty);

    final reopened = await JsonlDriveStore.open(tmp);
    await reopened.appendSamples(s.id, [fullPhone()]);
    await reopened.appendPingContext(s.id, 'p1', fullCtx());
    final lines = const LineSplitter().convert(await f(s.id, 'samples.jsonl').readAsString());
    expect(lines, hasLength(2));
    expect(lines.every((l) => jsonDecode(l) is Map), isTrue);
    expect((await reopened.pingContexts(s.id)).keys, ['p1']);
  });

  test('later context for the same ping replaces the earlier one; empty writes are not written', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendPingContext(s.id, 'p1', PingContext(altM: 10));
    await store.appendPingContext(s.id, 'p1', PingContext(altM: 20));
    await store.appendPingContext(s.id, 'p2', PingContext());
    await store.appendSamples(s.id, [DriveSample(ts: DateTime.utc(2026), src: SampleSource.radio)]);
    expect((await store.pingContexts(s.id)).map((k, v) => MapEntry(k, v.altM)), {'p1': 20.0});
    expect(await f(s.id, 'samples.jsonl').exists(), isFalse);
    await store.writeSessionContext(s.id, fullSession());
    await store.writeSessionContext(s.id, SessionContext());
    expect(await store.sessionContext(s.id), isNull);
  });

  test('writes to a session that does not exist fail; reads return empty', () async {
    expect(() => store.appendSamples('nope', [fullRadio()]), throwsStateError);
    expect(() => store.appendPingContext('nope', 'p', fullCtx()), throwsStateError);
    expect(() => store.writeSessionContext('nope', fullSession()), throwsStateError);
    expect(await store.samples('nope'), isEmpty);
    expect(await store.pingContexts('nope'), isEmpty);
    expect(await store.sessionContext('nope'), isNull);
  });

  test('stripCategories removes exactly that category everywhere, atomically, and drops emptied rows', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendSamples(s.id, [fullRadio(), fullPhone()]);
    await store.appendPingContext(s.id, 'p1', fullCtx());
    await store.appendPingContext(s.id, 'p2', PingContext(altM: 5));
    await store.writeSessionContext(s.id, fullSession());

    final r = await store.stripCategories(s.id, {CategoryId.radioHealth, CategoryId.motion});
    expect(r.samples, 1);
    expect(r.pingContexts, 2);
    expect(r.session, isFalse);
    expect(r.changed, isTrue);
    final samples = await store.samples(s.id);
    expect(samples.map((x) => x.src), [SampleSource.phone]);
    final ctx = await store.pingContexts(s.id);
    expect(ctx.keys, ['p1'], reason: 'p2 had only motion keys');
    expect(ctx['p1']!.toJson().keys.toSet(), {'pressure_hpa', 'phone_batt_pct'});
    for (final name in ['samples.jsonl', 'ctx.jsonl']) {
      expect(await File('${f(s.id, name).path}.tmp').exists(), isFalse);
    }

    final r2 = await store.stripCategories(s.id, {CategoryId.device});
    expect(r2.session, isTrue);
    expect((await store.sessionContext(s.id))!.toJson().keys, ['companion_ext']);
    expect((await store.stripCategories(s.id, {CategoryId.device})).changed, isFalse, reason: 'idempotent');

    // Appends after a strip still go to a clean file.
    await store.appendSamples(s.id, [fullRadio()]);
    expect(await store.samples(s.id), hasLength(2));
  });

  test('stripContextCategories over many sessions reports the ones that changed', () async {
    final a = makeSession(), b = makeSession();
    await store.startSession(a);
    await store.startSession(b);
    await store.appendSamples(a.id, [fullRadio()]);
    await store.appendSamples(b.id, [fullPhone()]);
    final changed = await stripContextCategories(store, [a.id, b.id, 'missing'], {CategoryId.radioHealth});
    expect(changed, [a.id]);
    expect(await stripContextCategories(store, [a.id], const {}), isEmpty);
  });

  test('deleting the drive deletes its context', () async {
    final s = makeSession();
    await store.startSession(s);
    await store.appendSamples(s.id, [fullRadio()]);
    await store.appendPingContext(s.id, 'p1', fullCtx());
    await store.writeSessionContext(s.id, fullSession());
    await store.deleteSession(s.id);
    expect(await store.samples(s.id), isEmpty);
    expect(await store.pingContexts(s.id), isEmpty);
    expect(await store.sessionContext(s.id), isNull);
  });
}
