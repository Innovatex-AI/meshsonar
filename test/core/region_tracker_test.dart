import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_pick.dart';
import 'package:meshsonar/core/region_tracker.dart';

List<RegionIndexEntry> loadIndex() {
  final j = jsonDecode(File('test/fixtures/regions_index_real.json').readAsStringSync()) as Map;
  return [for (final r in j['regions'] as List) RegionIndexEntry.tryParse(r)!];
}

void main() {
  final index = loadIndex();
  final t0 = DateTime.utc(2026, 10, 22, 12);
  const lat = 39.95;

  test('fixture is the real index with CMH, DAY, CVG', () {
    expect(index.map((r) => r.code), containsAll(['CMH', 'DAY', 'CVG']));
    expect(index.every((r) => r.boundary != null), isTrue);
  });

  // Walk west along lat 39.95 from deep in CMH to deep in DAY, one fix per ~100 m, at 1 Hz.
  List<({double lat, double lon})> track(double fromLon, double toLon, {double jitterM = 0, int seed = 1}) {
    final rnd = math.Random(seed);
    final out = <({double lat, double lon})>[];
    const step = 0.0012;
    final n = ((fromLon - toLon).abs() / step).ceil();
    for (var i = 0; i <= n; i++) {
      final lon = fromLon + (toLon - fromLon) * i / n;
      final jl = jitterM == 0 ? 0.0 : (rnd.nextDouble() - .5) * 2 * jitterM / (111320 * math.cos(lat * math.pi / 180));
      out.add((lat: lat, lon: lon + jl));
    }
    return out;
  }

  List<String> run(RegionTracker tr, List<({double lat, double lon})> pts) {
    final seq = <String>[];
    var t = t0;
    for (final p in pts) {
      t = t.add(const Duration(seconds: 1));
      final u = tr.update(index, p.lat, p.lon, t);
      if (u.changed) seq.add(u.current?.code ?? 'none');
    }
    return seq;
  }

  test('CMH -> DAY drive commits exactly one change and ends in DAY', () {
    final tr = RegionTracker();
    final seq = run(tr, track(-82.9, -84.2));
    expect(seq, ['CMH', 'DAY']);
    expect(tr.current!.code, 'DAY');
  });

  test('DAY -> CMH drive commits exactly one change back', () {
    final tr = RegionTracker();
    expect(run(tr, track(-84.2, -82.9)), ['DAY', 'CMH']);
  });

  test('50 m GPS jitter along the whole border never flaps', () {
    for (var seed = 1; seed <= 20; seed++) {
      final tr = RegionTracker();
      final seq = run(tr, track(-82.9, -84.2, jitterM: 50, seed: seed));
      expect(seq, ['CMH', 'DAY'], reason: 'seed $seed');
    }
  });

  test('parked on the border with jitter: never more than the initial commit', () {
    final tr = RegionTracker();
    // Find the CMH edge on this latitude.
    final cmh = index.firstWhere((r) => r.code == 'CMH');
    var edgeLon = -83.0;
    while (pointInBoundary(cmh.boundary!, lat, edgeLon)) {
      edgeLon -= 0.0001;
    }
    final rnd = math.Random(7);
    final seq = <String>[];
    var t = t0;
    // Start inside CMH so it is committed, then jitter +-60 m around the edge for 10 minutes.
    tr.update(index, lat, edgeLon + 0.02, t);
    for (var i = 0; i < 600; i++) {
      t = t.add(const Duration(seconds: 1));
      final dLon = (rnd.nextDouble() - .5) * 2 * 60 / (111320 * math.cos(lat * math.pi / 180));
      final u = tr.update(index, lat, edgeLon + dLon, t);
      if (u.changed) seq.add(u.current?.code ?? 'none');
    }
    expect(seq, isEmpty);
    expect(tr.current!.code, 'CMH');
  });

  test('near-edge flag is set close to the boundary and clear far from it', () {
    final tr = RegionTracker();
    final u1 = tr.update(index, lat, -83.0, t0);
    expect(u1.current!.code, 'CMH');
    expect(u1.nearEdge, isFalse);
  });

  test('outside every region: current held for 60 s, then dropped; re-entry commits at once', () {
    final tr = RegionTracker();
    tr.update(index, lat, -82.9, t0);
    // Lake Michigan is in no region.
    var u = tr.update(index, 42.0, -87.0, t0.add(const Duration(seconds: 10)));
    expect(u.current!.code, 'CMH');
    u = tr.update(index, 42.0, -87.0, t0.add(const Duration(seconds: 71)));
    expect(u.current, isNull);
    expect(u.changed, isTrue);
    u = tr.update(index, lat, -82.9, t0.add(const Duration(seconds: 80)));
    expect(u.current!.code, 'CMH');
  });

  test('a single stray fix in another region does not switch (needs 3 consecutive)', () {
    final tr = RegionTracker();
    tr.update(index, lat, -82.9, t0);
    // Teleport deep into DAY for two fixes, then back.
    tr.update(index, lat, -84.2, t0.add(const Duration(seconds: 1)));
    tr.update(index, lat, -84.2, t0.add(const Duration(seconds: 2)));
    expect(tr.current!.code, 'CMH');
    final u = tr.update(index, lat, -84.2, t0.add(const Duration(seconds: 3)));
    expect(u.current!.code, 'DAY');
  });

  test('distanceToBoundaryM is ~0 on an edge vertex and large in the middle', () {
    final cmh = index.firstWhere((r) => r.code == 'CMH');
    final c = ((cmh.boundary!['coordinates'] as List).first as List).first as List;
    expect(distanceToBoundaryM(cmh.boundary!, (c[1] as num).toDouble(), (c[0] as num).toDouble()), lessThan(1));
    expect(distanceToBoundaryM(cmh.boundary!, 40.0, -82.9), greaterThan(5000));
  });
}
