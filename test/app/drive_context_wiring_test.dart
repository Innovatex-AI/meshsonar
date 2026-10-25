// AppState -> drive context (stream 7 WP2): the context collectors start and stop with the drive, nothing is
// collected before the version-2 disclosure has been seen, the category switches are read live, context is only
// recorded for pings already saved, local delete strips a category from every drive, the upload body is untouched
// and the shared telemetry record can never carry a coordinate. Plus a real simulator drive that produces radio health.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/drive_context_hook.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/data_categories.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/phone_sensors.dart';
import 'package:meshsonar/core/region_cache.dart' show siteConfigFromJson, siteConfigToJson;
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

import '../ui/fakes.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_ctx_wiring_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<void> settle() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Harness harness({Map<String, Object?>? prefs}) {
    final h = Harness()
      ..barometer = FakeBarometer()
      ..phoneBattery = FakeBattery()
      ..deviceDetails = FakeDeviceDetails();
    if (prefs != null) {
      final f = File('${tmp.path}/ui_prefs.json')..writeAsStringSync(jsonEncode(prefs));
      h.uiPrefsFile = f;
    }
    return h;
  }

  Future<String> drive(Harness h) async {
    await h.state.init();
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    expect(h.state.driving, isTrue, reason: h.state.pendingNotice);
    await settle();
    return h.state.currentSession!.id;
  }

  FakeBarometer baro(Harness h) => h.barometer as FakeBarometer;

  test('the version-1 (packet headers only) disclosure is not enough: nothing new is collected until v2 is seen',
      () async {
    final h = harness(prefs: {'telemetry_disclosed': true});
    final sid = await drive(h);
    expect(baro(h).listens, 0, reason: 'no Motion & Fitness prompt before the disclosure');
    expect((h.deviceDetails as FakeDeviceDetails).reads, 0);
    expect((h.phoneBattery as FakeBattery).reads, 0);
    h.engines.single.emit(silentPing('p1'));
    await settle();
    expect(h.store.pingsBySession[sid]!.map((p) => p.id), ['p1'], reason: 'the drive itself records as always');
    expect(await h.store.samples(sid), isEmpty);
    expect(await h.store.sessionContext(sid), isNull);
    expect(h.state.collectionOn(CategoryId.packetHeaders), isTrue, reason: 'headers keep their v1 consent');
    expect(h.state.collectionOn(CategoryId.motion), isFalse);

    // The sheet is seen mid-drive: collection starts now.
    h.state.noteCollectionDisclosed();
    await settle();
    expect(baro(h).listening, isTrue);
    expect((await h.store.sessionContext(sid))!.device!.model, 'iPhone15,2');
    await h.state.stopDrive();
  });

  test('v2 seen: context recorded with the drive, motion from the engine fix, only after the ping is saved',
      () async {
    final h = harness(prefs: {'telemetry_disclosed': true, collectionDisclosedKey: collectionDisclosureVersion});
    final sid = await drive(h);
    expect(baro(h).listening, isTrue);
    expect((await h.store.samples(sid)).single.battPct, 64);
    final at = h.clockNow;
    h.engines.single.setStatus(EngineStatus(EngineState.pinging,
        lastFix: GeoFix(lat: 40.126, lon: -82.93, at: at, altitudeM: 251.3, altitudeAccuracyM: 6)));
    baro(h).emit(990.4);
    await settle();
    h.store.failAppend = true;
    h.engines.single.emit(heardPing('unsaved', const [], ts: at));
    await settle();
    expect(await h.store.pingContexts(sid), isEmpty, reason: 'no context for a ping that is not on disk');
    h.store.failAppend = false;
    h.engines.single.emit(heardPing('p1', const [], ts: at));
    await settle();
    final ctx = await h.store.pingContexts(sid);
    expect(ctx['p1']!.toJson(), {'alt_m': 251.3, 'alt_acc_m': 6.0, 'pressure_hpa': 990.4, 'phone_batt_pct': 64});

    await h.state.stopDrive();
    expect(baro(h).listening, isFalse, reason: 'stops with the drive');
    expect(h.state.barometerStatus, SensorStatus.reading, reason: 'Settings shows how the last drive went');
  });

  test('switching a category off in Settings stops it at once mid-drive', () async {
    final h = harness();
    final sid = await drive(h);
    expect(baro(h).listening, isTrue);
    await h.state.updateSettings(h.state.settings.withCollection(CategoryId.barometer, false));
    expect(baro(h).listening, isFalse);
    expect(h.settings.saved.collectionOff, {CategoryId.barometer});
    h.engines.single.emit(silentPing('p1'));
    await settle();
    expect((await h.store.pingContexts(sid))['p1']?.pressureHpa, isNull);
    await h.state.updateSettings(h.state.settings.withCollection(CategoryId.barometer, true));
    expect(baro(h).listening, isTrue);
    await h.state.stopDrive();
  });

  test('deleteCollectedLocally strips one category from every drive on the phone', () async {
    final h = harness();
    final sid = await drive(h);
    await h.state.stopDrive();
    expect((await h.store.samples(sid)).single.battPct, 64);
    expect(await h.state.deleteCollectedLocally(CategoryId.phoneBattery), 1);
    expect(await h.store.samples(sid), isEmpty);
    expect((await h.store.sessionContext(sid))!.device, isNotNull, reason: 'other categories stay');
    expect(await h.state.deleteCollectedLocally(CategoryId.phoneBattery), 0);
  });

  test('a phone without a barometer reports it after the drive; nothing invented', () async {
    final h = harness()..barometer = FakeBarometer(fail: true);
    final sid = await drive(h);
    await h.state.stopDrive();
    expect(h.state.barometerStatus, SensorStatus.unavailable);
    expect((await h.store.samples(sid)).every((s) => s.pressureHpa == null), isTrue);
  });

  test('no sensor services: unsupported, and drives work as before', () async {
    final h = Harness();
    expect(h.state.barometerStatus, SensorStatus.unsupported);
    await drive(h);
    h.engines.single.emit(silentPing('p1'));
    await h.state.stopDrive();
    expect(h.store.pingsBySession.values.single.single.id, 'p1');
  });

  test('the shared telemetry record has no coordinate or drive-context key', () {
    const forbidden = ['lat', 'lon', 'latitude', 'longitude', 'alt_m', 'pressure_hpa', 'batt_mv', 'ctx', 'samples'];
    for (final k in forbidden) {
      expect(TelemetryRecord.wireKeys, isNot(contains(k)), reason: k);
    }
  });

  test('Settings JSON: collection_off is optional, sorted, and unknown ids survive', () {
    expect(const Settings().toJson().containsKey('collection_off'), isFalse, reason: 'default file unchanged');
    final s = const Settings().withCollection('radio_health', false).withCollection('barometer', false);
    expect(s.toJson()['collection_off'], ['barometer', 'radio_health']);
    final back = Settings.fromJson({...s.toJson(), 'collection_off': ['barometer', 'future_category', 7]});
    expect(back.collectionOff, {'barometer', 'future_category'});
    expect(back.collectionOn('barometer'), isFalse);
    expect(back.collectionOn('motion'), isTrue);
    expect(back.withCollection('packet_headers', false).telemetryEnabled, isFalse);
    expect(Settings.fromJson({'collection_off': 'nope'}).collectionOff, isEmpty);
  });

  test('site-config capabilities (server request S1): only true flags, absent = feature absent, cached', () {
    expect(parseCapabilities(null), isEmpty);
    expect(parseCapabilities('x'), isEmpty);
    expect(parseCapabilities({'driveEnv': true, 'driveContextErase': false, 'driveFormats': ['a']}), {'driveEnv'});
    const sc = SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'driveEnv'});
    expect(sc.driveEnv, isTrue);
    final back = siteConfigFromJson(siteConfigToJson(sc))!;
    expect(back.driveEnv, isTrue);
    const none = SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'));
    expect(siteConfigToJson(none).contains('caps'), isFalse, reason: 'cache file unchanged without capabilities');
    expect(siteConfigFromJson(siteConfigToJson(none))!.driveEnv, isFalse);
  });

  test('simulator drive: the real link + simulator produce radio health and the radio identity', () async {
    final store = FakeDriveStore();
    final simLoc = SimulatedLocationSource(seed: 1);
    var n = 0;
    final services = AppServices(
      store: store,
      settingsStore: FakeSettingsStore(const Settings(intervalSec: 0)),
      cmatClientFactory: FakeCmatClient.new,
      syncServiceFactory: (_) => FakeSyncService(store),
      bluetoothScanner: FakeScanner(const []),
      simulatorScanner: SimulatedRadioScanner(location: simLoc, seed: 1),
      linkFactory: MeshCoreCompanionLink.new,
      location: FakeLocation(),
      simulatedLocation: simLoc,
      engineFactory: (link, loc) => DefaultWardriveEngine(link: link, location: loc),
      repeaterCache: MemoryRepeaterCache(),
      exportDir: () async => Directory.systemTemp,
      shareFile: (_) async {},
      clock: DateTime.now,
      newId: () => 'sim-${++n}',
    );
    final state = AppState(services);
    await state.init();
    expect(await state.connectSimulator(), isTrue, reason: state.connectError);
    await state.saveAntennaProfile(
        AntennaProfile(mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8, updatedAt: DateTime.now().toUtc()));
    await state.startDrive();
    expect(state.driving, isTrue, reason: state.pendingNotice);
    final sid = state.currentSession!.id;
    List<DriveSample> radio() => store.ctx.samplesBySession[sid]?.where((s) => s.src == SampleSource.radio).toList() ?? [];
    for (var i = 0; i < 200 && radio().isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(radio(), isNotEmpty, reason: 'first radio health poll runs at drive start');
    final j = radio().first.toJson();
    expect(j['batt_mv'], inInclusiveRange(3400, 4100));
    expect(j.containsKey('uptime_s'), isTrue);
    expect(j['storage_kb'], {'used': 120, 'total': 1984});
    expect(j.containsKey('pkts'), isTrue);
    expect(j['mcu_temp_c'], inInclusiveRange(24.0, 32.0), reason: 'radio chip temperature from self telemetry');
    for (final k in ['lat', 'lon']) {
      expect(j.containsKey(k), isFalse);
    }
    final ses = store.ctx.sessionBySession[sid];
    expect(ses?.companionExt, isNotNull, reason: 'radio identity from DEVICE_INFO / SELF_INFO');
    final p = await state.pingNow();
    expect(p, isNotNull);
    await state.stopDrive();
    final count = radio().length;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(radio().length, count, reason: 'nothing polled after the drive');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
