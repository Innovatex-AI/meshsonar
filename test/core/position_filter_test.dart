// PositionFilter / FilteredLocationSource: a parked phone must not "drive around", a real car must still be followed.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/position_filter.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart' show haversineM;

const lat0 = 40.1262, lon0 = -82.9293;
const mLat = 111320.0;
final mLon = mLat * math.cos(lat0 * math.pi / 180);

/// Position [east]/[north] metres from the origin.
({double lat, double lon}) at(double east, double north) => (lat: lat0 + north / mLat, lon: lon0 + east / mLon);

double eastOf(GeoFix f) => (f.lon - lon0) * mLon;
double northOf(GeoFix f) => (f.lat - lat0) * mLat;

final t0 = DateTime.utc(2026, 10, 16, 18);

GeoFix fix(double east, double north, int sec, {double? acc = 5, double? speed}) {
  final p = at(east, north);
  return GeoFix(lat: p.lat, lon: p.lon, at: t0.add(Duration(seconds: sec)), accuracyM: acc, speedMps: speed);
}

void main() {
  group('poor fixes cannot freeze the dot', () {
    test('a 300 m-accurate fix does not make a 600 m parked bubble: driving off is followed within a few fixes', () {
      final f = PositionFilter();
      // Only poor fixes at first (accepted after 10 s), no speed (cell-tower location).
      GeoFix? out;
      for (var s = 0; s <= 12; s++) {
        out = f.add(fix(0, 0, s, acc: 299, speed: null)) ?? out;
      }
      expect(f.stationary, isFalse, reason: 'never parks on a position that bad');
      // Real GPS comes back and the car is moving east at 20 m/s: the output follows, not a frozen anchor.
      for (var s = 13; s <= 25; s++) {
        out = f.add(fix(20.0 * (s - 12), 0, s, acc: 6, speed: 20)) ?? out;
      }
      expect(eastOf(out!), greaterThan(200), reason: 'tracks the car, not frozen at the start');
    });

    test('the hold radius is capped at 40 m however bad the accuracy', () {
      final f = PositionFilter();
      f.add(fix(0, 0, 0, acc: 30, speed: 0));
      expect(f.stationary, isTrue);
      // 120 m away, three fixes each farther, with a 45 m accuracy that used to mean a 90 m radius: leaves the hold.
      f.add(fix(60, 0, 1, acc: 45, speed: null));
      f.add(fix(90, 0, 2, acc: 45, speed: null));
      final out = f.add(fix(130, 0, 3, acc: 45, speed: null));
      expect(f.stationary, isFalse);
      expect(eastOf(out!), greaterThan(60));
    });
  });

  group('parked phone with ±20 m GPS jitter for 10 minutes', () {
    for (final reportSpeed in [true, false]) {
      for (final seed in [1, 2, 3, 4, 5]) {
        test('speed ${reportSpeed ? 'reported 0' : 'unknown'}, seed $seed: holds still', () async {
          var now = t0;
          final sim =
              SimulatedLocationSource.parked(jitterM: 20, reportSpeed: reportSpeed, clock: () => now, seed: seed);
          final f = PositionFilter();
          final out = <GeoFix>[];
          var rawSpread = 0.0;
          GeoFix? firstRaw;
          for (var i = 0; i < 600; i++) {
            now = t0.add(Duration(seconds: i));
            final raw = (await sim.current())!;
            firstRaw ??= raw;
            rawSpread = math.max(rawSpread, haversineM(firstRaw.lat, firstRaw.lon, raw.lat, raw.lon));
            final o = f.add(raw);
            if (o != null) out.add(o);
          }
          expect(rawSpread, greaterThan(15), reason: 'the raw fixes really do wander');
          expect(out.length, 600);
          // Total movement of the filtered track, and how far it ever got from where it started.
          var path = 0.0, maxFromStart = 0.0;
          for (var i = 1; i < out.length; i++) {
            path += haversineM(out[i - 1].lat, out[i - 1].lon, out[i].lat, out[i].lon);
            maxFromStart = math.max(maxFromStart, haversineM(out[0].lat, out[0].lon, out[i].lat, out[i].lon));
          }
          expect(path, lessThan(3), reason: 'no movement beyond a few metres in total');
          expect(maxFromStart, lessThan(3));
          expect(out.every((o) => o.speedMps == 0), isTrue);
          // Accuracy is passed through untouched.
          expect(out.first.accuracyM, isNotNull);
          // The distance rule (≥ 15 m from the last ping) would never fire.
          var pings = 1;
          var anchor = out.first;
          for (final o in out) {
            if (haversineM(anchor.lat, anchor.lon, o.lat, o.lon) >= 15) {
              pings++;
              anchor = o;
            }
          }
          expect(pings, 1);
        });
      }
    }
  });

  test('harsher: ±30 m drift with an over-optimistic 5–8 m accuracy and no speed (parked iPhone) still holds', () async {
    for (var seed = 0; seed < 10; seed++) {
      var now = t0;
      final sim = SimulatedLocationSource(
          speedMps: 0, jitterM: 30, jitterAccuracyM: (min: 5.0, max: 8.0), reportSpeed: false, clock: () => now, seed: seed);
      final f = PositionFilter();
      GeoFix? first;
      for (var i = 0; i < 600; i++) {
        now = t0.add(Duration(seconds: i));
        final o = f.add((await sim.current())!)!;
        first ??= o;
        expect(haversineM(first.lat, first.lon, o.lat, o.lon), lessThan(3), reason: 'seed $seed fix $i');
      }
    }
  });

  test('car pulling away from a parked spot is followed within 2 fixes', () {
    final f = PositionFilter();
    final rng = math.Random(4);
    double j() => (rng.nextDouble() * 2 - 1) * 12;
    for (var i = 0; i < 60; i++) {
      final o = f.add(fix(j(), j(), i, acc: 10, speed: 0))!;
      expect(o.speedMps, 0);
    }
    expect(f.stationary, isTrue);
    final anchor = f.last!;
    // Accelerate north at 2.5 m/s², GPS reporting speed, small noise.
    var lagOk = 0;
    for (var k = 1; k <= 15; k++) {
      final speed = 2.5 * k;
      final north = 1.25 * k * k;
      final o = f.add(fix(j() / 4, north + j() / 4, 60 + k, acc: 5, speed: speed))!;
      if (k >= 2) {
        expect(f.stationary, isFalse, reason: 'moving by fix $k');
        expect(o.speedMps, closeTo(speed, 1e-9));
        final err = (northOf(o) - north).abs();
        expect(err, lessThan(math.max(6, speed * 0.4)), reason: 'little lag at fix $k (err $err m)');
        lagOk++;
      }
    }
    expect(lagOk, 14);
    expect(haversineM(anchor.lat, anchor.lon, f.last!.lat, f.last!.lon), greaterThan(200));
  });

  test('car pulling away with no speed reported is still followed (a few fixes later)', () {
    final f = PositionFilter();
    for (var i = 0; i < 30; i++) {
      f.add(fix(0, 0, i, acc: 8));
    }
    expect(f.stationary, isTrue);
    int? leftAt;
    for (var k = 1; k <= 20; k++) {
      final o = f.add(fix(0, 1.5 * k * k, 30 + k, acc: 8))!;
      if (leftAt == null && northOf(o) > 1) leftAt = k;
    }
    expect(leftAt, isNotNull);
    expect(leftAt, lessThanOrEqualTo(8));
    expect(f.stationary, isFalse);
    expect((northOf(f.last!) - 1.5 * 400).abs(), lessThan(30));
  });

  test('90° turn at 13 m/s is not overshot', () {
    final f = PositionFilter();
    final rng = math.Random(11);
    double n() => (rng.nextDouble() * 2 - 1) * 2;
    var maxEast = double.negativeInfinity;
    var maxErr = 0.0;
    for (var i = 0; i <= 40; i++) {
      // East for 20 s (to x = 260 m), then north.
      final x = i <= 20 ? 13.0 * i : 260.0;
      final y = i <= 20 ? 0.0 : 13.0 * (i - 20);
      final o = f.add(fix(x + n(), y + n(), i, acc: 5, speed: 13))!;
      maxEast = math.max(maxEast, eastOf(o));
      if (i > 2) maxErr = math.max(maxErr, haversineM(o.lat, o.lon, at(x, y).lat, at(x, y).lon));
    }
    expect(maxEast, lessThan(260 + 3), reason: 'no overshoot past the corner');
    expect(maxErr, lessThan(8), reason: 'stays close to the road');
  });

  test('steady driving: output tracks the truth closely', () {
    final f = PositionFilter();
    for (var i = 0; i < 60; i++) {
      final o = f.add(fix(0, 15.0 * i, i, acc: 5, speed: 15))!;
      if (i > 2) expect((northOf(o) - 15.0 * i).abs(), lessThan(4));
    }
  });

  test('stopping at a light: holds still, then moves off again', () {
    final f = PositionFilter();
    for (var i = 0; i < 10; i++) {
      f.add(fix(0, 13.0 * i, i, speed: 13));
    }
    expect(f.stationary, isFalse);
    final rng = math.Random(2);
    for (var i = 10; i < 40; i++) {
      f.add(fix((rng.nextDouble() - 0.5) * 20, 130 + (rng.nextDouble() - 0.5) * 20, i, acc: 8, speed: 0));
    }
    expect(f.stationary, isTrue);
    final held = f.last!;
    expect((northOf(held) - 130).abs(), lessThan(15));
    f.add(fix(0, 133, 40, speed: 3));
    f.add(fix(0, 139, 41, speed: 6));
    expect(f.stationary, isFalse);
    expect(northOf(f.last!), closeTo(139, 3));
  });

  test('poor-accuracy fixes are dropped while good ones are recent, used after a drought', () {
    final f = PositionFilter();
    f.add(fix(0, 0, 0, acc: 5, speed: 10));
    expect(f.add(fix(0, 400, 1, acc: 120, speed: 10)), isNull);
    expect(f.add(fix(0, 400, 9, acc: 120, speed: 10)), isNull);
    final late = f.add(fix(0, 100, 11, acc: 80, speed: 10));
    expect(late, isNotNull, reason: 'nothing better for 10 s');
    expect(late!.accuracyM, 80, reason: 'original accuracy kept');
  });

  test('unknown accuracy and nonsense speeds do not break it', () {
    final f = PositionFilter();
    expect(f.add(fix(0, 0, 0, acc: null, speed: -1)), isNotNull);
    expect(f.add(fix(1, 1, 0, acc: 0, speed: double.nan)), isNotNull, reason: 'same timestamp is fine');
    expect(f.add(fix(1, 1, -5, acc: 5)), isNotNull, reason: 'time going backwards is fine');
  });

  group('FilteredLocationSource', () {
    test('shares one filter between listeners and current()', () async {
      final inner = _ManualGps();
      var now = t0;
      final src = FilteredLocationSource(inner, clock: () => now);
      final a = <GeoFix>[], b = <GeoFix>[];
      final sa = src.fixes.listen(a.add);
      final sb = src.fixes.listen(b.add);
      expect(inner.listeners, 1, reason: 'one GPS stream however many listeners');
      final rng = math.Random(3);
      for (var i = 0; i < 30; i++) {
        now = t0.add(Duration(seconds: i));
        inner.emit(fix((rng.nextDouble() - 0.5) * 30, (rng.nextDouble() - 0.5) * 30, i, acc: 10, speed: 0));
        await Future<void>.delayed(Duration.zero);
      }
      expect(a.length, 30);
      expect(b.length, 30);
      final cur = (await src.current())!;
      expect(cur.lat, a.last.lat);
      expect(cur.lon, a.last.lon);
      expect(a.map((f) => '${f.lat},${f.lon}').toSet().length, 1, reason: 'parked: one position');
      expect(inner.currentCalls, 0, reason: 'fresh filtered fix used');
      // Stale: asks the GPS, and still filters.
      now = now.add(const Duration(seconds: 10));
      inner.next = fix(8, 8, 40, acc: 10, speed: 0);
      final c2 = (await src.current())!;
      expect(inner.currentCalls, 1);
      expect(c2.lat, a.last.lat, reason: 'jitter inside the hold radius is ignored');
      await sa.cancel();
      await sb.cancel();
      expect(inner.listeners, 0);
      expect(await src.ensurePermission(), isTrue);
    });

    test('no fix at all → null', () async {
      final src = FilteredLocationSource(_ManualGps());
      expect(await src.current(), isNull);
    });
  });
}

class _ManualGps implements LocationSource {
  final _c = StreamController<GeoFix>.broadcast();
  int listeners = 0;
  int currentCalls = 0;
  GeoFix? next;
  _ManualGps() {
    _c.onListen = () => listeners++;
    _c.onCancel = () => listeners--;
  }
  void emit(GeoFix f) => _c.add(f);
  @override
  Stream<GeoFix> get fixes => _c.stream;
  @override
  Future<GeoFix?> current() async {
    currentCalls++;
    return next;
  }

  @override
  Future<bool> ensurePermission() async => true;
}
