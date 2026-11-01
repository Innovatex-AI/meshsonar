// An AppState wired to the REAL companion link over the simulated radio (not the FakeLink of the other UI tests), with an
// in-memory chat store: what the wiring tests need to see chat work end to end.
import 'dart:io';

import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/chat/secret_store.dart';
import 'package:meshsonar/chat/store.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/simulator.dart';

import '../fakes.dart';

class SimChatHarness extends Harness {
  final SimulatedRadioScanner scanner;
  final ChatStore chatStore = ChatStore.inMemory(secrets: InMemorySecretStore());
  SimChatHarness({SimulatedRadioScanner? scanner}) : scanner = scanner ?? SimulatedRadioScanner(timeScale: 50, seed: 3);

  @override
  AppServices buildServices() => AppServices(
        store: store,
        settingsStore: settings,
        cmatClientFactory: makeClient,
        syncServiceFactory: (_) => sync,
        bluetoothScanner: bt,
        simulatorScanner: scanner,
        linkFactory: (t) => MeshCoreCompanionLink(t),
        location: location,
        simulatedLocation: simLocation,
        engineFactory: makeEngine,
        openUrl: recordOpenUrl,
        repeaterCache: cache,
        exportDir: () async => Directory.systemTemp,
        shareFile: (f) async => shared.add(f),
        clock: () => clockNow,
        newId: nextId,
        regionIndexCache: regionIndexCache,
        openChatStore: () async => chatStore,
      );
}

/// Polls [cond] on the real clock (the simulated radio runs on real timers).
Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10), String what = 'condition'}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
