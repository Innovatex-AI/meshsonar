// Auto-ping cadence: a ping goes out once BOTH intervalSec has passed since the last ping AND we've moved minDistanceM
// from it. The engine runs on a fake clock and a hand-driven GPS; the radio is the simulator (real frames), with short
// listen windows so the test runs in real time quickly.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/position_filter.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

const lat0 = 40.1262, lon0 = -82.9293;
const mLat = 111320.0;
final mLon = mLat * math.cos(lat0 * math.pi / 180);
final t0 = DateTime.utc(2026, 10, 16, 18);
const window = Duration(milliseconds: 40);

/// GPS driven by the test: [north] metres north of the start, at the fake time.
class HandGps implements LocationSource {
  final DateTime Function() clock;
  double north = 0, east = 0;
  double? speed;
  bool hasFix = true;
  // sync: a fix is in the engine's window the instant emit() returns, so a 5 ms tick can never see the new fake time without it.
  final _c = StreamController<GeoFix>.broadcast(sync: true);
  HandGps(this.clock);

  GeoFix get fix =>
      GeoFix(lat: lat0 + north / mLat, lon: lon0 + east / mLon, at: clock(), accuracyM: 5, speedMps: speed);
  void emit() {
    if (hasFix) _c.add(fix);
  }

  @override
  Stream<GeoFix> get fixes => _c.stream;
  @override
  Future<GeoFix?> current() async => hasFix ? fix : null;
  @override
  Future<bool> ensurePermission() async => true;
}

class Cad {
  DateTime now = t0;
  late final HandGps gps = HandGps(() => now);
  late final SimulatedTransport radio;
  late final MeshCoreCompanionLink link;
  late final DefaultWardriveEngine engine;
  final pings = <DrivePing>[];
  final statuses = <EngineStatus>[];

  Cad({LocationSource Function(HandGps gps)? wrap}) {
    radio = SimulatedTransport(location: SimulatedLocationSource(speedMps: 0), seed: 3, timeScale: 40);
    link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
    var n = 0;
    engine = DefaultWardriveEngine(
      link: link,
      location: wrap == null ? gps : wrap(gps),
      clock: () => now,
      newId: () => 'p${n++}',
      tick: const Duration(milliseconds: 5),
    );
    engine.pings.listen(pings.add);
    engine.status.listen(statuses.add);
  }

  int get sent => radio.sentFrames.where((f) => f[0] == 3).length;

  Future<void> start({int intervalSec = 10, int minDistanceM = 100}) async {
    await link.start();
    await engine.start(
        WardriveConfig(intervalSec: intervalSec, minDistanceM: minDistanceM, listenWindow: window));
    await settle();
  }

  /// Lets ticks run and any ping finish its (short, real-time) listen window.
  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 120));

  /// Moves the fake clock by [secs] and the car north by [metres], one GPS fix per second.
  Future<void> drive(int secs, {double metres = 0}) async {
    for (var i = 0; i < secs; i++) {
      now = now.add(const Duration(seconds: 1));
      gps.north += metres / secs;
      gps.emit();
      await Future<void>.delayed(const Duration(milliseconds: 15));
      // Hold the fake clock while a ping is on the air, so its timestamp is the second it was due.
      while (engine.current.state == EngineState.pinging) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    await settle();
  }
}

void main() {
  test('first ping as soon as the drive starts', () async {
    final c = Cad();
    await c.start();
    expect(c.sent, 1);
    expect(c.pings, hasLength(1));
    expect(c.engine.current.waitingFor, PingWait.time);
    expect(c.engine.current.nextPingAt, t0.add(const Duration(seconds: 10)));
    expect(c.engine.current.metresToGo, 100);
    await c.engine.stop();
  });

  test('interval passed but not moved far enough: waits for distance, pings the moment it is reached', () async {
    final c = Cad();
    await c.start(intervalSec: 10, minDistanceM: 100);
    await c.drive(15, metres: 60); // 15 s, only 60 m
    expect(c.sent, 1);
    expect(c.engine.current.waitingFor, PingWait.distance);
    expect(c.engine.current.metresToGo, closeTo(40, 1));
    expect(c.engine.current.message, contains('40 m'));
    await c.drive(1, metres: 25); // 85 m
    expect(c.sent, 1);
    await c.drive(1, metres: 20); // 105 m, at t = 17 s: no need to wait for t = 20 s
    expect(c.sent, 2);
    expect(c.pings.last.ts, t0.add(const Duration(seconds: 17)));
    await c.engine.stop();
  });

  test('moved far enough but interval not passed: waits for time, pings the moment it passes', () async {
    final c = Cad();
    await c.start(intervalSec: 30, minDistanceM: 50);
    await c.drive(29, metres: 400);
    expect(c.sent, 1, reason: 'never closer together than intervalSec');
    expect(c.engine.current.waitingFor, PingWait.time);
    expect(c.engine.current.metresToGo, 0);
    expect(c.engine.current.nextPingAt, t0.add(const Duration(seconds: 30)));
    await c.drive(1, metres: 10);
    expect(c.sent, 2);
    expect(c.pings.last.ts, t0.add(const Duration(seconds: 30)));
    await c.engine.stop();
  });

  test('fast driving: pings exactly every intervalSec, never closer', () async {
    final c = Cad();
    await c.start(intervalSec: 10, minDistanceM: 15);
    await c.drive(60, metres: 60 * 30); // 30 m/s for a minute
    expect(c.sent, 7); // t = 0, 10, …, 60
    final ts = c.pings.map((p) => p.ts).toList();
    for (var i = 1; i < ts.length; i++) {
      expect(ts[i].difference(ts[i - 1]), const Duration(seconds: 10));
    }
    await c.engine.stop();
  });

  test('parked: no auto pings at all, however long', () async {
    final c = Cad();
    await c.start(intervalSec: 10, minDistanceM: 15);
    await c.drive(120);
    expect(c.sent, 1);
    expect(c.engine.current.waitingFor, PingWait.distance);
    expect(c.engine.current.metresToGo, 15);
    await c.engine.stop();
  });

  test('Ping now resets both the timer and the distance anchor', () async {
    final c = Cad();
    await c.start(intervalSec: 10, minDistanceM: 100);
    await c.drive(6, metres: 150); // at 150 m, t = 6
    await c.engine.pingNow();
    expect(c.sent, 2);
    await c.drive(6, metres: 50); // t = 12: 200 m from the first ping but only 50 m from the manual one
    expect(c.sent, 2);
    expect(c.engine.current.waitingFor, PingWait.time, reason: 'manual ping at t=6 → next not before t=16');
    await c.drive(4, metres: 60); // t = 16, 110 m from the manual ping
    expect(c.sent, 3);
    expect(c.pings.last.ts, t0.add(const Duration(seconds: 16)));
    await c.engine.stop();
  });

  test('config is clamped: 1 s → 10 s, 5 m → 15 m, 1000 m → 500 m, 999 s → 120 s; 0 s = manual only', () async {
    WardriveConfig cl(int i, int d) => DefaultWardriveEngine.clampConfig(WardriveConfig(intervalSec: i, minDistanceM: d));
    expect(cl(1, 5).intervalSec, 10);
    expect(cl(1, 5).minDistanceM, 15);
    expect(cl(999, 1000).intervalSec, 120);
    expect(cl(999, 1000).minDistanceM, 500);
    expect(cl(0, 100).intervalSec, 0);
    expect(cl(-3, 100).intervalSec, 0);
    expect(cl(45, 250).intervalSec, 45);

    final c = Cad();
    await c.start(intervalSec: 1, minDistanceM: 5);
    await c.drive(9, metres: 500);
    expect(c.sent, 1, reason: '1 s is treated as 10 s');
    await c.drive(1, metres: 10);
    expect(c.sent, 2);
    await c.drive(10, metres: 12); // 12 m < 15 m minimum
    expect(c.sent, 2);
    await c.engine.stop();
  });

  test('intervalSec 0: manual only, never auto-pings, no wait info', () async {
    final c = Cad();
    await c.start(intervalSec: 0, minDistanceM: 15);
    expect(c.sent, 0);
    await c.drive(60, metres: 2000);
    expect(c.sent, 0);
    expect(c.engine.current.nextPingAt, isNull);
    expect(c.engine.current.waitingFor, isNull);
    await c.engine.pingNow();
    expect(c.sent, 1);
    await c.engine.stop();
  });

  test('updateConfig mid-drive takes effect at once (and can switch auto on/off)', () async {
    final c = Cad();
    await c.start(intervalSec: 120, minDistanceM: 500);
    await c.drive(20, metres: 300);
    expect(c.sent, 1);
    expect(c.engine.current.nextPingAt, t0.add(const Duration(seconds: 120)));
    c.engine.updateConfig(const WardriveConfig(intervalSec: 15, minDistanceM: 200, listenWindow: window));
    await c.settle();
    expect(c.sent, 2, reason: 'already 20 s and 300 m since the last ping');
    c.engine.updateConfig(const WardriveConfig(intervalSec: 0, minDistanceM: 200, listenWindow: window));
    await c.drive(60, metres: 3000);
    expect(c.sent, 2, reason: 'switched to manual');
    expect(c.engine.current.message, contains('manual'));
    c.engine.updateConfig(const WardriveConfig(channel: '#other', intervalSec: 10, minDistanceM: 15, listenWindow: window));
    await c.settle();
    expect(c.sent, 3, reason: 'auto back on; channel change ignored');
    await c.engine.stop();
    c.engine.updateConfig(const WardriveConfig(intervalSec: 10, listenWindow: window)); // not driving: no-op
    await c.drive(30, metres: 1000);
    expect(c.sent, 3);
  });

  test('no GPS: waits (status says so), pings when the fix comes back', () async {
    final c = Cad();
    c.gps.hasFix = false;
    await c.start(intervalSec: 10, minDistanceM: 15);
    expect(c.sent, 0);
    expect(c.engine.current.waitingFor, PingWait.gps);
    expect(c.engine.current.message, contains('GPS'));
    c.gps.hasFix = true;
    await c.drive(1);
    expect(c.sent, 1);
    await c.engine.stop();
  });

  test('a ping never starts during another ping\'s listen window', () async {
    final c = Cad();
    await c.link.start();
    await c.engine.start(const WardriveConfig(intervalSec: 10, minDistanceM: 15, listenWindow: Duration(milliseconds: 300)));
    while (c.sent == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    // While the first ping listens, time and distance are both "met" on the fake clock.
    c.now = c.now.add(const Duration(seconds: 30));
    c.gps.north = 1000;
    c.gps.emit();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(c.sent, 1);
    expect(c.engine.current.state, EngineState.pinging);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(c.sent, 2, reason: 'the next one goes out after the window closes');
    await c.engine.stop();
  });

  test('parked phone with a jittery GPS behind FilteredLocationSource: 10 minutes, one ping', () async {
    late SimulatedLocationSource noisy;
    final c = Cad(wrap: (gps) {
      noisy = SimulatedLocationSource.parked(jitterM: 20, reportSpeed: false, clock: gps.clock, seed: 5);
      return FilteredLocationSource(_Relay(noisy, gps), clock: gps.clock);
    });
    await c.start(intervalSec: 10, minDistanceM: 15);
    for (var i = 0; i < 600; i++) {
      c.now = c.now.add(const Duration(seconds: 1));
      c.gps.emit(); // _Relay forwards a fresh noisy fix
      await Future<void>.delayed(Duration.zero);
    }
    await c.settle();
    expect(c.sent, 1);
    expect(c.engine.current.waitingFor, PingWait.distance);
    expect(c.engine.current.metresToGo, 15);
    await c.engine.stop();
  });
}

/// Emits a fix from [noisy] each time the hand GPS emits (so the test controls the timing).
class _Relay implements LocationSource {
  final SimulatedLocationSource noisy;
  final HandGps trigger;
  _Relay(this.noisy, this.trigger);
  @override
  Stream<GeoFix> get fixes => trigger.fixes.asyncMap((_) async => (await noisy.current())!);
  @override
  Future<GeoFix?> current() => noisy.current();
  @override
  Future<bool> ensurePermission() async => true;
}
