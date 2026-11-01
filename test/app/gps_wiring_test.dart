// The app side of the GPS work: the drive owns the GPS stream (keepalive), the map gets every fix on `rawFixes`, the drive screen gets
// `gpsHealth`, the trace gets the health records, and the drive timing is read back from the trace.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_timing.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/radio/radio_api.dart';

import '../ui/fakes.dart';

Future<void> settle([int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('a drive keeps the GPS stream open, hands every fix to rawFixes, and shows health; stopping closes it all', () async {
    final h = Harness();
    await h.state.init();
    expect(await h.state.connectSimulator(), isTrue);
    final loc = h.simLocation; // the simulator radio uses the simulated location source
    expect(loc.fixController.hasListener, isFalse);
    final got = <GeoFix>[];
    final sub = h.state.rawFixes.listen(got.add);
    await h.state.startDrive();
    expect(loc.fixController.hasListener, isTrue, reason: 'nobody else listens (fake engine): the monitor is the keepalive');
    expect(h.state.gpsHealth.value.kind, GpsHealthKind.waiting);

    final now = h.clockNow;
    loc.fixController.add(GeoFix(lat: 40.126, lon: -82.93, accuracyM: 12, at: now));
    loc.fixController.add(GeoFix(lat: 40.1261, lon: -82.93, accuracyM: 12, at: now.add(const Duration(seconds: 1))));
    await settle();
    expect(got.length, 2);
    // Cached fix: not forwarded.
    loc.fixController.add(GeoFix(lat: 39.0, lon: -82.93, accuracyM: 30, at: now.subtract(const Duration(minutes: 3))));
    await settle();
    expect(got.length, 2);

    await Future<void>.delayed(const Duration(milliseconds: 1200)); // the monitor's once-a-second health tick
    expect(h.state.gpsHealth.value.kind, GpsHealthKind.good);

    final sid = h.state.currentSession!.id;
    await h.state.stopDrive();
    expect(loc.fixController.hasListener, isFalse);
    expect(h.state.gpsHealth.value.kind, GpsHealthKind.idle);
    final recs = h.store.traces[sid] ?? const [];
    expect(recs.where((r) => r['health'] == 'gps').map((r) => r['kind']), containsAllInOrder(['waiting', 'good']));
    expect(recs.where((r) => r['health'] == 'fix_drop'), isNotEmpty);
    await sub.cancel();
  });

  test('the drive timing is read back from the trace, and a drive without one has none', () async {
    final h = Harness();
    await h.state.init();
    final t = DriveTiming()..begin(Duration.zero, 15);
    t.sent(const Duration(seconds: 2), late: Duration.zero);
    t.sent(const Duration(seconds: 17), late: Duration.zero);
    await h.store.appendTrace('s1', {'v': 1, 'health': 'gps', 'kind': 'good'});
    await h.store.appendTrace('s1', {'v': 1, 'health': 'timing', ...t.summary(const Duration(seconds: 30)).toJson()});
    final back = await h.state.driveTimingFor('s1');
    expect(back!.sent, 2);
    expect(back.gapP50S, 15);
    expect(await h.state.driveTimingFor('none'), isNull);
  });

  test('driveHealthSink is a no-op outside a drive and a trace writer inside one', () async {
    final h = Harness();
    await h.state.init();
    expect(await h.state.connectSimulator(), isTrue);
    h.state.driveHealthSink.record('frame', {'late_ms': 5}); // must not throw
    await h.state.startDrive();
    final sid = h.state.currentSession!.id;
    h.state.driveHealthSink.record('frame', {'late_ms': 140});
    await settle();
    expect(h.store.traces[sid]!.any((r) => r['health'] == 'frame' && r['late_ms'] == 140), isTrue);
    await h.state.stopDrive();
  });
}
