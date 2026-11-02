// The ping fix policy (lib/core/fix_window.dart): window selection, the accuracy gate, the first-ping rule, stale (cached) fixes, derived speed.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/fix_window.dart';
import 'package:meshsonar/radio/radio_api.dart';

final t0 = DateTime.utc(2026, 11, 1, 14, 30);
Duration s(num sec) => Duration(milliseconds: (sec * 1000).round());

GeoFix fix(double acc, {double north = 0, double? speed, double? course, int atSec = 0}) =>
    GeoFix(lat: 40.1 + north / 111320.0, lon: -82.9, accuracyM: acc, speedMps: speed, courseDeg: course, at: t0.add(Duration(seconds: atSec)));

void main() {
  group('selection', () {
    test('the freshest fix wins when accuracy is similar and the car is moving', () {
      final w = FixWindow();
      w.add(fix(40, speed: 10, atSec: 0), s(0));
      w.add(fix(42, speed: 10, atSec: 3), s(3));
      w.add(fix(41, speed: 10, atSec: 6), s(6));
      final p = w.pick(s(7))!;
      expect(p.fix.at, t0.add(const Duration(seconds: 6)));
      expect(p.age, s(1));
      expect(p.notNewest, isFalse);
      expect(p.candidates, 3);
    });

    test('a much better older fix beats a poor fresh one, but only if the car has not travelled further than the gain', () {
      final w = FixWindow();
      w.add(fix(5, speed: 0.0, atSec: 0), s(0)); // parked, 5 m
      w.add(fix(60, speed: 0.0, atSec: 6), s(6)); // parked, 60 m
      expect(w.pick(s(7))!.accuracyM, 5, reason: 'parked: age costs nothing, accuracy decides');
      expect(w.pick(s(7))!.notNewest, isTrue);

      final m = FixWindow();
      m.add(fix(35, speed: 13, atSec: 0), s(0));
      m.add(fix(52, speed: 13, atSec: 6), s(6));
      // 35 m + 7 s * 13 m/s = 126 m of effective error vs 52 + 13 = 65 m: the fresh one wins even though it is worse on paper.
      expect(m.pick(s(7))!.accuracyM, 52);
    });

    test('a speedless old fix does not beat fresher ones: it takes the newest known speed (first seconds of a drive)', () {
      final w = FixWindow();
      w.add(fix(5, north: 0, atSec: 0), s(0)); // no speed yet: no 3 s baseline
      w.add(fix(5, north: 56, atSec: 1), s(1));
      w.add(fix(5, north: 167, speed: 55.5, atSec: 3), s(3));
      w.add(fix(5, north: 500, speed: 55.5, atSec: 9), s(9));
      // Old: 5 + 0 (parked, wrongly) would win at t = 10. With the car's speed it costs 5 + 55.5 * 10.
      expect(w.pick(s(10))!.fix.at, t0.add(const Duration(seconds: 9)));
    });

    test('ties go to the fresher fix', () {
      final w = FixWindow();
      w.add(fix(30, speed: 0.0, atSec: 0), s(0));
      w.add(fix(30, speed: 0.0, atSec: 4), s(4));
      expect(w.pick(s(5))!.fix.at, t0.add(const Duration(seconds: 4)));
    });

    test('only the last 8 s count', () {
      final w = FixWindow();
      w.add(fix(5, speed: 0.0, atSec: 0), s(0));
      expect(w.pick(s(8))!.accuracyM, 5);
      expect(w.pick(s(8.5)), isNull);
    });

    test('the gate is 100 m: a 52-100 m fix is usable (and flagged), a 101 m fix is not', () {
      final w = FixWindow();
      w.add(fix(99.9, atSec: 0), s(0));
      final p = w.pick(s(1))!;
      expect(p.lowAccuracy, isTrue);
      expect(p.accuracyM, 99.9);
      final w2 = FixWindow()..add(fix(101, atSec: 0), s(0));
      expect(w2.pick(s(1)), isNull);
      expect(FixWindow()..add(fix(50, atSec: 0), s(0)), isNotNull);
      expect((FixWindow()..add(fix(50, atSec: 0), s(0))).pick(s(1))!.lowAccuracy, isFalse, reason: '50 m itself is not flagged');
      expect((FixWindow()..add(fix(50.1, atSec: 0), s(0))).pick(s(1))!.lowAccuracy, isTrue);
    });

    test('a poor fix never hides a usable one; refused ones are counted', () {
      final w = FixWindow();
      w.add(fix(300, atSec: 0), s(0));
      w.add(fix(45, atSec: 2), s(2));
      final p = w.pick(s(3))!;
      expect(p.accuracyM, 45);
      expect(p.refusedPoor, 1);
    });

    test('unknown accuracy is treated as usable, with a nominal error', () {
      final w = FixWindow()..add(GeoFix(lat: 40.1, lon: -82.9, at: t0), s(0));
      expect(w.pick(s(1)), isNotNull);
    });
  });

  group('first ping', () {
    test('needs 50 m or better until it has waited 20 s, then takes anything inside the gate', () {
      final w = FixWindow()..add(fix(80, atSec: 0), s(0));
      expect(w.pick(s(1), first: true, waited: s(1)), isNull, reason: 'a coarse first fix is not ping 1');
      expect(w.pick(s(1), first: true, waited: const Duration(seconds: 19)), isNull);
      expect(w.pick(s(1), first: true, waited: const Duration(seconds: 20))!.accuracyM, 80);
      expect(w.pick(s(1)), isNotNull, reason: 'a later ping takes it at once');
      w.add(fix(40, atSec: 1), s(1));
      final p = w.pick(s(2), first: true, waited: s(2))!;
      expect(p.accuracyM, 40);
      expect(p.first, isTrue);
    });

    test('an unknown accuracy is not good enough for the first ping', () {
      final w = FixWindow()..add(GeoFix(lat: 40.1, lon: -82.9, at: t0), s(0));
      expect(w.pick(s(1), first: true, waited: s(1)), isNull);
    });
  });

  group('stale (cached) fixes', () {
    test('a fix timestamped minutes ago is refused on arrival; the next fresh one is fine', () {
      final g = StaleFixGuard();
      final now = t0;
      expect(g.isStale(now.subtract(const Duration(seconds: 120)), now), isTrue);
      expect(g.isStale(now.subtract(const Duration(seconds: 1)), now.add(const Duration(seconds: 2))), isFalse);
    });

    test('the same cached fix handed over twice (stream, then current()) is still stale', () {
      final g = StaleFixGuard();
      final cached = t0.subtract(const Duration(seconds: 120));
      expect(g.isStale(cached, t0), isTrue);
      expect(g.isStale(cached, t0.add(const Duration(milliseconds: 500))), isTrue);
    });

    test('a phone clock that is simply wrong gives a steady offset and is NOT mistaken for cached fixes (only the first is lost)', () {
      final g = StaleFixGuard();
      final skew = const Duration(minutes: 5);
      var refused = 0;
      for (var i = 0; i < 20; i++) {
        final now = t0.add(Duration(seconds: i));
        if (g.isStale(now.add(skew), now.add(skew * 2))) refused++; // GPS time is 5 minutes behind the phone: age steady 5 min
      }
      expect(refused, 1);
    });

    test('the window counts and drops what the guard flags', () {
      final w = FixWindow();
      expect(w.add(fix(10), s(0), stale: true), isNull);
      expect(w.staleRefused, 1);
      expect(w.pick(s(1)), isNull);
    });
  });

  group('speed and course', () {
    test('the OS speed is kept as reported', () {
      final w = FixWindow();
      final e = w.add(fix(10, speed: 7.5, course: 90), s(0))!;
      expect(e.speedMps, 7.5);
      expect(e.courseDeg, 90);
      expect(w.pick(s(1))!.speedSource, SpeedSource.os);
    });

    test('derived from the window when the OS gives none: a 10 m/s car', () {
      final w = FixWindow();
      for (var i = 0; i <= 8; i++) {
        w.add(fix(35, north: i * 10.0, atSec: i), s(i));
      }
      final p = w.pick(s(8))!;
      expect(p.speedSource, SpeedSource.derived);
      expect(p.fix.speedMps, closeTo(10, 1.5));
      expect(p.fix.courseDeg, closeTo(0, 5), reason: 'north');
    });

    test('a parked phone whose fixes wander inside their accuracy gets NO speed (nothing is invented)', () {
      final w = FixWindow();
      const wander = [0.0, 18.0, -12.0, 25.0, -20.0, 9.0, -25.0, 14.0, -5.0];
      for (var i = 0; i < wander.length; i++) {
        w.add(fix(40, north: wander[i], atSec: i), s(i));
      }
      final p = w.pick(s(8))!;
      expect(p.fix.speedMps, isNull);
      expect(p.speedSource, SpeedSource.none);
      expect(p.fix.courseDeg, isNull);
    });

    test('too short a baseline derives nothing', () {
      final w = FixWindow()
        ..add(fix(10, north: 0, atSec: 0), s(0))
        ..add(fix(10, north: 30, atSec: 2), s(2));
      expect(w.pick(s(2))!.fix.speedMps, isNull);
    });

    test('an impossible implied speed (teleport) is dropped', () {
      final w = FixWindow()
        ..add(fix(10, north: 0, atSec: 0), s(0))
        ..add(fix(10, north: 5000, atSec: 4), s(4));
      expect(w.pick(s(4))!.fix.speedMps, isNull);
    });
  });
}
