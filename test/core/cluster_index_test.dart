import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/cluster_index.dart';

ClusterIndex idx(List<(double, double)> pts, {List<int>? bands, int maxZoom = 14}) => ClusterIndex.buildSync(
  Float64List.fromList([for (final p in pts) p.$1]),
  Float64List.fromList([for (final p in pts) p.$2]),
  band: bands == null ? null : Uint8List.fromList(bands),
  maxZoom: maxZoom,
);

/// Deterministic pseudo-random points: [n] in a box (default: the continental US plus some worldwide).
(Float64List, Float64List, Uint8List) synthetic(int n, {int seed = 7}) {
  final r = math.Random(seed);
  final lat = Float64List(n), lon = Float64List(n);
  final band = Uint8List(n);
  for (var i = 0; i < n; i++) {
    if (i % 5 == 0) {
      lat[i] = -60 + r.nextDouble() * 130;
      lon[i] = -180 + r.nextDouble() * 360;
    } else {
      lat[i] = 25 + r.nextDouble() * 24;
      lon[i] = -125 + r.nextDouble() * 58;
    }
    band[i] = r.nextInt(4);
  }
  return (lat, lon, band);
}

/// The whole world at [zoom].
ClusterSlice world(ClusterIndex i, double zoom) => i.query(0, 0, 1 - 1e-12, 1 - 1e-12, zoom);

void main() {
  group('projection', () {
    test('matches EPSG:3857 at known points and round-trips', () {
      expect(mercatorX(-180), 0);
      expect(mercatorX(180), 0, reason: '180 is the same meridian as -180');
      expect(mercatorX(0), closeTo(0.5, 1e-12));
      expect(mercatorY(0), closeTo(0.5, 1e-12));
      expect(mercatorY(90), closeTo(0, 1e-9), reason: 'clamped to the Mercator limit');
      expect(mercatorY(-90), closeTo(1, 1e-9));
      for (final lat in [-85.0, -45.5, 0.0, 39.96, 85.0]) {
        expect(latFromMercatorY(mercatorY(lat)), closeTo(lat, 1e-9));
      }
      for (final lon in [-179.5, -82.99, 0.0, 179.5]) {
        expect(lonFromMercatorX(mercatorX(lon)), closeTo(lon, 1e-9));
      }
      expect(mercatorX(190), closeTo(mercatorX(-170), 1e-12), reason: 'wraps');
      expect(worldPixels(0), 256);
      expect(worldPixels(3), 2048);
    });

    test('labels and radii', () {
      expect(clusterLabel(7), '7');
      expect(clusterLabel(999), '999');
      expect(clusterLabel(1000), '1k');
      expect(clusterLabel(1250), '1.2k');
      expect(clusterLabel(12345), '12k');
      expect(clusterLabel(1300000), '1.3M');
      expect(clusterRadiusPx(1), 5);
      expect(clusterRadiusPx(2), 13);
      expect(clusterRadiusPx(1000000), 30, reason: 'capped');
      expect(clusterRadiusPx(100), greaterThan(clusterRadiusPx(10)));
    });
  });

  group('build', () {
    test('empty input', () {
      final i = idx(const []);
      expect(i.indexedCount, 0);
      expect(world(i, 3).length, 0);
      expect(i.hitTest(0.5, 0.5, 3), isNull);
    });

    test('one point is a single at every zoom', () {
      final i = idx(const [(39.96, -82.99)]);
      for (var z = 0; z <= 16; z++) {
        final s = world(i, z.toDouble());
        expect(s.length, 1, reason: 'zoom $z');
        expect(s.count[0], 1);
        expect(s.point[0], 0);
        expect(s.x[0], closeTo(mercatorX(-82.99), 1e-12));
      }
    });

    test('two co-located points: one cluster of 2 until the singles zoom, then two singles flagged co-located', () {
      final i = idx(const [(39.96, -82.99), (39.96, -82.99)]);
      final low = world(i, 10);
      expect(low.length, 1);
      expect(low.count[0], 2);
      expect(low.point[0], -1);
      final tap = i.hitTest(low.x[0], low.y[0], 10)!;
      expect(tap.isCluster, isTrue);
      expect(tap.colocated, [0, 1]);
      final high = world(i, 14);
      expect(high.length, 2);
      final t2 = i.hitTest(high.x[0], high.y[0], 15)!;
      expect(t2.isCluster, isFalse);
      expect(t2.colocated, [0, 1]);
    });

    test('non-finite points are skipped but keep their index', () {
      final i = idx(const [(double.nan, 0), (10, 10), (20, double.infinity)]);
      expect(i.pointCount, 3);
      expect(i.indexedCount, 1);
      final s = world(i, 2);
      expect(s.point.toList(), [1]);
    });

    test('rejects bad arguments', () {
      expect(() => ClusterIndex.buildSync(Float64List(2), Float64List(3)), throwsArgumentError);
      expect(() => ClusterIndex.buildSync(Float64List(1), Float64List(1), cellPx: 60), throwsArgumentError);
      expect(() => ClusterIndex.buildSync(Float64List(1), Float64List(1), maxZoom: 30), throwsArgumentError);
    });
  });

  group('invariants on 20k synthetic points', () {
    final (lat, lon, band) = synthetic(20000);
    late ClusterIndex i;
    setUpAll(() {
      final sw = Stopwatch()..start();
      i = ClusterIndex.buildSync(lat, lon, band: band);
      sw.stop();
      // ignore: avoid_print
      print('cluster_index: buildSync 20k points, 15 levels: ${sw.elapsedMilliseconds} ms (host JIT, not a device)');
    });

    test('every level: counts sum to N and every point is in exactly one cluster', () {
      for (var z = 0; z <= i.maxZoom; z++) {
        final l = i.levels[z];
        var sum = 0;
        final seen = Uint8List(20000);
        for (var c = 0; c < l.length; c++) {
          sum += l.count[c];
          final m = i.members(z, c);
          expect(m.length, l.count[c]);
          for (final p in m) {
            seen[p]++;
          }
        }
        expect(sum, 20000, reason: 'level $z');
        expect(seen.every((v) => v == 1), isTrue, reason: 'level $z');
      }
    });

    test('levels nest: each cluster of level z+1 lies inside one cluster of level z', () {
      for (var z = 0; z < i.maxZoom; z++) {
        final coarse = i.levels[z], fine = i.levels[z + 1];
        for (var c = 0; c < fine.length; c++) {
          expect(coarse.find(fine.cell[c] >> 2), greaterThanOrEqualTo(0));
        }
        expect(coarse.length, lessThanOrEqualTo(fine.length));
      }
    });

    test('cell codes are sorted, centroid is the members mean, bounds hold every member', () {
      final z = 6;
      final l = i.levels[z];
      for (var c = 1; c < l.length; c++) {
        expect(l.cell[c], greaterThan(l.cell[c - 1]));
      }
      for (var c = 0; c < l.length; c += 37) {
        final m = i.members(z, c);
        var sx = 0.0, sy = 0.0;
        for (final p in m) {
          sx += i.px[p];
          sy += i.py[p];
          expect(i.px[p], inInclusiveRange(l.bounds[c * 4], l.bounds[c * 4 + 2]));
          expect(i.py[p], inInclusiveRange(l.bounds[c * 4 + 1], l.bounds[c * 4 + 3]));
        }
        expect(l.x[c], closeTo(sx / m.length, 1e-12));
        expect(l.y[c], closeTo(sy / m.length, 1e-12));
      }
    });

    test('dominant band is the most common member band (lowest wins a tie)', () {
      final l = i.levels[3];
      for (var c = 0; c < l.length; c++) {
        final h = List.filled(16, 0);
        for (final p in i.members(3, c)) {
          h[band[p]]++;
        }
        var best = 0;
        for (var b = 1; b < 16; b++) {
          if (h[b] > h[best]) best = b;
        }
        expect(l.band[c], best);
      }
    });

    test('a viewport query returns only items inside it, and the same items as a full scan', () {
      // A box over Ohio at zoom 9 (about a phone screen).
      final x0 = mercatorX(-84.5), x1 = mercatorX(-82.0), y0 = mercatorY(41.0), y1 = mercatorY(39.0);
      final s = i.query(x0, y0, x1, y1, 9);
      expect(s.length, greaterThan(0));
      for (var k = 0; k < s.length; k++) {
        expect(s.x[k], inInclusiveRange(x0, x1));
        expect(s.y[k], inInclusiveRange(y0, y1));
      }
      // Full scan of level 9 clusters whose drawn position is in the box (singles: the point itself).
      final l = i.levels[9];
      var expected = 0;
      for (var c = 0; c < l.length; c++) {
        if (l.count[c] == 1) {
          final p = i.members(9, c)[0];
          if (i.px[p] >= x0 && i.px[p] <= x1 && i.py[p] >= y0 && i.py[p] <= y1) expected++;
        } else if (l.x[c] >= x0 && l.x[c] <= x1 && l.y[c] >= y0 && l.y[c] <= y1) {
          expected++;
        }
      }
      expect(s.length, expected);
      // The viewport is a tiny part of the world: far fewer items than points.
      expect(s.length, lessThan(2000));
    });

    test('zoom >= maxZoom returns individual points only', () {
      final x0 = mercatorX(-100), x1 = mercatorX(-99.5), y0 = mercatorY(40.5), y1 = mercatorY(40);
      final s = i.query(x0, y0, x1, y1, 14.5);
      expect(s.level, 14);
      expect(s.count.every((c) => c == 1), isTrue);
      expect(s.point.every((p) => p >= 0), isTrue);
    });

    test('zoomed out: the world has few clusters and they cover all 20k points', () {
      final s = world(i, 0);
      var total = 0;
      for (var k = 0; k < s.length; k++) {
        total += s.count[k];
      }
      expect(total, 20000);
      expect(s.length, lessThanOrEqualTo(16), reason: 'zoom 0 = 4 x 4 cells of 64 px');
    });

    test('query time for a phone viewport at several zooms', () {
      final sw = Stopwatch()..start();
      var items = 0;
      for (var z = 0; z <= 16; z++) {
        final scale = worldPixels(z.toDouble());
        final cx = mercatorX(-83), cy = mercatorY(40);
        final s = i.query(cx - 200 / scale, cy - 430 / scale, cx + 200 / scale, cy + 430 / scale, z.toDouble());
        items += s.length;
      }
      sw.stop();
      // ignore: avoid_print
      print('cluster_index: 17 viewport queries (400x860 px, z0..16) on 20k points: ${sw.elapsedMicroseconds} us, $items items');
      expect(items, greaterThan(0));
    });

    test('Isolate.run build gives the same index as buildSync (and its time is logged)', () async {
      final sw = Stopwatch()..start();
      final a = await ClusterIndex.build(lat, lon, band: band);
      sw.stop();
      // ignore: avoid_print
      print('cluster_index: build via Isolate.run 20k points: ${sw.elapsedMilliseconds} ms (incl. isolate start and copies)');
      expect(a.indexedCount, i.indexedCount);
      for (var z = 0; z <= i.maxZoom; z++) {
        expect(a.levels[z].cell, i.levels[z].cell);
        expect(a.levels[z].count, i.levels[z].count);
        expect(a.levels[z].x, i.levels[z].x);
      }
    });
  });

  group('determinism and stable ids', () {
    test('the same input builds an identical index', () {
      final (lat, lon, band) = synthetic(3000, seed: 3);
      final a = ClusterIndex.buildSync(lat, lon, band: band);
      final b = ClusterIndex.buildSync(lat, lon, band: band);
      for (var z = 0; z <= a.maxZoom; z++) {
        expect(a.levels[z].cell, b.levels[z].cell);
        expect(a.levels[z].x, b.levels[z].x);
        expect(a.levels[z].y, b.levels[z].y);
        expect(a.levels[z].band, b.levels[z].band);
        expect(a.levels[z].start, b.levels[z].start);
      }
      expect(a.order, b.order);
    });

    test('cluster ids depend on the cell, not on input order or other data', () {
      final pts = [(39.96, -82.99), (39.97, -82.98), (40.0, -83.0)];
      final a = idx(pts);
      final b = idx([...pts.reversed, (-33.9, 151.2)]); // reordered, plus a far-away point
      final ta = a.hitTest(mercatorX(-82.99), mercatorY(39.96), 6)!;
      final tb = b.hitTest(mercatorX(-82.99), mercatorY(39.96), 6)!;
      expect(ta.isCluster, isTrue);
      expect(ta.id, tb.id);
      expect(ta.count, 3);
      expect(tb.count, 3);
    });
  });

  group('hit test', () {
    test('nearest single within the radius; nothing beyond it', () {
      final i = idx(const [(40, -83), (40, -82.9)]);
      const z = 15.0;
      final scale = worldPixels(z);
      final x = mercatorX(-83), y = mercatorY(40);
      expect(i.hitTest(x + 10 / scale, y, z)!.point, 0);
      expect(i.hitTest(x + 21 / scale, y, z)!.point, 0);
      expect(i.hitTest(x + 23 / scale, y, z), isNull);
      expect(i.hitTest(x, y, z, radiusPx: 5)!.point, 0);
      final far = i.hitTest(mercatorX(-82.9), y, z)!;
      expect(far.point, 1);
      expect(far.lat, closeTo(40, 1e-9));
      expect(far.lon, closeTo(-82.9, 1e-9));
    });

    test('a cluster is hit anywhere within its bubble and reports member bounds', () {
      final pts = [for (var k = 0; k < 50; k++) (40 + k * 0.001, -83 + k * 0.001)];
      final i = idx(pts);
      final s = world(i, 4);
      expect(s.length, 1);
      final t = i.hitTest(s.x[0], s.y[0], 4)!;
      expect(t.isCluster, isTrue);
      expect(t.count, 50);
      expect(t.bounds.south, closeTo(40, 1e-9));
      expect(t.bounds.north, closeTo(40.049, 1e-9));
      expect(t.bounds.west, closeTo(-83, 1e-9));
      expect(t.bounds.east, closeTo(-82.951, 1e-9));
      expect(t.colocated, isEmpty);
      final r = clusterRadiusPx(50);
      expect(i.hitTest(s.x[0] + (r - 1) / worldPixels(4), s.y[0], 4, radiusPx: 4), isNotNull);
    });

    test('garbage taps are null', () {
      final i = idx(const [(40, -83)]);
      expect(i.hitTest(double.nan, 0.5, 10), isNull);
      expect(i.hitTest(0.5, double.infinity, 10), isNull);
    });
  });

  group('antimeridian and poles', () {
    test('points on both sides of the antimeridian never share a cluster', () {
      final i = idx(const [(0, 179.99), (0, -179.99), (0, 180)]);
      final s = world(i, 0);
      // -179.99 and 180 (= -180) are in the first column, 179.99 in the last.
      expect(s.length, 2);
      final xs = s.x.toList()..sort();
      expect(xs.first, lessThan(0.01));
      expect(xs.last, greaterThan(0.99));
    });

    test('a viewport across the antimeridian returns both sides, the west side shifted by one world', () {
      final i = idx(const [(-17.7, 178.0), (-17.7, -178.0)]); // Fiji either side of 180
      final z = 8.0;
      final x0 = mercatorX(176.0), x1 = 1.0 + mercatorX(-176.0); // 176E .. 176W, continuous
      final s = i.query(x0, mercatorY(-15), x1, mercatorY(-20), z);
      expect(s.length, 2);
      final xs = s.x.toList()..sort();
      expect(xs[0], closeTo(mercatorX(178.0), 1e-12));
      expect(xs[1], closeTo(1.0 + mercatorX(-178.0), 1e-12));
      // A tap on the shifted copy hits the west point.
      final t = i.hitTest(1.0 + mercatorX(-178.0), mercatorY(-17.7), z)!;
      expect(t.point, 1);
      expect(t.lon, closeTo(-178.0, 1e-9));
    });

    test('a zoomed-out camera wider than the world returns each copy (at most 3)', () {
      final i = idx(const [(10, 10)]);
      final s = i.query(-1.0, 0, 2.0, 1, 0);
      expect(s.length, 3);
      final xs = s.x.toList()..sort();
      expect(xs[1] - xs[0], closeTo(1, 1e-12));
    });

    test('poles are clamped, not lost', () {
      final i = idx(const [(90, 0), (-90, 0), (89.9, 45)]);
      expect(i.indexedCount, 3);
      final s = world(i, 2);
      var total = 0;
      for (var k = 0; k < s.length; k++) {
        total += s.count[k];
        expect(s.y[k], inInclusiveRange(0, 1));
      }
      expect(total, 3);
    });
  });
}
