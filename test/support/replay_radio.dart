// A deterministic "radio on the road" for replay tests: a ByteTransport that speaks the companion protocol, answers every
// command after a BLE-sized delay, and plays back SCRIPTED over-the-air timelines for each ping it is asked to send
// (which repeaters repeat it, after how long, at what SNR, over how many hops) plus background traffic from other
// wardrivers on the same channel. Everything runs on fake time (package:fake_async), so a 30 minute drive replays in
// milliseconds and the numbers it measures are exactly repeatable.
//
// Used by test/radio/ping_replay_test.dart (current engine) and, copied unchanged into an older commit's worktree, to
// measure the pre-session engine on the very same timeline (see HANDOFF "ping + detection audit").
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

/// One scripted copy of a ping arriving back at the radio.
class ScriptedEcho {
  /// Path as heard (first = the repeater that heard our transmission directly).
  final List<int> path;
  final int delayMs;
  final double snrDb;
  final int rssiDbm;
  const ScriptedEcho(this.path, this.delayMs, this.snrDb, this.rssiDbm);
  int get repeater => path.first;
}

/// What the world does to one ping.
typedef EchoScript = List<ScriptedEcho> Function(int pingIndex, math.Random rng);

/// The default timeline: 0-4 repeaters hear the car directly (250-2500 ms, the simulator's backoff), a second-hop repeater now
/// and then, repeat copies of the same repeater (same first hop, longer path) and a tail of late copies (7-12 s) like a
/// slow multi-hop mesh.
List<ScriptedEcho> defaultEchoScript(int index, math.Random rng) {
  const ids = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66];
  final out = <ScriptedEcho>[];
  final direct = rng.nextInt(5); // 0..4
  final pool = [...ids]..shuffle(rng);
  for (var i = 0; i < direct; i++) {
    final late = rng.nextDouble() < 0.12;
    out.add(ScriptedEcho([pool[i]], late ? 7200 + rng.nextInt(4200) : 250 + rng.nextInt(2300), -2.0 + rng.nextInt(14), -105 + rng.nextInt(30)));
  }
  // A repeater we did not hear directly: its repeat reached us through another one (path [far, via]).
  if (rng.nextDouble() < 0.4) {
    final far = pool[direct % pool.length == 0 ? 5 : 5 - (direct % 2)];
    final via = pool[(direct + 1) % pool.length];
    if (far != via && !out.any((e) => e.repeater == far)) {
      final late = rng.nextDouble() < 0.25;
      out.add(ScriptedEcho([far, via], late ? 7500 + rng.nextInt(4000) : 1800 + rng.nextInt(3800), -8.0 + rng.nextInt(8), -122 + rng.nextInt(10)));
    }
  }
  // A repeat of an already-heard repeater that came round another way (same first hop, 2 hops, later, weaker).
  if (out.isNotEmpty && rng.nextDouble() < 0.35) {
    final r = out.first.repeater;
    out.add(ScriptedEcho([r, pool[(direct + 2) % pool.length]], 3000 + rng.nextInt(3000), -9.0, -120));
  }
  out.sort((a, b) => a.delayMs.compareTo(b.delayMs));
  return out;
}

class SentPing {
  final DateTime at;
  final int timestamp;
  final String text;
  final List<ScriptedEcho> script;
  SentPing(this.at, this.timestamp, this.text, this.script);

  /// Distinct first-hop repeaters the world sent back within [withinMs] of the send.
  Set<int> truth({int withinMs = 1 << 30}) => {for (final e in script) if (e.delayMs <= withinMs) e.repeater};
}

class ScriptedTransport implements ByteTransport {
  final DateTime Function() clock;
  final Duration bleLatency;
  final math.Random _rng;
  final EchoScript script;

  /// Mean seconds between other wardrivers' pings on the channel (0 = quiet).
  final double backgroundEverySec;
  final String nodeName;
  final int sf;
  final int bwHz;
  final Uint8List publicKey = sha256(utf8.encode('replay-radio'));
  final int wardriveSlot = 1;
  final String wardriveName;
  late final Uint8List wardriveSecret = hashtagChannelSecret(wardriveName);
  final _out = StreamController<Uint8List>.broadcast();
  bool _connected = true;
  final List<Uint8List> _offline = [];
  final sent = <SentPing>[];
  final List<Uint8List> sentFrames = [];
  int commands = 0;
  int syncCommands = 0;
  int _bg = 0;
  Timer? _bgTimer;

  /// When the radio put a frame on the wire to the app, per packet: key = raw packet identity.
  final Map<int, DateTime> pushedAt = {};
  int _pushSeq = 0;
  final int _slotCount = 8;
  final Map<int, ({String name, Uint8List secret})> _slots = {};

  ScriptedTransport({
    required this.clock,
    int seed = 1,
    this.bleLatency = const Duration(milliseconds: 45),
    this.script = defaultEchoScript,
    this.backgroundEverySec = 0,
    this.nodeName = 'KE4BFI',
    this.sf = 7,
    this.bwHz = 62500,
    this.wardriveName = '#wardriving',
  }) : _rng = math.Random(seed) {
    _slots[0] = (name: 'Public', secret: Uint8List.fromList(publicChannelSecret));
  }

  void startBackground() {
    if (backgroundEverySec <= 0) return;
    void next() {
      final ms = (backgroundEverySec * 1000 * (0.4 + _rng.nextDouble() * 1.2)).round();
      _bgTimer = Timer(Duration(milliseconds: ms), () {
        if (!_connected) return;
        _otherDriverPing();
        next();
      });
    }

    next();
  }

  @override
  Stream<Uint8List> get incoming => _out.stream;
  @override
  bool get isConnected => _connected;
  @override
  Future<void> disconnect() async {
    _connected = false;
    _bgTimer?.cancel();
    if (!_out.isClosed) await _out.close();
  }

  void _emit(Uint8List f, Duration after) {
    Timer(after, () {
      if (_connected && !_out.isClosed) _out.add(f);
    });
  }

  void _reply(Uint8List f) => _emit(f, bleLatency);

  void _hear(List<int> raw, double snr, int rssi, Duration after, {int? key}) {
    final id = key ?? _pushSeq++;
    Timer(after, () {
      if (!_connected || _out.isClosed) return;
      pushedAt[id] = clock();
      _out.add(encodeLogRxData(snr, rssi, raw));
    });
  }

  Uint8List _grp(int ts, String text, String sender, List<int> path) {
    final payload = buildGroupTextPayload(wardriveSecret, ts, sender, text);
    return MeshPacket(header: makeHeader(RouteType.flood, PayloadType.grpTxt), pathLenByte: encodePathLen(1, path.length), path: [for (final p in path) Uint8List.fromList([p])], payload: payload)
        .toBytes();
  }

  void _otherDriverPing() {
    final ts = clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    final text = formatPingText(newPingTag(random: _rng));
    final raw = _grp(ts, text, 'OtherDriver${_bg++ % 7}', [0x70 + _rng.nextInt(8)]);
    _hear(raw, 3.0, -108, Duration.zero);
    // The radio queues a message it has not seen before and tickles the app (MyMesh.cpp addToOfflineQueue).
    _offline.add(encodeChannelMsg(wardriveSlot, 'OtherDriver: $text', timestamp: ts, pathLen: 1, snrDb: 3));
    if (_offline.length > 16) _offline.removeAt(0);
    _emit(encodeMsgWaiting(), const Duration(milliseconds: 15));
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (!_connected) throw StateError('replay radio disconnected');
    sentFrames.add(Uint8List.fromList(frame));
    commands++;
    final bd = ByteData.sublistView(frame);
    switch (frame[0]) {
      case Cmd.appStart:
        _reply(encodeSelfInfo(
            txPowerDbm: 22, maxTxPowerDbm: 22, publicKey: publicKey, freqKhz: 910525, bwHz: bwHz, sf: sf, cr: 5, name: nodeName));
      case Cmd.deviceQuery:
        _reply(encodeDeviceInfo(
            firmwareVerCode: 9, maxChannels: _slotCount, buildDate: '1 Oct 2026', manufacturer: 'Replay', firmwareVersion: 'v1.18.0'));
      case Cmd.setDeviceTime:
        _reply(encodeOk());
      case Cmd.getChannel:
        final i = frame.length > 1 ? frame[1] : 255;
        if (i >= _slotCount) return _reply(encodeErr(ErrCode.notFound));
        final s = _slots[i];
        _reply(encodeChannelInfo(i, s?.name ?? '', s?.secret ?? Uint8List(16)));
      case Cmd.setChannel:
        final i = frame[1];
        final nameBytes = frame.sublist(2, 34).takeWhile((b) => b != 0).toList();
        _slots[i] = (name: utf8.decode(nameBytes, allowMalformed: true), secret: Uint8List.fromList(frame.sublist(34, 50)));
        _reply(encodeOk());
      case Cmd.sendChannelTxtMsg:
        final ts = bd.getUint32(3, Endian.little);
        final text = utf8.decode(frame.sublist(7), allowMalformed: true);
        _reply(encodeOk());
        final idx = sent.length;
        final plan = script(idx, math.Random(idx * 7919 + 13));
        final at = clock();
        sent.add(SentPing(at, ts, text, plan));
        for (final e in plan) {
          _hear(_grp(ts, text, nodeName, e.path), e.snrDb, e.rssiDbm, Duration(milliseconds: e.delayMs), key: null);
        }
      case Cmd.syncNextMessage:
        syncCommands++;
        _reply(_offline.isEmpty ? encodeNoMoreMessages() : _offline.removeAt(0));
      case Cmd.getStats:
        switch (frame[1]) {
          case StatsType.radio:
            _reply(encodeRadioStats(noiseFloorDbm: -112));
          case StatsType.core:
            _reply(encodeCoreStats(batteryMv: 4000, uptimeSecs: 1000, queueLen: 0));
          default:
            _reply(encodePacketStats(recv: 0, sent: 0, floodTx: 0, directTx: 0, floodRx: 0, directRx: 0, recvErrors: 0));
        }
      case Cmd.getBattAndStorage:
        _reply(encodeBattAndStorage(batteryMv: 4000));
      case Cmd.setFloodScopeKey:
        _reply(encodeOk());
      default:
        _reply(encodeErr(ErrCode.unsupportedCmd));
    }
  }
}

/// A car at 13 m/s heading north; one fix per second.
class ReplayLocation implements LocationSource {
  final DateTime Function() clock;
  final DateTime start;
  final double speedMps;
  final _c = StreamController<GeoFix>.broadcast();
  Timer? _t;
  /// How long the platform takes to answer [current] (an iPhone's getCurrentPosition can sit for many seconds while the
  /// position stream is running); the stream itself keeps delivering a fix a second.
  final Duration currentDelay;
  ReplayLocation(this.clock, {this.speedMps = 13, this.currentDelay = Duration.zero}) : start = clock();

  GeoFix _fix() {
    final s = clock().difference(start).inMilliseconds / 1000.0;
    return GeoFix(lat: 40.1262 + s * speedMps / 111320.0, lon: -82.9312, accuracyM: 5, speedMps: speedMps, at: clock());
  }

  void run() => _t = Timer.periodic(const Duration(seconds: 1), (_) => _c.add(_fix()));
  void stop() => _t?.cancel();
  @override
  Stream<GeoFix> get fixes => _c.stream;
  @override
  Future<GeoFix?> current() async {
    if (currentDelay > Duration.zero) await Future<void>.delayed(currentDelay);
    return _fix();
  }
  @override
  Future<bool> ensurePermission() async => true;
}

/// What a replay run measured.
class ReplayResult {
  final List<DrivePing> pings;
  final ScriptedTransport radio;
  final DefaultWardriveEngine engine;
  final Duration driven;
  final Map<String, DateTime> echoSeenByApp; // (ping id|repeater) -> when the engine held the echo
  ReplayResult(this.pings, this.radio, this.engine, this.driven, this.echoSeenByApp);

  int get pingsSent => radio.sent.length;

  /// Detection: of the distinct repeaters the world sent back within [withinMs], the share the engine recorded.
  double detection({int withinMs = 10000}) {
    var truth = 0, hit = 0;
    for (final p in pings) {
      final sp = radio.sent.where((s) => s.text.endsWith(p.wireTag ?? '\u0000')).firstOrNull;
      if (sp == null) continue;
      final t = sp.truth(withinMs: withinMs);
      truth += t.length;
      final got = {for (final e in p.echoes) int.parse(e.repeater, radix: 16)};
      hit += got.intersection(t).length;
    }
    return truth == 0 ? 1 : hit / truth;
  }

  /// Echoes recorded that the 7 s window would have missed (late attribution), per ping.
  int get lateEchoes => pings.fold(0, (a, p) => a + p.echoes.where((e) => (e.delayMs ?? 0) > 10000).length);

  /// Median / p95 / max of "send command on the wire minus due time", seconds, over the pings after the first.
  List<double> sendGaps() {
    final g = <double>[];
    for (var i = 1; i < radio.sent.length; i++) {
      g.add(radio.sent[i].at.difference(radio.sent[i - 1].at).inMilliseconds / 1000.0);
    }
    return g;
  }
}

typedef StackBuilder = Future<DefaultWardriveEngine> Function(MeshCoreCompanionLink link, LocationSource gps, DateTime Function() clock);

/// Drives [driveSeconds] of fake time at [intervalSec] cadence (distance rule always met) and returns what was measured.
ReplayResult runReplay({
  required StackBuilder build,
  int seed = 1,
  int driveSeconds = 1800,
  int intervalSec = 15,
  double backgroundEverySec = 0,
  EchoScript script = defaultEchoScript,
  Duration listenWindow = const Duration(seconds: 10),
  int bleLatencyMs = 45,
  int sf = 7,
  Duration currentDelay = Duration.zero,
  WardriveConfig Function(WardriveConfig base)? tweak,
}) {
  late ReplayResult result;
  fakeAsync((fa) {
    final t0 = DateTime.utc(2026, 11, 1, 12);
    DateTime clock() => t0.add(fa.elapsed);
    final radio = ScriptedTransport(clock: clock, seed: seed, script: script, backgroundEverySec: backgroundEverySec, bleLatency: Duration(milliseconds: bleLatencyMs), sf: sf);
    final gps = ReplayLocation(clock, currentDelay: currentDelay);
    final link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 5), clock: clock);
    final pings = <DrivePing>[];
    late DefaultWardriveEngine engine;
    var ready = false;
    () async {
      await link.start();
      engine = await build(link, gps, clock);
      engine.pings.listen(pings.add);
      var cfg = WardriveConfig(intervalSec: intervalSec, minDistanceM: 15, listenWindow: listenWindow);
      if (tweak != null) cfg = tweak(cfg);
      await engine.start(cfg);
      gps.run();
      radio.startBackground();
      ready = true;
    }();
    fa.flushMicrotasks();
    fa.elapse(const Duration(seconds: 2));
    for (var i = 0; i < 50 && !ready; i++) {
      fa.elapse(const Duration(milliseconds: 100));
    }
    assert(ready, 'stack did not start');
    for (var s = 0; s < driveSeconds; s++) {
      fa.elapse(const Duration(seconds: 1));
    }
    var stopped = false;
    engine.stop().then((_) => stopped = true);
    for (var i = 0; i < 400 && !stopped; i++) {
      fa.elapse(const Duration(milliseconds: 100));
    }
    gps.stop();
    result = ReplayResult(pings, radio, engine, Duration(seconds: driveSeconds), const {});
    unawaited(link.close());
    fa.flushMicrotasks();
  });
  return result;
}
