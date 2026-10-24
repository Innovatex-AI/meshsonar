// Regression: the network list decode in a background isolate (the production setting, parseInIsolate: true). The
// first version built the Isolate.run closure inside an async instance method, which captured pending Futures and
// failed every real fetch with "object is unsendable - _Future" (found against the live 55.6k-row body, Oct 24 2026).
// Also the store's launch read of network.json (6.2 MB for the live list), decoded in a background isolate too.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/network_repeaters.dart';
import 'package:meshsonar/core/repeater_sync.dart';

void main() {
  test('syncNetwork with parseInIsolate: true decodes the list off the main isolate', () async {
    final body = jsonEncode({
      'v': 1,
      'asOf': '2026-10-24T22:40:07.688Z',
      'generatedAt': '2026-10-24T23:15:03.126Z',
      'count': 2,
      'hidden': 0,
      'attribution': {'name': 'MeshCore Map', 'url': 'https://map.meshcore.io'},
      'rows': [
        ['ab' * 32, 'Alpha', 40.0, -83.0, 2, 1792272501],
        ['cd' * 32, null, 41.0, -84.0, 3, null],
      ],
    });
    final c = MockClient((req) async => http.Response(body, 200, headers: {'etag': '"x"'}));
    final sync = RepeaterSync(rosterClient: () => c, networkClient: () => c, parseInIsolate: true);
    final ok = await sync.syncNetwork(server: Uri.parse('https://meshsonar.com'), trigger: SyncTrigger.launch);
    expect(sync.networkError, isNull);
    expect(ok, isTrue);
    expect(sync.globalSet.state, SyncState.ready);
    expect(sync.globalSet.rows.map((r) => r.displayName), ['Alpha', 'cdcdcdcd']);
  });

  test('parseNetworkBodyInIsolate parses the exact server shape', () async {
    final data = await parseNetworkBodyInIsolate(utf8.encode(jsonEncode({'v': 1, 'rows': [['ef' * 32, 'E', 1.0, 2.0, 2, null]]})));
    expect(data.rows.single.name, 'E');
  });

  group('store load of network.json', () {
    late Directory tmp;
    setUp(() async => tmp = await Directory.systemTemp.createTemp('ms_rs_iso_'));
    tearDown(() async => tmp.delete(recursive: true));

    final rec = NetworkRecord(
      data: NetworkRepeaters.parse({'asOf': '2026-10-24T22:40:07Z', 'hidden': 3, 'rows': [['ab' * 32, 'Alpha', 40.0, -83.0, 2, 1792272501], ['cd' * 32, null, 41.0, -84.0, 3, null]]}),
      etag: '"n1-x"',
      fetchedAt: DateTime.utc(2026, 10, 24, 23),
      checkedAt: DateTime.utc(2026, 10, 24, 23, 5),
    );

    for (final iso in [true, false]) {
      test('round trip with parseInIsolate: $iso', () async {
        final store = RepeaterSyncStore(Directory('${tmp.path}/s'), parseInIsolate: iso);
        expect(await store.saveNetwork(rec), isTrue);
        final back = await store.loadNetwork();
        expect(back, isNotNull);
        expect(back!.etag, '"n1-x"');
        expect(back.fetchedAt, rec.fetchedAt);
        expect(back.checkedAt, rec.checkedAt);
        expect(back.data.hidden, 3);
        expect(back.data.asOf, DateTime.utc(2026, 10, 24, 22, 40, 7));
        expect(back.data.rows.map((r) => (r.key, r.name, r.type)), [('ab' * 32, 'Alpha', 2), ('cd' * 32, null, 3)]);
      });

      test('damaged, other version or missing times = null (parseInIsolate: $iso)', () async {
        final store = RepeaterSyncStore(Directory('${tmp.path}/s'), parseInIsolate: iso);
        expect(await store.loadNetwork(), isNull, reason: 'no file');
        final f = File('${tmp.path}/s/network.json')..createSync(recursive: true);
        f.writeAsStringSync('{"v":1,"rows":[');
        expect(await store.loadNetwork(), isNull);
        f.writeAsStringSync(jsonEncode({'v': 2, 'fetchedAt': '2026-10-24T23:00:00Z', 'checkedAt': '2026-10-24T23:00:00Z', 'rows': []}));
        expect(await store.loadNetwork(), isNull);
        f.writeAsStringSync(jsonEncode({'v': 1, 'checkedAt': '2026-10-24T23:00:00Z', 'rows': []}));
        expect(await store.loadNetwork(), isNull);
      });
    }

    test('RepeaterSync.load reads the stored list through the isolate path (the production default)', () async {
      await RepeaterSyncStore(Directory('${tmp.path}/s'), parseInIsolate: false).saveNetwork(rec);
      final sync = RepeaterSync(store: RepeaterSyncStore(Directory('${tmp.path}/s')));
      await sync.load();
      expect(sync.network?.data.rows, hasLength(2));
      expect(sync.globalSet.state, SyncState.ready);
    });
  });
}
