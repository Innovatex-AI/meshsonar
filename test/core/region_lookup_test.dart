// lib/core/region_lookup.dart: bbox-only region matching, the regions-index cache, and its fetch/cache wrapper.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';

const cmh = RegionIndexEntry(
  code: 'CMH',
  slug: 'cmh',
  name: 'Columbus, US',
  url: 'https://cmh.meshsonar.com',
  bbox: [-83.5, 39.75, -82.45, 40.65],
);

const dayton = RegionIndexEntry(
  code: 'DAY',
  slug: 'day',
  name: 'Dayton, US',
  url: 'https://day.meshsonar.com',
  bbox: [-84.5, 39.5, -83.6, 40.2],
);

/// Overlaps CMH's southwest corner; its own centroid is closer to a fix placed right in that overlap.
const overlapper = RegionIndexEntry(
  code: 'OVL',
  slug: 'ovl',
  name: 'Overlap region',
  url: 'https://ovl.meshsonar.com',
  bbox: [-83.0, 39.8, -82.8, 40.0],
);

const noBbox = RegionIndexEntry(code: 'NOX', slug: 'nox', name: 'No bbox yet', url: 'https://nox.meshsonar.com');

void main() {
  group('RegionIndexEntry.tryParse', () {
    test('parses a full entry (bbox + Polygon boundary)', () {
      final e = RegionIndexEntry.tryParse({
        'code': 'CMH',
        'slug': 'cmh',
        'name': 'Columbus, US',
        'url': 'https://cmh.meshsonar.com',
        'bbox': [-83.5, 39.75, -82.45, 40.65],
        'boundary': {
          'type': 'Polygon',
          'coordinates': [
            [
              [-83.5, 39.75],
              [-82.45, 39.75],
              [-82.45, 40.65],
              [-83.5, 40.65],
              [-83.5, 39.75],
            ]
          ],
        },
      });
      expect(e, isNotNull);
      expect(e!.code, 'CMH');
      expect(e.bbox, [-83.5, 39.75, -82.45, 40.65]);
      expect(e.boundary?['type'], 'Polygon');
    });

    test('bbox null is a real, expected state (parses fine, just never matches)', () {
      final e = RegionIndexEntry.tryParse({'code': 'CMH', 'slug': 'cmh', 'name': 'Columbus, US', 'url': 'https://cmh.meshsonar.com', 'bbox': null});
      expect(e, isNotNull);
      expect(e!.bbox, isNull);
    });

    test('a MultiPolygon boundary parses too (the real contract allows either)', () {
      final e = RegionIndexEntry.tryParse({
        'code': 'CMH',
        'slug': 'cmh',
        'name': 'Columbus, US',
        'url': 'https://cmh.meshsonar.com',
        'boundary': {'type': 'MultiPolygon', 'coordinates': []},
      });
      expect(e!.boundary?['type'], 'MultiPolygon');
    });

    test('missing required fields, a malformed bbox, or not a map returns null', () {
      expect(RegionIndexEntry.tryParse('not a map'), isNull);
      expect(RegionIndexEntry.tryParse({'slug': 'cmh', 'name': 'x', 'url': 'y'}), isNull); // no code
      expect(RegionIndexEntry.tryParse({'code': '', 'slug': 'cmh', 'name': 'x', 'url': 'y'}), isNull); // empty code
      expect(RegionIndexEntry.tryParse({'code': 'CMH', 'slug': 'cmh', 'name': 'x', 'url': 'y', 'bbox': [1, 2, 3]})!.bbox, isNull); // wrong length
      expect(
          RegionIndexEntry.tryParse({'code': 'CMH', 'slug': 'cmh', 'name': 'x', 'url': 'y', 'bbox': [1, 2, 3, 'nope']})!.bbox,
          isNull); // non-numeric
    });
  });

  group('regionAt (bbox point-in-rectangle + nearest-centroid tiebreak)', () {
    final index = [cmh, dayton, overlapper, noBbox];

    test('a fix inside exactly one bbox matches it', () {
      // Dayton, OH is inside dayton's bbox and clear of cmh's and overlapper's.
      expect(regionAt(index, 39.76, -84.19)?.code, 'DAY');
    });

    test('no match: outside every known bbox', () {
      expect(regionAt(index, 35.0, -80.0), isNull);
    });

    test('no match: an empty index', () {
      expect(regionAt(const [], 40.0, -83.0), isNull);
    });

    test('a region with no bbox never matches, even exactly at another region\'s fix', () {
      // noBbox has no bbox at all; this point is also inside cmh, so cmh must win, never noBbox.
      expect(regionAt([noBbox, cmh], 40.0, -83.0)?.code, 'CMH');
    });

    test('overlap tiebreak: the region whose bbox centroid is nearest the fix wins', () {
      // Inside both cmh and overlapper's bboxes. overlapper's bbox is small and centred close to this fix;
      // cmh's bbox is much larger, so its centroid is farther away.
      final fix = regionAt(index, 39.9, -82.9);
      expect(fix?.code, 'OVL');
    });

    test('a fix near cmh\'s own centroid (away from the overlap) matches cmh, not the overlapper', () {
      final cmhCentroidLat = (cmh.bbox![1] + cmh.bbox![3]) / 2;
      final cmhCentroidLon = (cmh.bbox![0] + cmh.bbox![2]) / 2;
      expect(regionAt(index, cmhCentroidLat, cmhCentroidLon)?.code, 'CMH');
    });

    test('a fix exactly on a bbox edge counts as inside (inclusive bounds)', () {
      expect(regionAt([cmh], 39.75, -83.0)?.code, 'CMH'); // south edge
      expect(regionAt([cmh], 40.65, -83.0)?.code, 'CMH'); // north edge
      expect(regionAt([cmh], 40.0, -83.5)?.code, 'CMH'); // west edge
      expect(regionAt([cmh], 40.0, -82.45)?.code, 'CMH'); // east edge
    });

    test('an invalid fix (NaN, or out of lat/lon range) never matches', () {
      expect(regionAt(index, double.nan, -83.0), isNull);
      expect(regionAt(index, 91.0, -83.0), isNull);
      expect(regionAt(index, 40.0, -181.0), isNull);
    });
  });

  group('FileRegionIndexCache', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('region_cache_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('missing file: load returns empty, no error', () async {
      final cache = FileRegionIndexCache(File('${tmp.path}/regions.json'));
      expect(await cache.load(), isEmpty);
    });

    test('save then load round-trips the regions, atomically (no stray .tmp file left)', () async {
      final file = File('${tmp.path}/regions.json');
      final cache = FileRegionIndexCache(file);
      await cache.save([cmh, dayton]);
      expect(File('${file.path}.tmp').existsSync(), isFalse);
      final loaded = await cache.load();
      expect(loaded.map((r) => r.code), ['CMH', 'DAY']);
      expect(loaded.first.bbox, cmh.bbox);
    });

    test('a damaged cache file only costs region awareness: load returns empty, never throws', () async {
      final file = File('${tmp.path}/regions.json');
      await file.create(recursive: true);
      await file.writeAsString('{not json');
      final cache = FileRegionIndexCache(file);
      expect(await cache.load(), isEmpty);
    });

    test('a cache file that is valid JSON but not a list returns empty', () async {
      final file = File('${tmp.path}/regions.json');
      await file.create(recursive: true);
      await file.writeAsString('{"regions": []}'); // an object, not the bare array this cache writes
      final cache = FileRegionIndexCache(file);
      expect(await cache.load(), isEmpty);
    });
  });

  group('MemoryRegionIndexCache', () {
    test('starts with the seeded value and save overwrites it', () async {
      final cache = MemoryRegionIndexCache([cmh]);
      expect(await cache.load(), [cmh]);
      await cache.save([dayton]);
      expect((await cache.load()).single.code, 'DAY');
    });
  });

  group('RegionIndexService (fetch + cache wrapper)', () {
    test('loadCached fills regions from the cache without touching fetch', () async {
      var fetchCalls = 0;
      final svc = RegionIndexService(
        fetch: () async {
          fetchCalls++;
          return [dayton];
        },
        cache: MemoryRegionIndexCache([cmh]),
      );
      final loaded = await svc.loadCached();
      expect(loaded.single.code, 'CMH');
      expect(svc.regions.single.code, 'CMH');
      expect(svc.everLoaded, isTrue);
      expect(fetchCalls, 0);
    });

    test('loadCached with nothing cached: regions stays empty, everLoaded stays false', () async {
      final svc = RegionIndexService(fetch: () async => [cmh], cache: MemoryRegionIndexCache());
      final loaded = await svc.loadCached();
      expect(loaded, isEmpty);
      expect(svc.everLoaded, isFalse);
    });

    test('refresh fetches, updates regions, clears lastError, and persists to the cache', () async {
      final cache = MemoryRegionIndexCache();
      final svc = RegionIndexService(fetch: () async => [cmh, dayton], cache: cache);
      final r = await svc.refresh();
      expect(r.map((e) => e.code), ['CMH', 'DAY']);
      expect(svc.regions.map((e) => e.code), ['CMH', 'DAY']);
      expect(svc.everLoaded, isTrue);
      expect(svc.lastError, isNull);
      expect((await cache.load()).map((e) => e.code), ['CMH', 'DAY']); // persisted, not just held in memory
    });

    test('a failed refresh keeps the previous regions (the cache), and records lastError', () async {
      final svc = RegionIndexService(
        fetch: () => Future.error(Exception('offline')),
        cache: MemoryRegionIndexCache([cmh]),
      );
      await svc.loadCached();
      final r = await svc.refresh();
      expect(r.single.code, 'CMH', reason: 'the stale cache is still served after a failed fetch');
      expect(svc.lastError, isNotNull);
    });

    test('a failed refresh with no cache at all: regions stays empty, everLoaded stays false', () async {
      final svc = RegionIndexService(fetch: () => Future.error(Exception('offline')), cache: MemoryRegionIndexCache());
      await svc.refresh();
      expect(svc.regions, isEmpty);
      expect(svc.everLoaded, isFalse);
      expect(svc.lastError, isNotNull);
    });

    test('a later successful refresh clears a previous lastError', () async {
      var fail = true;
      final svc = RegionIndexService(
        fetch: () async {
          if (fail) throw Exception('offline');
          return [cmh];
        },
        cache: MemoryRegionIndexCache(),
      );
      await svc.refresh();
      expect(svc.lastError, isNotNull);
      fail = false;
      await svc.refresh();
      expect(svc.lastError, isNull);
      expect(svc.regions.single.code, 'CMH');
    });

    test('concurrent refresh calls share one fetch', () async {
      var fetchCalls = 0;
      final gate = Completer<void>();
      final svc = RegionIndexService(
        fetch: () async {
          fetchCalls++;
          await gate.future;
          return [cmh];
        },
        cache: MemoryRegionIndexCache(),
      );
      final a = svc.refresh();
      final b = svc.refresh();
      gate.complete();
      await Future.wait([a, b]);
      expect(fetchCalls, 1);
    });
  });
}
