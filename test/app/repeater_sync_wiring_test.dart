// Stream 3 through AppState: the synced lists feed the names used for pings and the heard box with a fixed priority
// (region roster > drive-repeaters > network list near the phone > map.meshcore.io directory); prefixes the roster marks
// as shared never resolve; the network list, once the server offers it, replaces the 17 MB map.meshcore.io download;
// stored lists give names offline at the next launch; the map interface is exposed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/repeater_directory.dart';
import 'package:meshsonar/core/repeater_sync.dart';

import '../ui/fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
final rosterDa = 'da5d${'0' * 60}', cmatDa = 'da99${'0' * 60}', rosterEe = 'ee01${'0' * 60}', cmatEe = 'ee77${'0' * 60}';
final globalAb = 'ab12${'0' * 60}', globalFar = 'ac12${'0' * 60}', directoryCd = 'cd12${'0' * 60}';

class _DirHarness extends Harness {
  final RepeaterDirectory directory;
  _DirHarness(this.directory);
  @override
  AppServices buildServices() {
    final b = super.buildServices();
    return AppServices(
      store: b.store,
      settingsStore: b.settingsStore,
      cmatClientFactory: b.cmatClientFactory,
      syncServiceFactory: b.syncServiceFactory,
      bluetoothScanner: b.bluetoothScanner,
      simulatorScanner: b.simulatorScanner,
      linkFactory: b.linkFactory,
      location: b.location,
      simulatedLocation: b.simulatedLocation,
      engineFactory: b.engineFactory,
      repeaterCache: b.repeaterCache,
      exportDir: b.exportDir,
      shareFile: b.shareFile,
      clock: b.clock,
      newId: b.newId,
      regionIndexCache: b.regionIndexCache,
      repeaterSync: b.repeaterSync,
      directory: directory,
    );
  }
}

void main() {
  late Directory tmp;
  late List<Uri> seen;
  late int networkStatus;
  _DirHarness? current;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('ms_rsw_');
    seen = [];
    networkStatus = 200;
  });
  tearDown(() async {
    await current?.state.repeaterSync?.writesDone;
    current = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  http.Client server() => MockClient((req) async {
        seen.add(req.url);
        final p = req.url.path;
        if (req.url.host == 'cmh.meshsonar.com' && p.endsWith('/region-repeaters')) {
          return http.Response(
              jsonEncode({
                'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-16T17:00:00Z'},
                'rows': [
                  {'key': rosterDa, 'hashPrefix': 'da', 'name': 'Roster-DA', 'role': 'repeater', 'lat': 40.1, 'lon': -82.9, 'ambiguous': false, 'status': 'active'},
                  {'key': rosterEe, 'hashPrefix': 'ee', 'name': 'Roster-EE', 'role': 'repeater', 'lat': 40.1, 'lon': -82.9, 'ambiguous': true, 'status': 'active'},
                ],
                'counts': {'active': 2},
              }),
              200);
        }
        if (req.url.host == 'meshsonar.com' && p == '/api/cmh/network-repeaters') {
          if (networkStatus != 200) return http.Response('{"error":"not found"}', networkStatus);
          return http.Response(
              jsonEncode({
                'v': 1,
                'asOf': '2026-10-16T12:00:00Z',
                'count': 2,
                'hidden': 0,
                'rows': [
                  [globalAb, 'Global-AB', 40.2, -83.0, 2, null],
                  [globalFar, 'Global-Far', 47.6, -122.3, 2, null],
                ],
              }),
              200);
        }
        if (req.url.host == 'map.meshcore.io') {
          return http.Response(
              jsonEncode([
                {'public_key': directoryCd, 'type': 2, 'adv_name': 'Dir-CD', 'adv_lat': 40.0, 'adv_lon': -83.0, 'last_advert': '2026-10-15T00:00:00Z'},
              ]),
              200);
        }
        return http.Response('nope', 404);
      });

  _DirHarness make() {
    final c = server();
    final h = _DirHarness(RepeaterDirectory(cacheFile: File('${tmp.path}/nodes.json'), client: c, clock: () => DateTime.utc(2026, 10, 16, 18)));
    h.repeaterSync = RepeaterSync(
        store: RepeaterSyncStore(Directory('${tmp.path}/sync')),
        rosterClient: () => c,
        networkClient: () => c,
        clock: () => DateTime.utc(2026, 10, 16, 18),
        parseInIsolate: false);
    h.approveKey();
    h.client.regionsIndexResult = const [cmh];
    h.client.repeaterList = [
      RepeaterRef(key: cmatDa, name: 'CMAT-DA', lat: 40.0, lon: -83.0),
      RepeaterRef(key: cmatEe, name: 'CMAT-EE', lat: 40.0, lon: -83.0),
    ];
    current = h;
    return h;
  }

  // Waits on the real completion signal: launch has fetched the index, located the phone, run the launch sync and
  // written what it fetched (no fixed delay).
  Future<void> settle() => current!.state.launchSettled.timeout(const Duration(seconds: 20));

  test('priority: roster > drive-repeaters > network nearby > directory; roster-shared prefixes never resolve', () async {
    final h = make();
    await h.state.init();
    await settle();
    expect(h.state.currentRegion?.code, 'CMH');
    final s = h.state;
    // Both the roster and drive-repeaters have a 'da' repeater: the roster wins.
    expect(s.repeaterName('da'), 'Roster-DA');
    expect(s.lookup.resolve('da').source, RepeaterSource.cmat);
    // drive-repeaters still names what the roster lacks (full key prefix).
    expect(s.repeaterName('da99'), 'CMAT-DA');
    // The roster says 'ee' is shared: no single name, even though drive-repeaters lists one 'ee'.
    final ee = s.lookup.resolve('ee');
    expect(ee.ref, isNull);
    expect(ee.ambiguous, isTrue);
    expect(ee.candidates.map((r) => r.key).toSet(), {rosterEe, cmatEe});
    // A longer prefix can still be told apart.
    expect(s.repeaterName('ee77'), 'CMAT-EE');
    // The network list near the phone; the far one (Seattle) is not used for names.
    expect(s.repeaterName('ab'), 'Global-AB');
    expect(s.lookup.resolve('ab').source, RepeaterSource.publicMap);
    expect(s.repeaterName('ac'), isNull);
    // Map interface for the maps stream.
    expect(s.regionRepeaterSet.rows.map((r) => r.name), containsAll(['Roster-DA', 'Roster-EE']));
    expect(s.globalRepeaterSet.rows, hasLength(2));
    expect(s.globalRepeaterSet.state, SyncState.ready);
  });

  test('the network list replaces the map.meshcore.io download; without it (404) the directory is used as before', () async {
    final h = make();
    await h.state.init();
    await settle();
    await h.state.refreshDirectory(lat: 40.0, lon: -83.0, force: true);
    expect(seen.where((u) => u.host == 'map.meshcore.io'), isEmpty);
    expect(h.state.diagnostics.lines.join('\n'), contains('Network repeater list: 2 repeaters'));

    networkStatus = 404;
    await h.state.repeaterSync!.writesDone;
    await tmp.delete(recursive: true);
    tmp = await Directory.systemTemp.createTemp('ms_rsw_');
    seen.clear();
    final h2 = make();
    await h2.state.init();
    await settle();
    expect(h2.state.repeaterSync!.networkCapability, NetworkCapability.absent);
    expect(h2.state.globalRepeaterSet.state, SyncState.unsupported);
    expect(h2.state.pendingNotice, isNull, reason: 'capability absent is a diagnostics line only');
    await h2.state.refreshDirectory(lat: 40.0, lon: -83.0, force: true);
    expect(seen.where((u) => u.host == 'map.meshcore.io'), hasLength(1));
    expect(h2.state.repeaterName('cd'), 'Dir-CD');
  });

  test('stored lists give names at the next launch with no network', () async {
    final h = make();
    await h.state.init();
    await settle();
    // Next launch, everything offline.
    final c = MockClient((req) async => throw const SocketException('offline'));
    final h2 = Harness();
    h2.repeaterSync = RepeaterSync(
        store: RepeaterSyncStore(Directory('${tmp.path}/sync')),
        rosterClient: () => c,
        networkClient: () => c,
        clock: () => DateTime.utc(2026, 10, 16, 19),
        parseInIsolate: false);
    h2.client.regionsIndexResult = const [cmh];
    await h2.state.init();
    expect(h2.state.repeaterSync!.roster('cmh'), isNotNull, reason: 'loaded before any network call');
    await h2.state.launchSettled.timeout(const Duration(seconds: 20));
    expect(h2.state.repeaterName('da'), 'Roster-DA');
    expect(h2.state.repeaterName('ab'), 'Global-AB');
    expect(h2.state.repeaterSync!.rosterLabel('cmh'), 'Offline - as of 1h ago');
    await h2.state.repeaterSync!.writesDone;
  });
}
