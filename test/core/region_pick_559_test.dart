// Region detection and ordering over 559 regions: border slivers, nested zones, seams between thinned outlines,
// the switcher order and the cost of all of it.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_pick.dart';
import 'package:meshsonar/core/region_tracker.dart';

import '../support/regions_559.dart';

void main() {
  // Two neighbours that overlap by a 0.02 degree sliver (the lon 1.99..2.01 strip), and a small zone nested in the big one.
  final west = square('WST', 0, 0, 2.01, 2);
  final east = square('EST', 1.99, 0, 4, 2);
  final nested = square('NST', 0.5, 0.5, 1, 1);

  test('a fix in the sliver is held by BOTH, smallest real area first (ties by code), and regionContaining names the first', () {
    final idx = [east, west, nested];
    final hits = regionsContaining(idx, 1.0, 2.0);
    expect(hits.map((r) => r.code), ['EST', 'WST']);
    expect(regionContaining(idx, 1.0, 2.0)!.code, 'EST');
    expect(regionsContaining(idx, 1.0, 0.1).map((r) => r.code), ['WST'], reason: 'outside the sliver only one holds it');
  });

  test('a nested zone beats the zone around it, outside the nested zone the big one answers', () {
    final idx = [west, nested];
    expect(regionContaining(idx, 0.7, 0.7)!.code, 'NST');
    expect(regionsContaining(idx, 0.7, 0.7).map((r) => r.code), ['NST', 'WST']);
    expect(regionContaining(idx, 1.5, 1.5)!.code, 'WST');
  });

  test('a seam between two thinned outlines: no real hit, but within 300 m the nearest edge answers', () {
    final a = square('AAA', 0, 0, 1, 1);
    final b = square('BBB', 1.002, 0, 2, 1); // a 222 m gap
    final idx = [a, b];
    expect(regionContaining(idx, 0.5, 1.001), isNull, reason: 'the exact rule says neither');
    expect(regionContaining(idx, 0.5, 1.0008, seamM: 300)!.code, 'AAA');
    expect(regionContaining(idx, 0.5, 1.0012, seamM: 300)!.code, 'BBB');
    expect(regionContaining(idx, 0.5, 1.5, seamM: 300)!.code, 'BBB', reason: 'inside BBB for real');
    expect(regionContaining(idx, 0.5, 3.0, seamM: 300), isNull, reason: 'far from every outline is outside');
    expect(regionContaining(idx, 0.5, 1.001, seamM: 50), isNull, reason: 'the seam rule has a limit');
  });

  test('nearestRegion: a fix inside the BOX of a region but outside its outline goes to the nearer edge, not the box', () {
    final l = lShape('LLL');
    final near = square('NEA', 0.95, 0, 2.5, 2); // its box ends 0.05 degrees from the fix
    expect(nearestRegion([l, near], 0.9, 0.9)!.code, 'NEA');
    expect(nearestRegion([near, l], 0.9, 0.9)!.code, 'NEA', reason: 'list order does not matter');
    final far = square('FAR', 1.5, 0, 2.5, 2); // 0.6 degrees away: the L notch edge (0.3) is nearer
    expect(nearestRegion([far, l], 0.9, 0.9)!.code, 'LLL');
    // Inside an outline is distance 0.
    expect(nearestRegion([far, l], 1.8, 1.0)!.code, 'LLL');
  });

  test('regionsForSwitcher: the GPS region first, then nearest, ties inside one big box ranked by centre distance', () {
    final big = square('BIG', -10, -10, 10, 10);
    final nearSmall = square('NEA', 0.9, 0.9, 1.1, 1.1);
    final farSmall = square('FAR', 7, 7, 8, 8);
    final out = regionsForSwitcher([farSmall, big, nearSmall], gpsRegion: big, lat: 1.0, lon: 1.0);
    expect(out.map((r) => r.code), ['BIG', 'NEA', 'FAR']);
    final noFix = regionsForSwitcher([farSmall, big, nearSmall]);
    expect(noFix.map((r) => r.name), [...noFix.map((r) => r.name)]..sort());
  });

  test('559 regions: detection of every region centre finds its own region, outside the grid finds none', () {
    final idx = syntheticIndex559();
    for (final r in idx) {
      final c = regionCenter(r)!;
      expect(regionContaining(idx, c.lat, c.lon)?.code, r.code, reason: r.name);
    }
    expect(regionContaining(idx, 80, 0), isNull);
    expect(regionContaining(idx, 0, 179.9), isNull);
  });

  test('559 regions: 5,000 fixes are cheap (bbox then typed-array ray cast)', () {
    final idx = syntheticIndex559();
    final rnd = math.Random(1);
    final pts = [for (var i = 0; i < 5000; i++) (rnd.nextDouble() * 90 - 48, rnd.nextDouble() * 340 - 168)];
    regionContaining(idx, pts.first.$1, pts.first.$2); // warm: builds the typed arrays
    final sw = Stopwatch()..start();
    var found = 0;
    for (final p in pts) {
      if (regionContaining(idx, p.$1, p.$2, seamM: 300) != null) found++;
    }
    sw.stop();
    // Debug-mode VM on a laptop: ~10-50 us a fix. A generous ceiling that still catches a per-fix rescan of every outline.
    expect(sw.elapsedMilliseconds, lessThan(1500), reason: '${sw.elapsedMilliseconds} ms for 5000 fixes ($found found)');
  });

  test('559 regions: the switcher order is built in well under a frame budget and is stable', () {
    final idx = syntheticIndex559();
    final sw = Stopwatch()..start();
    final a = regionsForSwitcher(idx, gpsRegion: idx[10], lat: 5.0, lon: -100.0);
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(250));
    expect(a.length, 559);
    expect(a.first.code, idx[10].code);
    final b = regionsForSwitcher(idx.reversed.toList(), gpsRegion: idx[10], lat: 5.0, lon: -100.0);
    expect(b.map((r) => r.code), a.map((r) => r.code), reason: 'same input set, same order');
  });

  test('tracker: a ping near a seam does not flap and does not drop the region; "also in" is reported in a sliver', () {
    final a = square('AAA', 0, 0, 1.0, 1);
    final b = square('BBB', 1.002, 0, 2, 1);
    final idx = [a, b];
    final tr = RegionTracker();
    var t = DateTime.utc(2026, 10, 28, 12);
    RegionTrackUpdate step(double lon) => tr.update(idx, 0.5, lon, t = t.add(const Duration(seconds: 1)));
    expect(step(0.9).current!.code, 'AAA');
    // On the seam (no real hit): the committed region stays, no change.
    final seam = step(1.001);
    expect(seam.current!.code, 'AAA');
    expect(seam.changed, isFalse);
    // Well inside B, three fixes confirm the crossing.
    step(1.2);
    step(1.2);
    expect(step(1.2).current!.code, 'BBB');

    final west2 = square('WST', 0, 0, 2.01, 2), east2 = square('EST', 1.99, 0, 4, 2);
    final tr2 = RegionTracker();
    final u = tr2.update([west2, east2], 1.0, 2.0, DateTime.utc(2026, 10, 28));
    expect(u.alsoIn.length, 1);
    expect({u.current!.code, u.alsoIn.single.code}, {'WST', 'EST'});
  });

  test('tracker: the first fix on a seam commits to the nearest outline instead of "outside coverage"', () {
    final a = square('AAA', 0, 0, 1, 1);
    final b = square('BBB', 1.002, 0, 2, 1);
    final u = RegionTracker().update([a, b], 0.5, 1.0015, DateTime.utc(2026, 10, 28));
    expect(u.current!.code, 'BBB');
    final exact = RegionTracker(seamM: 0).update([a, b], 0.5, 1.0015, DateTime.utc(2026, 10, 28));
    expect(exact.current, isNull);
  });
}

/// A C-shaped zone: the box [0,0,2,2] minus the notch [0,0,1.2,1.2] (lower left), so (0.9, 0.9) is in its box and not in it.
RegionIndexEntry lShape(String code) => RegionIndexEntry(
      code: code,
      slug: code.toLowerCase(),
      name: '$code, US',
      url: 'https://${code.toLowerCase()}.meshsonar.com',
      bbox: const [0, 0, 2, 2],
      boundary: {
        'type': 'Polygon',
        'coordinates': [
          [[1.2, 0], [2, 0], [2, 2], [0, 2], [0, 1.2], [1.2, 1.2], [1.2, 0]],
        ],
      },
    );
