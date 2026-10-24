// Regression: the network list decode in a background isolate (the production setting, parseInIsolate: true). The
// first version built the Isolate.run closure inside an async instance method, which captured pending Futures and
// failed every real fetch with "object is unsendable - _Future" (found against the live 55.6k-row body, Oct 24 2026).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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
}
