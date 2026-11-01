import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_health_sink.dart';
import 'package:meshsonar/core/drive_timing.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/core/startup_location.dart';

Duration s(num x) => Duration(milliseconds: (x * 1000).round());

void main() {
  group('GPS health lines', () {
    test('waiting for the first usable fix shows a timer; a coarse best-so-far is mentioned', () {
      final h = computeGpsHealth(sinceStart: s(12), haveUsableFix: false);
      expect(h.kind, GpsHealthKind.waiting);
      expect(h.line, 'Waiting for GPS (12 s)');
      final c = computeGpsHealth(sinceStart: s(5), fixAge: s(1), accuracyM: 120, haveUsableFix: false);
      expect(c.line, 'Waiting for GPS (5 s) (best so far ±120 m)');
    });

    test('weak, good and no-fix', () {
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(1), accuracyM: 47.2, haveUsableFix: true).line, 'GPS weak (47 m)');
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(1), accuracyM: 6, haveUsableFix: true).kind, GpsHealthKind.good);
      final n = computeGpsHealth(sinceStart: s(60), fixAge: s(8), accuracyM: 6, haveUsableFix: true);
      expect(n.kind, GpsHealthKind.noFix);
      expect(n.line, 'No GPS for 8 s');
      expect(n.advice, isNull);
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(25), haveUsableFix: true).advice, contains('Location is on'));
    });

    test('a fix 7.9 s old is still fine, 8 s is not', () {
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(7.9), accuracyM: 6, haveUsableFix: true).kind, GpsHealthKind.good);
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(8), accuracyM: 6, haveUsableFix: true).kind, GpsHealthKind.noFix);
    });

    test('lengths follow the units setting (feet for imperial)', () {
      String ft(double m) => '${(m / 0.3048).round()} ft';
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(1), accuracyM: 47, haveUsableFix: true, distance: ft).line, 'GPS weak (154 ft)');
      expect(computeGpsHealth(sinceStart: s(5), fixAge: s(1), accuracyM: 120, haveUsableFix: false, distance: ft).line, contains('±394 ft'));
    });

    test('Precise Location off is its own state with the Settings action', () {
      final h = computeGpsHealth(sinceStart: s(3), fixAge: s(1), accuracyM: 1500, haveUsableFix: false, access: LocationAccess.approximate);
      expect(h.kind, GpsHealthKind.approximate);
      expect(h.line, 'Precise Location is off.');
      expect(h.advice, contains('Settings > MeshSonar > Location'));
      expect(h.action, GpsHealthAction.openAppSettings);
    });

    test('permission and services states', () {
      for (final a in [LocationAccess.denied, LocationAccess.deniedForever, LocationAccess.restricted, LocationAccess.notAsked]) {
        final h = computeGpsHealth(sinceStart: s(3), haveUsableFix: false, access: a);
        expect(h.kind, GpsHealthKind.noPermission);
        expect(h.action, GpsHealthAction.openAppSettings);
      }
      final off = computeGpsHealth(sinceStart: s(3), haveUsableFix: false, access: LocationAccess.servicesOff);
      expect(off.action, GpsHealthAction.openLocationSettings);
    });

    test('While Using adds the Always advice for background drives, on any healthy state', () {
      final h = computeGpsHealth(
          sinceStart: s(60), fixAge: s(1), accuracyM: 6, haveUsableFix: true, background: BackgroundLocation.whileUsing);
      expect(h.kind, GpsHealthKind.good);
      expect(h.advice, contains('Always'));
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(1), accuracyM: 6, haveUsableFix: true, background: BackgroundLocation.always).advice, isNull);
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(1), accuracyM: 6, haveUsableFix: true).advice, isNull, reason: 'Android: not applicable');
    });

    test('equality is by words and state, so the UI is only told on a change', () {
      final a = computeGpsHealth(sinceStart: s(60), fixAge: s(1), accuracyM: 6.1, haveUsableFix: true);
      final b = computeGpsHealth(sinceStart: s(61), fixAge: s(2), accuracyM: 6.4, haveUsableFix: true);
      expect(a, b, reason: 'same line "GPS good (6 m)"');
      expect(a.needsAttention, isFalse);
      expect(computeGpsHealth(sinceStart: s(60), fixAge: s(1), accuracyM: 40, haveUsableFix: true).needsAttention, isTrue);
    });
  });

  group('drive timing', () {
    test('gaps, lateness, expected, held-back episodes', () {
      final t = DriveTiming()..begin(s(0), 15);
      t.sent(s(0), late: Duration.zero);
      t.sent(s(15), late: Duration.zero);
      t.sent(s(31), late: s(1), lowAccuracy: true);
      t.sent(s(45), late: Duration.zero);
      t.skipped('no_fix');
      t.skipped('no_fix');
      t.skipped('distance');
      final sum = t.summary(s(60));
      expect(sum.sent, 4);
      expect(sum.expected, 4);
      expect(sum.gapP50S, 15);
      expect(sum.gapMaxS, 16);
      expect(sum.lateMaxS, 1);
      expect(sum.lowAccuracyPings, 1);
      expect(sum.skipped, {'no_fix': 2, 'distance': 1});
      expect(sum.line, 'Sent 4 of 4 expected. typical gap 15 s, worst 16 s');
      expect(sum.skippedLine, 'Held back: 2x waiting for GPS, 1x waiting to move');
    });

    test('an interval change mid-drive banks what the old interval expected', () {
      final t = DriveTiming()..begin(s(0), 15);
      t.intervalChanged(s(60), 30); // 4 expected so far
      expect(t.summary(s(120)).expected, 6);
    });

    test('round trip through the trace record', () {
      final t = DriveTiming()..begin(s(0), 15);
      t.sent(s(2), late: Duration.zero);
      t.sent(s(17), late: s(0.5));
      t.skipped('first_fix');
      final j = t.summary(s(30)).toJson();
      final back = timingFromJson(j);
      expect(back.sent, 2);
      expect(back.skipped, {'first_fix': 1});
      expect(back.gapMaxS, 15);
      expect(back.firstPingS, 2);
    });

    test('nothing sent says so', () {
      expect((DriveTiming()..begin(s(0), 15)).summary(s(5)).line, 'No pings were sent.');
    });
  });

  group('drive health sink', () {
    test('records are flat, stamped and rate limited per kind; a failing writer never throws', () {
      final out = <Map<String, Object?>>[];
      var now = DateTime.utc(2026, 11, 1, 14, 30);
      final sink = TraceDriveHealthSink(out.add, clock: () => now);
      for (var i = 0; i < 10; i++) {
        sink.record('frame', {'late_ms': i});
      }
      expect(out.length, 4, reason: 'at most 4 per second per kind');
      expect(out.first, {'v': 1, 'health': 'frame', 'at': '2026-11-01T14:30:00.000Z', 'late_ms': 0});
      sink.record('gps', {'kind': 'weak'});
      expect(out.length, 5, reason: 'another kind has its own budget');
      now = now.add(const Duration(seconds: 1));
      sink.record('frame', {'late_ms': 99});
      expect(out.length, 6);
      TraceDriveHealthSink((_) => throw StateError('disk full'), clock: () => now).record('x', {});
      const NullDriveHealthSink().record('x', {});
    });
  });
}
