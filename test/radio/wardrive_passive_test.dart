// Discovery / listen-only mode: a continuous, always-on passive RX pipeline (not the few-second window around a
// ping — there is no ping) that overhears other mesh traffic and turns it into rx-kind DrivePings. Modelled on
// MeshMapper's Passive RX logging (see wardrive_engine.dart's own citation of meshsonar-infra/docs/planning/
// meshmapper-teardown.md §3.3-3.4) but, unlike MeshMapper's "Passive" mode, never transmits anything at all — not
// even a zero-hop discovery request.
//
// Uses a hand-written fake CompanionLink (not the full companion-protocol simulator) so the test can push arbitrary
// ambient GRP_TXT packets — traffic from OTHER nodes on the mesh, nothing this engine ever sent — onto the radio's
// RX log directly. The companion-protocol framing itself (real BLE frames) is already covered end-to-end by
// wardrive_engine_test.dart and companion_link_test.dart; this file is about the passive pipeline's own logic.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

final t0 = DateTime.utc(2026, 10, 20, 12);
final _secret = hashtagChannelSecret('#wardriving');

/// Builds the raw over-the-air bytes of a flood GRP_TXT on `#wardriving`, as if some other node on the mesh sent
/// it and [path] of repeaters (each a 1-byte hash, first-heard to last-heard order) repeated it. Not built by, or
/// known to, the engine under test — exactly the "other mesh traffic" a listen-only drive is supposed to overhear.
Uint8List ambientGrpTxt(List<int> path, {int ts = 1000, String sender = 'KD8ZZZ', String text = 'anyone there?'}) {
  final payload = buildGroupTextPayload(_secret, ts, sender, text);
  final header = makeHeader(RouteType.flood, PayloadType.grpTxt);
  return MeshPacket(
    header: header,
    pathLenByte: encodePathLen(1, path.length),
    path: [for (final b in path) Uint8List.fromList([b])],
    payload: payload,
  ).toBytes();
}

/// A minimal, hand-driven CompanionLink: no transmission side effects beyond recording them, a controllable RX
/// log, and nothing else. Records every call that would put something on the air, so "nothing is transmitted" is
/// an assertion, not an assumption.
class PassiveLink implements CompanionLink {
  final _rx = StreamController<RxPacket>.broadcast();
  bool _connected = true;
  final List<String> sentTexts = [];
  int ensureChannelCalls = 0;

  @override
  Future<SelfInfo> start() async => const SelfInfo(publicKey: 'aa', name: 'Fake', radio: Radio());
  @override
  Future<int> ensureChannel(String name) async {
    ensureChannelCalls++;
    return 1;
  }

  @override
  Future<void> sendChannelText(int channelIndex, String text) async => sentTexts.add(text);
  @override
  Stream<RxPacket> get rxPackets => _rx.stream;
  @override
  Future<double?> noiseFloor() async => null;
  @override
  Future<void> close() async => _connected = false;
  @override
  bool get isConnected => _connected;

  void heard(Uint8List raw, {double? snrDb, double? rssiDbm, DateTime? at}) {
    if (_rx.isClosed) return;
    _rx.add(RxPacket(at: at ?? DateTime.now(), raw: raw, snrDb: snrDb, rssiDbm: rssiDbm));
  }
}

/// A GPS the test drives by hand, same pattern as wardrive_cadence_test.dart's HandGps.
class HandGps implements LocationSource {
  final DateTime Function() clock;
  double north = 0, east = 0;
  bool hasFix = true;
  final _c = StreamController<GeoFix>.broadcast();
  HandGps(this.clock);

  static const double lat0 = 40.1262, lon0 = -82.9293;
  static const double mLat = 111320.0;

  GeoFix get fix => GeoFix(lat: lat0 + north / mLat, lon: lon0 + east, at: clock(), accuracyM: 5);
  void emit() {
    if (hasFix && !_c.isClosed) _c.add(fix);
  }

  @override
  Stream<GeoFix> get fixes => _c.stream;
  @override
  Future<GeoFix?> current() async => hasFix ? fix : null;
  @override
  Future<bool> ensurePermission() async => true;
}

class Rig {
  DateTime now = t0;
  final PassiveLink link = PassiveLink();
  late final HandGps gps = HandGps(() => now);
  late final DefaultWardriveEngine engine;
  final pings = <DrivePing>[];
  final statuses = <EngineStatus>[];
  var _n = 0;

  Rig() {
    engine = DefaultWardriveEngine(
      link: link,
      location: gps,
      clock: () => now,
      newId: () => 'rx-${_n++}',
      tick: const Duration(milliseconds: 5),
    );
    engine.pings.listen(pings.add);
    engine.status.listen(statuses.add);
  }

  Future<void> start({bool listenOnly = true}) async {
    await engine.start(WardriveConfig(listenOnly: listenOnly));
    await settle();
  }

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

  /// Advances the fake clock and lets the real (short) periodic timer catch up to it.
  Future<void> advance(Duration d) async {
    now = now.add(d);
    await settle();
  }
}

void main() {
  test('listen-only start never sends anything on the channel, but still joins it to decode traffic', () async {
    final r = Rig();
    await r.start();
    expect(r.engine.current.state, EngineState.driving);
    expect(r.link.ensureChannelCalls, 1, reason: 'needs the channel secret to decrypt overheard GRP_TXT');
    expect(r.link.sentTexts, isEmpty, reason: 'listen-only: nothing goes out, not even a zero-hop ping');
    await r.engine.stop();
    expect(r.link.sentTexts, isEmpty);
  });

  test('pingNow() rejects in listen-only mode: this drive transmits nothing, manual pings included', () async {
    final r = Rig();
    await r.start();
    await expectLater(r.engine.pingNow(), throwsA(isA<StateError>()));
    expect(r.link.sentTexts, isEmpty);
    await r.engine.stop();
  });

  test('status fields related to ping countdown are null/not-applicable in listen-only mode', () async {
    final r = Rig();
    await r.start();
    final st = r.engine.current;
    expect(st.nextPingAt, isNull);
    expect(st.waitingFor, isNull);
    expect(st.metresToGo, isNull);
    expect(st.message, 'Listening');
    await r.engine.stop();
  });

  test('the persistent RX collector produces an rx-kind ping from overheard traffic with no ping ever sent',
      () async {
    final r = Rig();
    await r.start();
    r.gps.emit(); // gives the window a starting position
    await r.settle();

    // Someone else's traffic, repeated by repeater 0xB1 (the last, and only, path hop here).
    r.link.heard(ambientGrpTxt([0xB1]), snrDb: 4.0, rssiDbm: -90);
    await r.settle();
    expect(r.pings, isEmpty, reason: 'not flushed yet: neither 30 s nor 25 m has passed');

    await r.advance(const Duration(seconds: 31));
    expect(r.pings, hasLength(1));
    final p = r.pings.single;
    expect(p.kind, PingKind.rx);
    expect(p.echoes, hasLength(1));
    expect(p.echoes.single.repeater, 'b1');
    expect(p.echoes.single.snrDb, 4.0);
    expect(p.echoes.single.hops, 1, reason: 'the last-hop repeater is always a direct hear');
    expect(r.link.sentTexts, isEmpty);
    await r.engine.stop();
  });

  test('keys by the LAST path hop (the repeater actually heard), not the first (src/Mesh.cpp append order)',
      () async {
    final r = Rig();
    await r.start();
    r.gps.emit();
    await r.settle();

    // A 2-hop packet: repeater 0xA1 heard the original sender first, then 0xB2 repeated A1's copy. We physically
    // heard B2's transmission, not A1's — keying on path.first would wrongly credit A1.
    r.link.heard(ambientGrpTxt([0xA1, 0xB2]), snrDb: 2.0);
    await r.advance(const Duration(seconds: 31));
    expect(r.pings, hasLength(1));
    expect(r.pings.single.echoes.single.repeater, 'b2');
    expect(r.pings.single.echoes.single.path, ['a1', 'b2']);
    await r.engine.stop();
  });

  test('best SNR per repeater is kept within one flush window; one rx ping per repeater heard', () async {
    final r = Rig();
    await r.start();
    r.gps.emit();
    await r.settle();

    r.link.heard(ambientGrpTxt([0xC1], ts: 1001), snrDb: -2.0);
    await r.settle();
    r.link.heard(ambientGrpTxt([0xC1], ts: 1002), snrDb: 7.5); // stronger copy of a different packet, same repeater
    await r.settle();
    r.link.heard(ambientGrpTxt([0xC1], ts: 1003), snrDb: 1.0); // weaker again: best (7.5) must stick
    await r.settle();
    r.link.heard(ambientGrpTxt([0xD9], ts: 1004), snrDb: 3.0); // a different repeater entirely
    await r.advance(const Duration(seconds: 31));

    expect(r.pings, hasLength(2), reason: 'one rx ping per repeater heard, not per packet');
    final byRepeater = {for (final p in r.pings) p.echoes.single.repeater: p};
    expect(byRepeater['c1']!.echoes.single.snrDb, 7.5);
    expect(byRepeater['d9']!.echoes.single.snrDb, 3.0);
    await r.engine.stop();
  });

  test('30 s elapsed flushes even standing still', () async {
    final r = Rig();
    await r.start();
    r.gps.emit();
    await r.settle();
    r.link.heard(ambientGrpTxt([0xE1]));
    await r.advance(const Duration(seconds: 29));
    expect(r.pings, isEmpty, reason: 'not yet 30 s');
    await r.advance(const Duration(seconds: 2));
    expect(r.pings, hasLength(1));
    await r.engine.stop();
  });

  test('25 m moved flushes early, before 30 s elapses', () async {
    final r = Rig();
    await r.start();
    r.gps.emit(); // origin
    await r.settle();
    r.link.heard(ambientGrpTxt([0xF1]));
    await r.settle();

    r.gps.north = 10;
    r.gps.emit();
    await r.settle();
    expect(r.pings, isEmpty, reason: 'only 10 m, and well under 30 s');

    r.gps.north = 26;
    r.gps.emit();
    await r.settle();
    expect(r.pings, hasLength(1), reason: '26 m >= the 25 m flush distance');
    await r.engine.stop();
  });

  test('stop flushes a pending partial batch rather than dropping it', () async {
    final r = Rig();
    await r.start();
    r.gps.emit();
    await r.settle();
    r.link.heard(ambientGrpTxt([0x42]));
    await r.settle();
    expect(r.pings, isEmpty);
    await r.engine.stop();
    expect(r.pings, hasLength(1), reason: 'the trailing partial window is saved, not lost, on stop');
  });

  test('filters: a non-flood, an empty path, and traffic on an unknown channel are never turned into rx pings',
      () async {
    final r = Rig();
    await r.start();
    r.gps.emit();
    await r.settle();

    // Direct (non-flood) route type: not what a passively-overheard flood looks like.
    final direct = MeshPacket(
      header: makeHeader(RouteType.direct, PayloadType.grpTxt),
      pathLenByte: encodePathLen(1, 1),
      path: [Uint8List.fromList([0x11])],
      payload: buildGroupTextPayload(_secret, 2000, 'X', 'hi'),
    ).toBytes();
    r.link.heard(direct);

    // Empty path: never repeated by anyone, nothing to key on.
    final noPath = MeshPacket(
      header: makeHeader(RouteType.flood, PayloadType.grpTxt),
      pathLenByte: encodePathLen(1, 0),
      path: const [],
      payload: buildGroupTextPayload(_secret, 2001, 'X', 'hi'),
    ).toBytes();
    r.link.heard(noPath);

    // A different channel's secret: can't be decrypted on #wardriving's key, so it's noise, not traffic.
    // Layout: [header][pathLenByte][path (1 byte)][payload: channel-hash byte, then the ciphertext] — flip the
    // channel-hash byte so decryptGroupText's channel check fails.
    final otherChannel = ambientGrpTxt([0x22]);
    final tampered = Uint8List.fromList(otherChannel)..[3] = otherChannel[3] ^ 0xff;
    r.link.heard(tampered);

    await r.advance(const Duration(seconds: 31));
    expect(r.pings, isEmpty);
    await r.engine.stop();
  });

  test('updateConfig cannot switch listen-only on or off mid-drive', () async {
    final r = Rig();
    await r.start();
    r.engine.updateConfig(const WardriveConfig(listenOnly: false, intervalSec: 10));
    r.gps.emit();
    await r.settle();
    expect(r.link.sentTexts, isEmpty, reason: 'still listen-only: updateConfig cannot flip it mid-drive');

    r.link.heard(ambientGrpTxt([0x77]));
    await r.advance(const Duration(seconds: 31));
    expect(r.pings, hasLength(1), reason: 'the passive pipeline is still the one running');
    await r.engine.stop();
  });
}
