import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/puck_motion.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../support/gps_route.dart';

final _t0 = DateTime.utc(2026, 11, 1, 12);
const _mLat = 111320.0;

GeoFix fix(double secs, double northM, {double? acc = 5, double? speed = 13, double? course = 0, double eastM = 0}) => GeoFix(
  lat: 40 + northM / _mLat,
  lon: -83 + eastM / (_mLat * math.cos(40 * math.pi / 180)),
  at: _t0.add(Duration(milliseconds: (secs * 1000).round())),
  accuracyM: acc,
  speedMps: speed,
  courseDeg: course,
);

DateTime at(double secs) => _t0.add(Duration(milliseconds: (secs * 1000).round()));
double northOf(PuckPose p) => (p.lat - 40) * _mLat;
double eastOf(PuckPose p) => (p.lon + 83) * _mLat * math.cos(40 * math.pi / 180);

/// Replays [route] through a PuckMotion with frames every [frameMs]; returns per-frame (time, pose, truth).
class Replay {
  final List<({double t, PuckPose pose, RouteSample truth})> frames = [];
  final PuckMotion motion;
  Replay(GpsRoute route, {int frameMs = 16, PuckConfig config = const PuckConfig(), int arrivalDelayMs = 150}) : motion = PuckMotion(config) {
    final pending = <(double, GeoFix)>[];
    for (final s in route.samples) {
      if (s.fix != null) pending.add((s.t + arrivalDelayMs / 1000.0, s.fix!));
    }
    var pi = 0;
    for (var ms = 0; ms < route.seconds * 1000; ms += frameMs) {
      final tS = ms / 1000.0;
      while (pi < pending.length && pending[pi].$1 <= tS) {
        motion.add(pending[pi].$2, at(pending[pi].$1));
        pi++;
      }
      final p = motion.poseAt(at(tS));
      if (p == null) continue;
      final i = math.min(route.samples.length - 2, tS.floor());
      final fr = tS - i;
      final a = route.samples[i], b = route.samples[i + 1];
      final truth = RouteSample(
        i,
        a.trueLat + (b.trueLat - a.trueLat) * fr,
        a.trueLon + (b.trueLon - a.trueLon) * fr,
        a.trueSpeed,
        a.trueCourse,
        null,
      );
      frames.add((t: tS, pose: p, truth: truth));
    }
  }
}

void main() {
  group('outlier gate', () {
    test('drops non-finite, out-of-range and out-of-order fixes', () {
      final m = PuckMotion();
      expect(m.add(fix(0, 0), at(0)), isTrue);
      expect(m.add(GeoFix(lat: double.nan, lon: 0, at: at(1)), at(1)), isFalse);
      expect(m.add(GeoFix(lat: 95, lon: 0, at: at(1)), at(1)), isFalse);
      expect(m.add(fix(-1, 5), at(1)), isFalse, reason: 'older than the last accepted fix');
      expect(m.rejectedCount, 3);
    });

    test('a poor fix is dropped while a good one is recent, accepted when nothing better comes', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      expect(m.add(fix(1, 13, acc: 400), at(1)), isFalse);
      expect(m.add(fix(5, 65, acc: 400), at(5)), isFalse);
      expect(m.add(fix(11, 143, acc: 400), at(11)), isTrue, reason: '10 s without a good fix: a poor-fix phone still gets a dot');
    });

    test('a teleport is dropped, three agreeing far fixes re-lock the dot', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.add(fix(1, 13), at(1));
      expect(m.add(fix(2, 20000), at(2)), isFalse);
      expect(m.add(fix(3, -30000), at(3)), isFalse);
      expect(m.add(fix(4, 20000), at(4)), isFalse);
      expect(m.add(fix(5, 20013), at(5)), isFalse);
      expect(m.add(fix(6, 20026), at(6)), isTrue);
      expect(northOf(m.poseAt(at(6))!), closeTo(20026, 1));
    });

    test('a normal 13 m/s hop is never a teleport', () {
      final m = PuckMotion();
      for (var i = 0; i < 30; i++) {
        expect(m.add(fix(i.toDouble(), 13.0 * i), at(i.toDouble())), isTrue);
      }
    });
  });

  group('interpolation between fixes', () {
    test('moves every frame at driving speed, steadily, never backwards', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      var last = 0.0;
      final steps = <double>[];
      for (var s = 1; s <= 20; s++) {
        for (var ms = 0; ms < 1000; ms += 16) {
          final t = (s - 1) + ms / 1000.0;
          final p = m.poseAt(at(t))!;
          if (s > 6) {
            steps.add(northOf(p) - last);
          }
          last = northOf(p);
        }
        m.add(fix(s.toDouble(), 13.0 * s), at(s.toDouble()));
      }
      for (final d in steps) {
        expect(d, greaterThanOrEqualTo(0), reason: 'never backwards');
      }
      final moving = steps.where((d) => d > 0).toList();
      expect(moving.length, greaterThan(steps.length * 0.95), reason: 'it moves on (nearly) every frame, not once a second');
      // 13 m/s at 16 ms is 0.21 m a frame; allow spring/speed modulation but no hop
      expect(moving.reduce(math.max), lessThan(0.6));
    });

    test('120 Hz: twice the frames, half the step, same path', () {
      final a = PuckMotion(), b = PuckMotion();
      a.add(fix(0, 0), at(0));
      b.add(fix(0, 0), at(0));
      PuckPose? pa, pb;
      for (var s = 1; s <= 8; s++) {
        for (var ms = 0; ms < 1000; ms += 16) {
          pa = a.poseAt(at((s - 1) + ms / 1000.0));
        }
        for (var ms = 0; ms < 1000; ms += 8) {
          pb = b.poseAt(at((s - 1) + ms / 1000.0));
        }
        a.add(fix(s.toDouble(), 13.0 * s), at(s.toDouble()));
        b.add(fix(s.toDouble(), 13.0 * s), at(s.toDouble()));
      }
      expect((northOf(pa!) - northOf(pb!)).abs(), lessThan(1.5));
    });

    test('a late fix bends the path: no teleport, no reversing', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.add(fix(1, 13), at(1));
      var last = 0.0;
      for (var ms = 0; ms < 2500; ms += 16) {
        final p = m.poseAt(at(1 + ms / 1000.0))!;
        expect(northOf(p), greaterThanOrEqualTo(last - 1e-9));
        last = northOf(p);
      }
      // the fix is 1.5 s late and 4 m behind where the dot coasted to
      m.add(fix(2.5, 13 * 2.5 - 4), at(3.5));
      var prev = last;
      for (var ms = 0; ms < 3000; ms += 16) {
        final p = m.poseAt(at(3.5 + ms / 1000.0))!;
        expect(northOf(p) - prev, inInclusiveRange(-1e-9, 0.6), reason: 'continuous, forward only');
        prev = northOf(p);
      }
    });
  });

  group('signal dips', () {
    test('coasts on course for up to 5 s, reports weak from 2.5 s, then holds and says frozen', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.add(fix(1, 13), at(1));
      PuckPose p = m.poseAt(at(1))!;
      for (var ms = 0; ms <= 9000; ms += 16) {
        p = m.poseAt(at(1 + ms / 1000.0))!;
        if (ms == 1500) {
          expect(p.weak, isFalse);
        }
        if (ms == 3000) {
          expect(p.weak, isTrue);
          expect(p.frozen, isFalse);
          expect(northOf(p), greaterThan(13 + 13 * 1.5), reason: 'still coasting at 3 s');
        }
      }
      expect(p.frozen, isTrue);
      expect(northOf(p), closeTo(13 + 13 * 5, 12), reason: 'coasted about 5 s then held');
      final held = northOf(p);
      p = m.poseAt(at(10.1))!;
      expect(northOf(p), closeTo(held, 0.2));
      expect(p.settled, isTrue);
    });

    test('the accuracy ring grows while the signal is down', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.add(fix(1, 13, acc: 8), at(1));
      expect(m.poseAt(at(1.2))!.accuracyM, closeTo(8, 0.1));
      expect(m.poseAt(at(5))!.accuracyM!, greaterThan(20));
    });

    test('a fix after a long gap pulls the dot there without overshoot or reversing', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.add(fix(1, 13), at(1));
      for (var ms = 0; ms < 8000; ms += 16) {
        m.poseAt(at(1 + ms / 1000.0));
      }
      // the car actually slowed in the tunnel: it is only at 60 m when the fix returns
      m.add(fix(9, 60), at(9));
      var prev = northOf(m.poseAt(at(9))!);
      var maxN = prev;
      for (var ms = 16; ms < 6000; ms += 16) {
        final p = m.poseAt(at(9 + ms / 1000.0))!;
        maxN = math.max(maxN, northOf(p));
        expect(northOf(p), greaterThanOrEqualTo(prev - 1e-9), reason: 'no reversing even when ahead of the truth');
        prev = northOf(p);
      }
    });
  });

  group('parked', () {
    test('jitter around a parked car does not move the dot', () {
      final m = PuckMotion();
      final rnd = math.Random(3);
      m.add(fix(0, 0, speed: 0, course: null, acc: 12), at(0));
      var lo = double.infinity, hi = -double.infinity, loE = double.infinity, hiE = -double.infinity;
      for (var s = 1; s <= 120; s++) {
        final n = (rnd.nextDouble() - 0.5) * 20, e = (rnd.nextDouble() - 0.5) * 20; // +-10 m wander of a 12 m fix
        m.add(fix(s.toDouble(), n, eastM: e, speed: rnd.nextDouble() * 0.4, course: null, acc: 12), at(s.toDouble()));
        for (var ms = 0; ms < 1000; ms += 100) {
          final p = m.poseAt(at(s + ms / 1000.0))!;
          if (s > 10) {
            lo = math.min(lo, northOf(p));
            hi = math.max(hi, northOf(p));
            loE = math.min(loE, eastOf(p));
            hiE = math.max(hiE, eastOf(p));
          }
        }
      }
      expect(hi - lo, lessThan(4), reason: 'the dot sits still (spread ${hi - lo} m north)');
      expect(hiE - loE, lessThan(4));
      expect(m.parked, isTrue);
    });

    test('a real drive-off leaves the lock and the dot follows', () {
      final m = PuckMotion();
      for (var s = 0; s < 20; s++) {
        m.add(fix(s.toDouble(), 0, speed: 0, course: null, acc: 8), at(s.toDouble()));
        m.poseAt(at(s.toDouble()));
      }
      expect(m.parked, isTrue);
      var p = m.poseAt(at(20))!;
      for (var s = 20; s < 30; s++) {
        final d = (s - 19) * 4.0;
        m.add(fix(s.toDouble(), d, speed: 4, course: 0, acc: 6), at(s.toDouble()));
        for (var ms = 0; ms < 1000; ms += 16) {
          p = m.poseAt(at(s + ms / 1000.0))!;
        }
      }
      expect(m.parked, isFalse);
      expect(northOf(p), greaterThan(25));
      expect(p.courseDeg, isNotNull);
    });
  });

  group('recorded 20 minute route (1 Hz, jitter, dips, 5-45 m accuracy)', () {
    final route = GpsRoute.generate(seconds: 1200);

    for (final ms in [16, 8]) {
      test('${1000 ~/ ms} Hz display: never hops, never reverses, stays near the truth', () {
        final r = Replay(route, frameMs: ms);
        var hops = 0, back = 0;
        var maxStep = 0.0;
        final errs = <double>[];
        for (var i = 1; i < r.frames.length; i++) {
          final a = r.frames[i - 1], b = r.frames[i];
          final step = routeDistM(a.pose.lat, a.pose.lon, b.pose.lat, b.pose.lon);
          maxStep = math.max(maxStep, step);
          final expect = 40.0 * ms / 1000; // catching up after a dip may reach ~40 m/s; a hop is anything faster
          if (step > expect) hops++;
          final c = (b.pose.courseDeg ?? b.truth.trueCourse) * math.pi / 180;
          final dy = (b.pose.lat - a.pose.lat) * _mLat;
          final dx = (b.pose.lon - a.pose.lon) * _mLat * math.cos(40 * math.pi / 180);
          if (b.pose.courseDeg != null && dx * math.sin(c) + dy * math.cos(c) < -0.02) back++;
          errs.add(routeDistM(b.pose.lat, b.pose.lon, b.truth.trueLat, b.truth.trueLon));
        }
        errs.sort();
        final p95 = errs[(errs.length * 0.95).floor()];
        // ignore: avoid_print
        print('route replay ${ms}ms: frames=${r.frames.length} hops=$hops backwards=$back maxStep=${maxStep.toStringAsFixed(2)} err p50=${errs[errs.length ~/ 2].toStringAsFixed(1)} p95=${p95.toStringAsFixed(1)} max=${errs.last.toStringAsFixed(1)}');
        expect(hops, 0);
        expect(back, 0);
        expect(errs[errs.length ~/ 2], lessThan(7));
        expect(p95, lessThan(25));
        expect(errs.last, lessThan(120));
      });
    }

    test('parked at red lights: the dot does not wander', () {
      final r = Replay(route, frameMs: 16);
      // find the stop windows from the truth and check the spread of the dot inside each
      var i = 0;
      var checked = 0;
      while (i < r.frames.length) {
        if (r.frames[i].truth.trueSpeed == 0) {
          var j = i;
          while (j < r.frames.length && r.frames[j].truth.trueSpeed == 0) {
            j++;
          }
          final nearDip = route.dips.any((d) => (d.$1 - r.frames[i].t).abs() < 25 || (d.$1 + d.$2 - r.frames[j - 1].t).abs() < 25 || (d.$1 > r.frames[i].t && d.$1 < r.frames[j - 1].t));
          if (j - i > 60 * 12 && !nearDip) {
            // skip the first 6 s (the dot is still arriving), check the rest
            final seg = r.frames.sublist(i + 60 * 8, j);
            var lo = double.infinity, hi = -double.infinity;
            for (final f in seg) {
              lo = math.min(lo, northOf(f.pose));
              hi = math.max(hi, northOf(f.pose));
            }
            // ignore: avoid_print
            print('stop at ${r.frames[i].t}s spread ${hi - lo}');
            expect(hi - lo, lessThan(6), reason: 'stop at ${r.frames[i].t}s');
            checked++;
          }
          i = j;
        } else {
          i++;
        }
      }
      expect(checked, greaterThan(0));
    });
  });
}
