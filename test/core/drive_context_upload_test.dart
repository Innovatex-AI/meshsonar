// Stream 7 WP5: the sync service uploads the drive context to a server that accepts Drive Format v1.2, against a Dart
// port of the live server's strict validator (test/core/v12_server.dart): wire shape, capability gating, byte-identical
// baseline, the sent-ledger (idempotent), late context via POST drive-context, the 400 fallback, refused ctx, and the
// opt-out strip of context that was never uploaded.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_context_wire.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/sync_service.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';
import 'v12_server.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _v12caps = SiteConfig(region: _region, driveFormats: ['meshsonar.drive.v1', 'meshsonar.drive.v1.1', 'meshsonar.drive.v1.2']);
const _v1caps = SiteConfig(region: _region, driveFormats: ['meshsonar.drive.v1', 'meshsonar.drive.v1.1']);
const _app = AppInfo(name: 'MeshSonar', version: '0.19.0', platform: 'ios');

void main() {
  late Directory tmp;
  late JsonlDriveStore store;
  late FileSettingsStore settings;
  late V12Server server;
  late DefaultSyncService sync;
  SiteConfig? caps;

  Future<void> saveSettings({Set<String> off = const {}}) =>
      settings.save(Settings(driverKey: 'ms_testkey_0123456789abcdef', keyStatus: DriverKeyStatus.approved, collectionOff: off));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('meshsonar_v12_');
    store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
    settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
    await saveSettings();
    server = V12Server();
    caps = _v12caps;
    sync = DefaultSyncService(
      store: store,
      client: HttpCmatClient(Uri.parse('https://cmat.test'), client: server.client),
      settings: settings,
      app: _app,
      capabilities: () async => caps,
    );
  });
  tearDown(() async => tmp.delete(recursive: true));

  final base = DateTime.now().toUtc().subtract(const Duration(minutes: 40));

  /// A finished drive of [n] pings with no context.
  Future<DriveSession> drive(int n, {bool ended = true}) async {
    final s = makeSession(startedAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)), endedAt: null);
    await store.startSession(s);
    for (var i = 0; i < n; i++) {
      await store.appendPing(s.id, makePing(i));
    }
    if (ended) await store.endSession(s.id, DateTime.now().toUtc());
    return (await store.session(s.id))!;
  }

  DriveSample radio(int minute, {int? ble, int batt = 4012}) => DriveSample(
        ts: base.add(Duration(minutes: minute)),
        src: SampleSource.radio,
        battMv: batt,
        uptimeS: 86400,
        errFlags: 2,
        queue: 0,
        lastRssi: -101,
        lastSnr: 6.5,
        noiseDbm: -112,
        mcuTempC: 31.5,
        pkts: const PacketCounters(recv: 100, sent: 20, floodTx: 4, directTx: 16, floodRx: 70, directRx: 30, recvErrors: 1),
        storageUsedKb: 120,
        storageTotalKb: 1024,
        bleRssi: ble,
      );

  DriveSample phone(int minute, {double? hpa = 980.1, int pct = 81}) => DriveSample(
      ts: base.add(Duration(minutes: minute)),
      src: SampleSource.phone,
      battPct: pct,
      battState: PhoneBatteryState.unplugged,
      lowPower: false,
      pressureHpa: hpa);

  /// Context for the pings listed (ctx per ping), two samples per minute-index, and the session-level part.
  Future<void> addContext(DriveSession s, {List<DrivePing>? pings, bool withSession = true, int sampleFrom = 0, int samples = 2}) async {
    final ps = pings ?? await store.pings(s.id);
    for (final pg in ps) {
      await store.appendPingContext(
          s.id, pg.id, PingContext(altM: 240.5, courseDeg: 271, pressureHpa: 980.1, phoneBattPct: 81, radioBattMv: 4012));
    }
    await store.appendSamples(s.id, [
      for (var m = sampleFrom; m < sampleFrom + samples; m++) ...[radio(m, ble: -61), phone(m)],
    ]);
    if (withSession) {
      await store.writeSessionContext(
          s.id,
          SessionContext(
              device: DeviceDetails(os: 'ios', osVersion: '17.5.1', model: 'iPhone15,2', appBuild: '23'),
              companionExt: CompanionDetails(model: 'Heltec V3', fwCode: 9, fwBuild: '19 Feb 2025', maxTxDbm: 22, pathHashMode: 1)));
    }
  }

  String plainBytes(DriveSession s, List<DrivePing> pings) => jsonEncode(DriveBatch(app: _app, session: s, pings: pings).toJson());

  group('capability gating and the byte-identical baseline', () {
    test('a server that does not list v1.2: the body is exactly the plain drive, context stays on the phone', () async {
      caps = _v1caps;
      final s = await drive(4);
      await addContext(s);
      await sync.syncSession(s.id);
      expect(server.uploads, hasLength(1));
      expect(jsonEncode(server.uploads.single), plainBytes(s, await store.pings(s.id)));
      expect(server.uploads.single.containsKey('samples'), isFalse);
      // Nothing was marked as sent: the context is still waiting.
      expect(await store.samplesSentKeys(s.id), isEmpty);
      expect(await store.ctxSentPingIds(s.id), isEmpty);
    });

    test('unknown capabilities (no provider answer, or it throws) are the plain drive', () async {
      final s = await drive(3);
      await addContext(s);
      caps = null;
      await sync.syncSession(s.id);
      expect(jsonEncode(server.uploads.single), plainBytes(s, await store.pings(s.id)));
      sync = DefaultSyncService(
          store: store,
          client: HttpCmatClient(Uri.parse('https://cmat.test'), client: server.client),
          settings: settings,
          app: _app,
          capabilities: () async => throw StateError('offline'));
      server.uploads.clear();
      final s2 = await drive(2);
      await sync.syncSession(s2.id);
      expect(jsonEncode(server.uploads.single), plainBytes(s2, await store.pings(s2.id)));
    });

    test('v1.2 server, nothing recorded and weather off: still the plain drive, byte for byte', () async {
      await saveSettings(off: {'weather'});
      final s = await drive(3);
      await sync.syncSession(s.id);
      expect(jsonEncode(server.uploads.single), plainBytes(s, await store.pings(s.id)));
    });

    test('v1.2 server, nothing recorded, weather on: v1.2 with only session.enrich.weather', () async {
      final s = await drive(3);
      await sync.syncSession(s.id);
      final b = server.uploads.single;
      expect(b['format'], driveFormatV12);
      expect((b['session'] as Map)['enrich'], {'weather': true});
      expect((b['session'] as Map).containsKey('device'), isFalse);
      expect(b.containsKey('samples'), isFalse);
      expect(server.sessions[s.id]!.enrichWeather, isTrue);
    });
  });

  group('v1.2 upload', () {
    test('device, companion extras, enrich, ctx and samples reach the strict validator; ble_rssi never leaves', () async {
      final s = await drive(4);
      await addContext(s);
      final report = await sync.syncSession(s.id);
      expect(report.error, isNull);
      final b = server.uploads.single;
      expect(b['format'], 'meshsonar.drive.v1.2');
      final sess = b['session'] as Map;
      expect(sess['device'], {'os': 'ios', 'os_version': '17.5.1', 'model': 'iPhone15,2', 'app_build': '23'});
      // v1 companion keys stay, extras are merged into the same object.
      expect((sess['companion'] as Map).keys, containsAll(['public_key', 'name', 'firmware', 'model', 'fw_code', 'fw_build', 'max_tx_dbm', 'path_hash_mode']));
      expect(sess['enrich'], {'weather': true});
      for (final pg in (b['pings'] as List).cast<Map>()) {
        expect(pg['ctx'], containsPair('alt_m', 240.5));
        expect((pg['ctx'] as Map).keys, everyElement(isIn(['alt_m', 'alt_acc_m', 'course_deg', 'course_acc_deg', 'speed_acc_mps', 'pressure_hpa', 'phone_batt_pct', 'radio_batt_mv'])));
      }
      final samples = (b['samples'] as List).cast<Map>();
      expect(samples, hasLength(4));
      expect(samples.any((x) => x.containsKey('ble_rssi')), isFalse);
      expect(jsonEncode(b), isNot(contains('ble_rssi')));
      // The server stored it all: 4 pings with ctx, 4 samples, device, companion, weather on.
      final st = server.sessions[s.id]!;
      expect(st.pings, hasLength(4));
      expect(st.pingCtx, hasLength(4));
      expect(st.samples, hasLength(4));
      expect(st.device, isNotNull);
      expect(st.companionExt, containsPair('fw_code', 9));
      expect(st.enrichWeather, isTrue);
      expect(report.samplesStored, 4);
      expect(report.samplesRejected, 0);
      // Marked as sent.
      expect((await store.ctxSentPingIds(s.id)), hasLength(4));
      expect((await store.samplesSentKeys(s.id)), hasLength(4));
      expect(await store.sessionContextMark(s.id), isNotNull);
    });

    test('a second sync sends nothing again and counts nothing twice', () async {
      final s = await drive(3);
      await addContext(s);
      final first = await sync.syncSession(s.id);
      expect(first.samplesStored, 4);
      final n = server.uploads.length;
      final second = await sync.syncSession(s.id);
      expect(server.uploads.length, n, reason: 'nothing left to send');
      expect(server.lateUploads, isEmpty);
      expect(second.samplesStored + second.samplesDuplicate + second.contextPingsUpdated, 0);
    });

    test('a retry after a lost confirmation (marks gone) is a duplicate on the server, not a second count', () async {
      final s = await drive(3);
      await addContext(s);
      await sync.syncSession(s.id);
      // The app crashed after the server's 200 but before the marks were written.
      for (final f in ['samples_sent.txt', 'ctx_sent.txt', 'context_sent.txt']) {
        final file = File(p.join(tmp.path, 'drives', 'sessions', s.id, f));
        if (await file.exists()) await file.delete();
      }
      final again = await sync.syncSession(s.id);
      expect(again.samplesStored, 0);
      expect(again.samplesDuplicate, 4);
      expect(server.sessions[s.id]!.samples, hasLength(4));
      // The ctx of already-confirmed pings goes through the late endpoint; the server's stored values win.
      expect(server.lateUploads, hasLength(1));
    });

    test('more than 2,000 samples are split into requests of at most 2,000', () async {
      final s = await drive(2);
      final many = [
        for (var i = 0; i < 4500; i++)
          DriveSample(ts: base.add(Duration(seconds: i)), src: SampleSource.phone, battPct: 80, pressureHpa: 980 + (i % 10) / 10),
      ];
      await store.appendSamples(s.id, many);
      final report = await sync.syncSession(s.id);
      expect(report.error, isNull);
      final counts = [for (final u in server.uploads) ((u['samples'] as List?) ?? const []).length];
      expect(counts.where((c) => c > 0), [2000, 2000, 500]);
      expect(server.sessions[s.id]!.samples, hasLength(4500));
      expect(report.samplesStored, 4500);
    });

    test('samples that wire to nothing (only ble_rssi) are not sent', () async {
      final s = await drive(2);
      await store.appendSamples(s.id, [DriveSample(ts: base, src: SampleSource.radio, bleRssi: -60)]);
      await sync.syncSession(s.id);
      expect(server.uploads.every((u) => !u.containsKey('samples')), isTrue);
    });

    test('a desktop device (os not ios/android) and a model the server would refuse are left out, not sent', () async {
      final s = await drive(2);
      await store.writeSessionContext(
          s.id,
          SessionContext(
              device: DeviceDetails(os: 'macos', osVersion: '14.5', model: 'Mac14,2'),
              companionExt: CompanionDetails(model: "Andy's RAK (WisBlock)", fwCode: 9)));
      final report = await sync.syncSession(s.id);
      expect(report.error, isNull);
      final sess = server.uploads.single['session'] as Map;
      expect(sess.containsKey('device'), isFalse);
      expect((sess['companion'] as Map).containsKey('model'), isFalse);
      expect((sess['companion'] as Map)['fw_code'], 9);
    });
  });

  group('failures never lose the drive', () {
    test('a v1.2 body answered 400 as a whole is repeated once as the plain drive, then stays plain this run', () async {
      server.rejectV12Whole = true;
      final s = await drive(3);
      await addContext(s);
      final report = await sync.syncSession(s.id);
      expect(report.error, isNull);
      expect(report.contextFallbacks, 1);
      expect(server.uploads, hasLength(2));
      expect(server.uploads.first['format'], 'meshsonar.drive.v1.2');
      expect(jsonEncode(server.uploads.last), plainBytes(s, await store.pings(s.id)));
      expect(server.sessions[s.id]!.pings, hasLength(3), reason: 'the drive itself is stored');
      expect((await store.unsyncedPings(s.id)), isEmpty);
      // Nothing of the context was marked as sent: it is retried after a restart.
      expect(await store.samplesSentKeys(s.id), isEmpty);
      expect(await store.ctxSentPingIds(s.id), isEmpty);

      // Same run, new pings: no further v1.2 attempt for that session.
      await store.appendPing(s.id, makePing(9));
      await sync.syncSession(s.id);
      expect(server.uploads.length, 3);
      expect(server.uploads.last['format'], 'meshsonar.drive.v1');
    });

    test('a ping whose ctx the server refuses is stored without it; the ctx is counted as refused, not retried', () async {
      final s = await drive(3);
      await addContext(s);
      final bad = (await store.pings(s.id))[1].id;
      server.ctxRefused.add(bad);
      final report = await sync.syncSession(s.id);
      expect(report.error, isNull);
      expect(report.contextRejected, 1);
      expect(report.rejected, 0, reason: 'the ping was not lost, so it is not a rejected ping');
      final st = server.sessions[s.id]!;
      expect(st.pings, contains(bad));
      expect(st.pingCtx.containsKey(bad), isFalse);
      expect(st.pingCtx, hasLength(2));
      expect((await store.unsyncedPings(s.id)), isEmpty);
      expect(await store.rejectedIds(s.id), isEmpty);
      // Not retried forever.
      final n = server.uploads.length + server.lateUploads.length;
      await sync.syncSession(s.id);
      expect(server.uploads.length + server.lateUploads.length, n);
    });

    test('a sample the server refuses is counted honestly and not retried', () async {
      final s = await drive(2);
      // Outside the drive's window: the server refuses it (and says so), the rest are stored.
      await store.appendSamples(s.id, [phone(1), DriveSample(ts: base.subtract(const Duration(hours: 5)), src: SampleSource.phone, battPct: 50)]);
      final report = await sync.syncSession(s.id);
      expect(report.samplesStored, 1);
      expect(report.samplesRejected, 1);
      final n = server.uploads.length;
      await sync.syncSession(s.id);
      expect(server.uploads.length, n);
    });

    test('a network error mid-upload marks nothing and the next sync delivers everything once', () async {
      final s = await drive(3);
      await addContext(s);
      server.networkDown = true;
      final failed = await sync.syncSession(s.id);
      expect(failed.error, isNotNull);
      expect(await store.samplesSentKeys(s.id), isEmpty);
      expect(await store.ctxSentPingIds(s.id), isEmpty);
      server.networkDown = false;
      final ok = await sync.syncSession(s.id);
      expect(ok.error, isNull);
      expect(ok.samplesStored, 4);
      expect(server.sessions[s.id]!.pingCtx, hasLength(3));
    });
  });

  group('context that arrives late', () {
    test('ctx recorded after its ping was confirmed goes through POST drive-context, once', () async {
      final s = await drive(3);
      await sync.syncSession(s.id); // pings up, no context yet
      final pings = await store.pings(s.id);
      await store.appendPingContext(s.id, pings[0].id, PingContext(altM: 240.5, pressureHpa: 980.1));
      await store.appendPingContext(s.id, pings[2].id, PingContext(altM: 241.0));
      final report = await sync.syncSession(s.id);
      expect(report.error, isNull);
      expect(server.lateUploads, hasLength(1));
      final late = server.lateUploads.single;
      expect(late['format'], 'meshsonar.drive-context.v1');
      expect(late['session'], s.id);
      expect((late['pings'] as List).map((e) => (e as Map)['id']), unorderedEquals([pings[0].id, pings[2].id]));
      expect(report.contextPingsUpdated, 2);
      expect(server.sessions[s.id]!.pingCtx, hasLength(2));
      await sync.syncSession(s.id);
      expect(server.lateUploads, hasLength(1), reason: 'marked as sent');
    });

    test('a drive uploaded before the server accepted v1.2 gets its context from syncContextOnly', () async {
      caps = _v1caps;
      final s = await drive(4);
      await addContext(s);
      await sync.syncSession(s.id); // plain upload; context stays
      expect(server.uploads, hasLength(1));
      expect(server.sessions[s.id]!.pingCtx, isEmpty);

      caps = _v12caps; // the server learned v1.2
      final report = await sync.syncContextOnly();
      expect(report.error, isNull);
      final st = server.sessions[s.id]!;
      expect(st.pingCtx, hasLength(4), reason: 'ping ctx through POST drive-context');
      expect(st.samples, hasLength(4), reason: 'samples through a ping-less v1.2 upload');
      expect(st.device, isNotNull);
      expect(st.companionExt, isNotNull);
      expect(server.lateUploads, hasLength(1));
      final emptyUpload = server.uploads.last;
      expect(emptyUpload['format'], driveFormatV12);
      expect(emptyUpload['pings'], isEmpty);
      // Idempotent.
      final n = server.uploads.length;
      await sync.syncContextOnly();
      expect(server.uploads.length, n);
      expect(server.lateUploads, hasLength(1));
    });

    test('syncContextOnly leaves drives with pings still to send to the normal sync', () async {
      final s = await drive(3);
      await addContext(s);
      final report = await sync.syncContextOnly();
      expect(server.uploads, isEmpty);
      expect(report.sessions, 0);
    });

    test('late context for a drive the server does not know (404) or when rate limited (429) stays queued, no error', () async {
      final s = await drive(2);
      await sync.syncSession(s.id);
      await store.appendPingContext(s.id, (await store.pings(s.id)).first.id, PingContext(altM: 240.5));
      server.lateStatus = 404;
      var r = await sync.syncSession(s.id);
      expect(r.error, isNull);
      server.lateStatus = 429;
      r = await sync.syncSession(s.id);
      expect(r.error, isNull);
      expect(await store.ctxSentPingIds(s.id), isEmpty);
      server.lateStatus = null;
      await sync.syncSession(s.id);
      expect(await store.ctxSentPingIds(s.id), hasLength(1));
    });
  });

  group('opt-out', () {
    test('a category that is off is never in a body, even if its data is still on the phone', () async {
      final s = await drive(3);
      await addContext(s);
      await saveSettings(off: {'barometer', 'device', 'radio_health', 'weather'});
      await sync.syncSession(s.id);
      final b = server.uploads.single;
      final text = jsonEncode(b);
      expect(text, isNot(contains('pressure_hpa')));
      expect(text, isNot(contains('radio_batt_mv')));
      expect(text, isNot(contains('batt_mv')));
      expect((b['session'] as Map).containsKey('device'), isFalse);
      expect((b['session'] as Map)['enrich'], {'weather': false});
      // What is not off still goes.
      expect(text, contains('alt_m'));
      expect(text, contains('batt_pct'));
    });

    test('two drives queued offline (one never sent, one partly sent), a category switched off: nothing of it uploads afterwards, even switched back on',
        () async {
      // Drive B: partly sent. Its first pings + context go up under v1.2, then more is recorded while offline.
      final b = await drive(2, ended: false);
      await addContext(b, sampleFrom: 0, samples: 2);
      await sync.syncSession(b.id);
      final sentPressureB = jsonEncode(server.sessions[b.id]!.pingCtx.values.toList());
      expect(sentPressureB, contains('pressure_hpa'));
      server.networkDown = true;
      final newPings = [makePing(5), makePing(6)];
      for (final pg in newPings) {
        await store.appendPing(b.id, pg);
      }
      await addContext(b, pings: newPings, withSession: false, sampleFrom: 10, samples: 2);
      await store.endSession(b.id, DateTime.now().toUtc());
      // Drive A: never sent.
      final a = await drive(3);
      await addContext(a);
      server.uploads.clear();
      server.lateUploads.clear();

      // The person switches "Air pressure" off: the app strips what the server does not have.
      await saveSettings(off: {'barometer'});
      final changed = await stripUnsentContextCategories(store, [a.id, b.id], {'barometer'});
      expect(changed, unorderedEquals([a.id, b.id]));

      // On the phone: A has no pressure left at all; B keeps only what the server already has.
      expect(jsonEncode((await store.pingContexts(a.id)).values.map((c) => c.toJson()).toList()), isNot(contains('pressure_hpa')));
      expect(jsonEncode((await store.samples(a.id)).map((x) => x.toJson()).toList()), isNot(contains('pressure_hpa')));
      final bCtx = await store.pingContexts(b.id);
      final bSent = await store.ctxSentPingIds(b.id);
      for (final e in bCtx.entries) {
        expect(e.value.pressureHpa != null, bSent.contains(e.key), reason: 'sent part kept, unsent part stripped');
      }

      // Back online: the next upload batches carry none of it for the unsent parts.
      server.networkDown = false;
      await sync.syncAll();
      expect(server.uploads, isNotEmpty);
      for (final u in server.uploads) {
        expect(jsonEncode(u), isNot(contains('pressure_hpa')), reason: 'no pressure in any batch');
      }
      for (final u in server.lateUploads) {
        expect(jsonEncode(u), isNot(contains('pressure_hpa')));
      }
      expect(server.sessions[a.id]!.pingCtx.values.any((c) => c.containsKey('pressure_hpa')), isFalse);
      expect(server.sessions[a.id]!.samples.values.any((x) => jsonEncode(x).contains('pressure_hpa')), isFalse);
      // Other categories of the unsent parts still arrived.
      expect(server.sessions[a.id]!.pingCtx, hasLength(3));
      expect(server.sessions[a.id]!.samples, isNotEmpty);

      // Switching it back on does not resurrect the stripped data.
      await saveSettings();
      server.uploads.clear();
      final extra = await drive(1);
      await sync.syncAll();
      for (final u in server.uploads) {
        final ctxText = jsonEncode([for (final pg in (u['pings'] as List).cast<Map>()) pg['ctx']]);
        if (u['session']['id'] == a.id) expect(ctxText, isNot(contains('pressure_hpa')));
      }
      expect(extra.id, isNotEmpty);
    });

    test('stripUnsentCategories keeps what the server has and drops the rest, per record', () async {
      final s = await drive(2);
      final pings = await store.pings(s.id);
      await store.appendPingContext(s.id, pings[0].id, PingContext(altM: 1, pressureHpa: 990));
      await store.appendPingContext(s.id, pings[1].id, PingContext(altM: 2, pressureHpa: 991));
      await store.markCtxSent(s.id, [pings[0].id]);
      final sentSample = phone(1);
      await store.appendSamples(s.id, [sentSample, phone(2, hpa: 985)]);
      await store.markSamplesSent(s.id, [sampleKey(sentSample)]);
      final res = await store.stripUnsentCategories(s.id, {'barometer'});
      expect(res.pingContexts, 1);
      expect(res.samples, 1);
      final ctx = await store.pingContexts(s.id);
      expect(ctx[pings[0].id]!.pressureHpa, 990);
      expect(ctx[pings[1].id]!.pressureHpa, isNull);
      expect(ctx[pings[1].id]!.altM, 2);
      final samples = await store.samples(s.id);
      expect(samples.where((x) => x.pressureHpa != null), hasLength(1));
    });
  });

  group('wire shape against the server fixtures', () {
    Map<String, dynamic> fixture(String name) =>
        jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;

    Set<String> keys(Object? m) => m is Map ? m.keys.cast<String>().toSet() : <String>{};

    test('a v1.2 body has the same structure as the server\'s own golden fixture', () {
      final fx = fixture('server_drive_v1.2.json');
      final session = DriveSession(
        id: 'a1b2c3d4-0000-4000-8000-000000000001',
        startedAt: DateTime.utc(2026, 10, 24, 10),
        endedAt: DateTime.utc(2026, 10, 24, 11),
        label: 'Golden loop',
        channel: '#wardriving',
        radio: const Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22),
        antenna: const Antenna(type: 'external', gainDbi: 5.8, heightM: 1.8),
        companion: const Companion(publicKey: 'DF0136AA', name: 'KE4BFI-v4', firmware: '1.9'),
      );
      final ping = DrivePing(
        id: 'b1b2c3d4-0000-4000-8000-000000000001',
        ts: DateTime.utc(2026, 10, 24, 10, 1),
        lat: 40.129091,
        lon: -82.977705,
        gpsAccuracyM: 4,
        speedMps: 13.2,
        noiseFloorDbm: -94,
        echoes: const [Echo(repeater: 'DF0136', snrDb: 12.75, rssiDbm: -71, hops: 1, path: ['df0136'], delayMs: 840)],
      );
      final body = jsonDecode(jsonEncode(DriveBatch(
        app: const AppInfo(name: 'MeshSonar', version: '0.19.0', platform: 'ios'),
        session: session,
        pings: [ping],
        context: ContextUpload(
          weather: true,
          device: DeviceDetails(os: 'ios', osVersion: '17.5.1', model: 'iPhone15,2', appBuild: '23'),
          companion: CompanionDetails(model: 'Heltec V3', fwCode: 9, fwBuild: '19 Feb 2025', maxTxDbm: 22, pathHashMode: 1),
          pingContexts: {
            ping.id: PingContext(altM: 240.5, altAccM: 3.5, courseDeg: 271, courseAccDeg: 12, speedAccMps: 0.4, pressureHpa: 980.1, phoneBattPct: 81, radioBattMv: 4012),
          },
          samples: [
            DriveSample(
                ts: DateTime.utc(2026, 10, 24, 10, 5),
                src: SampleSource.radio,
                battMv: 4012,
                uptimeS: 86400,
                errFlags: 2,
                queue: 0,
                txAirS: 120,
                rxAirS: 900,
                lastRssi: -101,
                lastSnr: 6.5,
                noiseDbm: -112,
                mcuTempC: 31.5,
                pkts: const PacketCounters(recv: 100, sent: 20, floodTx: 4, directTx: 16, floodRx: 70, directRx: 30, recvErrors: 1),
                storageUsedKb: 120,
                storageTotalKb: 1024),
            DriveSample(
                ts: DateTime.utc(2026, 10, 24, 10, 5),
                src: SampleSource.phone,
                battPct: 81,
                battState: PhoneBatteryState.unplugged,
                lowPower: false,
                pressureHpa: 980.1),
          ],
        ),
      ).toJson())) as Map<String, dynamic>;

      expect(body['format'], fx['format']);
      expect(keys(body), keys(fx));
      final bs = body['session'] as Map, fs = fx['session'] as Map;
      expect(keys(bs), keys(fs), reason: 'session keys');
      expect(keys(bs['companion']), keys(fs['companion']));
      expect(keys(bs['device']), keys(fs['device']));
      expect(bs['enrich'], fs['enrich']);
      expect(bs['device'], fs['device']);
      expect({...bs['companion'] as Map}..remove('public_key'), {...fs['companion'] as Map}..remove('public_key'));
      final bp = (body['pings'] as List).first as Map, fp = (fx['pings'] as List).first as Map;
      expect(bp['ctx'], fp['ctx']);
      final fsamples = (fx['samples'] as List).cast<Map>();
      final bsamples = (body['samples'] as List).cast<Map>();
      // The fixture's first two samples are the valid radio and phone examples.
      expect(bsamples[0]['pkts'], fsamples[0]['pkts']);
      expect(bsamples[0]['storage_kb'], fsamples[0]['storage_kb']);
      expect(keys(bsamples[0]), keys(fsamples[0]));
      expect(keys(bsamples[1]), keys(fsamples[1]));
      expect(bsamples[1]['batt_state'], fsamples[1]['batt_state']);
    });

    test('the late-context body has the structure of the server\'s drive-context fixture', () {
      final fx = fixture('server_drive_context_v1.json');
      final body = jsonDecode(jsonEncode(DriveContextBatch(
        session: fx['session'] as String,
        pings: [PingContextEntry('b1b2c3d4-0000-4000-8000-000000000001', PingContext(altM: 240.5, pressureHpa: 980.1))],
        samples: [DriveSample(ts: DateTime.utc(2026, 10, 24, 10, 30), src: SampleSource.phone, battPct: 70)],
      ).toJson())) as Map<String, dynamic>;
      expect(keys(body), keys(fx));
      expect(body['format'], fx['format']);
      expect(body['session'], fx['session']);
      expect(((body['pings'] as List).first as Map)['ctx'], ((fx['pings'] as List).first as Map)['ctx']);
      final s = (body['samples'] as List).first as Map, f = (fx['samples'] as List).first as Map;
      expect(s['src'], f['src']);
      expect(s['batt_pct'], f['batt_pct']);
      expect(keys(s), keys(f));
    });

    test('the default toJson (no context) is the unchanged v1 body', () {
      final s = makeSession(startedAt: DateTime.utc(2026, 10, 24, 10), endedAt: DateTime.utc(2026, 10, 24, 11));
      final j = DriveBatch(app: _app, session: s, pings: [makePing(1)]).toJson();
      expect(j['format'], 'meshsonar.drive.v1');
      expect(keys(j), {'format', 'app', 'session', 'pings'});
      expect(keys(j['session']), {'id', 'started_at', 'ended_at', 'label', 'channel', 'radio', 'antenna', 'companion'});
    });
  });
}
