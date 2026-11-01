// Andy's real GPS (Nov 1 2026), replayed against the ping engine on a fake clock, fake GPS and fake radio, no simulator: accuracy 35-46 m
// with excursions to 52-70 m, no speed from the OS, a stale coarse first fix. The numbers it prints are the AFTER column of
// meshsonar-infra/docs/handoff-parts/gps-engine.md; the BEFORE column was measured with this same harness on the engine at f4dcd9b.
//
// Measured on f4dcd9b (BEFORE; same AndyGps seed 7, 1200 s):
//   15 s typical      sent=81/80  gap p50=15.0 p95=15.0 max=16.5  first ping 1.9 s, first->second ping jump 1,261 m (stale first fix)
//   15 s long dips    sent=74/80  gap p50=15.0 p95=25.0 max=30.0  145 gate refusals
//   30 s long dips    sent=38/40  gap p50=30.0 p95=40.0 max=45.0  124 gate refusals
// (the full table is in the handoff part).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_timing.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

import '../support/andy_gps.dart';
import '../support/replay_radio.dart';
import 'ping_replay_test.dart' show appStack;

class Run {
  final ReplayResult r;
  final List<Map<String, Object?>> traces;
  final int interval, seconds;
  Run(this.r, this.traces, this.interval, this.seconds);

  DriveTimingSummary get timing => r.engine.timingSummary();
  List<Map<String, Object?>> get pingTraces => traces.where((t) => t.containsKey('fix_rule')).toList();
  List<double> get gaps => r.sendGaps()..sort();
  double q(double p) => gaps.isEmpty ? 0 : gaps[((gaps.length - 1) * p).round()];
  double get firstS => r.radio.sent.first.at.difference(r.engineStartedAt!).inMilliseconds / 1000.0;
  double get firstJumpM => r.pings.length < 2 ? 0 : haversineM(r.pings[0].lat, r.pings[0].lon, r.pings[1].lat, r.pings[1].lon);
  List<double> get posErr {
    final g = r.gps as AndyGps;
    return [for (final p in r.pings) g.positionErrorM(p.lat, p.ts)]..sort();
  }

  double err(double p) => posErr[((posErr.length - 1) * p).round()];

  String line(String name) =>
      'AFTER $name: sent=${r.pingsSent}/${seconds ~/ interval} gap p50=${q(.5).toStringAsFixed(1)} p95=${q(.95).toStringAsFixed(1)} '
      'max=${q(1).toStringAsFixed(1)} late p95=${timing.lateP95S?.toStringAsFixed(2)} max=${timing.lateMaxS?.toStringAsFixed(2)} '
      'first=${firstS.toStringAsFixed(1)}s jump=${firstJumpM.toStringAsFixed(0)}m refused=${timing.fixesRefused} held=${timing.skipped} '
      'lowAcc=${timing.lowAccuracyPings} posErr p50=${err(.5).toStringAsFixed(0)} p95=${err(.95).toStringAsFixed(0)} max=${err(1).toStringAsFixed(0)}m';
}

Run replay(RunnableLocation Function(DateTime Function()) gps,
    {int interval = 15, int seconds = 1200, Duration Function(int)? jank, WardriveConfig Function(WardriveConfig)? tweak}) {
  final traces = <Map<String, Object?>>[];
  final r = runReplay(
    build: (l, g, c) async {
      final e = await appStack(chat: false)(l, g, c);
      e.onTrace = traces.add;
      return e;
    },
    driveSeconds: seconds,
    intervalSec: interval,
    makeGps: gps,
    jank: jank,
    tweak: tweak,
  );
  return Run(r, traces, interval, seconds);
}

const scenarios = <String, AndyProfile>{
  'typical(dips 3-8s)': AndyProfile(),
  'dropouts 3-8s': AndyProfile(dropouts: true),
  'long dips 10-25s': AndyProfile(dipEveryS: 45, dipMinS: 10, dipMaxS: 25),
};

void main() {
  for (final interval in [15, 30]) {
    for (final e in scenarios.entries) {
      test('Andy replay, 20 min at $interval s, ${e.key}: every ping on schedule, honest positions, no stale first fix', () {
        final run = replay((clock) => AndyGps(clock, profile: e.value, seed: 7), interval: interval);
        // ignore: avoid_print
        print(run.line('interval=$interval ${e.key}'));
        final expected = 1200 ~/ interval;
        expect(run.r.pingsSent, inInclusiveRange(expected, expected + 1), reason: 'count sent == count expected: nothing skipped');
        expect(run.q(1), lessThanOrEqualTo(interval + 2.0), reason: 'no gap longer than the interval + 2 s');
        expect(run.q(.95), lessThanOrEqualTo(interval + 1.0));
        expect(run.q(0), greaterThanOrEqualTo(interval - 1.0), reason: 'and none squeezed in early');
        expect(run.timing.lateMaxS!, lessThanOrEqualTo(1.0), reason: 'every ping within 1 s of its due time');
        expect(run.firstS, lessThan(6), reason: 'time to first ping: the first fix that meets the first-ping rule');
        expect(run.firstJumpM, lessThan(interval * 10 * 1.0 + 60), reason: 'ping 1 was NOT taken from the 1.2 km-away cached fix');
        expect(run.err(1), lessThan(120), reason: 'no ping is placed far from the car');
        expect(run.err(.5), lessThan(25));
        expect(run.err(.95), lessThan(65));
        // The poor fixes were not thrown away: pings above 50 m are sent, flagged, with their real accuracy.
        final lowAcc = run.pingTraces.where((t) => t['low_acc'] == true).length;
        final measured = run.r.pings.where((p) => (p.gpsAccuracyM ?? 0) > 50).length;
        expect(lowAcc, measured, reason: 'every >50 m ping is flagged in the trace');
        expect(run.timing.lowAccuracyPings, measured);
        for (final p in run.r.pings) {
          expect(p.gpsAccuracyM, isNotNull);
        }
      });
    }
  }

  test('Andy replay: a dropout longer than 10 s is the only reason for a late ping, and the engine resumes the moment fixes return', () {
    final run = replay((clock) => AndyGps(clock, profile: const AndyProfile(dropouts: true, dipEveryS: 90, dipMinS: 14, dipMaxS: 22), seed: 3));
    // ignore: avoid_print
    print(run.line('15 s dropouts 14-22s'));
    // A due time inside a dropout waits for the next fix (the window keeps the last 8 s): gap <= interval + dropout - 8 + 1 s.
    expect(run.q(1), lessThanOrEqualTo(15 + 22 - 8 + 1.0));
    expect(run.r.pingsSent, greaterThanOrEqualTo(60));
    expect(run.timing.skipped.containsKey('no_fix') || run.timing.skipped.containsKey('gate'), isTrue, reason: 'the held-back episodes are counted');
  });

  test('the ping carries a speed even though the OS reported none: derived from the window; parked stays honest', () {
    final run = replay((clock) => AndyGps(clock, profile: const AndyProfile(speedMps: 10), seed: 5), seconds: 300);
    final speeds = [for (final p in run.r.pings.skip(2)) p.speedMps];
    final known = speeds.whereType<double>().toList();
    expect(known.length, greaterThanOrEqualTo(speeds.length * 0.6), reason: 'most pings carry a derived speed (speed_mps used to be null)');
    for (final v in known) {
      expect(v, inInclusiveRange(4, 18), reason: 'a 10 m/s car, derived from fixes 35-46 m wide');
    }
    // Parked: no speed above a crawl, ever.
    final parked = replay((clock) => AndyGps(clock, profile: const AndyProfile(speedMps: 0), seed: 5), seconds: 300);
    for (final p in parked.r.pings) {
      expect(p.speedMps ?? 0, lessThan(2.0));
    }
  });

  test('a stale, coarse first fix is never the first ping: without the guard ping 1 sits 1.2 km behind', () {
    final run = replay((clock) => AndyGps(clock, profile: const AndyProfile(), seed: 11), seconds: 120);
    final g = run.r.gps as AndyGps;
    final p0 = run.r.pings.first;
    expect(g.positionErrorM(p0.lat, p0.ts), lessThan(60), reason: 'first ping is where the car is');
    expect(g.staleDropped, greaterThanOrEqualTo(1), reason: 'the cached fix was refused on arrival and counted');
  });

  test('jank: a UI isolate that stalls 2-5 s at random does not shift the cadence (monotonic grid), and no ping is skipped', () {
    final rng = math.Random(9);
    final stalls = <int, Duration>{for (var s = 5; s < 1180; s += 20 + rng.nextInt(40)) s: Duration(milliseconds: 2000 + rng.nextInt(3000))};
    final run = replay((clock) => AndyGps(clock, profile: const AndyProfile(), seed: 7), jank: (s) => stalls[s] ?? Duration.zero);
    // ignore: avoid_print
    print(run.line('15 s with ${stalls.length} stalls of 2-5 s'));
    final clockSpan = run.r.radio.sent.last.at.difference(run.r.radio.sent.first.at).inSeconds;
    expect(run.r.pingsSent, inInclusiveRange(clockSpan ~/ 15, clockSpan ~/ 15 + 2), reason: 'a late ping does not push every later ping late');
    expect(run.timing.lateMaxS!, lessThan(5.5));
    expect(run.q(1), lessThanOrEqualTo(15 + 5.5), reason: 'the worst gap is one stall, not a drift');
    // Averaged over the drive the cadence is exactly the interval.
    final total = run.r.radio.sent.last.at.difference(run.r.radio.sent.first.at).inSeconds;
    expect(total / (run.r.pingsSent - 1), closeTo(15, 0.5));
  });

  test('a fix wandering past 50 m does not stop the pings (the old 50 m gate did)', () {
    // A steady 55-90 m fix: every ping goes out on time, with the measured accuracy, all flagged.
    final run = replay((clock) => ScriptGps(clock, (s, now) => scriptFix(now, s * 10.0, 55.0 + (s % 7) * 5)), seconds: 300);
    expect(run.r.pingsSent, inInclusiveRange(19, 20), reason: 'the first waits 20 s for a 50 m fix, then every 15 s');
    expect(run.timing.lowAccuracyPings, run.r.pingsSent);
    expect(run.r.pings.map((p) => p.gpsAccuracyM!).reduce(math.min), greaterThan(50));
    expect(run.q(1), lessThanOrEqualTo(15.5));
    expect(run.pingTraces.every((t) => t['low_acc'] == true), isTrue);
  });

  test('a 150 m fix (cell tower / Wi-Fi guess) never becomes a ping position, and the wait is counted', () {
    final run = replay((clock) => ScriptGps(clock, (s, now) => scriptFix(now, s * 10.0, 150)), seconds: 120);
    expect(run.r.pingsSent, 0);
    expect(run.timing.skipped['first_fix'], 1, reason: 'one held-back episode, not one per second');
    expect(run.traces.any((t) => t['no_fix'] == true && t['why'] == 'first_fix' && t['acc'] == 150), isTrue, reason: 'the trace says why');
  });

  test('the first ping waits for a fix of 50 m or better, then goes at once; after 20 s it takes anything inside 100 m', () {
    final a = replay((clock) => ScriptGps(clock, (s, now) => scriptFix(now, s * 10.0, s < 8 ? 80 : 30)), seconds: 60);
    expect(a.firstS, inInclusiveRange(7, 10), reason: 'waited for the 30 m fix');
    final first = a.pingTraces.first;
    expect(first['fix_rule'], 'first');
    expect(a.r.pings.first.gpsAccuracyM, 30);
    final b = replay((clock) => ScriptGps(clock, (s, now) => scriptFix(now, s * 10.0, 80)), seconds: 60);
    expect(b.firstS, inInclusiveRange(20, 23), reason: 'no good fix came: a late first ping beats none');
  });

  test('a platform current-position call that never answers costs nothing: the stream window carries the pings', () {
    final run = replay((clock) => ScriptGps(clock, (s, now) => scriptFix(now, s * 10.0, 20), currentStalls: true), seconds: 300);
    expect(run.r.pingsSent, inInclusiveRange(20, 21));
    expect(run.q(1), lessThanOrEqualTo(15.5));
  });

  test('the engine records, per ping, the fix age, accuracy, rule, lateness and monotonic send time', () {
    final run = replay((clock) => AndyGps(clock, profile: const AndyProfile(), seed: 7), seconds: 120);
    final t = run.pingTraces;
    expect(t, isNotEmpty);
    for (final x in t) {
      for (final k in ['fix_age_ms', 'acc', 'low_acc', 'fix_rule', 'cands', 'refused_poor', 'speed_src', 'late_ms', 'mono_ms']) {
        expect(x.containsKey(k), isTrue, reason: 'trace has $k');
      }
      expect(['first', 'newest', 'best_in_window'], contains(x['fix_rule']));
      expect(x['fix_age_ms'] as int, lessThanOrEqualTo(8000));
    }
  });
}
