// Smoke test: AppState driving the real simulator, companion link and wardrive engine (no hardware).
// Everything else (store, sync, settings) is a fake. Runs in real time (~one listen window).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

import 'fakes.dart';

void main() {
  test('simulator: connect, start, ping now, stop -> ping stored', () async {
    final store = FakeDriveStore();
    final settings = FakeSettingsStore(const Settings(intervalSec: 0));
    final simLoc = SimulatedLocationSource(seed: 1);
    var n = 0;
    final services = AppServices(
      store: store,
      settingsStore: settings,
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
    expect(state.connectionLabel, 'Simulator');
    expect(state.selfInfo, isNotNull);

    // 0.4.0 (spec §4): the simulator, like a real radio, drives only once its antenna is set up.
    expect(state.needsAntennaSetup, isTrue);
    await state.startDrive();
    expect(state.driving, isFalse, reason: 'no drive before the antenna is set up');
    await state.saveAntennaProfile(
        AntennaProfile(mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8, updatedAt: DateTime.now().toUtc()));
    await state.startDrive();
    expect(state.driving, isTrue, reason: state.pendingNotice);
    final session = store.sessionsById.values.single;
    expect(session.companion.publicKey, state.selfInfo!.publicKey.toLowerCase());
    expect(session.antenna.toJson(), {'type': 'external', 'gain_dbi': 5.8, 'height_m': 1.8});

    final p = await state.pingNow();
    expect(p, isNotNull, reason: state.pendingNotice);
    await state.stopDrive();
    expect(store.pingsBySession[session.id]!.map((x) => x.id), contains(p!.id));
    expect(store.sessionsById[session.id]!.endedAt, isNotNull);
    await state.disconnect();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
