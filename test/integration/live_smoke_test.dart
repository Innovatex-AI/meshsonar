// Live smoke test against a deployed server. Skipped unless both are set:
//   MESHSONAR_LIVE_URL  e.g. https://cmh-meshcore.lovable.app
//   MESHSONAR_LIVE_KEY  an APPROVED driver key (use a test driver; reject it afterwards to keep it off the public map)
// Drives the simulator through the real engine, saves to disk, syncs to the live server, re-syncs (duplicates only).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/sync_service.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  final url = Platform.environment['MESHSONAR_LIVE_URL'];
  final key = Platform.environment['MESHSONAR_LIVE_KEY'];
  final skip = (url == null || key == null) ? 'set MESHSONAR_LIVE_URL and MESHSONAR_LIVE_KEY' : null;

  test('simulated drive syncs to the live server', () async {
    final tmp = await Directory.systemTemp.createTemp('meshsonar_live_');
    addTearDown(() => tmp.delete(recursive: true));
    final client = HttpCmatClient(Uri.parse(url!));
    final st = await client.status(key!);
    expect(st.status, DriverKeyStatus.approved, reason: 'the live key must be approved');
    final settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
    await settings.save(Settings(serverUrl: url, driverKey: key, keyStatus: st.status, display: st.display));

    final reps = await client.repeaters(key);
    // ignore: avoid_print
    print('live repeaters for offline names: ${reps.length}');

    final loc = SimulatedLocationSource(seed: 11, timeScale: 60);
    final scanner = SimulatedRadioScanner(location: loc, seed: 11, timeScale: 20);
    final dev = (await scanner.scan(timeout: const Duration(milliseconds: 200)).last).single;
    final link = MeshCoreCompanionLink(await scanner.connect(dev));
    final self = await link.start();
    final engine = DefaultWardriveEngine(link: link, location: loc);
    final store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'store')));
    final session = DriveSession(
      id: const Uuid().v4(),
      startedAt: DateTime.now().toUtc(),
      label: 'MeshSonar live smoke test (simulator)',
      channel: '#wardriving',
      radio: self.radio,
      antenna: const Antenna(type: 'simulated'),
      companion: Companion(publicKey: self.publicKey, name: self.name, firmware: self.firmware),
    );
    await store.startSession(session);
    final sub = engine.pings.listen((ping) => store.appendPing(session.id, ping));
    await engine.start(const WardriveConfig(intervalSec: 0, minDistanceM: 0, listenWindow: Duration(milliseconds: 700)));
    for (var i = 0; i < 16; i++) {
      await engine.pingNow();
    }
    await engine.stop();
    await link.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await sub.cancel();
    await store.endSession(session.id, DateTime.now().toUtc());
    final local = await store.pings(session.id);
    expect(local, hasLength(16));

    final sync = DefaultSyncService(store: store, client: client, settings: settings);
    final r1 = await sync.syncAll();
    // ignore: avoid_print
    print('live sync: stored ${r1.stored}, duplicate ${r1.duplicate}, rejected ${r1.rejected}, error ${r1.error}; '
        'session ${session.id}; heard ${local.where((x) => x.echoes.isNotEmpty).length}/16');
    expect(r1.error, isNull);
    expect(r1.stored, 16);
    expect(r1.rejected, 0);
    expect((await store.sessions()).single.unsyncedCount, 0);
    final r2 = await sync.syncAll();
    expect(r2.stored, 0);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
