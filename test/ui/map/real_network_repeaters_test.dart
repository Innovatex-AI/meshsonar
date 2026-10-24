// Opt-in: the REAL GET /api/cmh/network-repeaters body (55.6k rows, ~6.5 MB raw on Oct 24 2026) through the merged
// parser (lib/core/network_repeaters.dart), the RepeaterSync store (24 MB file cap) and sync (isolate decode), the
// name rule (network list used only within 150 km), and the map's points + cluster build for the global layer.
//
// The body is NOT committed (> 1 MB). Download it once and point the env var at it:
//   curl -sS --compressed -o /some/scratch/network-repeaters.json https://meshsonar.com/api/cmh/network-repeaters
//   MESHSONAR_REAL_NETWORK_REPEATERS=/some/scratch/network-repeaters.json flutter test test/ui/map/real_network_repeaters_test.dart
// Without the variable (or the file) every test here is skipped. Timings are printed (Mac host VM, JIT, not a phone).
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/heard.dart' show haversineM;
import 'package:meshsonar/core/network_repeaters.dart';
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/ui/map/layers/app_repeater_feed.dart' show networkMapRows;
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';

final String? _path = Platform.environment['MESHSONAR_REAL_NETWORK_REPEATERS'];
final File? _file = _path == null ? null : File(_path!);
final Object? _skip = (_file == null || !_file!.existsSync()) ? 'set MESHSONAR_REAL_NETWORK_REPEATERS to a downloaded network-repeaters body' : null;

void _log(String s) {
  // ignore: avoid_print
  print('[real network-repeaters] $s');
}

void main() {
  late List<int> bytes;
  setUpAll(() {
    if (_skip == null) bytes = _file!.readAsBytesSync();
  });

  test('parser accepts the real body (generatedAt, attribution, count are extra fields); nothing dropped', () {
    final sw = Stopwatch()..start();
    final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final decodeMs = sw.elapsedMilliseconds;
    final data = NetworkRepeaters.parse(decoded);
    sw.stop();
    _log('raw ${bytes.length} bytes; server count ${decoded['count']}, hidden ${decoded['hidden']}, rows sent ${(decoded['rows'] as List).length}; '
        'parsed ${data.rows.length}, dropped ${data.dropped}; jsonDecode $decodeMs ms + parse ${sw.elapsedMilliseconds - decodeMs} ms (main isolate)');
    expect(decoded['v'], 1);
    expect(decoded['generatedAt'], isA<String>());
    expect(data.asOf, isNotNull);
    expect(data.rows.length, greaterThan(50000));
    expect(data.rows.length + data.dropped, (decoded['rows'] as List).length);
    expect(data.dropped, lessThan(data.rows.length ~/ 100), reason: 'a few malformed upstream rows at most');
    expect(data.rows.every((r) => r.type == 2 || r.type == 3), isTrue);
  }, skip: _skip);

  test('RepeaterSync: fetch + isolate decode, store under the 24 MB cap, reload offline', () async {
    final tmp = await Directory.systemTemp.createTemp('ms_real_netreps_');
    try {
      final body = bytes;
      final c = MockClient((req) async => http.Response.bytes(body, 200, headers: {'etag': '"real"', 'content-type': 'application/json'}));
      final store = RepeaterSyncStore(Directory('${tmp.path}/sync'));
      final sync = RepeaterSync(store: store, rosterClient: () => c, networkClient: () => c, parseInIsolate: true);
      await sync.load();
      final sw = Stopwatch()..start();
      final ok = await sync.syncNetwork(server: Uri.parse('https://meshsonar.com'), trigger: SyncTrigger.launch);
      sw.stop();
      await sync.writesDone;
      expect(ok, isTrue, reason: 'networkError: ${sync.networkError}');
      final g = sync.globalSet;
      expect(g.state, SyncState.ready);
      expect(g.rows.length, greaterThan(50000));
      final f = File('${tmp.path}/sync/network.json');
      expect(f.existsSync(), isTrue, reason: 'saved: under the 24 MB file cap');
      final size = f.lengthSync();
      expect(size, lessThan(24 * 1024 * 1024));
      final re = Stopwatch()..start();
      final back = await RepeaterSyncStore(Directory('${tmp.path}/sync')).loadNetwork();
      re.stop();
      expect(back!.data.rows.length, g.rows.length);
      _log('syncNetwork (MockClient, decode+parse in Isolate.run, save) ${sw.elapsedMilliseconds} ms; network.json $size bytes '
          '(${(size / 1048576).toStringAsFixed(1)} MB of the 24 MB cap); reload from disk ${re.elapsedMilliseconds} ms');
    } finally {
      await tmp.delete(recursive: true);
    }
  }, skip: _skip);

  test('names: the network list is used within 150 km only (Columbus, Seattle, mid-Atlantic)', () {
    final data = NetworkRepeaters.parse(jsonDecode(utf8.decode(bytes)));
    final now = DateTime.now().toUtc();
    for (final (name, lat, lon) in [('Columbus', 39.96, -82.99), ('Seattle', 47.61, -122.33), ('mid-Atlantic', 35.0, -40.0)]) {
      final sw = Stopwatch()..start();
      final near = data.nearby(lat, lon, now: now);
      sw.stop();
      expect(near.length, lessThanOrEqualTo(3000));
      expect(near.every((r) => haversineM(lat, lon, r.lat, r.lon) <= 150000), isTrue);
      _log('nearby($name): ${near.length} within 150 km in ${sw.elapsedMilliseconds} ms');
    }
  }, skip: _skip);

  test('global layer: 55k points + cluster index built in one Isolate.run; viewport queries', () async {
    final data = NetworkRepeaters.parse(jsonDecode(utf8.decode(bytes)));
    final conv = Stopwatch()..start();
    final rows = networkMapRows(data.rows);
    conv.stop();
    final feed = StaticRepeaterMapFeed(global: MapRepeaterSet(rows: rows, state: MapFeedState.ready, attribution: 'Data: MeshCore Map (map.meshcore.io)'));
    final rssBefore = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();
    final src = RepeaterMapSource(feed);
    await src.settled;
    sw.stop();
    final rssAfter = ProcessInfo.currentRss;
    final idx = src.globalIndex!;
    expect(idx.indexedCount, src.globalPoints.length);
    expect(src.globalPoints.length, greaterThan(50000));
    expect(src.statusOf(kNetworkLayerId).availability, LayerAvailability.ready);
    final p = src.globalPoints;
    final typed = p.length * (8 + 8 + 1 + 1);
    _log('rows -> MapRepeaterRow ${conv.elapsedMilliseconds} ms (UI isolate, AppStateRepeaterFeed); rows -> points + cluster index '
        'in Isolate.run ${sw.elapsedMilliseconds} ms for ${p.length} points (${p.skipped} skipped); typed lists ~${(typed / 1024).round()} KB '
        '+ ${p.length} keys/names; RSS ${(rssBefore / 1048576).round()} -> ${(rssAfter / 1048576).round()} MB');
    // Isolate.run round trip on its own, to separate copy cost from build cost.
    final rt = Stopwatch()..start();
    await Isolate.run(() => rows.length);
    rt.stop();
    _log('Isolate.run copying the 55k rows in and back out (no work): ${rt.elapsedMilliseconds} ms');
    src.dispose();
  }, skip: _skip);
}
