// Region index benchmark against a real `regions-index` body.
//   curl -s --compressed https://meshsonar.com/api/cmh/regions-index -o /tmp/ri.json
//   dart run tool/bench_regions.dart /tmp/ri.json          (JIT, ~3-5x faster than a phone)
//   dart compile exe tool/bench_regions.dart -o /tmp/bench && /tmp/bench /tmp/ri.json   (AOT)
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_pick.dart';
import 'package:meshsonar/core/region_tracker.dart';

T time<T>(String what, T Function() f, {int reps = 1}) {
  final sw = Stopwatch()..start();
  late T r;
  for (var i = 0; i < reps; i++) {
    r = f();
  }
  sw.stop();
  final us = sw.elapsedMicroseconds / reps;
  stdout.writeln('${what.padRight(46)} ${us >= 1000 ? '${(us / 1000).toStringAsFixed(2)} ms' : '${us.toStringAsFixed(1)} us'}${reps > 1 ? '  (avg of $reps)' : ''}');
  return r;
}

void main(List<String> args) {
  final raw = File(args.isEmpty ? '/tmp/ri.json' : args.first).readAsStringSync();
  stdout.writeln('body ${(raw.length / 1e6).toStringAsFixed(2)} MB');
  final decoded = time('jsonDecode', () => jsonDecode(raw) as Map);
  final index = time('tryParse x all', () => [for (final r in decoded['regions'] as List) RegionIndexEntry.tryParse(r)!]);
  stdout.writeln('regions ${index.length}, vertices ${index.fold<int>(0, (a, r) => a + _verts(r))}');
  time('jsonEncode (cache save)', () => jsonEncode(index.map((r) => r.toJson()).toList()));

  final rnd = math.Random(7);
  // Points: the centre of every region (inside or near), plus random world points.
  final pts = <(double, double)>[
    for (final r in index) (regionCenter(r)!.lat, regionCenter(r)!.lon),
    for (var i = 0; i < 441; i++) (rnd.nextDouble() * 140 - 60, rnd.nextDouble() * 340 - 170),
  ];
  var k = 0;
  time('regionContaining, cold (first pass, builds typed arrays)', () => [for (final p in pts) regionContaining(index, p.$1, p.$2)]);
  time('regionContaining (1 fix)', () => regionContaining(index, pts[k++ % pts.length].$1, pts[k % pts.length].$2), reps: 2000);
  time('regionContaining, all ${pts.length} pts', () => [for (final p in pts) regionContaining(index, p.$1, p.$2)]);
  final cmh = index.firstWhere((r) => r.code == 'CMH');
  final c = regionCenter(cmh)!;
  time('regionContaining Columbus', () => regionContaining(index, c.lat, c.lon), reps: 2000);
  time('nearestRegion (1 fix)', () => nearestRegion(index, 10, 10), reps: 2000);
  time('regionsForSwitcher (sort 559)', () => regionsForSwitcher(index, gpsRegion: cmh, lat: c.lat, lon: c.lon), reps: 200);
  final tr = RegionTracker();
  var t = DateTime.utc(2026, 10, 28);
  time('RegionTracker.update (steady)', () => tr.update(index, c.lat, c.lon, t = t.add(const Duration(seconds: 1))), reps: 2000);
}

int _verts(RegionIndexEntry r) {
  var n = 0;
  final c = r.boundary?['coordinates'];
  void walk(Object? o) {
    if (o is List && o.isNotEmpty && o.first is num) {
      n++;
    } else if (o is List) {
      o.forEach(walk);
    }
  }
  walk(c);
  return n;
}
