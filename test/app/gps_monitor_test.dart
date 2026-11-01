import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/gps_monitor.dart';
import 'package:meshsonar/core/drive_health_sink.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/radio/radio_api.dart';

final t0 = DateTime.utc(2026, 11, 1, 14, 30);

class _Gps implements LocationSource {
  final c = StreamController<GeoFix>.broadcast();
  int listens = 0;
  @override
  Stream<GeoFix> get fixes => c.stream;
  @override
  Future<GeoFix?> current() async => null;
  @override
  Future<bool> ensurePermission() async => true;
}

class _Sink implements DriveHealthSink {
  final records = <(String, Map<String, Object?>)>[];
  @override
  void record(String kind, Map<String, Object?> data) => records.add((kind, data));
}

void main() {
  test('keeps the stream open, forwards every fix with a derived speed, refuses a cached one, and reports health only when it changes', () {
    fakeAsync((fa) {
      final gps = _Gps();
      final fixes = <GeoFix>[];
      final healths = <GpsHealth>[];
      final sink = _Sink();
      var pinged = false;
      final m = GpsMonitor(
        location: gps,
        clock: () => t0.add(fa.elapsed),
        mono: () => fa.elapsed,
        onFix: fixes.add,
        onHealth: healths.add,
        sink: sink,
        firstPingPending: () => !pinged,
      );
      m.start();
      fa.flushMicrotasks();
      expect(gps.c.hasListener, isTrue, reason: 'the keepalive: someone is always listening during a drive');

      // Nothing yet: "Waiting for GPS" with a timer, told to the UI at most every 1.5 s.
      fa.elapse(const Duration(seconds: 5));
      expect(healths.last.kind, GpsHealthKind.waiting);
      expect(healths.length, lessThanOrEqualTo(4));

      // The cached first fix is refused.
      gps.c.add(GeoFix(lat: 40.1, lon: -82.9, accuracyM: 30, at: t0.subtract(const Duration(seconds: 120))));
      fa.flushMicrotasks();
      expect(fixes, isEmpty);
      expect(m.cachedRefused, 1);
      expect(sink.records.any((r) => r.$1 == 'fix_drop'), isTrue);

      // A coarse fix: still waiting (the first ping needs 50 m).
      gps.c.add(GeoFix(lat: 40.1, lon: -82.9, accuracyM: 80, at: t0.add(fa.elapsed)));
      fa.elapse(const Duration(seconds: 2));
      expect(healths.last.kind, GpsHealthKind.waiting);
      expect(healths.last.line, contains('best so far ±80 m'));

      // A fine fix: good.
      gps.c.add(GeoFix(lat: 40.1, lon: -82.9, accuracyM: 12, at: t0.add(fa.elapsed)));
      fa.elapse(const Duration(seconds: 2));
      expect(healths.last.kind, GpsHealthKind.good);
      pinged = true;

      // Moving fixes at 10 m/s with no OS speed: the forwarded fixes carry a derived one.
      for (var i = 0; i < 10; i++) {
        gps.c.add(GeoFix(lat: 40.1 + (i * 10) / 111320.0, lon: -82.9, accuracyM: 12, at: t0.add(fa.elapsed)));
        fa.elapse(const Duration(seconds: 1));
      }
      expect(fixes.length, 12);
      expect(fixes.last.speedMps, closeTo(10, 2));
      expect(m.fixes, 12);

      // Poor fixes: weak.
      gps.c.add(GeoFix(lat: 40.1 + 100 / 111320.0, lon: -82.9, accuracyM: 47, at: t0.add(fa.elapsed)));
      fa.elapse(const Duration(seconds: 2));
      expect(healths.last.line, 'GPS weak (47 m)');

      // Silence: after 8 s, "No GPS for 8 s", at once (kind changes are not throttled).
      fa.elapse(const Duration(seconds: 9));
      expect(healths.last.kind, GpsHealthKind.noFix);
      expect(healths.last.line, startsWith('No GPS for '));

      // A fix and it recovers.
      gps.c.add(GeoFix(lat: 40.1, lon: -82.9, accuracyM: 9, at: t0.add(fa.elapsed)));
      fa.elapse(const Duration(seconds: 2));
      expect(healths.last.kind, GpsHealthKind.good);

      // Over the whole drive the UI was told a handful of times, not once per fix or per second.
      expect(healths.length, lessThan(25));
      expect(sink.records.where((r) => r.$1 == 'gps').length, greaterThanOrEqualTo(4), reason: 'kind changes land in the trace');

      unawaited(m.stop());
      fa.flushMicrotasks();
      expect(healths.last.kind, GpsHealthKind.idle);
      expect(gps.c.hasListener, isFalse);
    });
  });

  test('Precise Location off shows the prompt, and it clears when the person turns it on (re-read every 5 s while there is no fix)', () {
    fakeAsync((fa) {
      final gps = _Gps();
      var access = LocationAccess.approximate;
      final healths = <GpsHealth>[];
      final m = GpsMonitor(
        location: gps,
        clock: () => t0.add(fa.elapsed),
        mono: () => fa.elapsed,
        onHealth: healths.add,
        access: () async => access,
        background: () async => BackgroundLocation.whileUsing,
      );
      m.start();
      fa.elapse(const Duration(seconds: 2));
      expect(healths.last.kind, GpsHealthKind.approximate);
      expect(healths.last.action, GpsHealthAction.openAppSettings);
      access = LocationAccess.granted;
      fa.elapse(const Duration(seconds: 7));
      expect(healths.last.kind, GpsHealthKind.waiting);
      expect(healths.last.advice, contains('While Using'), reason: 'the background permission advice rides along');
      gps.c.add(GeoFix(lat: 40.1, lon: -82.9, accuracyM: 10, at: t0.add(fa.elapsed)));
      fa.elapse(const Duration(seconds: 2));
      expect(healths.last.kind, GpsHealthKind.good);
      expect(healths.last.advice, contains('Always'));
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });

  test('a throwing listener never reaches the GPS', () {
    fakeAsync((fa) {
      final gps = _Gps();
      final m = GpsMonitor(location: gps, clock: () => t0.add(fa.elapsed), mono: () => fa.elapsed, onFix: (_) => throw StateError('puck'), onHealth: (_) => throw StateError('ui'));
      m.start();
      gps.c.add(GeoFix(lat: 40.1, lon: -82.9, accuracyM: 10, at: t0));
      fa.elapse(const Duration(seconds: 3));
      expect(m.fixes, 1);
      unawaited(m.dispose());
      fa.flushMicrotasks();
    });
  });
}
