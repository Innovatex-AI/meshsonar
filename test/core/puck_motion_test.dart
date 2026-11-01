import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/puck_motion.dart';
import 'package:meshsonar/radio/radio_api.dart';

final _t0 = DateTime.utc(2026, 11, 1, 12);
const _mLat = 111320.0;

/// A fix [secs] after the start, [northM] metres north of the origin, driving north at [speed].
GeoFix fix(double secs, double northM, {double? acc = 5, double? speed = 13, double? course = 0, double eastM = 0}) =>
    GeoFix(
      lat: 40 + northM / _mLat,
      lon: -83 + eastM / (_mLat * math.cos(40 * math.pi / 180)),
      at: _t0.add(Duration(milliseconds: (secs * 1000).round())),
      accuracyM: acc,
      speedMps: speed,
      courseDeg: course,
    );

DateTime at(double secs) => _t0.add(Duration(milliseconds: (secs * 1000).round()));
double northOf(PuckPose p) => (p.lat - 40) * _mLat;

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
      // 10 s since the last good fix: a phone with only poor fixes still gets a dot.
      expect(m.add(fix(11, 143, acc: 400), at(11)), isTrue);
    });

    test('a teleport is dropped, a second one elsewhere is dropped, three that agree re-lock the dot', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.add(fix(1, 13), at(1));
      expect(m.add(fix(2, 20000), at(2)), isFalse);
      expect(m.add(fix(3, -30000), at(3)), isFalse, reason: 'a different place: the suspects do not agree');
      expect(m.add(fix(4, 20000), at(4)), isFalse);
      expect(m.add(fix(5, 20013), at(5)), isFalse);
      expect(m.add(fix(6, 20026), at(6)), isTrue, reason: 'third agreeing far fix: real jump');
      final p = m.poseAt(at(6))!;
      expect(northOf(p), closeTo(20026, 1), reason: 'snapped, no slide across 20 km');
    });

    test('a normal 13 m/s hop is never a teleport', () {
      final m = PuckMotion();
      for (var i = 0; i < 30; i++) {
        expect(m.add(fix(i.toDouble(), 13.0 * i), at(i.toDouble())), isTrue);
      }
      expect(m.rejectedCount, 0);
    });
  });

  group('motion', () {
    test('slides between fixes instead of hopping, and never overshoots the push-ahead limit', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.poseAt(at(0));
      m.add(fix(1, 13), at(1));
      var prev = northOf(m.poseAt(at(1))!);
      var biggestStep = 0.0;
      for (var ms = 1017; ms < 2000; ms += 17) {
        final p = northOf(m.poseAt(at(ms / 1000))!);
        biggestStep = math.max(biggestStep, p - prev);
        expect(p, greaterThanOrEqualTo(prev - 1e-6), reason: 'never backwards while heading north');
        prev = p;
      }
      // At 60 fps the dot moves ~0.2 m a frame; a hop would be 13 m.
      expect(biggestStep, lessThan(1.0));
      // And it never runs more than the 1.2 s push-ahead beyond the fix: 13 m/s x 1.2 s = 15.6 m.
      expect(prev, lessThan(13 + 15.6 + 0.01));
    });

    test('a late fix bends the path, it does not snap it', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.poseAt(at(0));
      m.add(fix(1, 13), at(1));
      for (var ms = 1000; ms <= 2400; ms += 20) {
        m.poseAt(at(ms / 1000));
      }
      final before = northOf(m.poseAt(at(2.4))!);
      // The next fix is 2.4 s late and is only 20 m up: a correction backwards, eased.
      m.add(fix(2.4, 20, speed: 13), at(2.4));
      final after = northOf(m.poseAt(at(2.417))!);
      expect((after - before).abs(), lessThan(2.0));
    });

    test('a parked phone does not drift: no push without speed, and jitter below speed gate stays put', () {
      final m = PuckMotion();
      m.add(fix(0, 0, speed: 0, course: null), at(0));
      final a = m.poseAt(at(0))!;
      final b = m.poseAt(at(1.5))!;
      expect(b.lat, closeTo(a.lat, 1e-9));
      expect(b.moving, isFalse);
      expect(b.settled, isTrue);
    });

    test('course is derived from consecutive fixes when the phone reports none', () {
      final m = PuckMotion();
      m.add(fix(0, 0, speed: null, course: null), at(0));
      m.add(fix(1, 0, speed: null, course: null, eastM: 12), at(1));
      final p = m.poseAt(at(1))!;
      expect(p.courseDeg, closeTo(90, 2));
      expect(p.speedMps, closeTo(12, 0.5));
    });

    test('reduced motion shows the newest fix as it is', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      m.add(fix(1, 13), at(1));
      final p = m.poseAt(at(1.5), reducedMotion: true)!;
      expect(northOf(p), closeTo(13, 0.01));
      expect(p.settled, isTrue);
    });

    test('settles once the push-ahead window has passed and the ease caught up', () {
      final m = PuckMotion();
      m.add(fix(0, 0), at(0));
      var p = m.poseAt(at(0))!;
      m.add(fix(1, 13), at(1));
      for (var ms = 1000; ms <= 4000; ms += 50) {
        p = m.poseAt(at(ms / 1000))!;
      }
      expect(p.settled, isTrue);
    });

    test('the raw fix is untouched: lastAccepted is exactly what was fed', () {
      final m = PuckMotion();
      final f = fix(0, 0);
      m.add(f, at(0));
      m.poseAt(at(0.8));
      expect(identical(m.lastAccepted, f), isTrue);
    });
  });
}
