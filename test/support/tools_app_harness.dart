// The app's Harness (fakes for server, storage, GPS) with the REAL radio stack: MeshCoreCompanionLink over the simulated
// radio, so AppState gets a session whose Tools work. For tests that prove the wiring from More to a Tool.
import 'dart:io';

import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/simulator.dart';

import '../ui/fakes.dart';

class ToolsAppHarness extends Harness {
  ToolsAppHarness({super.antennaProfile});

  late final SimulatedRadioScanner realSim = SimulatedRadioScanner(location: SimulatedLocationSource(speedMps: 0), seed: 4, timeScale: 50);

  @override
  AppServices buildServices() => AppServices(
        store: store,
        settingsStore: settings,
        cmatClientFactory: makeClient,
        syncServiceFactory: (_) => sync,
        bluetoothScanner: bt,
        simulatorScanner: realSim,
        linkFactory: (t) => MeshCoreCompanionLink(t, timeout: const Duration(seconds: 2), messagePollInterval: const Duration(minutes: 5)),
        location: location,
        simulatedLocation: simLocation,
        engineFactory: makeEngine,
        openUrl: recordOpenUrl,
        repeaterCache: cache,
        exportDir: () async => Directory.systemTemp,
        shareFile: (f) async => shared.add(f),
        clock: () => DateTime.now(),
        newId: nextId,
        regionIndexCache: regionIndexCache,
        uiPrefsFile: uiPrefsFile,
      );
}
