// The regions-index at 559 regions: parsing off the main isolate, not rewriting the cache for an unchanged answer,
// 429 / failure back-off, the resume cadence, full-detail outlines near an edge, the ETag/304 path for a 3.4 MB body.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/etag_client.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/region_lookup.dart';

import '../support/regions_559.dart';

class _CountingCache implements RegionIndexCache {
  List<RegionIndexEntry> items;
  int saves = 0;
  _CountingCache([this.items = const []]);
  @override
  Future<List<RegionIndexEntry>> load() async => items;
  @override
  Future<void> save(List<RegionIndexEntry> regions) async {
    saves++;
    items = regions;
  }
}

void main() {
  final index = syntheticIndex559();

  group('parsing', () {
    test('a 3.4 MB-class body parses off the main isolate to the same entries as inline', () async {
      final body = regionsIndexBody(index);
      expect(body.length, greaterThan(regionsIndexIsolateThreshold), reason: 'big enough to take the isolate path');
      final off = await parseRegionsIndexBodyOffMain(body);
      final inline = parseRegionsIndexBody(body);
      expect(off.length, 559);
      expect(regionsFingerprint(off), regionsFingerprint(inline));
      expect(off.first.code, index.first.code);
      expect(off[100].boundary!['type'], 'Polygon');
    });

    test('shape errors are FormatExceptions; a malformed region is skipped, not fatal', () {
      expect(() => parseRegionsIndexBody('[]'), throwsFormatException);
      expect(() => parseRegionsIndexBody('{"asOf":"x"}'), throwsFormatException);
      expect(() => parseRegionsIndexBody('{"regions":[]}'), throwsFormatException);
      final ok = parseRegionsIndexBody('{"regions":[{"code":"AAA","slug":"aaa","name":"A, US","url":"u"},{"code":1},"x"],"asOf":"t"}');
      expect(ok.map((r) => r.code), ['AAA']);
    });

    test('fingerprint: same content same digest, any outline or bbox change different', () {
      final a = syntheticIndex559(), b = syntheticIndex559();
      expect(regionsFingerprint(a), regionsFingerprint(b));
      final moved = [...b];
      final r = moved[7];
      moved[7] = RegionIndexEntry(code: r.code, slug: r.slug, name: r.name, url: r.url, bbox: r.bbox, boundary: {
        'type': 'Polygon',
        'coordinates': [
          [for (final p in ((r.boundary!['coordinates'] as List).first as List).cast<List>()) [p[0] + 0.001, p[1]]],
        ],
      });
      expect(regionsFingerprint(moved), isNot(regionsFingerprint(a)));
      expect(regionsFingerprint(a.reversed.toList()), isNot(regionsFingerprint(a)), reason: 'order counts');
    });
  });

  group('FileRegionIndexCache', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('ri_cache'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('559 regions round-trip through the file (loaded off the main isolate)', () async {
      final c = FileRegionIndexCache(File('${tmp.path}/regions_index.json'));
      await c.save(index);
      expect(File('${tmp.path}/regions_index.json').lengthSync(), greaterThan(regionsIndexIsolateThreshold));
      final back = await c.load();
      expect(back.length, 559);
      expect(regionsFingerprint(back), regionsFingerprint(index));
    });

    test('a damaged or oversized-garbage file is an empty cache, never an exception', () async {
      final f = File('${tmp.path}/regions_index.json')..writeAsStringSync('{' * 400000);
      expect(await FileRegionIndexCache(f).load(), isEmpty);
    });
  });

  group('RegionIndexService', () {
    test('an unchanged answer writes nothing and keeps the same list object; a changed one saves', () async {
      final cache = _CountingCache();
      var answer = index;
      final s = RegionIndexService(fetch: () async => answer, cache: cache);
      await s.refresh();
      expect(cache.saves, 1);
      final first = s.regions;
      answer = syntheticIndex559(); // equal content, new objects (what a 304 -> reparse gives)
      await s.refresh();
      expect(cache.saves, 1, reason: 'same index: the 3.4 MB file is not rewritten');
      expect(identical(s.regions, first), isTrue, reason: 'and everything keyed on the list stays warm');
      answer = [...answer]..removeLast();
      await s.refresh();
      expect(cache.saves, 2);
      expect(s.regions.length, 558);
    });

    test('a cached index that matches the live answer is not rewritten either', () async {
      final cache = _CountingCache(index);
      final s = RegionIndexService(fetch: () async => syntheticIndex559(), cache: cache);
      await s.loadCached();
      await s.refresh();
      expect(cache.saves, 0);
      expect(s.everLoaded, isTrue);
    });

    test('429 backs off for Retry-After; refreshIfDue does not ask during it; a person\'s refresh() still can', () async {
      var now = DateTime.utc(2026, 10, 28, 12);
      var calls = 0;
      Object? err = const CmatException('server answered 429', status: 429, retryAfterSec: 120);
      final s = RegionIndexService(
        fetch: () async {
          calls++;
          if (err != null) throw err;
          return index.take(3).toList();
        },
        cache: _CountingCache(),
        clock: () => now,
      );
      await s.refresh();
      expect(s.lastErrorStatus, 429);
      expect(s.due, isFalse);
      await s.refreshIfDue();
      expect(calls, 1);
      now = now.add(const Duration(seconds: 119));
      expect(s.due, isFalse);
      now = now.add(const Duration(seconds: 2));
      expect(s.due, isTrue);
      err = null;
      await s.refreshIfDue();
      expect(calls, 2);
      expect(s.lastError, isNull);
      expect(s.lastErrorStatus, isNull);
      expect(s.regions.length, 3);
    });

    test('429 without Retry-After waits a minute; offline failures back off 30 s, 60 s, ... up to 10 min', () async {
      var now = DateTime.utc(2026, 10, 28, 12);
      Object err = const CmatException('server answered 429', status: 429);
      final s = RegionIndexService(fetch: () async => throw err, cache: _CountingCache(), clock: () => now);
      await s.refresh();
      expect(s.backoffUntil, now.add(const Duration(seconds: 60)));
      err = const CmatException('network error: down');
      await s.refresh();
      expect(s.backoffUntil, now.add(const Duration(seconds: 60)), reason: 'second failure: 30 << 1');
      for (var i = 0; i < 6; i++) {
        await s.refresh();
      }
      expect(s.backoffUntil!.difference(now).inSeconds, lessThanOrEqualTo(600));
    });

    test('a failure keeps the cached index and flags it stale; due again after maxAge once it worked', () async {
      var now = DateTime.utc(2026, 10, 28, 12);
      final cache = _CountingCache(index);
      var fail = false;
      final s = RegionIndexService(fetch: () async => fail ? throw const CmatException('offline') : index, cache: cache, clock: () => now);
      await s.loadCached();
      fail = true;
      await s.refresh();
      expect(s.regions.length, 559);
      expect(s.lastError, isNotNull);
      fail = false;
      now = now.add(const Duration(minutes: 2));
      await s.refresh();
      expect(s.lastError, isNull);
      expect(s.due, isFalse);
      now = now.add(const Duration(hours: 5, minutes: 59));
      expect(s.due, isFalse);
      now = now.add(const Duration(minutes: 2));
      expect(s.due, isTrue);
    });

    test('refine swaps in the full outline of the asked regions once, in memory only, and a new index drops them', () async {
      final asks = <List<String>>[];
      final cache = _CountingCache();
      List<RegionIndexEntry> detail(List<String> slugs) => [
            for (final r in index)
              if (slugs.contains(r.slug))
                RegionIndexEntry(code: r.code, slug: r.slug, name: r.name, url: r.url, bbox: r.bbox, boundary: {'type': 'Polygon', 'coordinates': (r.boundary!['coordinates'] as List)}),
          ];
      final s = RegionIndexService(
        fetch: () async => index,
        cache: cache,
        fetchDetail: (slugs) async {
          asks.add(slugs);
          return detail(slugs);
        },
      );
      await s.refresh();
      final thin = s.regions;
      expect(await s.refine([thin[3].code, thin[4].code]), isTrue);
      expect(asks.single, [thin[3].slug, thin[4].slug]);
      expect(identical(s.regions[3].boundary, thin[3].boundary), isFalse);
      expect(identical(s.regions[5], thin[5]), isTrue);
      expect(s.refinedCodes, {thin[3].code, thin[4].code});
      expect(await s.refine([thin[3].code]), isFalse, reason: 'asked once per region');
      expect(asks.length, 1);
      expect(cache.saves, 1, reason: 'the cache keeps the thinned index; detail is not persisted');
      await s.refresh(); // unchanged: the refined outlines stay
      expect(s.refinedCodes.length, 2);
    });

    test('refine: no capability, an error, or an empty answer leaves the index alone and is not retried for an empty answer', () async {
      final s0 = RegionIndexService(fetch: () async => index, cache: _CountingCache());
      await s0.refresh();
      expect(await s0.refine([index.first.code]), isFalse);
      var tries = 0;
      final s1 = RegionIndexService(
          fetch: () async => index,
          cache: _CountingCache(),
          fetchDetail: (_) async {
            tries++;
            throw const CmatException('429', status: 429);
          });
      await s1.refresh();
      final before = s1.regions;
      expect(await s1.refine([index.first.code]), isFalse);
      expect(identical(s1.regions, before), isTrue);
      expect(await s1.refine([index.first.code]), isFalse);
      expect(tries, 2, reason: 'a failed ask may be retried');
      var empty = 0;
      final s2 = RegionIndexService(
          fetch: () async => index,
          cache: _CountingCache(),
          fetchDetail: (_) async {
            empty++;
            return const [];
          });
      await s2.refresh();
      expect(await s2.refine([index.first.code]), isFalse);
      expect(await s2.refine([index.first.code]), isFalse);
      expect(empty, 1, reason: 'a region the server does not return is asked about once');
    });
  });

  group('HttpCmatClient.regionsIndex', () {
    HttpCmatClient client(MockClientHandler h) => HttpCmatClient(Uri.parse('https://meshsonar.com'), client: MockClient(h));

    test('reads the whole index (isolate path), sends no driver key, asks for json', () async {
      final body = regionsIndexBody(index);
      late http.Request seen;
      final c = client((r) async {
        seen = r;
        return http.Response(body, 200, headers: {'content-type': 'application/json'});
      });
      final got = await c.regionsIndex();
      expect(got.length, 559);
      expect(seen.url.path, '/api/cmh/regions-index');
      expect(seen.url.query, isEmpty);
      expect(seen.headers.containsKey('x-driver-key'), isFalse);
    });

    test('slugs become ?slug=a,b', () async {
      late Uri seen;
      final c = client((r) async {
        seen = r.url;
        return http.Response(regionsIndexBody(index.take(2).toList()), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      });
      await c.regionsIndex(slugs: ['aaa', 'aab']);
      expect(seen.queryParameters['slug'], 'aaa,aab');
    });

    test('429 carries its status and Retry-After; 503 too; non-JSON and wrong shapes are CmatExceptions', () async {
      final c = client((r) async => http.Response('{"error":"rate limited"}', 429, headers: {'retry-after': '37'}));
      await expectLater(
          c.regionsIndex(),
          throwsA(isA<CmatException>().having((e) => e.status, 'status', 429).having((e) => e.retryAfterSec, 'retryAfter', 37)));
      final c2 = client((r) async => http.Response('nope', 503));
      await expectLater(c2.regionsIndex(), throwsA(isA<CmatException>().having((e) => e.status, 'status', 503)));
      final c3 = client((r) async => http.Response('<html>', 200));
      await expectLater(c3.regionsIndex(), throwsA(isA<CmatException>()));
      final c4 = client((r) async => http.Response('{"regions":3,"asOf":"x"}', 200));
      await expectLater(c4.regionsIndex(), throwsA(isA<CmatException>()));
    });
  });

  group('the 3.4 MB body through the ETag cache', () {
    late Directory dir;
    var now = DateTime.utc(2026, 10, 28, 12);
    setUp(() => dir = Directory.systemTemp.createTempSync('ri_etag'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a 304 serves the stored body, does not rewrite the file, and still moves "as of" and the LRU time', () async {
      final body = regionsIndexBody(index);
      final cache = RegionCache(dir, clock: () => now);
      var calls = 0;
      final etag = EtagClient(
          MockClient((req) async {
            calls++;
            if (calls == 1) return http.Response(body, 200, headers: {'etag': 'W/"abc"', 'content-type': 'application/json'});
            expect(req.headers['if-none-match'], 'W/"abc"');
            return http.Response('', 304);
          }),
          cache,
          serveStale: false);
      final u = Uri.parse('https://meshsonar.com/api/cmh/regions-index');
      expect((await etag.get(u)).body.length, body.length);
      final file = dir.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.json'));
      final written = file.statSync().modified;
      final size = file.lengthSync();
      now = now.add(const Duration(hours: 1));
      await Future<void>.delayed(const Duration(milliseconds: 1100)); // file mtime granularity
      final second = await etag.get(u);
      expect(second.statusCode, 200);
      expect(second.body.length, body.length);
      await Future<void>.delayed(const Duration(milliseconds: 20)); // the touch is unawaited
      expect(file.lengthSync(), size, reason: 'same bytes on disk');
      expect(file.statSync().modified.isAfter(written), isTrue, reason: 'LRU position moved');
      final key = EtagClient.keyFor(u);
      expect((await cache.read(key))!.fetchedAt, now, reason: 'as of moves without a rewrite');
    });

    test('small bodies are still rewritten on a 304 (their "as of" is on disk)', () async {
      final cache = RegionCache(dir, clock: () => now);
      await cache.put('k', '{"a":1}', etag: '"v"');
      now = now.add(const Duration(hours: 2));
      await cache.touch('k', '{"a":1}', etag: '"v"');
      final raw = jsonDecode(dir.listSync().whereType<File>().firstWhere((f) => f.path.endsWith('.json')).readAsStringSync()) as Map;
      expect(raw['at'], now.toUtc().toIso8601String());
    });
  });
}
