// A realistic recorded-car-route generator for the map and puck benchmarks and tests. Pure Dart, deterministic for a seed.
//
// The truth is a car driving ~15 m/s along straight legs joined by turns (slowing to ~6 m/s through each turn, 25 m
// radius), with a red-light stop every few minutes. The measured fixes are what an iPhone would report: 1 Hz, position
// noise that follows the reported accuracy (5..45 m, a slow random walk, bad before and after a dip), speed and course from
// the truth with a little error (course unknown below 0.5 m/s), and signal dips of 3..8 s where no fix arrives at all.
import 'dart:math' as math;

import 'package:meshsonar/radio/radio_api.dart';

const double _mPerDegLat = 111320.0;

class RouteSample {
  /// Seconds since the route start.
  final int t;

  /// The true position of the car (what a perfect receiver would say).
  final double trueLat, trueLon, trueSpeed, trueCourse;

  /// The fix the phone reports, null while the signal is down.
  final GeoFix? fix;
  const RouteSample(this.t, this.trueLat, this.trueLon, this.trueSpeed, this.trueCourse, this.fix);
}

class GpsRoute {
  final List<RouteSample> samples;
  const GpsRoute(this.samples);

  int get seconds => samples.length;
  Iterable<GeoFix> get fixes sync* {
    for (final s in samples) {
      if (s.fix != null) yield s.fix!;
    }
  }

  /// Signal dips as (start second, length seconds).
  List<(int, int)> get dips {
    final out = <(int, int)>[];
    int? start;
    for (final s in samples) {
      if (s.fix == null && start == null) start = s.t;
      if (s.fix != null && start != null) {
        out.add((start, s.t - start));
        start = null;
      }
    }
    if (start != null) out.add((start, samples.last.t + 1 - start));
    return out;
  }

  /// A GPX 1.1 file of the measured fixes (for `xcrun simctl location <udid> run`).
  String toGpx() {
    final b = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<gpx version="1.1" creator="meshsonar-bench" xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>\n');
    for (final f in fixes) {
      b.write('<trkpt lat="${f.lat.toStringAsFixed(7)}" lon="${f.lon.toStringAsFixed(7)}"><time>${f.at.toUtc().toIso8601String()}</time></trkpt>\n');
    }
    b.write('</trkseg></trk></gpx>\n');
    return b.toString();
  }

  /// Generates [seconds] of driving from ([lat], [lon]).
  factory GpsRoute.generate({
    int seconds = 1200,
    int seed = 7,
    double lat = 40.126,
    double lon = -82.93,
    double cruiseMps = 15,
    DateTime? start,
    bool dips = true,
  }) {
    final rnd = math.Random(seed);
    final t0 = start ?? DateTime.utc(2026, 11, 1, 12);
    final out = <RouteSample>[];
    var y = 0.0, x = 0.0; // metres north/east of the start
    var course = 20.0; // degrees clockwise from north
    var speed = 0.0;
    var legLeft = 400.0; // metres until the next turn
    var turnLeft = 0.0; // degrees of turn still to make
    var turnDir = 1.0;
    var stopLeft = 0; // seconds of red light left
    var nextStop = 150 + rnd.nextInt(120);
    var acc = 8.0;
    var nx = 0.0, ny = 0.0; // AR(1) position error
    var dipLeft = 0;
    var nextDip = 60 + rnd.nextInt(60);
    var dipRecover = 0;
    for (var t = 0; t < seconds; t++) {
      // --- truth ---
      double target;
      if (stopLeft > 0) {
        target = 0;
        stopLeft--;
      } else if (turnLeft.abs() > 0) {
        target = 6;
      } else {
        target = cruiseMps + 2.5 * math.sin(t / 40.0);
      }
      if (t > 0 && t == nextStop) {
        stopLeft = 12 + rnd.nextInt(18);
        nextStop = t + 150 + rnd.nextInt(150);
        target = 0;
      }
      final a = target > speed ? 2.5 : -4.0;
      speed = a > 0 ? math.min(target, speed + a) : math.max(target, speed + a);
      if (speed < 0.05) speed = 0;
      if (speed > 0.5) {
        if (turnLeft.abs() > 0) {
          final step = math.min(turnLeft.abs(), 90.0 / 4.0) * (turnLeft < 0 ? -1 : 1);
          course = (course + step + 360) % 360;
          turnLeft -= step;
          if (turnLeft.abs() < 0.5) turnLeft = 0;
        } else {
          // gentle road curvature
          course = (course + (rnd.nextDouble() - 0.5) * 1.2 + 360) % 360;
        }
        legLeft -= speed;
        if (legLeft <= 0 && turnLeft == 0) {
          turnDir = rnd.nextBool() ? 1 : -1;
          turnLeft = turnDir * 90.0;
          legLeft = 300 + rnd.nextInt(900).toDouble();
        }
      }
      final r = course * math.pi / 180;
      y += math.cos(r) * speed;
      x += math.sin(r) * speed;
      final tLat = lat + y / _mPerDegLat;
      final tLon = lon + x / (_mPerDegLat * math.cos(lat * math.pi / 180));

      // --- the receiver ---
      if (dips && dipLeft == 0 && t == nextDip) {
        dipLeft = 3 + rnd.nextInt(6);
        nextDip = t + 80 + rnd.nextInt(80);
        dipRecover = 3;
      }
      final inDip = dipLeft > 0;
      if (inDip) dipLeft--;
      final wantAcc = inDip || dipRecover > 0 ? 40.0 : (speed < 0.5 ? 12.0 : 7.0);
      acc = (acc + (wantAcc - acc) * 0.35 + (rnd.nextDouble() - 0.5) * 4).clamp(5.0, 45.0);
      if (!inDip && dipRecover > 0) dipRecover--;
      final sigma = acc / 2.2;
      nx = 0.8 * nx + 0.6 * sigma * _gauss(rnd);
      ny = 0.8 * ny + 0.6 * sigma * _gauss(rnd);
      GeoFix? fix;
      if (!inDip) {
        final mLat = tLat + ny / _mPerDegLat;
        final mLon = tLon + nx / (_mPerDegLat * math.cos(lat * math.pi / 180));
        final repSpeed = math.max(0.0, speed + 0.25 * _gauss(rnd));
        fix = GeoFix(
          lat: mLat,
          lon: mLon,
          at: t0.add(Duration(seconds: t)),
          accuracyM: acc,
          speedMps: repSpeed,
          courseDeg: speed < 0.5 ? null : (course + 3 * _gauss(rnd) + 360) % 360,
        );
      }
      out.add(RouteSample(t, tLat, tLon, speed, course, fix));
    }
    return GpsRoute(out);
  }
}

double _gauss(math.Random r) {
  final u1 = 1 - r.nextDouble(), u2 = r.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

/// Metres between two points (flat earth; fine for the short distances the tests use).
double routeDistM(double lat1, double lon1, double lat2, double lon2) {
  final dy = (lat2 - lat1) * _mPerDegLat;
  final dx = (lon2 - lon1) * _mPerDegLat * math.cos((lat1 + lat2) / 2 * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}
