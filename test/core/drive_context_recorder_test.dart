import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/data_categories.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_context_recorder.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:path/path.dart' as p;

import 'drive_context_test.dart' show fullPhone, fullRadio, fullSession;
import 'helpers.dart';

void main() {
  late Directory tmp;
  late JsonlDriveStore store;
  late DriveSession s;
  late Set<String> off;
  late DriveContextRecorder rec;
  final t0 = DateTime.utc(2026, 10, 24, 20, 11);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshsonar_rec_');
    store = await JsonlDriveStore.open(tmp);
    s = makeSession();
    await store.startSession(s);
    off = {};
    rec = DriveContextRecorder(ledger: store, sessionId: s.id, isOn: (id) => !off.contains(id));
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  GeoFix fix(DateTime at) => GeoFix(
        lat: 40.12,
        lon: -82.93,
        at: at,
        accuracyM: 4,
        speedMps: 13,
        altitudeM: 251.3,
        altitudeAccuracyM: 6,
        courseDeg: 87,
        courseAccuracyDeg: 12,
        speedAccuracyMps: 0.6,
      );
  DrivePing ping(DateTime at) => DrivePing(id: newId(), ts: at, lat: 40.12, lon: -82.93);

  test('ping context: altitude/course from the nearest fix, radio battery and phone readings from fresh samples', () async {
    rec.onFix(fix(t0.subtract(const Duration(seconds: 30))));
    rec.onFix(fix(t0.subtract(const Duration(seconds: 1))));
    await rec.recordSample(fullRadio());
    await rec.recordSample(fullPhone());
    final x = ping(t0);
    final ctx = await rec.recordPing(x);
    expect(ctx!.toJson(), {
      'alt_m': 251.3,
      'alt_acc_m': 6.0,
      'course_deg': 87.0,
      'course_acc_deg': 12.0,
      'speed_acc_mps': 0.6,
      'pressure_hpa': 987.4,
      'phone_batt_pct': 64,
      'radio_batt_mv': 3912,
    });
    expect((await store.pingContexts(s.id))[x.id]!.toJson(), ctx.toJson());
  });

  test('a fix too far from the ping, or a stale sample, is not used', () async {
    rec.onFix(fix(t0.subtract(const Duration(seconds: 30))));
    await rec.recordSample(fullRadio()); // at t0
    final later = ping(t0.add(const Duration(minutes: 6)));
    expect(await rec.recordPing(later), isNull);
    expect(await store.pingContexts(s.id), isEmpty);
  });

  test('each category off -> none of its keys are written (read at every write)', () async {
    rec.onFix(fix(t0));
    off = {CategoryId.motion};
    await rec.recordSample(fullRadio());
    final a = await rec.recordPing(ping(t0));
    expect(a!.toJson().keys.toSet(), {'radio_batt_mv'});

    off = {CategoryId.radioHealth};
    expect(await rec.recordSample(fullRadio()), isNull, reason: 'radio sample is all radio_health');
    final b = await rec.recordPing(ping(t0));
    expect(b!.toJson().containsKey('radio_batt_mv'), isFalse);
    expect(b.altM, 251.3);

    off = {CategoryId.barometer};
    final phone = await rec.recordSample(fullPhone());
    expect(phone!.pressureHpa, isNull);
    expect(phone.battPct, 64);

    off = {CategoryId.device};
    final sc = await rec.recordSession(device: fullSession().device, companion: fullSession().companionExt);
    expect(sc!.device, isNull);
    expect(sc.companionExt, isNotNull);

    off = {for (final c in dataCategories) c.id};
    expect(await rec.recordSample(fullPhone()), isNull);
    expect(await rec.recordPing(ping(t0)), isNull);
    expect(await rec.recordSession(device: fullSession().device), isNull);

    final samples = await store.samples(s.id);
    expect(samples.map((x) => x.src), [SampleSource.radio, SampleSource.phone]);
    expect(samples.first.toJson()['batt_mv'], 3912);
  });

  test('session snapshot: a later partial update keeps the other part', () async {
    await rec.recordSession(device: fullSession().device);
    await rec.recordSession(companion: fullSession().companionExt);
    expect((await store.sessionContext(s.id))!.toJson(), fullSession().toJson());
  });

  test('no coordinate key ever reaches samples.jsonl or context.json', () async {
    rec.onFix(fix(t0));
    await rec.recordSample(fullRadio());
    await rec.recordSample(fullPhone());
    await rec.recordPing(ping(t0));
    await rec.recordSession(device: fullSession().device, companion: fullSession().companionExt);
    final dir = p.join(tmp.path, 'sessions', s.id);
    for (final line in const LineSplitter().convert(await File(p.join(dir, 'samples.jsonl')).readAsString())) {
      final m = jsonDecode(line) as Map;
      expect(m.keys.toSet().intersection({'lat', 'lon', 'latitude', 'longitude'}), isEmpty);
    }
    final ctxJson = await File(p.join(dir, 'context.json')).readAsString();
    expect(ctxJson.contains('"lat"') || ctxJson.contains('"lon"'), isFalse);
  });

  test('failures are swallowed and counted; close() stops everything', () async {
    await store.deleteSession(s.id);
    expect(await rec.recordSample(fullRadio()), isNull);
    expect(rec.failedWrites, 1);
    rec.close();
    expect(await rec.recordSample(fullRadio()), isNull);
    expect(rec.failedWrites, 1);
  });
}
