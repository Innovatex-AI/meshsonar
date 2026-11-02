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
import 'tools/advert_decode.dart' show buildAdvertPayload;
import 'tools/lpp.dart';
import 'tools/tool_frames.dart';
import 'tools/transport_code.dart';
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
  SimulatedRepeater(this.name, this.lat, this.lon,
      {this.adminPassword = 'admin', this.guestPassword = 'guest', this.silent = false, this.wrongPasswordReplies = true, this.estTimeoutMs = 1200})
      : publicKey = sha256(utf8.encode('meshsonar-sim:$name'));
  String get keyHex => toHex(publicKey);

  /// Remote-request behaviour (CMD_SEND_LOGIN / CMD_SEND_STATUS_REQ), for the remote request queue tests.
  final String adminPassword;
  final String guestPassword;

  /// True: the repeater never answers anything (out of reach, off, busy): the radio still says SENT, then silence.
  bool silent;

  /// True: a wrong password is answered with PUSH_LOGIN_FAIL 0x86. False: pure silence (what most firmware does).
  bool wrongPasswordReplies;

  /// est_timeout the radio reports in SENT for requests to this repeater.
  int estTimeoutMs;

  /// Public-key prefixes (hex, 12 chars) of logins this repeater accepted; a status request needs one.
  final Set<String> loggedIn = {};
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

/// A contact in the simulated radio's table.
class _SimContact {
  final Uint8List key;
  int type;
  int flags = 0;
  int outPathLen = 0xFF;
  Uint8List outPath = Uint8List(0);
  String name;
  int lastAdvert = 0;
  double lat = 0, lon = 0;
  int lastMod;
  _SimContact(this.key, this.type, this.name, this.lastMod);
}

/// A chat contact the simulated radio knows from the start (made-up names and keys).
class SimulatedContact {
  final String name;
  final Uint8List publicKey;
  SimulatedContact(this.name) : publicKey = sha256(utf8.encode('meshsonar-sim-contact:$name'));
  String get keyHex => toHex(publicKey);
}

/// People the simulated radio can chat with. Tests and demos inject messages "from" them.
List<SimulatedContact> defaultSimulatedContacts() => [SimulatedContact('Ann KE8ANN'), SimulatedContact('Bob W8BOB')];

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

  // Settings the Tools can change (SET_ADVERT_NAME, SET_ADVERT_LATLON, SET_RADIO_TX_POWER, SET_RADIO_PARAMS,
  // SET_OTHER_PARAMS); SELF_INFO reports them.
  late String _name = nodeName;
  double _advLat = 0, _advLon = 0;
  int _txDbm = 22;
  int _freqKhz = 910525, _bwHz = 62500, _sf = 7, _cr = 5;

  /// Home page demo / screenshots: other nodes advertise and chatter on the Public channel now and then, so the Rx log and
  /// the adverts list are not empty. Off in tests.
  final bool ambientTraffic;
  Timer? _ambient;
  int _ambientTick = 0;

  /// Adverts this radio sent through SEND_SELF_ADVERT (true = flood), for tests.
  final List<bool> sentAdverts = [];

  /// The radio's current LoRa parameters as the app set them.
  ({int freqKhz, int bwHz, int sf, int cr}) get radioParams => (freqKhz: _freqKhz, bwHz: _bwHz, sf: _sf, cr: _cr);
  String get advertName => _name;
  ({double lat, double lon}) get advertPosition => (lat: _advLat, lon: _advLon);
  int get txPowerDbm => _txDbm;
  final _out = StreamController<Uint8List>.broadcast();
  bool _connected = true;
  final List<Timer> _timers = [];
  final List<_Slot> _slots;
  int _clockSecs = 0;

  // ---- chat traffic (all of it simulated; the real radio's queue behaviour is MyMesh.cpp addToOfflineQueue 224-244)
  /// The radio's offline message queue: RAM only, destructive, [offlineQueueSize] deep (16 is the firmware default).
  final List<Uint8List> _offline = [];
  final int offlineQueueSize;
  final List<_SimContact> _contacts = [];
  int _modClock = 1000;
  int _appTargetVer = 3;
  bool _contactIterating = false;

  /// The contact table size DEVICE_INFO reports (as MAX_CONTACTS / 2 in a byte, so at most 510).
  final int maxContacts;

  /// False: CMD_SET/GET_AUTOADD_CONFIG answer ERR UNSUPPORTED_CMD, like an older firmware.
  final bool autoAddSupported;

  /// Milliseconds between two CONTACT frames of GET_CONTACTS (before [timeScale]).
  final int contactFramePaceMs;

  // SELF_INFO bytes 44-47 and the auto-add config (MyMesh.cpp 1100-1104, 2023-2036). Default = the factory behaviour.
  int manualAddContacts = 0;
  int autoAddConfig = 0; // NodePrefs.h:38 default: with "ask before adding" on, nothing is added by itself
  int autoAddMaxHops = 0;
  int multiAcks = 0, advertLocPolicy = 0, telemetryModes = 0;

  /// Test knob: the link drops after this many CONTACT frames of the next GET_CONTACTS (null = never).
  int? dropAfterContactFrames;

  /// Contact packets each CMD (counted): removes, path resets, imports, shares, for assertions.
  final List<String> contactCommandLog = [];

  /// Test knobs: drop the PUSH_MSG_WAITING tickle (the real BLE queue is lossy), withhold DM ACKs, and the radio's
  /// outbound packet queue length that GET_STATS core reports.
  bool dropMsgWaiting = false;
  bool dropAcks = false;
  int outboundQueueLen = 0;

  /// The next N channel sends are answered with ERR NOT_FOUND although the slot exists: what the firmware does when its
  /// packet pool is full (MyMesh.cpp 1190-1195).
  int busyChannelSends = 0;

  /// Every SET_FLOOD_SCOPE_KEY the radio got, in order: `null` = clear, `'unscoped'`, or the key as hex.
  final List<String?> floodScopeLog = [];

  /// Direct messages the app sent to contacts: (contact key hex, attempt, timestamp, text).
  final List<({String contact, int attempt, int timestamp, String text})> sentDirect = [];

  /// Channel messages the app sent: (slot, text).
  final List<({int slot, String text})> sentChannel = [];

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

  /// The firmware string reported. Ending in `-sim` marks every drive recorded with it as a Simulator drive (never
  /// uploaded: Companion.simulatorFirmwareSuffix). Tests that stand in for a real radio pass another string.
  final String firmwareVersion;

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
    this.firmwareVersion = 'v1.18.0-sim',
    int maxChannels = 8,
    this.offlineQueueSize = 16,
    List<SimulatedContact>? contacts,
    this.maxContacts = 100,
    this.autoAddSupported = true,
    int extraContacts = 0,
    this.contactFramePaceMs = 10,
    this.ambientTraffic = false,
  })  : location = location ?? SimulatedLocationSource(timeScale: timeScale, clock: clock),
        repeaters = repeaters ?? defaultSimulatedRepeaters(),
        _rng = math.Random(seed),
        _clock = clock ?? DateTime.now,
        publicKey = sha256(utf8.encode('meshsonar-sim-companion')),
        _slots = List.generate(maxChannels, (i) => _Slot('', Uint8List(16))) {
    _slots[0] = _Slot('Public', Uint8List.fromList(publicChannelSecret));
    _bootAt = _clock();
    for (final c in contacts ?? defaultSimulatedContacts()) {
      _contacts.add(_SimContact(c.publicKey, AdvType.chat, c.name, _modClock++)..lastAdvert = _clockSecs);
    }
    for (final r in this.repeaters) {
      _contacts.add(_SimContact(r.publicKey, AdvType.repeater, r.name, _modClock++)
        ..lat = r.lat
        ..lon = r.lon);
    }
    for (var i = 0; i < extraContacts; i++) {
      final key = sha256(utf8.encode('meshsonar-sim-extra:$i'));
      _contacts.add(_SimContact(key, i % 5 == 0 ? AdvType.repeater : AdvType.chat, 'Extra ${i.toString().padLeft(3, '0')}', _modClock++)
        ..lastAdvert = _clockSecs
        ..lat = 39.7 + (i % 40) * 0.01
        ..lon = -84.2 + (i % 35) * 0.01);
    }
  }

  /// A message "from the mesh" on channel slot [channelIdx]: queued in the radio's offline queue like a real one, with the
  /// PUSH_MSG_WAITING tickle (unless [dropMsgWaiting]). [sender] becomes the "name: " text prefix. Returns false when the
  /// slot does not exist.
  bool injectChannelMessage(int channelIdx, String sender, String text,
      {int? timestamp, int pathLen = 1, double snrDb = 6.5}) {
    if (!_connected || channelIdx < 0 || channelIdx >= _slots.length) return false;
    final ts = timestamp ?? _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    _enqueueOffline(encodeChannelMsg(channelIdx, '$sender: $text', timestamp: ts, pathLen: pathLen, snrDb: snrDb, v3: _appTargetVer >= 3), isChannel: true);
    return true;
  }

  /// A direct message from the contact [fromKeyHex] (or a name from [defaultSimulatedContacts]). Returns false for an
  /// unknown contact (a real radio would have dropped a DM from a stranger it cannot decrypt).
  bool injectDirectMessage(String from, String text, {int? timestamp, int pathLen = 0xFF, double snrDb = 5.0, int txtType = txtTypePlain}) {
    if (!_connected) return false;
    final c = _contacts.where((c) => toHex(c.key) == from.toLowerCase() || c.name == from).firstOrNull;
    if (c == null) return false;
    final ts = timestamp ?? _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    _enqueueOffline(
        encodeContactText(c.key, text, txtType: txtType, timestamp: ts, pathLen: pathLen, snrDb: snrDb, v3: _appTargetVer >= 3),
        isChannel: false);
    return true;
  }

  /// A node advertising that the radio did not know (BaseChatMesh.cpp onAdvertRecv 156-186). With "ask before adding" on and
  /// the type's auto-add switch off, or when the table is full, or past the hop limit: NEW_ADVERT only, nothing is added
  /// (full also pushes CONTACTS_FULL). Otherwise the radio adds it and pushes ADVERT. Returns true when it was added.
  bool injectNewAdvert(String name, {int type = AdvType.chat, double lat = 0, double lon = 0, int hops = 0}) {
    final key = sha256(utf8.encode('meshsonar-sim-advert:$name'));
    return injectAdvertFrom(key, name, type: type, lat: lat, lon: lon, hops: hops);
  }

  /// Like [injectNewAdvert] for a node with a given 32-byte key.
  bool injectAdvertFrom(List<int> key32, String name, {int type = AdvType.chat, double lat = 0, double lon = 0, int hops = 0}) {
    if (!_connected) return false;
    final key = Uint8List.fromList(key32);
    final adv = _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    final raw = buildUnsignedAdvertPacket(key, type: type, name: name, timestamp: adv, lat: lat == 0 && lon == 0 ? null : lat, lon: lat == 0 && lon == 0 ? null : lon);
    return _hearAdvert(key, name, type, lat, lon, hops, adv, raw);
  }

  /// IMPORT_CONTACT loops the packet back as if heard (BaseChatMesh.cpp 588-601).
  void _importedAdvert(AdvertPacketInfo a, Uint8List raw) {
    final adv = a.timestamp == 0 ? _clock().toUtc().millisecondsSinceEpoch ~/ 1000 : a.timestamp;
    _hearAdvert(a.publicKey, a.name, a.type, a.lat ?? 0, a.lon ?? 0, 0, adv, raw, delay: const Duration(milliseconds: 80));
  }

  final Map<String, Uint8List> _heardAdverts = {};

  bool _hearAdvert(Uint8List key, String name, int type, double lat, double lon, int hops, int adv, Uint8List raw, {Duration delay = Duration.zero}) {
    final known = _contactByPrefix(key, 32);
    if (known != null) {
      known
        ..lastAdvert = adv
        ..lastMod = _modClock++;
      if (name.isNotEmpty) known.name = name;
      _heardAdverts[toHex(key)] = raw;
      _emit(encodeAdvertPush(key), delay);
      return false;
    }
    void announce() => _emit(
        encodeContactFrame(key, type: type, name: name, lastAdvert: adv, lat: lat, lon: lon, lastMod: _modClock, code: Push.newAdvert), delay);
    if (!_shouldAutoAdd(type) || (autoAddMaxHops > 0 && hops >= autoAddMaxHops)) {
      announce();
      return false;
    }
    if (_contacts.length >= maxContacts) {
      if ((autoAddConfig & AutoAddFlags.overwriteOldest) != 0) {
        final candidates = _contacts.where((c) => (c.flags & 1) == 0).toList()..sort((a, b) => a.lastMod.compareTo(b.lastMod));
        if (candidates.isNotEmpty) {
          _contacts.remove(candidates.first);
          _emit(encodeContactDeleted(candidates.first.key), delay);
        }
      }
      if (_contacts.length >= maxContacts) {
        announce();
        _emit(encodeContactsFull(), delay);
        return false;
      }
    }
    _contacts.add(_SimContact(key, type, name, _modClock++)
      ..lat = lat
      ..lon = lon
      ..lastAdvert = adv);
    _heardAdverts[toHex(key)] = raw;
    _emit(encodeAdvertPush(key), delay);
    return true;
  }

  bool _shouldAutoAdd(int type) {
    if ((manualAddContacts & 1) == 0) return true;
    final bit = switch (type) {
      AdvType.chat => AutoAddFlags.chat,
      AdvType.repeater => AutoAddFlags.repeater,
      AdvType.room => AutoAddFlags.room,
      AdvType.sensor => AutoAddFlags.sensor,
      _ => 0,
    };
    return (autoAddConfig & bit) != 0;
  }

  /// The radio's own table size right now.
  int get contactCount => _contacts.length;

  /// Forgets the contact on the radio without telling anyone (a table that changed while the phone was away).
  bool dropContactSilently(String keyHex) {
    final c = _contactByPrefix(fromHex(keyHex), 32);
    return c != null && _contacts.remove(c);
  }

  /// Drops the link now (tests: the radio goes away mid-sync).
  void dropLink() {
    _connected = false;
    for (final t in _timers) {
      t.cancel();
    }
    _timers.clear();
    _contactIterating = false;
    if (!_out.isClosed) _out.close();
  }

  /// Messages waiting in the radio's offline queue.
  int get offlineQueueLength => _offline.length;

  /// Public keys of the contacts in the table, hex.
  List<String> get contactKeys => [for (final c in _contacts) toHex(c.key)];

  // MyMesh.cpp addToOfflineQueue 224-244: when full, the OLDEST CHANNEL message is replaced; with none queued the new frame
  // is dropped. Then the one-byte PUSH_MSG_WAITING.
  void _enqueueOffline(Uint8List frame, {required bool isChannel}) {
    if (_offline.length >= offlineQueueSize) {
      final i = _offline.indexWhere((f) => f[0] == Resp.channelMsgRecv || f[0] == Resp.channelMsgRecvV3 || f[0] == Resp.channelDataRecv);
      if (i < 0) return;
      _offline.removeAt(i);
    }
    _offline.add(frame);
    _recv++;
    if (!dropMsgWaiting) _emit(encodeMsgWaiting());
  }

  /// Simulated seconds since this radio "booted" (scaled like the drive).
  int get _uptimeSecs => (_clock().difference(_bootAt).inMilliseconds * timeScale / 1000).floor();

  /// Chip temperature: 24.0 °C at boot, warming 0.1 °C per simulated minute to 32.0 °C. Simulated, not a model.
  double get _mcuTempC => math.min(32.0, 24.0 + (_uptimeSecs ~/ 60) / 10);

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

  SimulatedRepeater? _repeaterByKey(List<int> key) {
    final k = toHex(key);
    for (final r in repeaters) {
      if (r.keyHex == k) return r;
    }
    return null;
  }

  /// Remote logins the simulated radio got (key prefix hex), in order. Never holds a password.
  final List<String> remoteLoginLog = [];

  /// Remote status requests the radio got (key prefix hex), in order.
  final List<String> remoteStatusLog = [];

  void _onRemoteLogin(Uint8List frame) {
    if (frame.length < 34) return _emit(encodeErr(ErrCode.illegalArg));
    final r = _repeaterByKey(frame.sublist(1, 33));
    if (r == null) return _emit(encodeErr(ErrCode.notFound));
    final pw = utf8.decode(frame.sublist(33).takeWhile((b) => b != 0).toList(), allowMalformed: true);
    remoteLoginLog.add(r.keyHex.substring(0, 12));
    _emit(encodeSent(flood: false, tag: 0x1000 + remoteLoginLog.length, estTimeoutMs: r.estTimeoutMs));
    if (r.silent) return;
    final delay = Duration(milliseconds: 20);
    if (pw == r.adminPassword) {
      r.loggedIn.add(r.keyHex.substring(0, 12));
      _emit(encodeLoginSuccess(r.publicKey, isAdmin: true), delay);
    } else if (pw == r.guestPassword) {
      r.loggedIn.add(r.keyHex.substring(0, 12));
      _emit(encodeLoginSuccess(r.publicKey, isAdmin: false, aclPermissions: 0), delay);
    } else if (r.wrongPasswordReplies) {
      _emit(encodeLoginFail(r.publicKey), delay);
    }
  }

  void _onRemoteStatus(Uint8List frame) {
    if (frame.length < 33) return _emit(encodeErr(ErrCode.illegalArg));
    final r = _repeaterByKey(frame.sublist(1, 33));
    if (r == null) return _emit(encodeErr(ErrCode.notFound));
    remoteStatusLog.add(r.keyHex.substring(0, 12));
    _emit(encodeSent(flood: false, tag: 0x2000 + remoteStatusLog.length, estTimeoutMs: r.estTimeoutMs));
    if (r.silent || !r.loggedIn.contains(r.keyHex.substring(0, 12))) return;
    _emit(
        encodeStatusResponse(
            r.publicKey,
            const RepeaterStatus(
                battMilliVolts: 3860, txQueueLen: 0, noiseFloorDbm: -110, lastRssiDbm: -90, packetsRecv: 10, packetsSent: 5, airTimeSecs: 3, upTimeSecs: 3600, lastSnrDb: 5)),
        const Duration(milliseconds: 20));
  }

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
          txPowerDbm: _txDbm,
          maxTxPowerDbm: 22,
          publicKey: publicKey,
          advLat: _advLat,
          advLon: _advLon,
          freqKhz: _freqKhz,
          bwHz: _bwHz,
          sf: _sf,
          cr: _cr,
          name: _name,
          manualAdd: manualAddContacts,
          telemetryModes: telemetryModes,
          advertLocPolicy: advertLocPolicy,
          multiAcks: multiAcks,
        ));
        if (ambientTraffic) _startAmbient();
      case Cmd.deviceQuery:
        if (frame.length >= 2) _appTargetVer = frame[1];
        _emit(encodeDeviceInfo(
          firmwareVerCode: 9,
          maxContactsHalf: (maxContacts ~/ 2).clamp(1, 255),
          maxChannels: _slots.length,
          buildDate: '1 Oct 2026',
          manufacturer: 'MeshSonar Simulator',
          firmwareVersion: firmwareVersion,
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
        if (busyChannelSends > 0) {
          busyChannelSends--;
          return _emit(encodeErr(ErrCode.notFound));
        }
        final ts = bd.getUint32(3, Endian.little);
        final text = utf8.decode(frame.sublist(7), allowMalformed: true);
        _emit(encodeOk());
        _sent++;
        _txAirMs += _airMsPerPacket;
        sentChannel.add((slot: i, text: text));
        _simulateFlood(_slots[i].secret, ts, text);
      case Cmd.syncNextMessage:
        _emit(_offline.isEmpty ? encodeNoMoreMessages() : _offline.removeAt(0));
      case Cmd.getContacts:
        if (_contactIterating) return _emit(encodeErr(ErrCode.badState));
        _sendContacts(frame.length >= 5 ? bd.getUint32(1, Endian.little) : 0);
      case Cmd.getContactByKey:
        if (frame.length < 33) return _emit(encodeErr(ErrCode.illegalArg));
        final c = _contactByPrefix(frame.sublist(1, 33), 32);
        _emit(c == null ? encodeErr(ErrCode.notFound) : _contactFrame(c));
      case Cmd.addUpdateContact:
        if (frame.length < 1 + 32 + 3 + 64 + 32 + 4) return _emit(encodeErr(ErrCode.illegalArg));
        if (_contactByPrefix(frame.sublist(1, 33), 32) == null && _contacts.length >= maxContacts) {
          return _emit(encodeErr(ErrCode.tableFull));
        }
        _addUpdateContact(frame);
        _emit(encodeOk());
      case Cmd.removeContact:
        if (frame.length < 33) return _emit(encodeErr(ErrCode.illegalArg));
        final rc = _contactByPrefix(frame.sublist(1, 33), 32);
        contactCommandLog.add('remove ${toHex(frame.sublist(1, 33))}');
        if (rc == null) return _emit(encodeErr(ErrCode.notFound));
        _contacts.remove(rc);
        _emit(encodeOk());
      case Cmd.resetPath:
        if (frame.length < 33) return _emit(encodeErr(ErrCode.illegalArg));
        final pc = _contactByPrefix(frame.sublist(1, 33), 32);
        contactCommandLog.add('reset ${toHex(frame.sublist(1, 33))}');
        if (pc == null) return _emit(encodeErr(ErrCode.notFound));
        pc
          ..outPathLen = 0xFF
          ..outPath = Uint8List(0);
        _emit(encodeOk());
      case Cmd.exportContact:
        if (frame.length < 33) return _emit(encodeErr(ErrCode.tableFull));
        final ec = _contactByPrefix(frame.sublist(1, 33), 32);
        final raw = ec == null ? null : _heardAdverts[toHex(ec.key)];
        contactCommandLog.add('export ${toHex(frame.sublist(1, 33))}');
        _emit(raw == null ? encodeErr(ErrCode.notFound) : encodeExportContactResp(raw));
      case Cmd.shareContact:
        if (frame.length < 33) return _emit(encodeErr(ErrCode.illegalArg));
        final sc = _contactByPrefix(frame.sublist(1, 33), 32);
        contactCommandLog.add('share ${toHex(frame.sublist(1, 33))}');
        if (sc == null) return _emit(encodeErr(ErrCode.notFound));
        _emit(_heardAdverts.containsKey(toHex(sc.key)) ? encodeOk() : encodeErr(ErrCode.tableFull));
      case Cmd.importContact:
        contactCommandLog.add('import ${frame.length - 1}');
        if (frame.length <= 2 + 32 + 64) return _emit(encodeErr(ErrCode.unsupportedCmd));
        final adv = decodeAdvertPacket(frame.sublist(1));
        if (adv == null) return _emit(encodeErr(ErrCode.illegalArg));
        _emit(encodeOk());
        _importedAdvert(adv, frame.sublist(1));
      case Cmd.setOtherParams:
        if (frame.length < 2) return _emit(encodeErr(ErrCode.illegalArg));
        manualAddContacts = frame[1];
        if (frame.length >= 3) telemetryModes = frame[2];
        if (frame.length >= 4) advertLocPolicy = frame[3];
        if (frame.length >= 5) multiAcks = frame[4];
        _emit(encodeOk());
      case Cmd.setAutoAddConfig:
        if (!autoAddSupported) return _emit(encodeErr(ErrCode.unsupportedCmd));
        if (frame.length < 2) return _emit(encodeErr(ErrCode.illegalArg));
        autoAddConfig = frame[1];
        if (frame.length >= 3) autoAddMaxHops = frame[2].clamp(0, 64);
        _emit(encodeOk());
      case Cmd.getAutoAddConfig:
        if (!autoAddSupported) return _emit(encodeErr(ErrCode.unsupportedCmd));
        _emit(encodeAutoAddConfig(autoAddConfig, autoAddMaxHops));
      case Cmd.sendTxtMsg:
        _onSendTxt(frame);
      case Cmd.setFloodScopeKey:
        if (frame.length < 2) return _emit(encodeErr(ErrCode.illegalArg));
        floodScopeLog.add(frame[1] == 1 ? 'unscoped' : (frame.length >= 18 ? toHex(frame.sublist(2, 18)) : null));
        _emit(encodeOk());
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
            _emit(encodeCoreStats(batteryMv: _batteryMv, uptimeSecs: _uptimeSecs, queueLen: outboundQueueLen));
          case StatsType.packets:
            _emit(encodePacketStats(
                recv: _recv, sent: _sent, floodTx: _sent, directTx: 0, floodRx: _recv, directRx: 0, recvErrors: 0));
          default:
            _emit(encodeErr(ErrCode.illegalArg));
        }
      case Cmd.getBattAndStorage:
        _emit(encodeBattAndStorage(batteryMv: _batteryMv, usedKb: 120, totalKb: 1984));
      case Cmd.sendLogin:
        _onRemoteLogin(frame);
      case Cmd.sendStatusReq:
        _onRemoteStatus(frame);
      case Cmd.sendTelemetryReq:
        // The 'self' form ([39][3 reserved]) answers with a push only; the key form ([39][3 reserved][key x32]) answers SENT
        // and then a push from the contact (MyMesh.cpp 1680-1718).
        if (frame.length == 4) {
          _emit(encodeSelfTelemetryPush(prefix6: publicKey.sublist(0, 6), voltageV: _batteryMv / 1000, mcuTempC: _mcuTempC));
        } else if (frame.length >= 36) {
          _onTelemetryFor(frame.sublist(4, 36));
        } else {
          _emit(encodeErr(ErrCode.unsupportedCmd));
        }
      case Cmd.sendControlData:
        if (frame.length < 2 || (frame[1] & 0x80) == 0) return _emit(encodeErr(ErrCode.unsupportedCmd));
        _emit(encodeOk());
        _simulateDiscover(frame.sublist(1));
      case ToolCmd.sendSelfAdvert:
        _onSelfAdvert(frame.length >= 2 && frame[1] == 1);
      case ToolCmd.sendTracePath:
        _onTrace(frame);
      case ToolCmd.setAdvertName:
        if (frame.length < 2) return _emit(encodeErr(ErrCode.illegalArg));
        _name = utf8.decode(frame.sublist(1, math.min(frame.length, 32)), allowMalformed: true);
        _emit(encodeOk());
      case ToolCmd.setAdvertLatLon:
        if (frame.length < 9) return _emit(encodeErr(ErrCode.illegalArg));
        final la = bd.getInt32(1, Endian.little), lo = bd.getInt32(5, Endian.little);
        if (la.abs() > 90000000 || lo.abs() > 180000000) return _emit(encodeErr(ErrCode.illegalArg));
        _advLat = la / 1e6;
        _advLon = lo / 1e6;
        _emit(encodeOk());
      case ToolCmd.setRadioTxPower:
        if (frame.length < 2) return _emit(encodeErr(ErrCode.illegalArg));
        final p = bd.getInt8(1);
        if (p < -9 || p > 22) return _emit(encodeErr(ErrCode.illegalArg));
        _txDbm = p;
        _emit(encodeOk());
      case ToolCmd.setRadioParams:
        if (frame.length < 11) return _emit(encodeErr(ErrCode.illegalArg));
        final fk = bd.getUint32(1, Endian.little), bw = bd.getUint32(5, Endian.little), sf = frame[9], cr = frame[10];
        if (fk < 150000 || fk > 2500000 || sf < 5 || sf > 12 || cr < 5 || cr > 8 || bw < 7000 || bw > 500000) {
          return _emit(encodeErr(ErrCode.illegalArg));
        }
        _freqKhz = fk;
        _bwHz = bw;
        _sf = sf;
        _cr = cr;
        _emit(encodeOk());
      default:
        _emit(encodeErr(ErrCode.unsupportedCmd));
    }
  }

  // ---------------------------------------------------------------- contacts and direct messages

  _SimContact? _contactByPrefix(List<int> prefix, int n) {
    for (final c in _contacts) {
      var same = true;
      for (var i = 0; i < n && i < prefix.length; i++) {
        if (c.key[i] != prefix[i]) {
          same = false;
          break;
        }
      }
      if (same) return c;
    }
    return null;
  }

  Uint8List _contactFrame(_SimContact c, {int code = Resp.contact}) => encodeContactFrame(c.key,
      type: c.type,
      name: c.name,
      outPathLen: c.outPathLen,
      outPath: c.outPath,
      flags: c.flags,
      lastAdvert: c.lastAdvert,
      lat: c.lat,
      lon: c.lon,
      lastMod: c.lastMod,
      code: code);

  // GET_CONTACTS (MyMesh.cpp 1238-1258, 2385-2410): CONTACTS_START with the TOTAL, then one CONTACT per entry newer than
  // `since`, paced like the BLE writes, then END_OF_CONTACTS with the most recent lastmod.
  void _sendContacts(int since) {
    _contactIterating = true;
    _emit(encodeContactsStart(_contacts.length));
    var most = 0;
    var delay = contactFramePaceMs;
    var sent = 0;
    final dropAt = dropAfterContactFrames;
    for (final c in List.of(_contacts)) {
      if (c.lastMod <= since) continue;
      if (c.lastMod > most) most = c.lastMod;
      if (dropAt != null && sent >= dropAt) {
        dropAfterContactFrames = null;
        late Timer d;
        d = Timer(_scaled(Duration(milliseconds: delay)), () {
          _timers.remove(d);
          dropLink();
        });
        _timers.add(d);
        return;
      }
      _emit(_contactFrame(c), Duration(milliseconds: delay));
      delay += contactFramePaceMs;
      sent++;
    }
    _emit(encodeEndOfContacts(most), Duration(milliseconds: delay + contactFramePaceMs));
    late Timer t;
    t = Timer(_scaled(Duration(milliseconds: delay + 2 * contactFramePaceMs)), () {
      _timers.remove(t);
      _contactIterating = false;
    });
    _timers.add(t);
  }

  void _addUpdateContact(Uint8List f) {
    final key = Uint8List.fromList(f.sublist(1, 33));
    final bd = ByteData.sublistView(f);
    var c = _contactByPrefix(key, 32);
    if (c == null) {
      c = _SimContact(key, f[33], '', _modClock++);
      _contacts.add(c);
    }
    c
      ..type = f[33]
      ..flags = f[34]
      ..outPathLen = f[35]
      ..outPath = Uint8List.fromList(f.sublist(36, 36 + pathByteLength(f[35]).clamp(0, 64)))
      ..name = utf8.decode(f.sublist(100, 132).takeWhile((b) => b != 0).toList(), allowMalformed: true)
      ..lastAdvert = bd.getUint32(132, Endian.little);
    if (f.length >= 144) {
      c
        ..lat = bd.getInt32(136, Endian.little) / 1e6
        ..lon = bd.getInt32(140, Endian.little) / 1e6;
    }
    c.lastMod = _modClock++;
  }

  // CMD_SEND_TXT_MSG (MyMesh.cpp 1132-1177): plain text expects an ACK; CLI types expect none.
  void _onSendTxt(Uint8List f) {
    if (f.length < 14) return _emit(encodeErr(ErrCode.illegalArg));
    final txt = f[1], attempt = f[2];
    final ts = ByteData.sublistView(f).getUint32(3, Endian.little);
    final c = _contactByPrefix(f.sublist(7, 13), 6);
    if (c == null) return _emit(encodeErr(ErrCode.notFound));
    if (txt != txtTypePlain && txt != txtTypeCliData && txt != txtTypeCliCommand) return _emit(encodeErr(ErrCode.unsupportedCmd));
    final text = utf8.decode(f.sublist(13), allowMalformed: true);
    final flood = c.outPathLen == 0xFF;
    var ack = 0;
    if (txt == txtTypePlain) {
      // The tag only has to be stable per (timestamp, attempt & 3, text, sender): attempts N and N+4 collide, like the real hash.
      final h = sha256([...f.sublist(3, 7), attempt & 3, ...utf8.encode(text), ...publicKey]);
      ack = ByteData.sublistView(h).getUint32(0, Endian.little);
      sentDirect.add((contact: toHex(c.key), attempt: attempt & 3, timestamp: ts, text: text));
    }
    _sent++;
    _txAirMs += _airMsPerPacket;
    _emit(encodeSent(flood: flood, tag: ack, estTimeoutMs: flood ? 2500 : 1200));
    if (ack != 0 && !dropAcks && c.type == AdvType.chat) {
      _emit(encodeSendConfirmed(ack, 400 + _rng.nextInt(800)), Duration(milliseconds: 600 + _rng.nextInt(800)));
      if (flood) {
        // The radio learns a path from the exchange (MyMesh.cpp 409-415).
        c
          ..outPathLen = 1
          ..outPath = Uint8List.fromList([repeaters.isEmpty ? 0x11 : repeaters.first.publicKey[0]])
          ..lastMod = _modClock++;
        _emit(encodePathUpdated(c.key), const Duration(milliseconds: 1500));
      }
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
    final payload = buildGroupTextPayload(secret, ts, _name, text);
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

  // ---------------------------------------------------------------- Tools: adverts, trace, telemetry, ambient traffic

  /// Reported SNR saturates like a real radio's (see [_hearPacket]).
  double _reportSnr(double snr) => math.min(snr, 11.5 + _gauss() * 0.75).clamp(-31.0, 31.0);

  void _onSelfAdvert(bool flood) {
    sentAdverts.add(flood);
    _sent++;
    _txAirMs += 350;
    _emit(encodeOk());
    if (!flood) return;
    // Repeaters that hear the advert repeat it with their hash in the path; this radio hears the repeats.
    final me = location.positionAt(_clock());
    final payload = buildAdvertPayload(publicKey, _clock().toUtc().millisecondsSinceEpoch ~/ 1000, AdvType.chat, _name,
        lat: advertLocPolicy != 0 && (_advLat != 0 || _advLon != 0) ? _advLat : null,
        lon: advertLocPolicy != 0 && (_advLat != 0 || _advLon != 0) ? _advLon : null);
    for (final r in repeaters) {
      final up = _linkSnr(_kmTo(r, me));
      if (!_decodes(up)) continue;
      final down = _linkSnr(_kmTo(r, me)) + 2.0;
      if (!_decodes(down)) continue;
      _hearPacket(
          MeshPacket(header: makeHeader(RouteType.flood, PayloadType.advert), pathLenByte: encodePathLen(pathHashSize, 1), path: [_hash(r)], payload: payload),
          down,
          Duration(milliseconds: 400 + _rng.nextInt(1800)));
    }
  }

  // CMD_SEND_TRACE_PATH (MyMesh.cpp 1813-1832): a hop that does not exist, or a link that does not decode, gives silence.
  void _onTrace(Uint8List f) {
    if (f.length <= 10) return _emit(encodeErr(ErrCode.unsupportedCmd));
    final flags = f[9];
    final sz = 1 << (flags & 3);
    final path = f.sublist(10);
    if (path.length % sz != 0) return _emit(encodeErr(ErrCode.illegalArg));
    final tag = ByteData.sublistView(f).getUint32(1, Endian.little);
    final hops = path.length ~/ sz;
    _emit(encodeSent(tag: tag, estTimeoutMs: 1800 + 400 * hops));
    _sent++;
    _txAirMs += _airMsPerPacket;
    final me = location.positionAt(_clock());
    final chain = <SimulatedRepeater>[];
    for (var i = 0; i < hops; i++) {
      final h = path.sublist(i * sz, (i + 1) * sz);
      final r = repeaters.where((r) {
        for (var k = 0; k < sz; k++) {
          if (r.publicKey[k] != h[k]) return false;
        }
        return true;
      }).firstOrNull;
      if (r == null) return; // missing hop: silence
      chain.add(r);
    }
    final snrs = <double>[];
    for (var i = 0; i < chain.length; i++) {
      final link = i == 0 ? _linkSnr(_kmTo(chain[0], me)) : _linkSnr(_kmBetween(chain[i - 1], chain[i])) + 6.0;
      if (!_decodes(link)) return;
      snrs.add(_reportSnr(link));
    }
    final back = _linkSnr(_kmTo(chain.last, me)) + 2.0;
    if (!_decodes(back)) return;
    _emit(encodeTraceDataPush(tag, path, snrs, _reportSnr(back), hashSize: sz), Duration(milliseconds: 250 + 250 * hops + _rng.nextInt(200)));
  }

  void _onTelemetryFor(List<int> key) {
    final c = _contactByPrefix(key, 32);
    if (c == null) return _emit(encodeErr(ErrCode.notFound));
    _emit(encodeSent(tag: 0x7e1e, estTimeoutMs: 1800));
    if (c.type == AdvType.chat) return; // companions do not answer telemetry unless allowed: silence
    final lpp = <int>[
      ...lppVoltage(3.80 + (c.key[3] % 40) / 100),
      ...lppTemperature(18.0 + (c.key[4] % 200) / 10),
      if (c.lat != 0 || c.lon != 0) ...lppGps(c.lat, c.lon, 215),
    ];
    _emit(encodeTelemetryResponsePush(c.key.sublist(0, 6), lpp), const Duration(milliseconds: 700));
  }

  /// An advert "from the air": the RX log gets the packet, and the radio pushes ADVERT (a contact) or NEW_ADVERT (not a
  /// contact; it is added to the table unless the radio is in manual-add mode). [scope] puts a real transport code for that
  /// region name on the packet. Returns false when the radio is gone.
  bool injectAdvertHeard(String name,
      {int type = AdvType.repeater, double? lat, double? lon, List<int> pathHashes = const [], String? scope, double snrDb = 4.5, int? timestamp}) {
    if (!_connected) return false;
    final key = sha256(utf8.encode('meshsonar-sim-advert:$name'));
    final ts = timestamp ?? _clock().toUtc().millisecondsSinceEpoch ~/ 1000;
    final payload = buildAdvertPayload(key, ts, type, name, lat: lat, lon: lon);
    final path = [for (final h in pathHashes) Uint8List.fromList([h])];
    final scoped = scope != null;
    final pkt = MeshPacket(
      header: makeHeader(scoped ? RouteType.transportFlood : RouteType.flood, PayloadType.advert),
      transportCode1: scoped ? transportCodeFor(regionTransportKey(scope), PayloadType.advert, payload) : null,
      transportCode2: scoped ? 0 : null,
      pathLenByte: encodePathLen(1, path.length),
      path: path,
      payload: payload,
    );
    _recv++;
    _rxAirMs += _airMsPerPacket;
    final rssi = (_nf + snrDb).clamp(-140.0, -20.0).round();
    _lastRssi = rssi;
    _lastSnr = snrDb;
    _emit(encodeLogRxData(snrDb, rssi, pkt.toBytes()));
    final known = _contactByPrefix(key, 32);
    if (known != null) {
      _emit(encodeAdvertPush(key), const Duration(milliseconds: 10));
    } else if ((manualAddContacts & 1) == 0) {
      final c = _SimContact(key, type, name, _modClock++)
        ..lat = lat ?? 0
        ..lon = lon ?? 0
        ..lastAdvert = ts;
      _contacts.add(c);
      _emit(encodeContactFrame(key, type: type, name: name, lastAdvert: ts, lat: lat ?? 0, lon: lon ?? 0, lastMod: c.lastMod, code: Push.newAdvert),
          const Duration(milliseconds: 10));
    }
    return true;
  }

  /// Some other node's channel message "in the air" (header-only interest: the RX log shows it as a channel packet).
  void injectChatter(String sender, String text, {int slot = 0, List<int> pathHashes = const [0x1a], double snrDb = 2.0}) {
    if (!_connected || slot < 0 || slot >= _slots.length) return;
    final payload = buildGroupTextPayload(_slots[slot].secret, _clock().toUtc().millisecondsSinceEpoch ~/ 1000, sender, text);
    final path = [for (final h in pathHashes) Uint8List.fromList([h])];
    final pkt = MeshPacket(
        header: makeHeader(RouteType.flood, PayloadType.grpTxt), pathLenByte: encodePathLen(1, path.length), path: path, payload: payload);
    _recv++;
    _emit(encodeLogRxData(snrDb, (_nf + snrDb).round(), pkt.toBytes()));
  }

  void _startAmbient() {
    if (_ambient != null) return;
    _ambient = Timer.periodic(_scaled(const Duration(seconds: 6)), (_) {
      if (!_connected) return;
      final i = _ambientTick++;
      final r = repeaters[i % repeaters.length];
      if (i % 3 == 2) {
        injectChatter(['KD8XYZ', 'N8OHI', 'W8LAB'][i % 3], ['anyone around?', 'check check', 'net starts at 8'][(i ~/ 3) % 3]);
      } else {
        injectAdvertHeard(r.name,
            type: AdvType.repeater,
            lat: r.lat,
            lon: r.lon,
            pathHashes: i % 4 == 0 ? const [] : [repeaters[(i + 1) % repeaters.length].publicKey[0]],
            scope: i % 2 == 0 ? '#cmh' : null,
            snrDb: 6.0 - (i % 7));
      }
    });
    _timers.add(_ambient!);
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
  final String firmwareVersion;

  /// Other nodes advertise and chatter now and then (the app's Simulator; not tests).
  final bool ambientTraffic;

  /// The transport handed out by the last [connect], for tests and demos.
  SimulatedTransport? lastTransport;

  /// Chat traffic into the connected simulated radio (see [SimulatedTransport.injectChannelMessage]); false when none is
  /// connected. For debug screens and UI tests.
  bool injectChannelMessage(int channelIdx, String sender, String text) =>
      lastTransport?.injectChannelMessage(channelIdx, sender, text) ?? false;

  /// See [SimulatedTransport.injectDirectMessage].
  bool injectDirectMessage(String from, String text) => lastTransport?.injectDirectMessage(from, text) ?? false;

  /// Contact table of the simulated radio: its size (DEVICE_INFO), how many extra made-up contacts it starts with, whether it
  /// has the auto-add config commands, and the pause between CONTACT frames (ms before [timeScale]).
  final int maxContacts;
  final int extraContacts;
  final bool autoAddSupported;
  final int contactFramePaceMs;

  SimulatedRadioScanner({
    this.location,
    this.seed,
    this.timeScale = 1.0,
    this.clock,
    this.firmwareVersion = 'v1.18.0-sim',
    this.maxContacts = 100,
    this.extraContacts = 0,
    this.autoAddSupported = true,
    this.contactFramePaceMs = 10,
    this.ambientTraffic = false,
  });

  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) async* {
    await Future<void>.delayed(Duration(milliseconds: (300 / timeScale).round()));
    yield const [device];
  }

  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    if (device.id != SimulatedRadioScanner.device.id) throw StateError('unknown simulated device ${device.id}');
    final t = SimulatedTransport(
        location: location,
        seed: seed,
        timeScale: timeScale,
        clock: clock,
        firmwareVersion: firmwareVersion,
        maxContacts: maxContacts,
        extraContacts: extraContacts,
        autoAddSupported: autoAddSupported,
        contactFramePaceMs: contactFramePaceMs,
        ambientTraffic: ambientTraffic);
    lastTransport = t;
    return t;
  }
}
