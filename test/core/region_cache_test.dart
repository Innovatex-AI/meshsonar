import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/region_cache.dart';

void main() {
  late Directory dir;
  var now = DateTime.utc(2026, 10, 22, 12);
  setUp(() => dir = Directory.systemTemp.createTempSync('rc'));
  tearDown(() => dir.deleteSync(recursive: true));
  RegionCache cache({int max = 40}) => RegionCache(dir, maxEntries: max, clock: () => now);

  test('200 stores body+etag; next fetch sends the etag and a 304 keeps the body', () async {
    final c = cache();
    final a = await c.fetch('cmh/cov', (etag) async => const CacheFetch.fresh('{"a":1}', etag: '"v1"'));
    expect(a!.body, '{"a":1}');
    String? sent;
    now = now.add(const Duration(hours: 1));
    final b = await c.fetch('cmh/cov', (etag) async {
      sent = etag;
      return const CacheFetch.notModified();
    });
    expect(sent, '"v1"');
    expect(b!.body, '{"a":1}');
    expect(b.offline, isFalse);
    expect(b.fetchedAt, now);
  });

  test('network failure serves the stored copy flagged offline with its original time', () async {
    final c = cache();
    final t = now;
    await c.fetch('k', (_) async => const CacheFetch.fresh('x'));
    now = now.add(const Duration(hours: 5));
    final r = await c.fetch('k', (_) async => throw const SocketException('down'));
    expect(r!.offline, isTrue);
    expect(r.body, 'x');
    expect(r.fetchedAt, t);
    expect(asOfLabel(r.fetchedAt, now, offline: true), 'Offline - as of 5h ago');
  });

  test('failure with nothing cached returns null', () async {
    expect(await cache().fetch('none', (_) async => throw Exception('x')), isNull);
  });

  test('LRU: oldest entries are evicted past the cap, a touched one survives', () async {
    final c = cache(max: 2);
    await c.put('a', '1');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await c.put('b', '2');
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await c.fetch('a', (_) async => const CacheFetch.notModified()); // touches a
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await c.put('c', '3');
    expect(await c.read('b'), isNull);
    expect(await c.read('a'), isNotNull);
    expect(await c.read('c'), isNotNull);
  });

  test('labels', () {
    final t = DateTime.utc(2026, 10, 22, 12);
    expect(asOfLabel(t, t, offline: false), 'Updated just now');
    expect(asOfLabel(t, t.add(const Duration(minutes: 5)), offline: false), 'Updated 5m ago');
    expect(asOfLabel(t, t.add(const Duration(days: 3)), offline: true), 'Offline - as of 3d ago');
  });

  test('codecs round-trip', () {
    const sc = SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), radioPreset: RadioPreset(name: 'USA', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5));
    final back = siteConfigFromJson(siteConfigToJson(sc))!;
    expect(back.radioPreset!.freqMhz, 910.525);
    expect(back.region.slug, 'cmh');
    final pc = PublicCoverage(
        cells: const [CoverageCell(lat: 1, lon: 2, pings: 3, heard: 1, bestSnr: 4, medianSnr: null, repeaters: 2, lastAt: 'x', h3: 'abc', noiseFloor: -100)],
        asOf: 'now',
        grid: const CoverageGrid.h3(res: 9, cellDeg: 0.005));
    final pb = publicCoverageFromJson(publicCoverageToJson(pc))!;
    expect(pb.cells.single.h3, 'abc');
    expect(pb.grid.res, 9);
    expect(pb.cells.single.medianSnr, isNull);
  });
}
