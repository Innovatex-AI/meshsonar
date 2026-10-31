// The engine asks its PingGate before every ping. With the default gate (nobody chatting) it behaves exactly as before
// (every other wardrive test runs on that default); with a gate that says no, nothing is transmitted and nothing is queued
// for later.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/ping_gate.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

class Gps implements LocationSource {
  final _c = StreamController<GeoFix>.broadcast();
  GeoFix get fix => GeoFix(lat: 40.1262, lon: -82.9293, at: DateTime.now().toUtc(), accuracyM: 5, speedMps: 0);
  @override
  Stream<GeoFix> get fixes => _c.stream;
  @override
  Future<GeoFix?> current() async => fix;
  @override
  Future<bool> ensurePermission() async => true;
}

class ScriptedGate implements PingGate {
  PingDecision next = const PingDecision.go();
  int asked = 0, sent = 0;
  final manualFlags = <bool>[];
  @override
  FutureOr<PingDecision> requestPing({bool manual = false, int? airtimeMs}) {
    asked++;
    manualFlags.add(manual);
    return next;
  }

  @override
  void pingSent({int? airtimeMs}) => sent++;
}

void main() {
  late SimulatedTransport radio;
  late MeshCoreCompanionLink link;
  late DefaultWardriveEngine engine;
  late ScriptedGate gate;
  final pings = <DrivePing>[];
  final msgs = <String?>[];
  var now = DateTime.utc(2026, 11, 1, 12);

  int channelSends() => radio.sentFrames.where((f) => f[0] == 3).length;

  setUp(() async {
    pings.clear();
    msgs.clear();
    now = DateTime.utc(2026, 11, 1, 12);
    radio = SimulatedTransport(location: SimulatedLocationSource(speedMps: 0), seed: 3, timeScale: 40);
    link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 2));
    gate = ScriptedGate();
    engine = DefaultWardriveEngine(link: link, location: Gps(), clock: () => now, newId: () => 'p${pings.length}', tick: const Duration(milliseconds: 5))
      ..pingGate = gate
      ..pingSkipRetry = const Duration(milliseconds: 20);
    engine.pings.listen(pings.add);
    engine.status.listen((s) => msgs.add(s.message));
    await link.start();
  });

  tearDown(() async {
    await engine.stop();
    await link.close();
  });

  const cfg = WardriveConfig(intervalSec: 10, minDistanceM: 100, listenWindow: Duration(milliseconds: 40));

  test('default gate always says go', () async {
    expect(DefaultWardriveEngine(link: link, location: Gps()).pingGate, isA<AlwaysGoPingGate>());
  });

  test('gate says go: the ping goes out and the gate is told it was sent', () async {
    await engine.start(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(pings, hasLength(1));
    expect(channelSends(), 1);
    expect(gate.sent, 1);
    expect(gate.manualFlags.first, isFalse);
  });

  test('gate says skip: nothing is transmitted, the reason is shown and counted, and the ping is NOT queued for later', () async {
    gate.next = const PingDecision.skip(PingSkipReason.userSendRecent, 'Ping skipped: a message was just sent');
    final clockTimer = Timer.periodic(const Duration(milliseconds: 10), (_) => now = now.add(const Duration(milliseconds: 50)));
    addTearDown(clockTimer.cancel);
    await engine.start(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(channelSends(), 0);
    expect(pings, isEmpty);
    expect(msgs, contains('Ping skipped: a message was just sent'));
    expect(engine.skippedPings[PingSkipReason.userSendRecent], greaterThan(1), reason: 'asked again every retry, not once');
    expect(gate.sent, 0);
    // the gate opens: exactly ONE ping goes, not a backlog of the skipped ones
    gate.next = const PingDecision.go();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(channelSends(), 1);
    expect(pings, hasLength(1));
  });

  test('a skipped manual ping throws PingSkippedException with the reason, and asks as manual', () async {
    await engine.start(const WardriveConfig(intervalSec: 0, listenWindow: Duration(milliseconds: 40)));
    gate.next = const PingDecision.skip(PingSkipReason.radioQueueBusy, 'Ping skipped: the radio is busy sending');
    await expectLater(engine.pingNow(), throwsA(isA<PingSkippedException>().having((e) => e.decision.reason, 'reason', PingSkipReason.radioQueueBusy)));
    expect(gate.manualFlags.last, isTrue);
    expect(channelSends(), 0);
    gate.next = const PingDecision.go();
    final p = await engine.pingNow();
    expect(p.kind, PingKind.tx);
    expect(channelSends(), 1);
  });

  test('with the real arbiter, chat active: a ping right after a user message is skipped', () async {
    final arb = TxArbiter(queueProbe: () async => 0)..chatActive = true;
    engine.pingGate = arb;
    arb.admitUserSend(300);
    await engine.start(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(channelSends(), 0, reason: 'inside the 2 s window');
    expect(engine.skippedPings[PingSkipReason.userSendRecent], greaterThan(0));
  });

  test('with the real arbiter and nobody chatting: identical to no gate at all', () async {
    final arb = TxArbiter();
    engine.pingGate = arb;
    await engine.start(cfg);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(pings, hasLength(1));
    expect(arb.snapshot().pingsSent, 1);
    expect(engine.skippedPings, isEmpty);
  });
}
