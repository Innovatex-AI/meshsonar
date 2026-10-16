// AppState ↔ RepeaterDirectory hook: cached directory names load at init, the first ping of a drive refreshes the
// directory around that position, and nothing breaks when the node map is offline.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/repeater_directory.dart';

import 'fakes.dart';

AppState stateWith(Harness h, RepeaterDirectory dir) {
  final s = h.services;
  return AppState(AppServices(
    store: s.store,
    settingsStore: s.settingsStore,
    cmatClientFactory: s.cmatClientFactory,
    syncServiceFactory: s.syncServiceFactory,
    bluetoothScanner: s.bluetoothScanner,
    simulatorScanner: s.simulatorScanner,
    linkFactory: s.linkFactory,
    location: s.location,
    simulatedLocation: s.simulatedLocation,
    engineFactory: s.engineFactory,
    repeaterCache: s.repeaterCache,
    exportDir: s.exportDir,
    shareFile: s.shareFile,
    newId: s.newId,
    clock: s.clock,
    directory: dir,
  ));
}

Map<String, dynamic> node(String key, String name, double lat, double lon) =>
    {'public_key': key.padRight(64, '0'), 'type': 2, 'adv_name': name, 'adv_lat': lat, 'adv_lon': lon, 'last_advert': '2026-10-15T00:00:00Z'};

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dir_hook'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('first ping of a drive fetches the directory there; names resolve with source = map', () async {
    final h = Harness();
    var calls = 0;
    final dir = RepeaterDirectory(
      cacheFile: File('${tmp.path}/nd.json'),
      clock: () => DateTime.utc(2026, 10, 16, 18),
      client: MockClient((_) async {
        calls++;
        return http.Response.bytes(utf8.encode(jsonEncode([node('a1b2', 'Uptown Water Tower', 40.13, -82.93)])), 200);
      }),
    );
    final st = stateWith(h, dir);
    await st.init();
    expect(calls, 0, reason: 'no cache and no position yet: nothing to fetch');
    await st.connectSimulator();
    await st.startDrive();
    h.engines.last.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 5)]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, 1);
    final m = st.lookup.resolve('a1b2');
    expect(m.ref?.name, 'Uptown Water Tower');
    expect(m.source, RepeaterSource.publicMap);
    expect(st.repeaterName('a1b2'), 'Uptown Water Tower');
    expect(st.heard.repeaters.single.match.ref?.name, 'Uptown Water Tower');
    h.engines.last.emit(heardPing('p2', const []));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, 1, reason: 'only the first fix of a drive triggers a refresh');
    await st.stopDrive();

    // Next launch: names come straight from the cache file, no download (still fresh).
    final st2 = stateWith(Harness(), dir);
    await st2.init();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(st2.repeaterName('a1b2'), 'Uptown Water Tower');
    expect(calls, 1);
  });

  test('offline node map never breaks a drive', () async {
    final h = Harness();
    final st = stateWith(
        h,
        RepeaterDirectory(
          cacheFile: File('${tmp.path}/nd.json'),
          client: MockClient((_) async => throw const SocketException('offline')),
        ));
    await st.init();
    await st.connectSimulator();
    await st.startDrive();
    h.engines.last.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 5)]));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(st.pingCount, 1);
    expect(st.lookup.resolve('a1b2').known, isFalse);
    expect(st.pendingNotice, isNull);
    await st.stopDrive();
  });
}
