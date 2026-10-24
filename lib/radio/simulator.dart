// MeshSonar simulator: a fake MeshCore companion radio and a fake GPS drive, for the app's Simulator mode, UI tests
// and demos. No hardware.
//
// SimulatedTransport speaks the REAL companion protocol (frame layouts from MeshCore firmware
// examples/companion_radio/MyMesh.cpp — see protocol.dart), so MeshCoreCompanionLink runs on it unchanged, and it
// reports what it "hears" as PUSH_CODE_LOG_RX_DATA frames carrying real over-the-air packets (flood GRP_TXT with the
// path built up the way src/Mesh.cpp routeRecvPacket() appends repeater hashes, payload encrypted the way
// Mesh::createGroupDatagram() does). Nothing here is used when a real radio is connected.
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'crypto.dart';
import 'packet.dart';
import 'protocol.dart';
import 'radio_api.dart';

// ------------------------------------------------------------------ the drive

class _Pt {
  final double lat, lon;
  const _Pt(this.lat, this.lon);
}

/// A loop through Westerville, Ohio (Uptown at ~40.126, -82.93). Roughly 16 km.
const List<_Pt> _route = [
  _Pt(40.1262, -82.9293), // Uptown, State St & Main St
  _Pt(40.1345, -82.9290),
  _Pt(40.1440, -82.9285), // State St north
  _Pt(40.1445, -82.9150),
  _Pt(40.1440, -82.9020), // east toward Africa Rd
  _Pt(40.1300, -82.9010),
  _Pt(40.1150, -82.9030), // south
  _Pt(40.1060, -82.9180),
  _Pt(40.1050, -82.9330),
  _Pt(40.1060, -82.9520), // west toward Cleveland Ave
  _Pt(40.1180, -82.9560),
  _Pt(40.1262, -82.9450), // back east on Main St
];

double _distM(_Pt a, _Pt b) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.lat - a.lat), dLon = rad(b.lon - a.lon);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(a.lat)) * math.cos(rad(b.lat)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

/// GPS that drives the Westerville loop at [speedMps] (×[timeScale]). Position is a pure function of the clock, so
/// any two instances with the same settings agree (the simulated radio uses this to know where "you" are).
class SimulatedLocationSource implements LocationSource {
  final double speedMps;
  final double timeScale;
  final DateTime Function() _clock;
  final DateTime _epoch;
  final math.Random _rng;

  /// Set false to simulate losing the GPS fix.
  bool hasFix = true;

  /// GPS noise: when > 0, every fix wanders around the true position by a bounded random walk (±[jitterM] metres
  /// per axis, a few metres per fix) and reports accuracy between [jitterAccuracyM].min and .max — what a real
  /// phone does while parked. 0 (the default) = clean fixes.
  final double jitterM;
  final ({double min, double max}) jitterAccuracyM;

  /// False reports speed as unknown (null), like an iPhone that isn't sure it's moving.
  final bool reportSpeed;

  double _jx = 0, _jy = 0; // current noise offset, metres east/north

  late final List<double> _cum;

  SimulatedLocationSource({
    this.speedMps = 13.0,
    this.timeScale = 1.0,
    DateTime Function()? clock,
    DateTime? epoch,
    int? seed,
    this.jitterM = 0,
    this.jitterAccuracyM = (min: 5.0, max: 20.0),
    this.reportSpeed = true,
  })  : _clock = clock ?? DateTime.now,
        _epoch = epoch ?? DateTime.utc(2026, 1, 1),
        _rng = math.Random(seed) {
    _cum = [0];
    for (var i = 0; i < _route.length; i++) {
      _cum.add(_cum.last + _distM(_route[i], _route[(i + 1) % _route.length]));
    }
  }

  double get loopLengthM => _cum.last;

  /// Where the car is at [t].
  ({double lat, double lon}) positionAt(DateTime t) {
    final secs = t.difference(_epoch).inMicroseconds / 1e6;
    var s = (secs * speedMps * timeScale) % loopLengthM;
    if (s < 0) s += loopLengthM;
    var i = 0;
    while (i < _route.length - 1 && _cum[i + 1] <= s) {
      i++;
    }
    final a = _route[i], b = _route[(i + 1) % _route.length];
    final f = (s - _cum[i]) / (_cum[i + 1] - _cum[i]);
    return (lat: a.lat + (b.lat - a.lat) * f, lon: a.lon + (b.lon - a.lon) * f);
  }

  /// A parked phone with a noisy GPS: stands still at the start of the loop (Uptown) and wanders ±[jitterM] m.
  factory SimulatedLocationSource.parked({
    double jitterM = 20,
    bool reportSpeed = true,
    DateTime Function()? clock,
    int? seed,
  }) =>
      SimulatedLocationSource(speedMps: 0, jitterM: jitterM, reportSpeed: reportSpeed, clock: clock, seed: seed);

  GeoFix _fixAt(DateTime t) {
    final p = positionAt(t);
    if (jitterM <= 0) {
      return GeoFix(
        lat: p.lat,
        lon: p.lon,
        at: t.toUtc(),
        accuracyM: 4.0 + _rng.nextDouble() * 2.0,
        speedMps: reportSpeed ? speedMps * timeScale : null,
      );
    }
    double step(double v) => (v + (_rng.nextDouble() * 2 - 1) * 4).clamp(-jitterM, jitterM);
    _jx = step(_jx);
    _jy = step(_jy);
    const mPerDegLat = 111320.0;
    final mPerDegLon = mPerDegLat * math.cos(p.lat * math.pi / 180);
    final acc = jitterAccuracyM.min + _rng.nextDouble() * (jitterAccuracyM.max - jitterAccuracyM.min);
    return GeoFix(
      lat: p.lat + _jy / mPerDegLat,
      lon: p.lon + _jx / mPerDegLon,
      at: t.toUtc(),
      accuracyM: acc,
      speedMps: reportSpeed ? speedMps * timeScale : null,
    );
  }

  @override
  Future<GeoFix?> current() async => hasFix ? _fixAt(_clock()) : null;

  @override
  Stream<GeoFix> get fixes {
    late StreamController<GeoFix> c;
    Timer? t;
    c = StreamController<GeoFix>(
      onListen: () {
        final period = Duration(microseconds: (1e6 / timeScale).round().clamp(1000, 1000000));
        t = Timer.periodic(period, (_) {
          if (hasFix) c.add(_fixAt(_clock()));
        });
      },
      onCancel: () => t?.cancel(),
    );
    return c.stream;
  }

  @override
  Future<bool> ensurePermission() async => true;
}

// ------------------------------------------------------------------ the mesh

class SimulatedRepeater {
  final String name;
  final double lat, lon;
  final Uint8List publicKey;
  SimulatedRepeater(this.name, this.lat, this.lon) : publicKey = sha256(utf8.encode('meshsonar-sim:$name'));
  String get keyHex => toHex(publicKey);
}

/// Fixed repeaters around Westerville (made-up names and keys; plausible sites).
List<SimulatedRepeater> defaultSimulatedRepeaters() => [
      SimulatedRepeater('WSTV Uptown', 40.1258, -82.9312),
      SimulatedRepeater('Otterbein Hill', 40.1195, -82.9375),
      SimulatedRepeater('Hoover Dam Park', 40.1460, -82.8960),
      SimulatedRepeater('Polaris Tower', 40.1450, -82.9840),
      SimulatedRepeater('Alum Creek North', 40.1700, -82.9420),
      SimulatedRepeater('Minerva Park', 40.0760, -82.9390),
      SimulatedRepeater('Genoa Twp', 40.1590, -82.8730),
    ];

class _Slot {
  String name;
  Uint8List secret;
  _Slot(this.name, this.secret);
}

/// A simulated MeshCore companion radio.
class SimulatedTransport implements ByteTransport {
  final SimulatedLocationSource location;
  final List<SimulatedRepeater> repeaters;
  final double timeScale;
  final math.Random _rng;
  final DateTime Function() _clock;

  /// Bytes per path hash on air (1, 2 or 3; firmware path_hash_mode + 1).
  final int pathHashSize;

  /// Noise floor reported by CMD_GET_STATS; null = behave like firmware without stats (ERR unsupported).
  final int? noiseFloorDbm;

  final String nodeName;
  final Uint8List publicKey;
  final _out = StreamController<Uint8List>.broadcast();
  bool _connected = true;
  final List<Timer> _timers = [];
  final List<_Slot> _slots;
  int _clockSecs = 0;

  // Radio health counters, answered to GET_STATS core/packets and GET_BATT_AND_STORAGE (firmware layouts in
  // protocol.dart). Plausible, deterministic numbers that follow what the simulation actually did; not a model of
  // any real board.
  late final DateTime _bootAt;
  int _sent = 0;
  int _recv = 0;
  int _txAirMs = 0;
  int _rxAirMs = 0;
  int _lastRssi = 0; // 0 until something is heard, like the firmware
  double _lastSnr = 0;

  /// About what one short GRP_TXT costs on air at SF7 / 62.5 kHz.
  static const int _airMsPerPacket = 110;

  /// Received commands, for tests.
  final List<Uint8List> sentFrames = [];

  /// When false, the radio ignores commands (to test timeouts).
  bool responsive = true;

  SimulatedTransport({
    SimulatedLocationSource? location,
    List<SimulatedRepeater>? repeaters,
    int? seed,
    this.timeScale = 1.0,
    DateTime Function()? clock,
    this.pathHashSize = 1,
    this.noiseFloorDbm = -112,
    this.nodeName = 'MeshSonar Sim',
    int maxChannels = 8,
  })  : location = location ?? SimulatedLocationSource(timeScale: timeScale, clock: clock),
        repeaters = repeaters ?? defaultSimulatedRepeaters(),
        _rng = math.Random(seed),
        _clock = clock ?? DateTime.now,
        publicKey = sha256(utf8.encode('meshsonar-sim-companion')),
        _slots = List.generate(maxChannels, (i) => _Slot('', Uint8List(16))) {
    _slots[0] = _Slot('Public', Uint8List.fromList(publicChannelSecret));
    _bootAt = _clock();
  }

  /// Simulated seconds since this radio "booted" (scaled like the drive).
  int get _uptimeSecs => (_clock().difference(_bootAt).inMilliseconds * timeScale / 1000).floor();

  /// A LiPo slowly draining from 4.10 V: 1 mV per simulated 2 minutes, floor 3.40 V.
  int get _batteryMv => math.max(3400, 4100 - _uptimeSecs ~/ 120);

  @override
  Stream<Uint8List> get incoming => _out.stream;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> disconnect() async => _drop();

  /// Simulates the radio going away (out of range, powered off).
  void simulateDisconnect() => _drop();

  void _drop() {
    if (!_connected) return;
    _connected = false;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _out.close();
  }

  Duration _scaled(Duration d) => Duration(microseconds: (d.inMicroseconds / timeScale).round());

  void _emit(Uint8List frame, [Duration delay = const Duration(milliseconds: 5)]) {
    if (!_connected) return;
    late Timer t;
    t = Timer(_scaled(delay), () {
      _timers.remove(t);
      if (_connected) _out.add(frame);
    });
    _timers.add(t);
  }

  @override
  Future<void> send(Uint8List frame) async {
    if (!_connected) throw StateError('simulated radio disconnected');
    sentFrames.add(Uint8List.fromList(frame));
    if (!responsive || frame.isEmpty) return;
    final bd = ByteData.sublistView(frame);
    switch (frame[0]) {
      case Cmd.appStart:
        if (frame.length < 8) return _emit(encodeErr(ErrCode.illegalArg));
        _emit(encodeSelfInfo(
          txPowerDbm: 22,
          maxTxPowerDbm: 22,
          publicKey: publicKey,
          freqKhz: 910525,
          bwHz: 62500,
          sf: 7,
          cr: 5,
          name: nodeName,
        ));
      case Cmd.deviceQuery:
        _emit(encodeDeviceInfo(
          firmwareVerCode: 9,
          maxChannels: _slots.length,
          buildDate: '1 Oct 2026',
          manufacturer: 'MeshSonar Simulator',
          firmwareVersion: 'v1.18.0-sim',
          pathHashMode: pathHashSize - 1,
        ));
      case Cmd.setDeviceTime:
        if (frame.length < 5) return _emit(encodeErr(ErrCode.illegalArg));
        final secs = bd.getUint32(1, Endian.little);
        if (secs >= _clockSecs) {
          _clockSecs = secs;
          _emit(encodeOk());
        } else {
          _emit(encodeErr(ErrCode.illegalArg));
        }
      case Cmd.getChannel:
        final i = frame.length > 1 ? frame[1] : 255;
        if (i >= _slots.length) return _emit(encodeErr(ErrCode.notFound));
        _emit(encodeChannelInfo(i, _slots[i].name, _slots[i].secret));
      case Cmd.setChannel:
        if (frame.length >= 66) return _emit(encodeErr(ErrCode.unsupportedCmd));
        if (frame.length < 50) return _emit(encodeErr(ErrCode.unsupportedCmd));
        final i = frame[1];
        if (i >= _slots.length) return _emit(encodeErr(ErrCode.notFound));
        final nameBytes = frame.sublist(2, 34).takeWhile((b) => b != 0).toList();
        _slots[i] = _Slot(utf8.decode(nameBytes, allowMalformed: true), Uint8List.fromList(frame.sublist(34, 50)));
        _emit(encodeOk());
      case Cmd.sendChannelTxtMsg:
        if (frame.length < 7 || frame[1] != txtTypePlain) return _emit(encodeErr(ErrCode.unsupportedCmd));
        final i = frame[2];
        if (i >= _slots.length) return _emit(encodeErr(ErrCode.notFound));
        final ts = bd.getUint32(3, Endian.little);
        final text = utf8.decode(frame.sublist(7), allowMalformed: true);
        _emit(encodeOk());
        _sent++;
        _txAirMs += _airMsPerPacket;
        _simulateFlood(_slots[i].secret, ts, text);
      case Cmd.syncNextMessage:
        _emit(encodeNoMoreMessages());
      case Cmd.getStats:
        final nf = noiseFloorDbm;
        if (nf == null) return _emit(encodeErr(ErrCode.unsupportedCmd));
        if (frame.length < 2) return _emit(encodeErr(ErrCode.illegalArg));
        switch (frame[1]) {
          case StatsType.radio:
            _emit(encodeRadioStats(
              noiseFloorDbm: nf + _rng.nextInt(5) - 2,
              lastRssiDbm: _lastRssi,
              lastSnrDb: _lastSnr,
              txAirSecs: _txAirMs ~/ 1000,
              rxAirSecs: _rxAirMs ~/ 1000,
            ));
          case StatsType.core:
            _emit(encodeCoreStats(batteryMv: _batteryMv, uptimeSecs: _uptimeSecs));
          case StatsType.packets:
            _emit(encodePacketStats(
                recv: _recv, sent: _sent, floodTx: _sent, directTx: 0, floodRx: _recv, directRx: 0, recvErrors: 0));
          default:
            _emit(encodeErr(ErrCode.illegalArg));
        }
      case Cmd.getBattAndStorage:
        _emit(encodeBattAndStorage(batteryMv: _batteryMv, usedKb: 120, totalKb: 1984));
      case Cmd.sendControlData:
        if (frame.length < 2 || (frame[1] & 0x80) == 0) return _emit(encodeErr(ErrCode.unsupportedCmd));
        _emit(encodeOk());
        _simulateDiscover(frame.sublist(1));
      default:
        _emit(encodeErr(ErrCode.unsupportedCmd));
    }
  }

  // ---------------------------------------------------------------- radio model

  double get _nf => (noiseFloorDbm ?? -112).toDouble();

  /// Link SNR (dB) over [km]: simple log-distance (exponent ~3.2 in the suburbs) plus Gaussian shadowing.
  double _linkSnr(double km) {
    final d = math.max(km, 0.05);
    return 12.0 - 32.0 * (math.log(d / 0.5) / math.ln10) + _gauss() * 3.0;
  }

  /// Chance a packet at [snr] decodes (LoRa SF7 decodes down to about −7.5 dB).
  bool _decodes(double snr) => _rng.nextDouble() < 1 / (1 + math.exp(-(snr + 7.5) / 1.5));

  double _gauss() {
    final u1 = math.max(_rng.nextDouble(), 1e-12), u2 = _rng.nextDouble();
    return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  double _kmTo(SimulatedRepeater r, ({double lat, double lon}) p) =>
      _distM(_Pt(p.lat, p.lon), _Pt(r.lat, r.lon)) / 1000.0;

  double _kmBetween(SimulatedRepeater a, SimulatedRepeater b) => _distM(_Pt(a.lat, a.lon), _Pt(b.lat, b.lon)) / 1000.0;

  Uint8List _hash(SimulatedRepeater r) => Uint8List.sublistView(r.publicKey, 0, pathHashSize);

  /// Reports a heard packet. RSSI follows the true link, but reported SNR saturates like a real LoRa radio's
  /// (about +10…+14 dB at most, however strong the signal), so strong links read realistically, not +26 dB.
  void _hearPacket(MeshPacket pkt, double snr, Duration delay) {
    _recv++;
    _rxAirMs += _airMsPerPacket;
    final rssi = (_nf + snr).clamp(-140.0, -20.0).round();
    final reported = math.min(snr, 11.5 + _gauss() * 0.75);
    _lastRssi = rssi;
    _lastSnr = reported.clamp(-31.0, 31.0);
    _emit(encodeLogRxData(reported.clamp(-31.0, 31.0), rssi, pkt.toBytes()), delay);
  }

  void _simulateFlood(Uint8List secret, int ts, String text) {
    final me = location.positionAt(_clock());
    final payload = buildGroupTextPayload(secret, ts, nodeName, text);
    final header = makeHeader(RouteType.flood, PayloadType.grpTxt);

    // Hop 1: repeaters that decode our transmission retransmit with path [self].
    final firstHop = <SimulatedRepeater>[];
    final firstDelay = <SimulatedRepeater, Duration>{};
    for (final r in repeaters) {
      final up = _linkSnr(_kmTo(r, me));
      if (!_decodes(up)) continue;
      firstHop.add(r);
      final delay = Duration(milliseconds: 250 + _rng.nextInt(1400));
      firstDelay[r] = delay;
      final down = _linkSnr(_kmTo(r, me)) + 2.0; // repeaters usually sit higher than the car
      if (_decodes(down)) {
        _hearPacket(
          MeshPacket(header: header, pathLenByte: encodePathLen(pathHashSize, 1), path: [_hash(r)], payload: payload),
          down,
          delay,
        );
      }
    }

    // Hop 2: repeaters that didn't hear us but heard a first-hop repeater retransmit with path [A, self].
    for (final b in repeaters) {
      if (firstHop.contains(b)) continue;
      for (final a in firstHop) {
        final abSnr = _linkSnr(_kmBetween(a, b)) + 6.0; // tower-to-tower links are better
        if (!_decodes(abSnr)) continue;
        final down = _linkSnr(_kmTo(b, me)) + 2.0;
        if (_decodes(down)) {
          _hearPacket(
            MeshPacket(
              header: header,
              pathLenByte: encodePathLen(pathHashSize, 2),
              path: [_hash(a), _hash(b)],
              payload: payload,
            ),
            down,
            firstDelay[a]! + Duration(milliseconds: 300 + _rng.nextInt(1200)),
          );
        }
        break; // flood de-dup: B repeats once, the first copy it heard
      }
    }

    // Background traffic that must NOT be counted as an echo: someone else on Public, via a nearby repeater.
    if (firstHop.isNotEmpty && _rng.nextDouble() < 0.3) {
      final r = firstHop[_rng.nextInt(firstHop.length)];
      _hearPacket(
        MeshPacket(
          header: header,
          pathLenByte: encodePathLen(pathHashSize, 1),
          path: [_hash(r)],
          payload: buildGroupTextPayload(publicChannelSecret, ts, 'KD8XYZ', 'anyone on 2m tonight?'),
        ),
        _linkSnr(_kmTo(r, me)),
        Duration(milliseconds: 200 + _rng.nextInt(2000)),
      );
    }
  }

  void _simulateDiscover(Uint8List req) {
    // NODE_DISCOVER_REQ (examples/simple_repeater/MyMesh.cpp ~791): [0x80|prefix][filter][tag u32][since u32].
    if ((req[0] & 0xF0) != 0x80 || req.length < 6) return;
    if ((req[1] & (1 << 2)) == 0) return;
    final prefixOnly = (req[0] & 1) != 0;
    final tag = req.sublist(2, 6);
    final me = location.positionAt(_clock());
    for (final r in repeaters) {
      final up = _linkSnr(_kmTo(r, me));
      if (!_decodes(up)) continue;
      final down = _linkSnr(_kmTo(r, me)) + 2.0;
      if (!_decodes(down)) continue;
      final resp = <int>[
        0x90 | 2,
        (up * 4).round().clamp(-128, 127) & 0xff,
        ...tag,
        ...(prefixOnly ? r.publicKey.sublist(0, 8) : r.publicKey),
      ];
      final rssi = (_nf + down).clamp(-140.0, -20.0).round();
      _emit(encodeControlDataPush(down.clamp(-31.0, 31.0), rssi, 0, resp),
          Duration(milliseconds: 100 + _rng.nextInt(1500)));
    }
  }
}

/// Lists one device, "MeshSonar Simulator"; connecting returns a fresh [SimulatedTransport].
class SimulatedRadioScanner implements RadioScanner {
  static const device = RadioDevice(id: 'meshsonar-simulator', name: 'MeshSonar Simulator', rssi: -50);

  final SimulatedLocationSource? location;
  final int? seed;
  final double timeScale;
  final DateTime Function()? clock;

  /// The transport handed out by the last [connect], for tests and demos.
  SimulatedTransport? lastTransport;

  SimulatedRadioScanner({this.location, this.seed, this.timeScale = 1.0, this.clock});

  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) async* {
    await Future<void>.delayed(Duration(milliseconds: (300 / timeScale).round()));
    yield const [device];
  }

  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    if (device.id != SimulatedRadioScanner.device.id) throw StateError('unknown simulated device ${device.id}');
    final t = SimulatedTransport(location: location, seed: seed, timeScale: timeScale, clock: clock);
    lastTransport = t;
    return t;
  }
}
