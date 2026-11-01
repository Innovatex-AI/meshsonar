// End to end, nothing faked except the radio hardware and the GPS:
//   simulated radio (real companion frames, real encrypted echoes)
//   → MeshCoreCompanionLink → DefaultWardriveEngine
//   → JsonlDriveStore (on disk) → DefaultSyncService → HttpCmatClient
//   → CMAT's REAL endpoint code (meshcore-insights src/lib/drive/handlers.ts, in-memory store, served by bun)
// and then checks the server holds exactly what the radio heard. Skips when bun or the CMAT checkout is missing
// (CMAT_DIR=<meshcore-insights checkout>, BUN=<bun>; see test/core/cmat_env.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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

import '../core/cmat_env.dart';

const adminKey = 'e2e-admin-key-0123456789abcdef';

void main() {
  // CMAT_DIR / BUN as in test/core/cmat_env.dart; skipped with the reason when either is missing.
  final bunPath = findBun();
  final skip = contractSkipReason('src/lib/drive/handlers.ts');

  Process? server;
  late Uri base;

  setUpAll(() async {
    if (skip != null) return;
    server = await Process.start(bunPath!, ['run', p.join(Directory.current.path, 'test', 'fixtures', 'cmat_server.ts'), adminKey, cmatDir()]);
    final err = StringBuffer();
    server!.stderr.transform(utf8.decoder).listen(err.write);
    final lines = server!.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final port = await lines.firstWhere((l) => l.startsWith('PORT ')).timeout(const Duration(seconds: 20),
        onTimeout: () => throw StateError('server did not start: $err'));
    lines.listen((_) {});
    base = Uri.parse('http://127.0.0.1:${port.substring(5).trim()}');
  });
  tearDownAll(() => server?.kill());

  test('simulated drive → local store → sync → real CMAT handlers: server has every ping and echo', () async {
    final tmp = await Directory.systemTemp.createTemp('meshsonar_e2e_');
    addTearDown(() => tmp.delete(recursive: true));

    // --- driver key: request (self-serve: approved at once), save in settings (what the Settings screen does)
    final client = HttpCmatClient(base);
    final settingsStore = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
    final req = await client.requestKey(name: 'E2E Driver', callsign: 'KE4BFI');
    expect(req.status, DriverKeyStatus.approved);
    final st = await client.status(req.key);
    expect(st.status, DriverKeyStatus.approved);
    await settingsStore.save(Settings(driverKey: req.key, keyStatus: st.status, display: st.display));

    // --- radio + GPS: the simulator, sped up so a lap of pings takes seconds
    final loc = SimulatedLocationSource(seed: 7, timeScale: 60);
    final scanner = SimulatedRadioScanner(location: loc, seed: 7, timeScale: 20);
    final devices = await scanner.scan(timeout: const Duration(milliseconds: 200)).last;
    final transport = await scanner.connect(devices.single);
    final link = MeshCoreCompanionLink(transport);
    final self = await link.start();
    final engine = DefaultWardriveEngine(link: link, location: loc);

    // --- drive: what AppState does — session first, every ping saved the moment it's finished
    final store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'store')));
    final session = DriveSession(
      id: const Uuid().v4(),
      startedAt: DateTime.now().toUtc(),
      channel: '#wardriving',
      radio: self.radio,
      antenna: const Antenna(type: 'external', gainDbi: 5.8, heightM: 1.8),
      // The app never uploads a Simulator drive (firmware ends in '-sim'); this test sends the simulated pings as if a real radio
      // made them, to exercise the wire contract.
      companion: Companion(publicKey: self.publicKey, name: self.name, firmware: self.firmware?.replaceAll(Companion.simulatorFirmwareSuffix, '')),
    );
    await store.startSession(session);
    final saved = engine.pings.asyncMap((ping) => store.appendPing(session.id, ping).then((_) => ping)).toList();

    await engine.start(const WardriveConfig(intervalSec: 0, minDistanceM: 0, listenWindow: Duration(milliseconds: 700)));
    const n = 24;
    for (var i = 0; i < n; i++) {
      await engine.pingNow();
    }
    await engine.stop();
    await link.close();
    await store.endSession(session.id, DateTime.now().toUtc());

    // the stream closes after stop+close; give it a moment, then read what's on disk
    final emitted = await saved.timeout(const Duration(seconds: 10), onTimeout: () => const []);
    final local = await store.pings(session.id);
    expect(local, hasLength(n), reason: 'every ping must be on disk before any upload');
    final heard = local.where((x) => x.echoes.isNotEmpty).length;
    final nothing = local.where((x) => x.heardNothing).length;
    // ignore: avoid_print
    print('E2E: ${local.length} pings on disk (${emitted.length} via stream): $heard heard, $nothing heard nothing, '
        '${local.expand((x) => x.echoes).length} echoes, multi-hop ${local.expand((x) => x.echoes).where((e) => (e.hops ?? 1) > 1).length}');
    expect(heard, greaterThan(0), reason: 'the simulator should be heard somewhere on the loop');
    expect(local.every((x) => x.echoes.every((e) => RegExp(r'^[0-9a-f]+$').hasMatch(e.repeater) && e.repeater.length.isEven)), isTrue);

    // --- sync to the real server code
    final sync = DefaultSyncService(store: store, client: client, settings: settingsStore);
    final r1 = await sync.syncAll();
    expect(r1.error, isNull);
    expect(r1.stored, n);
    expect(r1.rejected, 0, reason: 'the real validator must accept everything the engine produced');
    final summary = (await store.sessions()).single;
    expect(summary.unsyncedCount, 0);

    // --- server state matches the radio, ping for ping
    final state = jsonDecode((await http.get(base.resolve('/__test/state'))).body) as Map<String, dynamic>;
    final srvSession = (state['sessions'] as List).cast<Map<String, dynamic>>().singleWhere((s) => s['id'] == session.id);
    expect(srvSession['pingCount'], n);
    expect(srvSession['endedAt'], isNotNull, reason: 'the end of the drive reaches the server');
    final srvEchoes = {for (final x in (state['pings'] as List).cast<Map<String, dynamic>>()) x['id']: x['echoes']};
    for (final ping in local) {
      expect(srvEchoes[ping.id], ping.echoes.length, reason: 'ping ${ping.id} echo count on server');
    }

    // --- re-sync is harmless
    final r2 = await sync.syncAll();
    expect(r2.stored, 0);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
