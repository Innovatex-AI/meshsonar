// End-to-end: DefaultWardriveEngine → MeshCoreCompanionLink → SimulatedTransport (real companion frames, real
// over-the-air packets). Time is sped up: the simulator's delays are divided by timeScale, listen windows are short.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

const window = Duration(milliseconds: 200);

class Rig {
  final SimulatedLocationSource gps;
  final SimulatedTransport radio;
  final MeshCoreCompanionLink link;
  final DefaultWardriveEngine engine;
  final pings = <DrivePing>[];
  final statuses = <EngineStatus>[];
  Rig._(this.gps, this.radio, this.link, this.engine) {
    engine.pings.listen(pings.add);
    engine.status.listen(statuses.add);
  }

  factory Rig({double speedMps = 13, double gpsScale = 1, int seed = 7, DateTime Function()? worldClock}) {
    final gps = SimulatedLocationSource(speedMps: speedMps, timeScale: gpsScale, seed: seed, clock: worldClock);
    final radio = SimulatedTransport(location: gps, seed: seed, timeScale: 40, clock: worldClock);
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
    var n = 0;
    final engine = DefaultWardriveEngine(link: link, location: gps, newId: () => 'id-${n++}');
    return Rig._(gps, radio, link, engine);
  }

  Future<void> open() async {
    await link.start();
  }
}

WardriveConfig manual() => const WardriveConfig(intervalSec: 0, minDistanceM: 100, listenWindow: window, txPowerW: 1.0);

void main() {
  resumeTests();
  test('ping text is "MS:" plus a random 10-character tag, nothing else', () {
    expect(formatPingText('m3jnr7dan5'), 'MS:m3jnr7dan5');
    final seen = <String>{};
    for (var i = 0; i < 2000; i++) {
      final tag = newPingTag();
      expect(tag, matches(RegExp(r'^[0-9a-z]{10}$')));
      expect(formatPingText(tag), matches(RegExp(r'^MS:[0-9a-z]{10}$')));
      seen.add(tag);
    }
    expect(seen.length, 2000, reason: 'a fresh random tag every time');
    // PRIVACY: no coordinate-looking text, no old branding
    expect(formatPingText(newPingTag()), isNot(matches(RegExp(r'-?\d{1,3}\.\d{3,}'))));
    expect(formatPingText(newPingTag()), isNot(contains('MapperBot')));
  });

  test('the tag is not derived from anything: seeded randoms differ from each other, same seed repeats only itself', () {
    expect(newPingTag(random: math.Random(1)), newPingTag(random: math.Random(1)));
    expect(newPingTag(random: math.Random(1)), isNot(newPingTag(random: math.Random(2))));
  });

  test('start joins the channel; pingNow emits one finished ping with real echoes', () async {
    final rig = Rig(speedMps: 0); // parked in Uptown, next to "WSTV Uptown"
    await rig.open();
    await rig.engine.start(manual());
    expect(rig.engine.current.state, EngineState.driving);

    final p = await rig.engine.pingNow();
    expect(rig.pings, [p]);
    expect(p.id, 'id-0');
    expect(p.kind, PingKind.tx);
    expect(p.lat, closeTo(40.1262, 1e-6));
    expect(p.gpsAccuracyM, inInclusiveRange(4, 6));
    expect(p.noiseFloorDbm, inInclusiveRange(-114, -110));
    expect(p.echoes, isNotEmpty);
    final keys = defaultSimulatedRepeaters().map((r) => r.keyHex.substring(0, 2)).toSet();
    for (final e in p.echoes) {
      expect(keys, contains(e.repeater));
      expect(e.hops, inInclusiveRange(1, 2));
      expect(e.path!.first, e.repeater);
      expect(e.path!.length, e.hops);
      expect(e.snrDb, isNotNull);
      expect(e.rssiDbm, isNotNull);
      expect(e.delayMs, inInclusiveRange(0, window.inMilliseconds + 100));
    }
    expect(p.echoes.map((e) => e.repeater).toSet().length, p.echoes.length, reason: 'one echo per repeater');
    // The ping text on air: MeshSonar's, with the power and NO position (public channel).
    final sent = rig.radio.sentFrames.lastWhere((f) => f[0] == 3);
    final onAir = String.fromCharCodes(sent.sublist(7));
    expect(onAir, matches(RegExp(r'^MS:[0-9a-z]{10}$')));
    expect(p.wireTag, onAir.substring(3), reason: 'the ping stores the tag it sent');
    expect(onAir, isNot(contains('40.1')));
    expect(onAir, isNot(contains('-82.')));
    await rig.engine.stop();
    expect(rig.engine.current.state, EngineState.idle);
  });

  test('driving the loop: some pings hear repeaters, some hear nothing; every ping is emitted', () async {
    // Deterministic: the car's position comes from a stepped clock (one ping every 40 s of driving at 13 m/s,
    // i.e. every ~520 m, 30 pings ≈ one lap); the radio's randomness is seeded.
    var world = DateTime.utc(2026, 1, 1);
    final rig = Rig(speedMps: 13, worldClock: () => world);
    await rig.open();
    await rig.engine.start(manual());
    for (var i = 0; i < 30; i++) {
      world = world.add(const Duration(seconds: 40));
      await rig.engine.pingNow();
    }
    await rig.engine.stop();
    expect(rig.pings.length, 30);
    expect(rig.pings.map((p) => p.id).toSet().length, 30);
    final heard = rig.pings.where((p) => p.echoes.isNotEmpty).length;
    expect(heard, greaterThan(0));
    expect(rig.pings.where((p) => p.heardNothing), isNotEmpty);
    expect(rig.pings.expand((p) => p.echoes).any((e) => e.hops == 2), isTrue, reason: 'occasional 2-hop echoes');
    // Background traffic on Public is never counted.
    for (final p in rig.pings) {
      expect(p.toJson()['echoes'], isA<List>());
    }
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('auto (real clock): first ping immediate; 1 s interval is clamped to 10 s; manual pings still allowed', () async {
    // Full cadence rules (time AND distance, clamping, updateConfig) are in wardrive_cadence_test.dart on a fake clock.
    final moving = Rig(speedMps: 13, gpsScale: 20); // 260 m/s
    await moving.open();
    await moving.engine
        .start(const WardriveConfig(intervalSec: 1, minDistanceM: 100, listenWindow: window, txPowerW: null));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(moving.radio.sentFrames.where((f) => f[0] == 3).length, 1, reason: 'first ping immediately');
    await Future<void>.delayed(const Duration(milliseconds: 2400));
    expect(moving.pings.length, 1, reason: 'never more often than 10 s, however fast we drive');
    expect(moving.engine.current.waitingFor, PingWait.time);
    expect(moving.engine.current.nextPingAt, isNotNull);
    expect(String.fromCharCodes(moving.radio.sentFrames.lastWhere((f) => f[0] == 3).sublist(7)), matches(RegExp(r'^MS:[0-9a-z]{10}$')));
    // A manual ping is allowed any time.
    await moving.engine.pingNow();
    expect(moving.pings.length, 2);
    await moving.engine.stop();
    expect(moving.engine.current.nextPingAt, isNull);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('no GPS fix: no ping, status says so', () async {
    final rig = Rig(speedMps: 0);
    await rig.open();
    await rig.engine.start(manual());
    rig.gps.hasFix = false;
    await expectLater(rig.engine.pingNow(), throwsA(isA<StateError>()));
    expect(rig.pings, isEmpty);
    expect(rig.radio.sentFrames.where((f) => f[0] == 3), isEmpty);
    expect(rig.engine.current.message, contains('GPS'));
    await rig.engine.stop();
  });

  test('stop waits for the ping on the air, then nothing more is sent', () async {
    final rig = Rig(speedMps: 13, gpsScale: 20);
    await rig.open();
    await rig.engine.start(const WardriveConfig(intervalSec: 1, minDistanceM: 10, listenWindow: window));
    await Future<void>.delayed(const Duration(milliseconds: 50)); // first ping is listening now
    await rig.engine.stop();
    expect(rig.pings.length, 1, reason: 'the in-flight ping is finished, not dropped');
    final sends = rig.radio.sentFrames.where((f) => f[0] == 3).length;
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(rig.radio.sentFrames.where((f) => f[0] == 3).length, sends);
    expect(rig.engine.current.state, EngineState.idle);
    expect(() => rig.engine.pingNow(), throwsA(isA<StateError>()));
    // Can drive again.
    await rig.engine.start(manual());
    await rig.engine.pingNow();
    await rig.engine.stop();
    expect(rig.pings.length, 2);
  });

  test('radio disconnect mid-drive: error state, no crash, stop still works', () async {
    final rig = Rig(speedMps: 13, gpsScale: 20);
    await rig.open();
    await rig.engine.start(const WardriveConfig(intervalSec: 1, minDistanceM: 10, listenWindow: window));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    rig.radio.simulateDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(rig.engine.current.state, EngineState.error);
    expect(rig.engine.current.message, contains('disconnected'));
    await expectLater(rig.engine.pingNow(), throwsA(isA<StateError>()));
    await rig.engine.stop();
    expect(rig.engine.current.state, EngineState.idle);
  });

  test('start on a dead radio reports error and throws', () async {
    final rig = Rig(speedMps: 0);
    await rig.open();
    rig.radio.simulateDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await expectLater(rig.engine.start(manual()), throwsA(anything));
    expect(rig.engine.current.state, EngineState.error);
  });

  test('optional neighbor discovery records a two-way exchange', () async {
    final rig = Rig(speedMps: 0);
    await rig.open();
    rig.engine.discoverNeighbors = true;
    await rig.engine.start(manual());
    final p = await rig.engine.pingNow();
    expect(p.neighbor, isNotNull);
    expect(p.neighbor!.repeater.length, 64);
    expect(p.neighbor!.remoteSnrDb, isNotNull);
    expect(p.neighbor!.localSnrDb, isNotNull);
    await rig.engine.stop();
  });

  test('v1.1: each ping carries pkt_hash, tx_epoch_s and tx_dbm for the exact packet sent', () async {
    final rig = Rig(speedMps: 0);
    await rig.open();
    await rig.engine.start(const WardriveConfig(intervalSec: 0, minDistanceM: 100, listenWindow: window, txPowerW: 0.16, txDbm: 22));
    final a = await rig.engine.pingNow();
    final b = await rig.engine.pingNow();
    for (final p in [a, b]) {
      final sent = rig.radio.sentFrames.where((f) => f[0] == 3).toList()[p == a ? 0 : 1];
      final ts = sent[3] | (sent[4] << 8) | (sent[5] << 16) | (sent[6] << 24);
      expect(p.txEpochS, ts, reason: 'the second inside the packet, not a guess from ts');
      expect(p.txEpochS! - p.ts.millisecondsSinceEpoch ~/ 1000, inInclusiveRange(0, 1));
      final text = String.fromCharCodes(sent.sublist(7));
      expect(p.pktHash, groupTextPacketHashHex(hashtagChannelSecret('#wardriving'), ts, 'MeshSonar Sim', text));
      expect(p.pktHash, hasLength(16));
      expect(p.txDbm, 22);
      expect(p.toJson()['pkt_hash'], p.pktHash);
    }
    expect(a.echoes, isNotEmpty, reason: 'the hash also agrees with the heard repeats (taken from them when present)');
    expect(a.pktHash, isNot(b.pktHash));
    await rig.engine.stop();
  });

  test('v1.1: with nothing heard the hash is predicted from the send; unknown power stays null', () async {
    final rig = Rig(speedMps: 0);
    rig.radio.repeaters.clear();
    await rig.open();
    await rig.engine.start(manual());
    final p = await rig.engine.pingNow();
    expect(p.echoes, isEmpty);
    final sent = rig.radio.sentFrames.lastWhere((f) => f[0] == 3);
    final ts = sent[3] | (sent[4] << 8) | (sent[5] << 16) | (sent[6] << 24);
    expect(p.txEpochS, ts);
    expect(p.pktHash,
        groupTextPacketHashHex(hashtagChannelSecret('#wardriving'), ts, 'MeshSonar Sim', String.fromCharCodes(sent.sublist(7))));
    expect(p.txDbm, isNull);
    await rig.engine.stop();
  });
}

void resumeTests() {
  test('radio drop mid-drive: resumeOnLink rejoins the channel and the SAME engine carries on pinging', () async {
    final rig = Rig(speedMps: 13, gpsScale: 20);
    await rig.open();
    await rig.engine.start(const WardriveConfig(intervalSec: 10, minDistanceM: 15, listenWindow: window));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    rig.radio.simulateDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(rig.engine.current.state, EngineState.error);
    final before = rig.pings.length;

    // A new connection to the same radio.
    final radio2 = SimulatedTransport(location: rig.gps, seed: 7, timeScale: 40);
    final link2 = MeshCoreCompanionLink(radio2, timeout: const Duration(seconds: 2));
    await link2.start();
    await rig.engine.resumeOnLink(link2);
    expect(rig.engine.current.state, anyOf(EngineState.driving, EngineState.pinging));
    final p = await rig.engine.pingNow();
    expect(rig.pings.length, greaterThan(before), reason: 'the drive carries on on the new link');
    expect(p.kind, PingKind.tx);
    expect(radio2.sentFrames.where((f) => f[0] == 3), isNotEmpty, reason: 'the pings go out on the new radio');
    await rig.engine.stop();
    expect(rig.engine.current.state, EngineState.idle);
  });

  test('resumeOnLink on a drive that was never started is refused', () async {
    final rig = Rig(speedMps: 0);
    await rig.open();
    await expectLater(rig.engine.resumeOnLink(rig.link), throwsA(isA<StateError>()));
  });

  test('resumeOnLink with a link that is already dead stays in error', () async {
    final rig = Rig(speedMps: 13, gpsScale: 20);
    await rig.open();
    await rig.engine.start(const WardriveConfig(intervalSec: 10, minDistanceM: 15, listenWindow: window));
    rig.radio.simulateDisconnect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await expectLater(rig.engine.resumeOnLink(rig.link), throwsA(isA<StateError>()));
    expect(rig.engine.current.state, EngineState.error);
    await rig.engine.stop();
  });
}
