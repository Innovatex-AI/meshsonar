// Live contract test: the app's delta client against the REAL server (https://meshsonar.com/api/cmh/network-repeaters,
// public, read-only GETs). Same idea as cmat_contract_test.dart (the app's parser and sync against the server's real
// answers), but it needs the internet instead of a local checkout, so it is skipped unless
//   MESHSONAR_LIVE_CONTRACT=1 flutter test test/core/network_delta_live_contract_test.dart
// (MESHSONAR_LIVE_SERVER=<origin> to aim it at another server). It sends about 4 GETs plus one 3.5 MB gzip download.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/network_repeaters.dart';
import 'package:meshsonar/core/repeater_sync.dart';

void main() {
  final env = Platform.environment;
  final skip = env['MESHSONAR_LIVE_CONTRACT'] == '1' ? null : 'set MESHSONAR_LIVE_CONTRACT=1 to run against the live server';
  final origin = env['MESHSONAR_LIVE_SERVER'] ?? 'https://meshsonar.com';
  final url = Uri.parse('$origin/api/cmh/network-repeaters');

  test('live: full list, delta by the list\'s own cursor, 304, 410 for an old cursor, 400 for garbage', () async {
    final c = http.Client();
    addTearDown(c.close);

    // Full list: parses with the production parser; the cursor derives from asOf.
    final fullRes = await c.get(url, headers: {'accept': 'application/json'});
    expect(fullRes.statusCode, 200);
    final full = NetworkRepeaters.parse(jsonDecode(utf8.decode(fullRes.bodyBytes)));
    expect(full.rows.length, greaterThan(1000));
    expect(full.asOf, isNotNull);
    final cursor = deltaCursorOf(full)!;
    // ignore: avoid_print
    print('live full: ${full.rows.length} rows, ${fullRes.bodyBytes.length} bytes decoded, asOf ${full.asOf}, ETag ${fullRes.headers['etag']}');

    // 304 on the full list.
    final etag = fullRes.headers['etag'];
    expect(etag, isNotNull);
    final again = await c.get(url, headers: {'accept': 'application/json', 'if-none-match': etag!});
    expect(again.statusCode, 304);

    // Delta from the list's own cursor: the envelope the parser needs, consistent counts, rows in the full-list shape.
    final deltaRes = await c.get(url.replace(queryParameters: {'updated_since': '$cursor'}), headers: {'accept': 'application/json'});
    expect(deltaRes.statusCode, 200, reason: deltaRes.body);
    final raw = jsonDecode(utf8.decode(deltaRes.bodyBytes)) as Map<String, dynamic>;
    expect(raw['v'], 1);
    expect(raw['asOfS'], isA<int>());
    expect(raw['count'], (raw['rows'] as List).length);
    expect(raw['removedCount'], (raw['removed'] as List).length);
    final delta = NetworkDelta.parse(raw);
    expect(delta.asOfS, greaterThanOrEqualTo(cursor));
    expect(delta.dropped, 0, reason: 'the server\'s rows pass the app\'s strict row rules');
    final merged = delta.applyTo(full);
    // ignore: avoid_print
    print('live delta: +${delta.rows.length} changed, -${delta.removed.length} removed, ${deltaRes.bodyBytes.length} bytes decoded, '
        'asOfS ${delta.asOfS} (${DateTime.fromMillisecondsSinceEpoch(delta.asOfS * 1000, isUtc: true)}), now ${merged.rows.length} rows');
    expect(merged.rows.length, inInclusiveRange(full.rows.length - 500, full.rows.length + 500));

    // An absurdly old cursor: 410 with code since_too_old (the app then downloads the full list once).
    final old = await c.get(url.replace(queryParameters: {'updated_since': '1000000000'}), headers: {'accept': 'application/json'});
    expect(old.statusCode, 410);
    expect(jsonDecode(old.body)['code'], 'since_too_old');
    // Garbage and the future are 400.
    expect((await c.get(url.replace(queryParameters: {'updated_since': 'abc'}))).statusCode, 400);
    expect((await c.get(url.replace(queryParameters: {'updated_since': '9999999999'}))).statusCode, 400);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));

  test('live: RepeaterSync (production path, isolate decode, real HTTP) downloads once, then refreshes by delta and agrees with a fresh full list', () async {
    final dir = await Directory.systemTemp.createTemp('ms_live_delta_');
    addTearDown(() async => dir.delete(recursive: true));
    var now = DateTime.now().toUtc();
    final logs = <String>[];
    final sync = RepeaterSync(
      store: RepeaterSyncStore(dir),
      networkClient: http.Client.new,
      clock: () => now,
      deltaCapable: () => true,
    )..log = logs.add;
    final server = Uri.parse(origin);

    expect(await sync.syncNetwork(server: server, trigger: SyncTrigger.launch), isTrue, reason: logs.join('\n'));
    final fullBytes = sync.networkBytesIn;
    final fullRows = sync.network!.data.rows.length;
    expect(fullRows, greaterThan(1000));
    expect(sync.network!.cursorS, deltaCursorOf(sync.network!.data));

    now = now.add(const Duration(hours: 7)); // past the 6 h gate (the cursor check uses the same clock: 7 h is fine)
    expect(await sync.syncNetwork(server: server, trigger: SyncTrigger.resume), isTrue, reason: logs.join('\n'));
    // ignore: avoid_print
    print(logs.join('\n'));
    expect(logs.last, contains('delta +'), reason: 'the second refresh went through the delta path');
    final deltaBytes = sync.networkBytesIn - fullBytes;
    // ignore: avoid_print
    print('live sync: full $fullBytes bytes, delta $deltaBytes bytes, ${sync.networkRequests} requests, '
        'now ${sync.network!.data.rows.length} rows, cursorS ${sync.network!.cursorS}');
    expect(sync.networkRequests, 2);
    expect(deltaBytes, lessThan(fullBytes));
    expect(sync.networkError, isNull);

    // Agreement with the server's own current full list (it moves while the test runs: allow a small drift).
    final res = await http.get(server.replace(path: '/api/cmh/network-repeaters'), headers: {'accept': 'application/json'});
    final fresh = NetworkRepeaters.parse(jsonDecode(utf8.decode(res.bodyBytes)));
    final mine = {for (final r in sync.network!.data.rows) r.key};
    final theirs = {for (final r in fresh.rows) r.key};
    final differ = mine.difference(theirs).length + theirs.difference(mine).length;
    // ignore: avoid_print
    print('live agreement: ${mine.length} vs ${theirs.length} keys, $differ differ');
    expect(differ, lessThan(fresh.rows.length * 0.01));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 3)));
}
