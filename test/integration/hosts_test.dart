// AC-12 (spec m1-app-0.4.0 §5): MeshSonar sends drive data to one place only, the server in Settings.
// Only the configured server, map.meshcore.io (GET, no body) and map tile hosts are ever contacted.
//
//  (The static half — hosts written in lib/ — is hosts_static_test.dart, which runs before 0.4.0 code exists.)
//  Dynamic: the real AppState with the real store, sync, CMAT client, node directory and simulated radio, all
//     HTTP through one recording client: connect, set the antenna, drive, upload, refresh names, refresh the node map,
//     send a problem report. No other host is seen, no request body goes anywhere but the server, and nothing
//     opens a dart:io HttpClient behind the recorder's back.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/repeater_directory.dart';
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/core/report_draft_store.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/sync_service.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

class Seen {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int> body;
  Seen(this.method, this.url, this.headers, this.body);
}

/// The real engine with a short listen window, so a drive of a few pings takes seconds.
class FastEngine implements WardriveEngine {
  final WardriveEngine inner;
  FastEngine(this.inner);
  @override
  Stream<DrivePing> get pings => inner.pings;
  @override
  Stream<EngineStatus> get status => inner.status;
  @override
  EngineStatus get current => inner.current;
  @override
  Future<void> start(WardriveConfig c) => inner.start(WardriveConfig(
      channel: c.channel,
      intervalSec: c.intervalSec,
      minDistanceM: c.minDistanceM,
      listenWindow: const Duration(milliseconds: 600),
      txPowerW: c.txPowerW,
      txDbm: c.txDbm));
  @override
  void updateConfig(WardriveConfig c) => inner.updateConfig(c);
  @override
  Future<DrivePing> pingNow() => inner.pingNow();
  @override
  Future<void> stop() => inner.stop();
}

void main() {
  test('dynamic: drive + sync + names + node map + report reach only the server and map.meshcore.io (GET)', () async {
    final tmp = await Directory.systemTemp.createTemp('meshsonar_hosts_');
    addTearDown(() => tmp.delete(recursive: true));
    final server = Uri.parse('https://cmat.hosts-test.example/base/');
    const driverKey = 'ms_hostsTestKey_0123456789abcdefghijABCDEFGHIJ0';
    final seen = <Seen>[];
    final rawClients = <String>[];

    final recorder = MockClient((req) async {
      seen.add(Seen(req.method, req.url, req.headers, req.bodyBytes));
      if (req.url.host == server.host) {
        final name = req.url.pathSegments.last;
        switch (name) {
          case 'driver-status':
            return http.Response(jsonEncode({'status': 'approved', 'display': 'HOSTS'}), 200);
          case 'drive-repeaters':
            return http.Response(jsonEncode({'repeaters': [], 'at': '2026-10-17T00:00:00Z'}), 200);
          case 'drive-upload':
            final b = jsonDecode(utf8.decode(req.bodyBytes)) as Map;
            final n = (b['pings'] as List).length;
            return http.Response(
                jsonEncode({'sessionId': (b['session'] as Map)['id'], 'stored': n, 'duplicate': 0, 'rejected': 0, 'rejections': []}),
                200);
          case 'problem-report':
            return http.Response(
                jsonEncode({'id': '3f2a9c1e-7b6d-4e21-9a0c-1d2e3f4a5b6c', 'status': 'new', 'receivedAt': '2026-10-17T14:00:00Z', 'redacted': {}}),
                201);
        }
        return http.Response(jsonEncode({'error': 'not found'}), 404);
      }
      if (req.url.host == 'map.meshcore.io') return http.Response('[]', 200);
      return http.Response('nope', 404);
    });

    await HttpOverrides.runZoned(() async {
      final settingsStore = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
      await settingsStore.save(Settings(
          serverUrl: server.toString(), driverKey: driverKey, keyStatus: DriverKeyStatus.approved, display: 'HOSTS'));
      final store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
      final simLoc = SimulatedLocationSource(seed: 3, timeScale: 30);
      const app = AppInfo(name: 'MeshSonar', version: '0.4.0', build: '5', platform: 'linux');
      final services = AppServices(
        store: store,
        settingsStore: settingsStore,
        cmatClientFactory: (u) => HttpCmatClient(u, client: recorder),
        syncServiceFactory: (c) => DefaultSyncService(store: store, client: c, settings: settingsStore, app: app),
        bluetoothScanner: SimulatedRadioScanner(location: simLoc, seed: 3, timeScale: 20),
        simulatorScanner: SimulatedRadioScanner(location: simLoc, seed: 3, timeScale: 20),
        linkFactory: (t) => MeshCoreCompanionLink(t),
        location: simLoc,
        simulatedLocation: simLoc,
        engineFactory: (link, loc) => FastEngine(DefaultWardriveEngine(link: link, location: loc)),
        repeaterCache: FileRepeaterCache(File(p.join(tmp.path, 'repeaters.json'))),
        exportDir: () async => Directory(p.join(tmp.path, 'out'))..createSync(recursive: true),
        shareFile: (_) async {},
        openUrl: (_) async => true,
        appInfo: app,
        directory: RepeaterDirectory(cacheFile: File(p.join(tmp.path, 'nodes.json')), client: recorder),
        // Stream 3: the roster/network list sync through the same recorder (network-repeaters goes to the server only).
        repeaterSync: RepeaterSync(
            store: RepeaterSyncStore(Directory(p.join(tmp.path, 'repeater_sync'))),
            rosterClient: () => recorder,
            networkClient: () => recorder,
            parseInIsolate: false),
        reportDraftStore: FileReportDraftStore(File(p.join(tmp.path, 'report_draft.json'))),
        clock: DateTime.now,
        newId: () => const Uuid().v4(),
      );
      final state = AppState(services);
      await state.init();

      expect(await state.connectSimulator(), isTrue, reason: state.connectError);
      await state.saveAntennaProfile(AntennaProfile(
          mount: AntennaMount.roofMagMount, gainDbi: 5.8, heightM: 1.8, updatedAt: DateTime.now().toUtc()));
      await state.startDrive(label: 'hosts');
      expect(state.driving, isTrue, reason: state.pendingNotice);
      for (var i = 0; i < 3; i++) {
        await state.pingNow();
      }
      await state.stopDrive();
      await state.syncAll();
      await state.refreshRepeaters();
      await state.refreshDirectory(lat: 40.126, lon: -82.93, force: true);
      final report = await state.previewProblemReport(category: 'other', description: 'hosts test report');
      await state.sendProblemReport(report);
      await state.disconnect(quiet: true);
    }, createHttpClient: (_) {
      rawClients.add(StackTrace.current.toString().split('\n').take(6).join('\n'));
      throw StateError('a dart:io HttpClient was opened outside the injected http.Client');
    });

    expect(rawClients, isEmpty, reason: rawClients.join('\n---\n'));
    final hosts = seen.map((s) => s.url.host).toSet();
    expect(hosts.difference({server.host, 'map.meshcore.io'}), isEmpty, reason: 'unexpected hosts: $hosts');
    for (final s in seen) {
      if (s.body.isNotEmpty) expect(s.url.host, server.host, reason: 'a request body went to ${s.url}');
      if (s.headers.keys.any((k) => k.toLowerCase() == 'x-driver-key')) {
        expect(s.url.host, server.host, reason: 'the driver key went to ${s.url}');
      }
      if (s.url.host == 'map.meshcore.io') {
        expect(s.method, 'GET');
        expect(s.url.hasQuery, isFalse, reason: 'no location in the node-map request');
      }
    }
    final names = seen.where((s) => s.url.host == server.host).map((s) => s.url.pathSegments.last).toSet();
    expect(names, containsAll(['drive-upload', 'problem-report']), reason: 'the test must really drive, sync and report');
    expect(names, contains('network-repeaters'), reason: 'the network list is asked of the configured server, nowhere else');
    for (final s in seen.where((s) => s.url.pathSegments.last == 'network-repeaters')) {
      expect(s.method, 'GET');
      expect(s.url.hasQuery, isFalse);
      expect(s.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-driver-key')));
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
