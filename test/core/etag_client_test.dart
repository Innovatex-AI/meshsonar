import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/etag_client.dart';
import 'package:meshsonar/core/region_cache.dart';

void main() {
  late Directory dir;
  var now = DateTime.utc(2026, 10, 24, 12);
  setUp(() => dir = Directory.systemTemp.createTempSync('etag'));
  tearDown(() {
    setSharedEtagClientForTest(null);
    dir.deleteSync(recursive: true);
  });

  final url = Uri.parse('https://cmh.meshsonar.com/api/cmh/region-overview');

  EtagClient make(MockClientHandler h, {bool stale = true}) =>
      EtagClient(MockClient(h), RegionCache(dir, clock: () => now), serveStale: stale, staleAfter: const Duration(milliseconds: 200));

  test('200 is stored; the next GET sends If-None-Match and a 304 serves the stored body as a 200', () async {
    final seen = <String?>[];
    var calls = 0;
    final c = make((req) async {
      seen.add(req.headers['if-none-match']);
      calls++;
      if (calls == 1) return http.Response('{"a":1}', 200, headers: {'etag': '"v1"', 'content-type': 'application/json'});
      return http.Response('', 304);
    });
    final a = await c.get(url);
    expect(a.statusCode, 200);
    expect(a.body, '{"a":1}');
    final b = await c.get(url);
    expect(seen, [null, '"v1"']);
    expect(b.statusCode, 200);
    expect(b.body, '{"a":1}');
    expect(b.headers['x-meshsonar-cache'], '304');
    expect(c.offlineSince, isNull);
  });

  test('a changed 200 replaces the stored body and ETag', () async {
    var n = 0;
    final seen = <String?>[];
    final c = make((req) async {
      seen.add(req.headers['if-none-match']);
      n++;
      return http.Response('{"n":$n}', 200, headers: {'etag': '"v$n"'});
    });
    await c.get(url);
    final b = await c.get(url);
    expect(b.body, '{"n":2}');
    await c.get(url);
    expect(seen, [null, '"v1"', '"v2"']);
  });

  test('network failure serves the stored copy and says when it is from', () async {
    var down = false;
    final t = now;
    final c = make((req) async {
      if (down) throw const SocketException('down');
      return http.Response('{"a":1}', 200, headers: {'etag': '"v1"'});
    });
    await c.get(url);
    down = true;
    now = now.add(const Duration(hours: 3));
    final r = await c.get(url);
    expect(r.statusCode, 200);
    expect(r.body, '{"a":1}');
    expect(r.headers['x-meshsonar-cache'], 'offline');
    expect(c.offlineSince, t);
    expect(asOfLabel(c.offlineSince!, now, offline: true), 'Offline - as of 3h ago');
    down = false;
    await c.get(url);
    expect(c.offlineSince, isNull, reason: 'a live answer clears the offline state');
  });

  test('a hung request and a 5xx also fall back to the stored copy', () async {
    var mode = 'ok';
    final c = make((req) async {
      if (mode == 'hang') return Completer<http.Response>().future;
      if (mode == '503') return http.Response('busy', 503);
      return http.Response('{"a":1}', 200, headers: {'etag': '"v1"'});
    });
    await c.get(url);
    mode = 'hang';
    expect((await c.get(url)).body, '{"a":1}');
    mode = '503';
    expect((await c.get(url)).body, '{"a":1}');
  });

  test('failure with nothing stored rethrows; other statuses pass through', () async {
    var status = 0;
    final c = make((req) async {
      if (status == 0) throw const SocketException('down');
      return http.Response('{"error":"nope"}', status);
    });
    await expectLater(c.get(url), throwsA(isA<SocketException>()));
    status = 404;
    final r = await c.get(url);
    expect(r.statusCode, 404);
    expect(r.body, contains('nope'));
  });

  test('serveStale false: ETag still works but failures reach the caller', () async {
    var down = false;
    final c = make((req) async {
      if (down) throw const SocketException('down');
      if (req.headers['if-none-match'] == '"v1"') return http.Response('', 304);
      return http.Response('{"a":1}', 200, headers: {'etag': '"v1"'});
    }, stale: false);
    await c.get(url);
    expect((await c.get(url)).body, '{"a":1}');
    down = true;
    await expectLater(c.get(url), throwsA(isA<SocketException>()));
  });

  test('POSTs, driver-key GETs and other paths pass straight through', () async {
    final seen = <http.BaseRequest>[];
    final c = make((req) async {
      seen.add(req);
      return http.Response('{}', 200, headers: {'etag': '"x"'});
    });
    await c.post(url, body: '{}');
    await c.get(url, headers: {'x-driver-key': 'k'});
    await c.get(Uri.parse('https://cmh.meshsonar.com/api/cmh/upload-status'));
    await c.get(Uri.parse('https://example.com/other'));
    expect(seen.every((r) => !r.headers.containsKey('if-none-match')), isTrue);
    expect(dir.listSync(), isEmpty, reason: 'nothing written to the cache');
  });

  test('which paths are cacheable', () {
    for (final p in ['/api/cmh/region-repeater', '/api/cmh/region-overview', '/api/cmh/regions-index', '/api/cmh/public-coverage', '/api/cmh/site-config', '/v1/regions']) {
      expect(EtagClient.isCacheable(Uri.parse('https://x.test$p?a=1')), isTrue, reason: p);
    }
    for (final p in ['/api/cmh/ping', '/api/cmh/upload', '/api/cmh/whoami']) {
      expect(EtagClient.isCacheable(Uri.parse('https://x.test$p')), isFalse, reason: p);
    }
  });

  test('cache keys differ per query and stay file-name sized', () {
    final a = EtagClient.keyFor(Uri.parse('https://cmh.meshsonar.com/api/cmh/region-repeater?key=${'a' * 64}'));
    final b = EtagClient.keyFor(Uri.parse('https://cmh.meshsonar.com/api/cmh/region-repeater?key=${'b' * 64}'));
    expect(a, isNot(b));
    expect(a.length, lessThan(120));
    expect(a, matches(RegExp(r'^[A-Za-z0-9_]+$')));
  });

  test('shared client: fetchers get it via newRegionWireClient and closing it does not close the shared one', () async {
    var calls = 0;
    final inner = MockClient((req) async {
      calls++;
      return http.Response(jsonEncode({'ok': true}), 200, headers: {'etag': '"s"'});
    });
    setSharedEtagClientForTest(EtagClient(inner, RegionCache(dir)));
    final c1 = newRegionWireClient();
    await c1.get(url);
    c1.close();
    final c2 = newRegionWireClient();
    expect((await c2.get(url)).statusCode, 200);
    expect(calls, 2);
    setSharedEtagClientForTest(null);
    expect(newRegionWireClient(), isNot(isA<EtagClient>()));
  });
}
