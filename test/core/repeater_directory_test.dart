import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/repeater_directory.dart';

// Shapes copied from a real https://map.meshcore.io/api/v1/nodes response (2026-10-16).
Map<String, dynamic> node(String key, {int type = 2, String name = 'R', double? lat = 40.13, double? lon = -82.93, String? lastAdvert}) => {
      'public_key': key,
      'type': type,
      'adv_name': name,
      'last_advert': lastAdvert ?? '2026-10-14T21:28:21.000Z',
      'adv_lat': lat,
      'adv_lon': lon,
      'inserted_date': '2026-10-14T23:28:57.000Z',
      'updated_date': '2026-10-14T23:28:57.000Z',
      'params': {'freq': 910.525, 'cr': 5, 'sf': 7, 'bw': 62.5},
      'link': 'meshcore://11…',
      'source': 'uploader',
      'inserted_by': 'abc',
      'updated_by': null,
    };

String _k(String p) => p.padRight(64, '0');

/// UTF-8 body (the real registry has non-Latin-1 names).
http.Response ok(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200, headers: {'content-type': 'application/json'});

List<Map<String, dynamic>> sample() => [
      node(_k('DF01'), name: 'Polaris Tower', lat: 40.145, lon: -82.984), // ~5 km, kept (key lower-cased)
      node(_k('ab12'), name: 'Uptown {"x"} \\ tricky', lat: 40.1258, lon: -82.9312), // ~0 km, braces in a string
      node(_k('cc00'), type: 1, name: 'A phone'), // chat node, dropped
      node(_k('dd00'), name: 'Dayton', lat: 39.76, lon: -84.19), // ~115 km, kept
      node(_k('ee00'), name: 'Cleveland', lat: 41.5, lon: -81.7), // ~190 km, dropped
      node(_k('ff00'), name: 'No position', lat: null, lon: null), // dropped
      node(_k('0a00'), name: 'Ancient', lastAdvert: '2024-05-01T00:00:00.000Z'), // too old, dropped
      node(_k('0b00'), name: 'Never advertised', lastAdvert: '1970-01-01T00:00:00.000Z'), // kept (unknown age)
      node('zz-not-hex', name: 'Bad key'), // dropped
    ];

void main() {
  const lat = 40.126, lon = -82.93;
  final now = DateTime.utc(2026, 10, 16, 12);
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('dir_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  RepeaterDirectory make(http.Client c, {DateTime Function()? clock}) =>
      RepeaterDirectory(cacheFile: File('${tmp.path}/node_directory.json'), client: c, clock: clock ?? () => now);

  test('parseNodes: repeaters with a position within the radius, nearest first, lower-case keys', () {
    final list = RepeaterDirectory.parseNodes(sample(), lat: lat, lon: lon, now: now, maxAdvertAge: const Duration(days: 180));
    expect(list.map((r) => r.name), ['Uptown {"x"} \\ tricky', 'Never advertised', 'Polaris Tower', 'Dayton']);
    expect(list.first.key, _k('ab12'));
    expect(list[2].key, _k('df01'));
    expect(RepeaterDirectory.parseNodes({'nodes': sample()}, lat: lat, lon: lon).length, 5); // also no age filter
    expect(() => RepeaterDirectory.parseNodes({'oops': 1}, lat: lat, lon: lon), throwsFormatException);
  });

  test('splitter decodes objects across arbitrary chunk boundaries', () {
    final bytes = utf8.encode(jsonEncode(sample()));
    for (final size in [1, 7, 64, bytes.length]) {
      final got = <String>[];
      final s = JsonArraySplitter((o) => got.add(o['adv_name'] as String));
      for (var i = 0; i < bytes.length; i += size) {
        s.add(bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size));
      }
      expect(got.length, sample().length, reason: 'chunk size $size');
      expect(got[1], 'Uptown {"x"} \\ tricky');
      expect(s.sawArray, isTrue);
    }
  });

  test('refresh downloads, filters, caches to file; load() reads it back', () async {
    var calls = 0;
    final d = make(MockClient((req) async {
      calls++;
      expect(req.url.toString(), 'https://map.meshcore.io/api/v1/nodes');
      return ok(sample());
    }));
    final snap = await d.refresh(lat: lat, lon: lon);
    expect(calls, 1);
    expect(snap!.repeaters.length, 4);
    expect(snap.totalNodes, 9);
    expect(d.lastError, isNull);

    final again = make(MockClient((_) async => throw StateError('should not fetch')));
    final cached = await again.load();
    expect(cached!.repeaters.map((r) => r.name), contains('Polaris Tower'));
    expect(cached.centerLat, lat);
    expect(cached.fetchedAt, now);
  });

  test('TTL: no refetch within 24 h; refetch after 24 h, when the centre moves far, or when forced', () async {
    var t = now;
    var calls = 0;
    final d = make(MockClient((_) async {
      calls++;
      return ok(sample());
    }), clock: () => t);
    await d.refresh(lat: lat, lon: lon);
    t = now.add(const Duration(hours: 23));
    await d.refresh(lat: lat, lon: lon);
    expect(calls, 1);
    await d.refresh(lat: lat, lon: lon, force: true);
    expect(calls, 2);
    await d.refresh(lat: 41.5, lon: -81.7); // Cleveland: > half the radius away
    expect(calls, 3);
    t = now.add(const Duration(hours: 48));
    expect(d.isStale(d.snapshot), isTrue);
    await d.refresh(lat: 41.5, lon: -81.7);
    expect(calls, 4);
  });

  test('offline / server error / bad JSON: never throws, keeps the old cache, backs off', () async {
    var t = now;
    var mode = 'ok';
    var calls = 0;
    final d = make(MockClient((_) async {
      calls++;
      if (mode == 'offline') throw const SocketException('no route');
      if (mode == '500') return http.Response('nope', 500);
      if (mode == 'junk') return http.Response('<html>', 200);
      return ok(sample());
    }), clock: () => t);
    final good = await d.refresh(lat: lat, lon: lon);

    t = now.add(const Duration(days: 2));
    mode = 'offline';
    final s1 = await d.refresh(lat: lat, lon: lon);
    expect(identical(s1, good), isTrue);
    expect(d.lastError, contains('No connection'));
    final before = calls;
    await d.refresh(lat: lat, lon: lon); // within the back-off window: no new attempt
    expect(calls, before);

    mode = '500';
    expect((await d.refresh(lat: lat, lon: lon, force: true))!.repeaters.length, 4);
    expect(d.lastError, contains('500'));

    mode = 'junk';
    expect(await d.refresh(lat: lat, lon: lon, force: true), same(good));
    expect(d.lastError, isNotNull);
  });

  test('no cache and offline → null; damaged cache file → null', () async {
    final d = make(MockClient((_) async => throw const SocketException('offline')));
    expect(await d.load(), isNull);
    expect(await d.refresh(lat: lat, lon: lon), isNull);
    File('${tmp.path}/node_directory.json').writeAsStringSync('{broken');
    expect(await make(MockClient((_) async => http.Response('[]', 200))).load(), isNull);
  });

  test('times out quickly on a server that never answers', () async {
    final d = RepeaterDirectory(
      cacheFile: File('${tmp.path}/n.json'),
      client: MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 50),
      clock: () => now,
    );
    expect(await d.refresh(lat: lat, lon: lon), isNull);
    expect(d.lastError, contains('in time'));
  });

  test('size limit: an oversized body is refused', () async {
    final d = RepeaterDirectory(
      cacheFile: File('${tmp.path}/n.json'),
      client: MockClient((_) async => ok(sample())),
      maxBytes: 100,
      clock: () => now,
    );
    expect(await d.refresh(lat: lat, lon: lon), isNull);
    expect(d.lastError, contains('too large'));
  });

  test('maxRepeaters keeps the nearest', () async {
    final d = RepeaterDirectory(
      cacheFile: File('${tmp.path}/n.json'),
      client: MockClient((_) async => ok(sample())),
      maxRepeaters: 2,
      clock: () => now,
    );
    final s = await d.refresh(lat: lat, lon: lon);
    expect(s!.repeaters.map((r) => r.name), ['Uptown {"x"} \\ tricky', 'Never advertised']);
  });
}
