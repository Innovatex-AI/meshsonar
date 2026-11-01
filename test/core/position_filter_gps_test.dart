// The filter against Andy's GPS (Nov 1 2026): 35-46 m accuracy, no speed, a cached first fix. Before: it took a 10 m/s car for parked
// (hold radius saturates at 40 m), froze the dot at an anchor for ~9 s at a time and let a position-only blend lag the car 40-60 m.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/position_filter.dart';
import 'package:meshsonar/radio/radio_api.dart';

const _lat0 = 40.1262, _lon0 = -82.9312;
final t0 = DateTime.utc(2026, 11, 1, 14, 30);

GeoFix raw(int s, double northM, double acc, {double? speed, double? course, double eastM = 0}) => GeoFix(
    lat: _lat0 + northM / 111320.0,
    lon: _lon0 + eastM / (111320.0 * math.cos(_lat0 * math.pi / 180)),
    accuracyM: acc,
    speedMps: speed,
    courseDeg: course,
    at: t0.add(Duration(seconds: s)));

double northErr(GeoFix out, double truthNorthM) => ((out.lat - _lat0) * 111320.0 - truthNorthM).abs();

void main() {
  test('a car at 10 m/s with 35-46 m fixes and no speed is followed: never frozen in a parked hold, error far below the accuracy', () {
    final f = PositionFilter();
    final rng = math.Random(3);
    final errs = <double>[];
    var heldAfterWarmup = 0;
    for (var s = 0; s < 300; s++) {
      final acc = 35 + rng.nextInt(12).toDouble();
      final e = acc * 0.7 * rng.nextDouble(), a = rng.nextDouble() * 2 * math.pi;
      final o = f.add(raw(s, s * 10.0 + e * math.cos(a), acc, eastM: e * math.sin(a)));
      if (o == null || s < 30) continue;
      errs.add(northErr(o, s * 10.0));
      if (f.stationary) heldAfterWarmup++;
    }
    errs.sort();
    expect(errs[errs.length ~/ 2], lessThan(8));
    expect(errs[(errs.length * .95).floor()], lessThan(25));
    expect(heldAfterWarmup, 0, reason: 'a moving car is never "parked"');
  });

  test('fixes of 52-70 m pass (they used to be dropped at 50 m), 150 m ones are dropped while a good one is recent', () {
    final f = PositionFilter();
    expect(f.add(raw(0, 0, 40)), isNotNull);
    expect(f.add(raw(1, 10, 65)), isNotNull);
    expect(f.add(raw(2, 20, 99)), isNotNull);
    expect(f.add(raw(3, 30, 150)), isNull);
    expect(f.add(raw(14, 140, 150)), isNotNull, reason: 'after 10 s with nothing better, anything is used so the dot has a position');
  });

  test('a parked phone with 40 m of jitter and no speed holds one position (the hold needs several still fixes, not three)', () {
    final f = PositionFilter();
    final rng = math.Random(8);
    GeoFix? last;
    final seen = <GeoFix>[];
    for (var s = 0; s < 120; s++) {
      final o = f.add(raw(s, (rng.nextDouble() - .5) * 40, 40 + rng.nextInt(6).toDouble(), eastM: (rng.nextDouble() - .5) * 40));
      if (o != null && s > 30) seen.add(o);
      last = o;
    }
    expect(last, isNotNull);
    expect(f.stationary, isTrue);
    final lats = seen.map((x) => x.lat).toSet();
    expect(lats.length, lessThanOrEqualTo(3), reason: 'the reported position barely moves');
  });

  test('speed and course the OS reports prime the velocity: a straight 13 m/s run tracks within a few metres', () {
    final f = PositionFilter();
    final errs = <double>[];
    for (var s = 0; s < 120; s++) {
      final o = f.add(raw(s, s * 13.0, 30, speed: 13, course: 0));
      if (o != null && s > 10) errs.add(northErr(o, s * 13.0));
    }
    errs.sort();
    expect(errs.last, lessThan(10));
  });

  test('FilteredLocationSource: a cached first fix never seeds the filter and is counted', () async {
    final raws = StreamController<GeoFix>.broadcast();
    var now = t0;
    final src = FilteredLocationSource(_Src(raws.stream), clock: () => now);
    final got = <GeoFix>[];
    final sub = src.fixes.listen(got.add);
    await Future<void>.delayed(Duration.zero);
    raws.add(GeoFix(lat: _lat0 - 0.011, lon: _lon0, accuracyM: 30, at: t0.subtract(const Duration(seconds: 120)))); // cached, 1.2 km back
    await Future<void>.delayed(Duration.zero);
    expect(got, isEmpty);
    expect(src.staleDropped, 1);
    now = t0.add(const Duration(seconds: 2));
    raws.add(GeoFix(lat: _lat0, lon: _lon0, accuracyM: 12, at: now));
    await Future<void>.delayed(Duration.zero);
    expect(got.single.lat, closeTo(_lat0, 1e-6), reason: 'the first output is the real position');
    await sub.cancel();
    await raws.close();
  });
}

class _Src implements LocationSource {
  final Stream<GeoFix> s;
  _Src(this.s);
  @override
  Stream<GeoFix> get fixes => s;
  @override
  Future<GeoFix?> current() async => null;
  @override
  Future<bool> ensurePermission() async => true;
}
