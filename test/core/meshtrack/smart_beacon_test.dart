import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/meshtrack/smart_beacon.dart';

final _t0 = DateTime.utc(2026, 11, 16, 12);
const _sf7 = Duration(microseconds: 255000);

/// Drives east along the equator-ish line at [kmh] for [duration], one fix per second, with an optional course
/// function; returns the decisions that said send (and marks them sent).
List<(Duration, MtBeaconDecision)> _drive(SmartBeacon b, double kmh,
    {Duration duration = const Duration(minutes: 30),
    double Function(int s)? course,
    int groups = 1,
    MtRate rate = MtRate.smart,
    Duration airtime = _sf7,
    bool reportSpeed = true}) {
  final out = <(Duration, MtBeaconDecision)>[];
  var lat = 40.0, lon = -83.0;
  final mps = kmh / 3.6;
  for (var s = 0; s <= duration.inSeconds; s++) {
    final c = course?.call(s) ?? 90.0;
    final now = _t0.add(Duration(seconds: s));
    final fix = MtFix(lat: lat, lon: lon, at: now, accuracyM: 5, speedMps: reportSpeed ? mps : null, courseDeg: reportSpeed ? c : null);
    final d = b.decide(fix, now: now, groups: groups, positionAirtime: airtime, rate: rate);
    if (d.send) {
      b.markSent(d, fix, now);
      out.add((Duration(seconds: s), d));
    }
    final rad = c * math.pi / 180;
    lat += mps * math.cos(rad) / 111320.0;
    lon += mps * math.sin(rad) / (111320.0 * math.cos(lat * math.pi / 180));
  }
  return out;
}

void main() {
  group('interval table', () {
    test('rates at 0/5/10/40/80/120 km/h', () {
      expect(SmartBeacon.interval(0), const Duration(seconds: 300));
      expect(SmartBeacon.interval(5), const Duration(seconds: 300));
      expect(SmartBeacon.interval(10), const Duration(seconds: 300));
      expect(SmartBeacon.interval(40), const Duration(seconds: 120));
      expect(SmartBeacon.interval(80), const Duration(seconds: 60));
      expect(SmartBeacon.interval(120), const Duration(seconds: 60));
      expect(SmartBeacon.interval(20), const Duration(seconds: 240));
    });

    test('low traffic doubles every interval', () {
      expect(SmartBeacon.interval(80, rate: MtRate.lowTraffic), const Duration(seconds: 120));
      expect(SmartBeacon.interval(5, rate: MtRate.lowTraffic), const Duration(seconds: 600));
    });

    test('multi-group stretch: intervals and floor times the group count, max 3', () {
      expect(SmartBeacon.interval(80, groups: 2), const Duration(seconds: 120));
      expect(SmartBeacon.interval(80, groups: 3), const Duration(seconds: 180));
      expect(SmartBeacon.interval(80, groups: 5), const Duration(seconds: 180));
      expect(SmartBeacon.floor(_sf7, groups: 2), const Duration(milliseconds: 51000));
    });

    test('corner threshold: 30 km/h -> 35 deg, 90 km/h -> 28.3 deg', () {
      expect(SmartBeacon.cornerThresholdDeg(30), 35);
      expect(SmartBeacon.cornerThresholdDeg(90), closeTo(28.33, 0.01));
    });
  });

  group('floor per preset (airtime table, plan section 3)', () {
    // position airtime ms per preset, and the floor max(20 s, 100 x airtime)
    final cases = <(int, double, int, int)>[
      (7, 62.5, 255, 25500),
      (8, 62.5, 468, 46800),
      (10, 250, 341, 34100),
      (11, 250, 641, 64100),
      (12, 125, 2730, 273000),
    ];
    for (final (sf, bw, ms, floorMs) in cases) {
      test('SF$sf BW$bw', () {
        final a = meshTrackPositionAirtime(sf: sf, bwKhz: bw);
        expect(a.inMicroseconds / 1000, closeTo(ms, 5), reason: 'airtime');
        expect(SmartBeacon.floor(a).inMilliseconds, closeTo(floorMs, 500));
      });
    }
    test('unknown preset falls back to SF7 BW62.5; fast presets floor at 20 s', () {
      expect(meshTrackPositionAirtime(), meshTrackPositionAirtime(sf: 7, bwKhz: 62.5));
      expect(SmartBeacon.floor(const Duration(milliseconds: 50)), const Duration(seconds: 20));
    });

    test('SF12 floor holds back a highway drive', () {
      final sends = _drive(SmartBeacon(), 100, airtime: meshTrackPositionAirtime(sf: 12, bwKhz: 125));
      for (var i = 1; i < sends.length; i++) {
        expect(sends[i].$1 - sends[i - 1].$1, greaterThanOrEqualTo(const Duration(seconds: 273)));
      }
    });
  });

  group('driving straight', () {
    for (final (kmh, every) in [(5.0, 300), (10.0, 300), (40.0, 120), (80.0, 60), (120.0, 60)]) {
      test('$kmh km/h sends every $every s', () {
        final sends = _drive(SmartBeacon(), kmh);
        expect(sends.first.$1, Duration.zero);
        expect(sends.first.$2.why, MtBeaconWhy.first);
        for (var i = 1; i < sends.length; i++) {
          expect((sends[i].$1 - sends[i - 1].$1).inSeconds, every, reason: 'gap $i');
          expect(sends[i].$2.why, MtBeaconWhy.interval);
        }
        expect(sends.length, 1 + 1800 ~/ every);
      });
    }

    test('speed derived from fixes when not reported', () {
      final sends = _drive(SmartBeacon(), 80, reportSpeed: false, duration: const Duration(minutes: 10));
      expect(sends.length, inInclusiveRange(10, 11));
    });

    test('low traffic halves the sends', () {
      expect(_drive(SmartBeacon(), 80, rate: MtRate.lowTraffic).length, 1 + 1800 ~/ 120);
    });

    test('two sharing groups: highway update every 2 min', () {
      final sends = _drive(SmartBeacon(), 100, groups: 2);
      expect((sends[2].$1 - sends[1].$1).inSeconds, 120);
    });
  });

  group('corner pegging', () {
    test('a 90 degree turn at 30 km/h sends early, at least 15 s after the last send', () {
      final sends = _drive(SmartBeacon(), 30, duration: const Duration(seconds: 100), course: (s) => s < 40 ? 90.0 : 180.0);
      expect(sends.length, 2);
      expect(sends[1].$2.why, MtBeaconWhy.corner);
      expect(sends[1].$1, const Duration(seconds: 40));
    });

    test('turn just after a send waits for the 15 s gap (and the 25.5 s floor)', () {
      final sends = _drive(SmartBeacon(), 30, duration: const Duration(seconds: 60), course: (s) => s < 5 ? 90.0 : 180.0);
      expect(sends[1].$2.why, MtBeaconWhy.corner);
      expect(sends[1].$1, const Duration(seconds: 26));
    });

    test('a gentle bend below the threshold does not send early', () {
      // 30 km/h threshold is 35 deg; a 30 deg bend stays on the 160 s interval
      final sends = _drive(SmartBeacon(), 30, duration: const Duration(seconds: 150), course: (s) => s < 40 ? 90.0 : 120.0);
      expect(sends.length, 1);
    });

    test('no corner rule below 10 km/h', () {
      final sends = _drive(SmartBeacon(), 8, duration: const Duration(seconds: 200), course: (s) => s < 40 ? 90.0 : 270.0);
      expect(sends.length, 1);
    });

    test('course wraps around north', () {
      expect(angleDiffDeg(350, 10), 20);
      expect(angleDiffDeg(10, 350), 20);
      expect(angleDiffDeg(0, 180), 180);
    });
  });

  group('parked', () {
    test('stopped: first, then one s0 after 90 s, then nothing', () {
      final b = SmartBeacon();
      final sends = _drive(b, 0, duration: const Duration(minutes: 30));
      expect(sends.length, 2);
      expect(sends[1].$2.parked, isTrue);
      expect(sends[1].$2.speedKmh, 0);
      expect(sends[1].$1, const Duration(seconds: 90));
      expect(b.parked, isTrue);
    });

    test('drive, park, drive again: resumes after moving more than 50 m', () {
      final b = SmartBeacon();
      final out = <(int, MtBeaconDecision)>[];
      var lon = -83.0;
      for (var s = 0; s < 1200; s++) {
        final moving = s < 300 || s >= 700;
        final now = _t0.add(Duration(seconds: s));
        final fix = MtFix(lat: 40, lon: lon, at: now, accuracyM: 5, speedMps: moving ? 15 : 0, courseDeg: 90);
        final d = b.decide(fix, now: now, positionAirtime: _sf7);
        if (d.send) {
          b.markSent(d, fix, now);
          out.add((s, d));
        }
        if (moving) lon += 15 / (111320.0 * math.cos(40 * math.pi / 180));
      }
      final parked = out.where((e) => e.$2.parked).toList();
      expect(parked.length, 1);
      expect(parked.single.$1, 390); // 90 s after stopping at 300
      // nothing between the s0 and moving again
      expect(out.where((e) => e.$1 > 390 && e.$1 < 700), isEmpty);
      final moved = out.firstWhere((e) => e.$1 >= 700);
      expect(moved.$2.why, MtBeaconWhy.moved);
      expect(moved.$1, inInclusiveRange(703, 706)); // 15 m/s: just past 50 m
      expect(b.parked, isFalse);
    });

    test('no heartbeat while parked (GPS jitter under 50 m)', () {
      final b = SmartBeacon();
      final rnd = math.Random(3);
      var n = 0;
      for (var s = 0; s < 7200; s++) {
        final now = _t0.add(Duration(seconds: s));
        final fix = MtFix(lat: 40 + (rnd.nextDouble() - 0.5) * 0.0003, lon: -83, at: now, speedMps: 0.3);
        final d = b.decide(fix, now: now, positionAirtime: _sf7);
        if (d.send) {
          b.markSent(d, fix, now);
          n++;
        }
      }
      expect(n, 2);
    });

    test('creeping at 1 km/h keeps to the slow interval (no burst of s0)', () {
      final sends = _drive(SmartBeacon(), 1, duration: const Duration(hours: 2));
      for (var i = 1; i < sends.length; i++) {
        expect(sends[i].$1 - sends[i - 1].$1, greaterThanOrEqualTo(const Duration(seconds: 90)), reason: 'gap $i');
      }
      expect(sends.length, lessThanOrEqualTo(1 + 7200 ~/ 300));
    });
  });

  test('restore undoes a send the budget refused', () {
    final b = SmartBeacon();
    final f = MtFix(lat: 40, lon: -83, at: _t0, speedMps: 20, courseDeg: 0);
    final d = b.decide(f, now: _t0);
    final mark = b.markSent(d, f, _t0);
    expect(b.lastSentAt, _t0);
    b.restore(mark);
    expect(b.lastSentAt, isNull);
    expect(b.decide(f, now: _t0.add(const Duration(seconds: 1))).why, MtBeaconWhy.first);
  });

  test('restart keeps the last-sent time: a share restarted inside the floor waits, then sends as first', () {
    final b = SmartBeacon();
    MtFix f(int s) => MtFix(lat: 40, lon: -83, at: _t0.add(Duration(seconds: s)), accuracyM: 5, speedMps: 14, courseDeg: 90);
    final d0 = b.decide(f(0), now: _t0, positionAirtime: _sf7);
    b.markSent(d0, f(0), _t0);
    b.restart();
    expect(b.decide(f(5), now: _t0.add(const Duration(seconds: 5)), positionAirtime: _sf7).send, isFalse);
    final d = b.decide(f(26), now: _t0.add(const Duration(seconds: 26)), positionAirtime: _sf7);
    expect(d.why, MtBeaconWhy.first, reason: 'past the floor the new share goes at once, not after the 72 s interval');
  });

  test('restore with a backoff waits the floor, then the refused send is still owed', () {
    final b = SmartBeacon();
    MtFix f(int s) => MtFix(lat: 40, lon: -83, at: _t0.add(Duration(seconds: s)), accuracyM: 5, speedMps: 14, courseDeg: 90);
    final d0 = b.decide(f(0), now: _t0, positionAirtime: _sf7);
    final mark = b.markSent(d0, f(0), _t0);
    b.restore(mark, backoffFrom: _t0);
    expect(b.decide(f(1), now: _t0.add(const Duration(seconds: 1)), positionAirtime: _sf7).send, isFalse);
    expect(b.decide(f(26), now: _t0.add(const Duration(seconds: 26)), positionAirtime: _sf7).send, isTrue);
  });
}
