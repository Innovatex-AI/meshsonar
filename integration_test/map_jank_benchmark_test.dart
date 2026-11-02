// Map and puck jank benchmark. Plays a recorded-style car route through the REAL Map tab (the Harness app: DriveScreen,
// DriveMapModel, CoverageMap, PuckController) with a realistic data load (thousands of network hex cells, 60 repeaters,
// a 300-ping drive, synthetic base-map tiles) and measures what the person would feel:
//
//   * frame cost per frame (max of build and raster, SchedulerBinding.addTimingsCallback): p50/p95/p99/worst, janky counts;
//   * UI-isolate event-loop lag (a 4 ms probe timer: the longest gap is the longest the isolate was busy);
//   * puck update rate (how often the dot moved on screen per second) and how smooth the movement was
//     (per-frame step of the dot against the true route: lag, biggest hop, backwards steps);
//   * the camera follow error.
//
// Run on a simulator (one temp device, deleted afterwards):
//   flutter test integration_test/map_jank_benchmark_test.dart -d <udid> \
//     --dart-define=BENCH_SECONDS=90 --dart-define=BENCH_NAME=before
// Results are printed as `BENCH_RESULT {json}` lines and written to `<app documents>/bench_<name>.json`.
//
// Thresholds are RELATIVE (the simulator renders on the host GPU, so absolutes move with the machine): a regression
// fails the run when p95 > BENCH_P95_MAX_MS, worst > BENCH_WORST_MAX_MS or the event loop stalls > BENCH_LAG_MAX_MS
// (defaults are generous; the absolute numbers are always reported).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/frame_stats.dart';
import 'package:h3_flutter/h3_flutter.dart' show GeoCoord;
import 'package:meshsonar/core/hex_cells.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';

import '../test/support/gps_route.dart';
import '../test/ui/drive_flow_test.dart' show connectViaUi;
import '../test/ui/fakes.dart';

const _seconds = int.fromEnvironment('BENCH_SECONDS', defaultValue: 90);
const _name = String.fromEnvironment('BENCH_NAME', defaultValue: 'run');
const _tiles = String.fromEnvironment('BENCH_TILES', defaultValue: 'none');
const _cellCount = int.fromEnvironment('BENCH_CELLS', defaultValue: 4000);
// Repeater count (spike S5 variant: 600 badges). Default keeps the recorded baseline comparable.
const _repeaterCount = int.fromEnvironment('BENCH_REPEATERS', defaultValue: 60);
const _p95Max = int.fromEnvironment('BENCH_P95_MAX_MS', defaultValue: 40);
const _worstMax = int.fromEnvironment('BENCH_WORST_MAX_MS', defaultValue: 250);
const _lagMax = int.fromEnvironment('BENCH_LAG_MAX_MS', defaultValue: 250);

final _base = DateTime.utc(2026, 11, 1, 12);

String _hex(math.Random r, int n) => [for (var i = 0; i < n; i++) r.nextInt(16).toRadixString(16)].join();

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('map jank benchmark', (t) async {
    // A simulator has no barometer: the stream fails with UNAVAILABLE through FlutterError. Not a failure of this run.
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      final s = d.exceptionAsString();
      if (s.contains('Barometer is not available') || s.contains('NetworkImageLoadException') || s.contains('SocketException')) return;
      prev?.call(d);
    };
    CoverageMap.tilesByDefault = _tiles != 'none';
    DriveMapModel.debugFixes = (s) => s.activeLocation.fixes; // the fake location stands in for the engine's rawFixes

    final rnd = math.Random(11);
    final route = GpsRoute.generate(seconds: _seconds + 40, seed: 7);
    // The data (cells, repeaters, the 300-ping history) spreads over a full 20-minute drive; only the first part is played live.
    final full = GpsRoute.generate(seconds: 1200, seed: 7);
    final h3 = loadHexEngine()!;

    // --- data load ---
    final h = Harness()..approveKey();
    final repeaters = <RepeaterRef>[];
    final used = <String>{};
    while (repeaters.length < _repeaterCount) {
      final key = _hex(rnd, 64);
      if (!used.add(key.substring(0, 4))) continue;
      final at = full.samples[rnd.nextInt(full.samples.length)];
      repeaters.add(RepeaterRef(
        key: key,
        name: 'Rep-${repeaters.length}',
        lat: at.trueLat + (rnd.nextDouble() - 0.5) * 0.03,
        lon: at.trueLon + (rnd.nextDouble() - 0.5) * 0.04,
      ));
    }
    h.cache.items = repeaters;

    final cells = <String, CoverageCell>{};
    var guard = 0;
    while (cells.length < _cellCount && guard++ < _cellCount * 6) {
      // Cells follow the roads loosely: around random points of the route.
      final at = full.samples[rnd.nextInt(full.samples.length)];
      final lat = at.trueLat + (rnd.nextDouble() - 0.5) * 0.05;
      final lon = at.trueLon + (rnd.nextDouble() - 0.5) * 0.07;
      final id = h3.geoToCell(GeoCoord(lat: lat, lon: lon), 10).toRadixString(16);
      final c = h3.cellToGeo(BigInt.parse(id, radix: 16));
      final pings = 1 + rnd.nextInt(12);
      final heard = rnd.nextInt(pings + 1);
      cells[id] = CoverageCell(
        lat: c.lat,
        lon: c.lon,
        pings: pings,
        heard: heard,
        bestSnr: heard == 0 ? null : -12 + rnd.nextDouble() * 24,
        medianSnr: heard == 0 ? null : -12 + rnd.nextDouble() * 20,
        repeaters: heard == 0 ? 0 : 1 + rnd.nextInt(4),
        lastAt: '2026-10-2${rnd.nextInt(9)}T12:00:00Z',
        h3: id,
      );
    }
    h.client.publicCoverageResult = PublicCoverage(
      cells: cells.values.toList(),
      asOf: '2026-11-01T00:00:00Z',
      grid: const CoverageGrid.h3(res: 10, cellDeg: 0.003),
    );

    // --- app up, drive started ---
    h.clockNow = _base;
    await h.pumpApp(t);
    await connectViaUi(t);
    await t.tap(find.byKey(const Key('start-stop')));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final engine = h.engines.single;
    DrivePing pingAt(int i, RouteSample s) {
      final near = (repeaters.toList()
            ..sort((a, b) => routeDistM(s.trueLat, s.trueLon, a.lat, a.lon).compareTo(routeDistM(s.trueLat, s.trueLon, b.lat, b.lon))))
          .take(1 + rnd.nextInt(3))
          .toList();
      final heard = rnd.nextDouble() > 0.1;
      return DrivePing(
        id: 'bench-$i',
        ts: _base.add(Duration(seconds: s.t)),
        lat: s.trueLat,
        lon: s.trueLon,
        gpsAccuracyM: 8,
        echoes: heard ? [for (final r in near) Echo(repeater: r.key.substring(0, 4), snrDb: -8 + rnd.nextDouble() * 18, hops: 1)] : const [],
      );
    }

    for (var i = 0; i < 300; i++) {
      engine.emit(pingAt(i, full.samples[(i * 4) % full.samples.length]));
      if (i % 20 == 0) await t.pump(const Duration(milliseconds: 20));
    }
    await t.pump(const Duration(seconds: 1));
    await h.state.refreshNetworkCoverage();
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    final mapFinder = find.byKey(const Key('drive-map'));
    expect(mapFinder, findsOneWidget);
    final puck = t.widget<CoverageMap>(mapFinder).puck!;
    final cmCells = h.state.networkCoverage?.cells.length ?? 0;

    // --- instruments ---
    final frames = FrameStatsWindow();
    var recording = false;
    var alive = true;
    void onTimings(List<ui.FrameTiming> ts) {
      if (!recording) return;
      for (final f in ts) {
        frames.add(FrameSample(
          f.buildDuration.inMicroseconds / 1000,
          f.rasterDuration.inMicroseconds / 1000,
          f.totalSpan.inMicroseconds / 1000,
        ));
      }
    }

    SchedulerBinding.instance.addTimingsCallback(onTimings);
    final sw = Stopwatch()..start();
    var lastProbe = 0;
    var lastPingAt = 0, lastFixAt = 0;
    final routeWall = Stopwatch()..start();
    var worstLag = 0;
    final lags = <int>[];
    final probe = Timer.periodic(const Duration(milliseconds: 4), (_) {
      final now = sw.elapsedMilliseconds;
      if (recording) {
        final gap = now - lastProbe - 4;
        if (gap > 0) lags.add(gap);
        if (gap > 50) {
          // ignore: avoid_print
          print('LAG ${gap}ms at ${routeWall.elapsedMilliseconds} ms; last ping ${routeWall.elapsedMilliseconds - lastPingAt} ms ago, last fix ${routeWall.elapsedMilliseconds - lastFixAt} ms ago');
        }
        worstLag = math.max(worstLag, gap);
      }
      lastProbe = now;
    });

    var puckNotifies = 0;
    puck.addListener(() {
      if (recording) puckNotifies++;
    });

    // The clock the puck and the model see follows the wall clock from the route start.
    void clockFrame(Duration _) {
      if (!alive) return;
      h.clockNow = _base.add(routeWall.elapsed);
      SchedulerBinding.instance.scheduleFrameCallback(clockFrame);
    }

    SchedulerBinding.instance.scheduleFrameCallback(clockFrame);

    // Fixes: one per route second, at that second of wall time.
    var next = 0;
    final feeder = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final ms = routeWall.elapsedMilliseconds;
      while (next < route.samples.length && route.samples[next].t * 1000 <= ms) {
        final f = route.samples[next].fix;
        next++;
        if (f != null) {
          lastFixAt = ms;
          h.location.fixController.add(f);
        }
      }
    });
    // A live ping every 8 s.
    var livePing = 1000;
    final pinger = Timer.periodic(const Duration(seconds: 8), (_) {
      final s = route.samples[math.min(route.samples.length - 1, routeWall.elapsed.inSeconds)];
      lastPingAt = routeWall.elapsedMilliseconds;
      engine.emit(pingAt(livePing++, s));
    });

    // Per-frame samples of the dot against the truth.
    final lagM = <double>[];
    final stepsM = <double>[];
    var backwards = 0;
    var bigHops = 0;
    final screenDx = <double>[], screenDy = <double>[];
    double? lastLat, lastLon;
    double? lastFrameMs;
    void sampleFrame(Duration _) {
      if (!alive) return;
      final p = puck.pose;
      if (recording && p != null) {
        final secs = routeWall.elapsedMilliseconds / 1000.0;
        final i = secs.floor().clamp(0, route.samples.length - 2);
        final fr = secs - i;
        final a = route.samples[i], b = route.samples[i + 1];
        final tl = a.trueLat + (b.trueLat - a.trueLat) * fr;
        final tn = a.trueLon + (b.trueLon - a.trueLon) * fr;
        lagM.add(routeDistM(p.lat, p.lon, tl, tn));
        final mark = find.byKey(const Key('map-position'));
        if (mark.evaluate().isNotEmpty) {
          final c = t.getCenter(mark);
          screenDx.add(c.dx);
          screenDy.add(c.dy);
        }
        if (lastLat != null) {
          final step = routeDistM(lastLat!, lastLon!, p.lat, p.lon);
          stepsM.add(step);
          final dtS = (routeWall.elapsedMilliseconds - lastFrameMs!) / 1000.0;
          final expect = a.trueSpeed * dtS;
          if (step > math.max(4.0, 3 * expect + 2)) bigHops++;
          // backwards: movement against the course
          final c = (p.courseDeg ?? a.trueCourse) * math.pi / 180;
          final dy = (p.lat - lastLat!) * 111320.0;
          final dx = (p.lon - lastLon!) * 111320.0 * math.cos(p.lat * math.pi / 180);
          if (dx * math.sin(c) + dy * math.cos(c) < -0.05) backwards++;
        }
        lastLat = p.lat;
        lastLon = p.lon;
        lastFrameMs = routeWall.elapsedMilliseconds.toDouble();
      }
      SchedulerBinding.instance.scheduleFrameCallback(sampleFrame);
    }

    SchedulerBinding.instance.scheduleFrameCallback(sampleFrame);

    // --- warm up, then record ---
    const warm = 12;
    final start = DateTime.now();
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    while (DateTime.now().difference(start).inSeconds < warm) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    recording = true;
    frames.reset();
    final startMs = routeWall.elapsedMilliseconds;
    final end = DateTime.now().add(Duration(seconds: _seconds));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 33));
    }
    recording = false;
    alive = false;
    final windowS = (routeWall.elapsedMilliseconds - startMs) / 1000.0;
    feeder.cancel();
    pinger.cancel();
    probe.cancel();
    SchedulerBinding.instance.removeTimingsCallback(onTimings);

    final snap = frames.snapshot();
    lagM.sort();
    stepsM.sort();
    lags.sort();
    double q(List<num> s, double p) => s.isEmpty ? 0 : s[((s.length - 1) * p).round()].toDouble();
    double mean(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    double std(List<double> v) {
      if (v.isEmpty) return 0;
      final m = mean(v);
      return math.sqrt(v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length);
    }

    final result = <String, Object?>{
      'name': _name,
      'seconds': windowS.round(),
      'network_cells_loaded': cmCells,
      'cells_generated': cells.length,
      'repeaters': repeaters.length,
      'pings': h.state.drivePings.length,
      'tiles': _tiles,
      'frames': snap.toJson(),
      'event_loop_lag_ms': {'p95': q(lags, 0.95), 'p99': q(lags, 0.99), 'worst': worstLag},
      'puck_notifies_per_s': double.parse((puckNotifies / windowS).toStringAsFixed(1)),
      'puck_frames_sampled': stepsM.length,
      'puck_error_m': {'p50': q(lagM, 0.5), 'p95': q(lagM, 0.95), 'max': lagM.isEmpty ? 0 : lagM.last},
      'puck_step_m': {'p50': q(stepsM, 0.5), 'p95': q(stepsM, 0.95), 'max': stepsM.isEmpty ? 0 : stepsM.last},
      'puck_screen_px': {
        'mean_dx': mean(screenDx),
        'mean_dy': mean(screenDy),
        'std_dx': std(screenDx),
        'std_dy': std(screenDy),
        'map_height': t.getSize(mapFinder).height,
      },
      'puck_big_hops': bigHops,
      'puck_backwards_steps': backwards,
    };
    // ignore: avoid_print
    print('BENCH_RESULT ${jsonEncode(result)}');
    try {
      File('${Directory.systemTemp.path}/bench_$_name.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
    } catch (_) {}
    binding.reportData = {'bench_$_name': result};

    expect(snap.frames, greaterThan(10), reason: 'frames were recorded');
    expect(snap.p95Ms, lessThan(_p95Max), reason: 'p95 frame cost ${snap.p95Ms} ms');
    expect(snap.worstMs, lessThan(_worstMax), reason: 'worst frame ${snap.worstMs} ms');
    expect(std(screenDy), lessThan(4), reason: 'in follow mode the arrow stays put on the screen (std ${std(screenDy)} px)');
    expect(backwards, 0);
    expect(worstLag, lessThan(_lagMax), reason: 'UI isolate was blocked $worstLag ms');
  }, timeout: const Timeout(Duration(minutes: 30)));
}
