// The parts of the region work that only exist since 0.20.1 (search, fingerprint, off-main parse, picker rows).
//   dart run tool/bench_regions_new.dart /tmp/ri.json
import 'dart:convert';
import 'dart:io';

import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_search.dart';

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

Future<void> main(List<String> args) async {
  final raw = File(args.isEmpty ? '/tmp/ri.json' : args.first).readAsStringSync();
  final index = time('parseRegionsIndexBody (inline)', () => parseRegionsIndexBody(raw));
  final sw = Stopwatch()..start();
  await parseRegionsIndexBodyOffMain(raw);
  sw.stop();
  stdout.writeln('${'parse off main isolate (wall)'.padRight(46)} ${(sw.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms  (main isolate is free meanwhile)');
  time('regionsFingerprint (skip rewrite if equal)', () => regionsFingerprint(index), reps: 20);
  time('RegionSearchIndex build', () => RegionSearchIndex.of([...index]));
  final s = RegionSearchIndex.of(index);
  for (final q in ['du', 'dusseldorf', 'germany', 'columbus', 'zz', 'a']) {
    time('search "$q"', () => s.search(q), reps: 200);
  }
  time('groupByCountry (559)', () => groupByCountry(index), reps: 200);
  stdout.writeln(jsonEncode({'regions': index.length}));
}
