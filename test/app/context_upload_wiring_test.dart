// AppState -> drive context upload (stream 7 WP5): the app hands the sync service the UPLOAD server's capabilities and
// the opt-out switches (with the disclosure gate), so a drive goes up as v1.2 only for a server that accepts it, an
// unknown server is the plain drive, a category switched off is not in the body, nothing is uploaded before the
// version-2 disclosure was seen, and switching a category off strips what the server does not have.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/sync_service.dart';

import '../ui/fakes.dart';

const _region = RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com');
const _v12 = SiteConfig(
    region: _region, driveFormats: ['meshsonar.drive.v1', 'meshsonar.drive.v1.2'], capabilities: {'driveContextErase', 'driveEnv'});
const _v1 = SiteConfig(region: _region, driveFormats: ['meshsonar.drive.v1']);

final t0 = DateTime.now().toUtc().subtract(const Duration(minutes: 30));

/// A harness whose sync service is the real [DefaultSyncService] over the fake store (which keeps the context and its
/// sent-ledger in memory) and the app's own fake client, so the capability the app reads is the one that is used.
class UploadHarness extends Harness {
  @override
  AppServices buildServices() {
    final b = super.buildServices();
    return AppServices(
      store: b.store,
      settingsStore: b.settingsStore,
      cmatClientFactory: b.cmatClientFactory,
      syncServiceFactory: (c) => DefaultSyncService(store: store, client: c, settings: settings),
      bluetoothScanner: b.bluetoothScanner,
      simulatorScanner: b.simulatorScanner,
      linkFactory: b.linkFactory,
      location: b.location,
      simulatedLocation: b.simulatedLocation,
      engineFactory: b.engineFactory,
      repeaterCache: b.repeaterCache,
      exportDir: b.exportDir,
      shareFile: b.shareFile,
      newId: b.newId,
      uiPrefsFile: b.uiPrefsFile,
      clock: () => DateTime.now().toUtc(),
    );
  }

  FakeCmatClient get fake => state.client as FakeCmatClient;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_ctx_upload_wiring_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  UploadHarness harness({SiteConfig? caps, Set<String> off = const {}, bool disclosed = true}) {
    final h = UploadHarness();
    h.approveKey();
    h.settings.saved = h.settings.saved.copyWith(collectionOff: off);
    h.uiPrefsFile = File('${tmp.path}/ui_prefs.json')
      ..writeAsStringSync(jsonEncode({'onboarding_seen': true, if (disclosed) 'collection_disclosed_v': 2}));
    h.fake.siteConfigResult = caps;
    final s = DriveSession(id: 'd1', startedAt: t0, endedAt: t0.add(const Duration(minutes: 5)));
    h.store.seed(s, [
      DrivePing(id: 'p1', ts: t0.add(const Duration(minutes: 1)), lat: 40.1, lon: -82.9),
      DrivePing(id: 'p2', ts: t0.add(const Duration(minutes: 2)), lat: 40.1, lon: -82.9),
    ]);
    for (final p in ['p1', 'p2']) {
      h.store.ctx.appendPingContext('d1', p, PingContext(altM: 250, pressureHpa: 990, phoneBattPct: 70));
    }
    h.store.ctx.appendSamples('d1', [
      DriveSample(ts: t0.add(const Duration(minutes: 1)), src: SampleSource.phone, battPct: 70, pressureHpa: 990),
      DriveSample(ts: t0.add(const Duration(minutes: 1)), src: SampleSource.radio, battMv: 4000, bleRssi: -50),
    ]);
    h.store.ctx.writeSessionContext(
        'd1', SessionContext(device: DeviceDetails(os: 'ios', osVersion: '18.6', model: 'iPhone15,2', appBuild: '23')));
    return h;
  }

  test('a v1.2 server: the app reads the upload server\'s site-config and the drive goes up as v1.2 with its context',
      () async {
    final h = harness(caps: _v12);
    await h.state.init();
    final r = await h.state.syncSession('d1');
    expect(r?.error, isNull);
    final b = h.fake.uploads.single.toJson();
    expect(b['format'], driveFormatV12);
    expect((b['session'] as Map)['device'], containsPair('model', 'iPhone15,2'));
    expect((b['session'] as Map)['enrich'], {'weather': true});
    expect(((b['pings'] as List).first as Map)['ctx'], containsPair('pressure_hpa', 990));
    expect(jsonEncode(b), isNot(contains('ble_rssi')));
    expect(h.state.serverAcceptsDriveContext, isTrue);
    expect(h.state.serverCanEraseContext, isTrue);
  });

  test('an unknown server (site-config does not answer) or a v1-only server: the plain drive, byte for byte', () async {
    for (final caps in [null, _v1]) {
      final h = harness(caps: caps);
      await h.state.init();
      await h.state.syncSession('d1');
      final b = h.fake.uploads.single;
      expect(b.context, isNull);
      expect(jsonEncode(b.toJson()),
          jsonEncode(DriveBatch(app: b.app, session: b.session, pings: b.pings).toJson()));
      expect(b.toJson()['format'], driveFormat);
      expect(h.state.serverAcceptsDriveContext, isFalse);
    }
  });

  test('categories switched off never ride along; weather off is sent as enrich.weather=false', () async {
    final h = harness(caps: _v12, off: {'barometer', 'device', 'weather'});
    await h.state.init();
    await h.state.syncSession('d1');
    final text = jsonEncode(h.fake.uploads.single.toJson());
    expect(text, isNot(contains('pressure_hpa')));
    expect(text, isNot(contains('"device"')));
    expect(text, contains('"enrich":{"weather":false}'));
    expect(text, contains('alt_m'));
  });

  test('nothing is uploaded before the version-2 disclosure was seen; the weather flag is false until then', () async {
    final h = harness(caps: _v12, disclosed: false);
    await h.state.init();
    await h.state.syncSession('d1');
    final b = h.fake.uploads.single;
    final text = jsonEncode(b.toJson());
    expect(text, isNot(contains('pressure_hpa')));
    expect(text, isNot(contains('alt_m')));
    expect(b.toJson().containsKey('samples'), isFalse);
    expect(b.context?.weather ?? false, isFalse);
  });

  test('switching a category off strips what the server does not have, and only for a server that accepts context',
      () async {
    final h = harness(caps: _v12);
    await h.state.init();
    await h.state.refreshUploadSiteConfig();
    h.store.ctx.markCtxSent('d1', ['p1']);
    await h.state.updateSettings(h.state.settings.withCollection('barometer', false));
    for (var i = 0; i < 40 && h.store.ctx.ctxBySession['d1']!['p2']!.pressureHpa != null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(h.store.ctx.ctxBySession['d1']!['p1']!.pressureHpa, 990, reason: 'the server has p1\'s context');
    expect(h.store.ctx.ctxBySession['d1']!['p2']!.pressureHpa, isNull);
    expect(h.store.ctx.samplesBySession['d1']!.where((s) => s.pressureHpa != null), isEmpty);

    // A server that does not accept it: nothing is stripped (the local-delete dialog, default Keep, decides).
    final g = harness(caps: _v1);
    await g.state.init();
    await g.state.refreshUploadSiteConfig();
    await g.state.updateSettings(g.state.settings.withCollection('barometer', false));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(g.store.ctx.ctxBySession['d1']!['p2']!.pressureHpa, 990);
  });

  test('a new server URL forgets the old server\'s capabilities', () async {
    final h = harness(caps: _v12);
    await h.state.init();
    await h.state.refreshUploadSiteConfig();
    expect(h.state.serverAcceptsDriveContext, isTrue);
    await h.state.updateSettings(h.state.settings.copyWith(serverUrl: 'https://other.example.org'));
    expect(h.state.uploadSiteConfig, isNull);
    expect(h.state.serverAcceptsDriveContext, isFalse);
  });

  test('delete my data on the server: category=all and the packet headers; no key = nothing to ask', () async {
    final h = harness(caps: _v12);
    await h.state.init();
    final r = await h.state.deleteMyDataOnServer();
    expect(r.context.done, isTrue);
    expect(h.fake.erasedCategories, ['all']);
    final n = harness();
    n.settings.saved = const Settings();
    await n.state.init();
    final none = await n.state.deleteMyDataOnServer();
    expect(none.context.status.name, 'noKey');
    expect(n.fake.erasedCategories, isEmpty);
    expect(none.headers, isNull);
  });

  test('deleting everything saved on this phone strips every category from every drive', () async {
    final h = harness(caps: _v12);
    await h.state.init();
    final n = await h.state.deleteAllCollectedLocally();
    expect(n, 1);
    expect(h.store.ctx.ctxBySession['d1'] ?? const {}, isEmpty);
    expect(h.store.ctx.samplesBySession['d1'] ?? const [], isEmpty);
    expect(h.store.ctx.sessionBySession['d1'], isNull);
  });
}
