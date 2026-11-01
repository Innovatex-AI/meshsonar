// DefaultWardriveEngine: pings a channel on a time/distance schedule and records which repeaters repeated each ping.
//
// Behaviour is modelled on the MeshMapper web client (MIT, © 2025 MrAlders0n), content/wardrive.js:
//  - ping text: "MS:" + a random 10-character tag (e.g. "MS:m3jnr7dan5"). PRIVACY: the text goes out on a public channel
//    that anyone can read, so it NEVER carries a position or anything about the driver (MeshMapper's "@[MapperBot] <lat>,
//    <lon>" does; we do not). The tag is random per ping, made from the secure random source, and is stored with the ping
//    (`wire_tag`) so a heard repeat can be matched to exactly this ping during analysis. Where the ping happened is
//    recorded on the phone from its GPS and uploaded with the drive; the site also joins observer receptions by packet
//    hash (Drive Format v1.1 pkt_hash), so the air needs no coordinates;
//  - sendPing(): read the noise floor (CMD_GET_STATS radio), take a GPS fix, send on the channel, then listen to the
//    RX log for the listen window (RX_LOG_LISTEN_WINDOW_MS); auto mode waits the interval after each ping and won't
//    ping too close to the last one (validateMinimumDistance, haversine);
//  - handleTxLogging(): an echo is a GRP_TXT on our channel whose decrypted text is our ping and whose path is not
//    empty; repeater id = first path hop; one entry per repeater, best SNR kept.
// See packet.dart for where we deliberately differ (transport-flood, multi-byte path hashes, MAC/timestamp check).
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../core/api.dart' show Settings;
import '../core/model.dart';
import 'companion_link.dart';
import 'ping_gate.dart';
import 'crypto.dart';
import 'packet.dart';
import 'protocol.dart';
import 'radio_api.dart';

/// What every MeshSonar ping starts with on the channel.
const String pingPrefix = 'MS:';

const String _tagAlphabet = '0123456789abcdefghijklmnopqrstuvwxyz';

/// Length of the random part of a ping's tag.
const int pingTagLength = 10;

final math.Random _secureRandom = math.Random.secure();

/// A fresh random tag for one ping: [pingTagLength] characters of 0-9 a-z, from the secure random source, with no link to
/// the position, the time or the driver. Pass [random] only in tests.
String newPingTag({math.Random? random}) {
  final r = random ?? _secureRandom;
  return String.fromCharCodes([for (var i = 0; i < pingTagLength; i++) _tagAlphabet.codeUnitAt(r.nextInt(_tagAlphabet.length))]);
}

/// The text of a ping on the public channel: "MS:" and the ping's tag. It takes no position (and nothing else) on purpose:
/// nothing about where the driver is may go out on a channel anyone can read.
String formatPingText(String tag) => '$pingPrefix$tag';

/// "1.0w", "0.3w", "2.0w" — MeshMapper's style. Small powers keep two decimals so they don't round to "0.0w".
String formatPowerW(double w) => '${w < 0.1 ? w.toStringAsFixed(2) : w.toStringAsFixed(1)}w';

/// Great-circle distance in metres (MeshMapper calculateHaversineDistance, R = 6371 km).
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

class _Heard {
  final RxPacket rx;
  final DateTime arrived;
  _Heard(this.rx, this.arrived);
}

class _Waited {
  Duration d = Duration.zero;
}

class _Tail {
  final String id, tag, text;
  final int? ts;
  final DateTime sentAt;
  final Uint8List secret;
  final List<_Heard> frames = [];
  _Tail(this.id, this.tag, this.text, this.ts, this.sentAt, this.secret);
}

class _Ctl {
  final ControlPacket pkt;
  _Ctl(this.pkt);
}

// ------------------------------------------------------------------ discovery / listen-only (passive RX)
//
// Source: meshsonar-infra/docs/planning/meshmapper-teardown.md §3.3-3.4 (this project's own prior research, citing
// wiki.meshmapper.net and github.com/MeshMapper/MeshMapper_Flutter_App). MeshMapper's own "Passive" mode still
// transmits a zero-hop DISC request every 30 s — not fully silent. Its separate Passive RX logging pipeline is
// continuous and independent of transmission: it overhears GRP_TXT/ADVERT traffic, keys each sighting by the
// LAST-hop repeater (src/Mesh.cpp routeRecvPacket() appends each repeater's own hash to the END of the path before
// re-flooding, so the last path entry — not the first — is the repeater we actually, physically heard), keeps the
// best-SNR sighting per repeater, and flushes a batch every 25 m moved or 30 s elapsed, whichever comes first.
//
// This app's privacy stance is non-negotiable and stricter than MeshMapper's: listen-only means nothing goes out,
// not even a zero-hop ping. So we mirror the Passive RX pipeline (continuous overhearing, last-hop keying, 25 m /
// 30 s batching, best-SNR-per-repeater) but drop the DISC-every-30s transmission entirely.

/// How often a passive (listen-only) batch flushes, at most, even standing still.
const Duration passiveFlushInterval = Duration(seconds: 30);

/// After this long without any GPS fix the status tells the driver where to look (Location off, permission taken away).
const Duration noGpsHintAfter = Duration(seconds: 20);

/// A ping is only sent from a fix at least this accurate (metres). A worse one (a cell-tower or Wi-Fi guess, hundreds of
/// metres off) would put the ping on the wrong place on the map: the engine says "waiting for GPS" instead.
const double maxPingAccuracyM = 50;

/// How far the phone must move since the last flush to force an early one.
const double passiveFlushDistanceM = 25;

class DefaultWardriveEngine implements WardriveEngine {
  /// The radio session. Replaced by [resumeOnLink] when the radio drops mid-drive and the app reconnects.
  CompanionLink link;
  final LocationSource location;
  final DateTime Function() _clock;
  final String Function() _newId;

  /// Also send a zero-hop NODE_DISCOVER_REQ after each ping and record the strongest repeater that answers as the
  /// ping's `neighbor` (a genuine two-way exchange: the repeater reports the SNR it heard us at; firmware v8+).
  /// Off by default: it adds airtime on every ping and repeaters rate-limit discovery to 4 per 2 minutes
  /// (examples/simple_repeater/MyMesh.cpp discover_limiter). Only used with a [MeshCoreCompanionLink].
  bool discoverNeighbors = false;

  /// Asked before every ping (the session's TxArbiter). The default always says go: the engine's own interval and
  /// distance rule alone decide, as before sessions existed. A skipped ping is not retried late: the cadence check simply
  /// asks again after [pingSkipRetry].
  PingGate pingGate = const AlwaysGoPingGate();

  /// How long after a skipped ping the engine waits before asking the gate again.
  Duration pingSkipRetry = const Duration(seconds: 2);

  /// Pings the gate refused during this drive, by reason.
  final Map<PingSkipReason, int> skippedPings = {};

  /// Receives one JSON-ready record per ping (and per skipped ping, and per late tail): every frame the radio reported
  /// around the ping with its arrival time and why it did or did not count. The app writes them to `trace.jsonl` beside
  /// the drive. Local only: never uploaded, never part of the drive format.
  void Function(Map<String, Object?> record)? onTrace;

  /// Keep listening past the window while repeats are still arriving (see [_listenAdaptive]). On by default; the
  /// window never grows past [maxListen] or past the time the next ping is due.
  bool adaptiveListen = true;

  /// Listen windows shorter than this are never extended.
  Duration minAdaptiveBase = const Duration(seconds: 5);

  /// Hard ceiling of an extended listen.
  Duration maxListen = const Duration(seconds: 15);

  /// An extended listen carries on while the newest repeat is younger than this.
  Duration extendGap = const Duration(seconds: 4);

  /// After a ping's window closes its late repeats are still noted in the trace (never in the ping) until this long
  /// after the send or the next ping, whichever is first.
  Duration traceTail = const Duration(seconds: 20);

  final _pings = StreamController<DrivePing>.broadcast();
  final _status = StreamController<EngineStatus>.broadcast();
  EngineStatus _current = const EngineStatus(EngineState.idle);

  WardriveConfig _config = const WardriveConfig();
  int? _channelIndex;
  Uint8List? _secret;
  StreamSubscription<RxPacket>? _rxSub;

  // Auto-ping cadence: a ping goes out once BOTH the interval since the last ping has passed AND we've moved
  // minDistanceM from where it was sent. Checked on every GPS fix and on a [tick] timer.
  final Duration tick;
  Timer? _autoTimer;
  Timer? _dueTimer; // fires exactly when the next ping is due, so the cadence is the interval, not the interval + a tick
  StreamSubscription<GeoFix>? _fixSub;
  DateTime? _nextPingAt;
  DateTime? _lastPingTime; // when the last ping (auto or manual) was sent
  DateTime? _retryAfter; // after a failed auto ping, don't retry before this
  bool _evaluating = false;
  DateTime? _noFixTraceAt;
  DateTime? _noFixSince; // since when there has been no GPS fix at all (permission off, Location Services off, no sky)
  Duration? _clockSkew; // see EngineStatus.clockSkew
  int _skewRun = 0;
  Duration? _skewLast;
  PingWait? _waitingFor;
  PingDecision? _lastSkip;
  double? _metresToGo;
  bool _running = false;
  bool _stopping = false;
  bool _busy = false;
  Future<void> _pingChain = Future.value();
  Future<void>? _inFlight;
  void Function(RxPacket rx)? _collector;
  ({double lat, double lon})? _lastPingAt;
  GeoFix? _lastFix;
  final _rng = math.Random();

  // Passive (listen-only) pipeline state: best echo seen per repeater since the last flush, the position the
  // current window started at, and when it must flush at the latest.
  final Map<String, Echo> _passiveBest = {};
  ({double lat, double lon})? _passiveOrigin;
  DateTime? _passiveFlushDeadline;
  Timer? _passiveTimer;
  StreamSubscription<GeoFix>? _passiveFixSub;

  DefaultWardriveEngine({
    required this.link,
    required this.location,
    DateTime Function()? clock,
    String Function()? newId,
    this.tick = const Duration(seconds: 1),
  })  : _clock = clock ?? DateTime.now,
        _newId = newId ?? const Uuid().v4;

  @override
  Stream<DrivePing> get pings => _pings.stream;
  @override
  Stream<EngineStatus> get status => _status.stream;
  @override
  EngineStatus get current => _current;

  int? _heardSoFar;

  void _setStatus(EngineState s, [String? message]) {
    // Listen-only never pings, so a countdown / "move N m" / waiting-for-GPS status is meaningless in this mode.
    final auto = _running && !_config.listenOnly && _config.intervalSec > 0;
    _current = EngineStatus(
      s,
      message: message,
      lastFix: _lastFix,
      nextPingAt: auto ? _nextPingAt : null,
      waitingFor: auto ? _waitingFor : null,
      metresToGo: auto ? _metresToGo : null,
      clockSkew: _clockSkew,
      heardSoFar: s == EngineState.pinging ? _heardSoFar : null,
    );
    if (!_status.isClosed) _status.add(_current);
  }

  /// Keeps config values inside the ranges the app allows (Settings.minIntervalSec…): never hammer the mesh.
  /// intervalSec ≤ 0 stays 0 (manual pings only).
  static WardriveConfig clampConfig(WardriveConfig c) => WardriveConfig(
        channel: c.channel,
        intervalSec: c.intervalSec <= 0 ? 0 : c.intervalSec.clamp(Settings.minIntervalSec, Settings.maxIntervalSec),
        minDistanceM: c.minDistanceM.clamp(Settings.minDistance, Settings.maxDistance),
        listenWindow: c.listenWindow,
        txPowerW: c.txPowerW,
        txDbm: c.txDbm,
        listenOnly: c.listenOnly,
      );

  /// The listen window of a ping: the configured one, but never so long that it eats the interval (a 10 s interval with
  /// the default 10 s window would make every ping late): at most the interval less a second, and at least 7 s.
  Duration get _window {
    final w = _config.listenWindow;
    if (_config.intervalSec <= 0) return w;
    final room = Duration(seconds: math.max(7, _config.intervalSec - 1));
    return w < room ? w : room;
  }

  /// Shortest time between two auto pings: the interval, and never less than one listen window.
  Duration get _minGap {
    final i = Duration(seconds: _config.intervalSec);
    return i < _window ? _window : i;
  }

  /// Keeps the state, updates the message.
  void _note(String message) => _setStatus(_current.state, message);

  @override
  Future<void> start(WardriveConfig config) async {
    if (_running || _current.state == EngineState.starting) throw StateError('already driving');
    _config = clampConfig(config);
    config = _config;
    _lastPingAt = null;
    _lastPingTime = null;
    _retryAfter = null;
    _waitingFor = null;
    _metresToGo = null;
    _nextPingAt = null;
    _noFixSince = null;
    _clockSkew = null;
    _skewRun = 0;
    _skewLast = null;
    _stopping = false;
    _setStatus(EngineState.starting, 'Joining ${config.channel}');
    try {
      await _bindLink();
    } catch (e) {
      _setStatus(EngineState.error, _describe(e));
      rethrow;
    }
    _running = true;
    if (_config.listenOnly) {
      _setStatus(EngineState.driving, 'Listening');
      _startPassive();
    } else {
      _setStatus(EngineState.driving, config.intervalSec > 0 ? 'Driving' : 'Ready (manual pings)');
      _startAuto();
    }
  }

  /// Joins the channel on the current [link], learns its key and starts listening to what the radio hears.
  Future<void> _bindLink() async {
    if (!link.isConnected) throw StateError('Radio not connected');
    final idx = await link.ensureChannel(_config.channel);
    Uint8List? secret;
    final l = link;
    if (l is MeshCoreCompanionLink) secret = l.channelSecret(idx);
    secret ??= wellKnownChannelSecret(_config.channel);
    if (secret == null) {
      // Without the key we can't tell our echoes apart, and every ping would look like "heard nothing".
      throw StateError('Cannot recognise echoes on ${_config.channel}: channel key unknown');
    }
    _channelIndex = idx;
    _secret = secret;
    await _rxSub?.cancel();
    final bound = l;
    _rxSub = l.rxPackets.listen((rx) => _collector?.call(rx), onDone: () {
      if (identical(link, bound)) _onRadioLost(); // a late "done" from a link we already replaced is not a new drop
    });
  }

  @override
  Future<void> resumeOnLink(CompanionLink newLink) async {
    if (_stopping) throw StateError('The drive is stopping');
    if (_running && identical(link, newLink) && newLink.isConnected) return;
    if (_current.state != EngineState.error && !_running) throw StateError('Not driving: start() first');
    if (_running) _onRadioLost(); // the old radio is being replaced: wind it down the same way as a drop
    // A ping that was on the air ends at once (its listen window sees the radio gone); wait for it.
    final inflight = _inFlight;
    if (inflight != null) await inflight;
    link = newLink;
    _setStatus(EngineState.starting, 'Rejoining ${_config.channel}');
    try {
      await _bindLink();
    } catch (e) {
      _setStatus(EngineState.error, _describe(e));
      rethrow;
    }
    if (_stopping) return;
    _retryAfter = null;
    _running = true;
    // _lastPingTime / _lastPingAt are kept: the cadence carries on as if the radio had never dropped.
    if (_config.listenOnly) {
      _setStatus(EngineState.driving, 'Listening');
      _startPassive();
    } else {
      _setStatus(EngineState.driving, _config.intervalSec > 0 ? 'Driving' : 'Ready (manual pings)');
      _startAuto();
    }
  }

  @override
  void updateConfig(WardriveConfig config) {
    if (!_running || _stopping) return;
    final c = clampConfig(config);
    _config = WardriveConfig(
      channel: _config.channel, // can't switch channel mid-drive
      intervalSec: c.intervalSec,
      minDistanceM: c.minDistanceM,
      listenWindow: c.listenWindow,
      txPowerW: c.txPowerW,
      txDbm: c.txDbm,
      listenOnly: _config.listenOnly, // can't switch mid-drive either, same as the channel
    );
    if (_config.listenOnly) return; // interval/distance don't apply; the passive pipeline is already running
    _startAuto();
    if (_config.intervalSec <= 0 && !_busy) _setStatus(EngineState.driving, 'Ready (manual pings)');
  }

  void _onRadioLost() {
    if (!_running) return;
    if (!_busy) _closeTail();
    _running = false;
    _stopAuto();
    if (_config.listenOnly) _stopPassive();
    _setStatus(EngineState.error, 'Radio disconnected');
  }

  /// True (and the drop handled) when the radio has gone away without any stream telling us.
  bool _radioGone() {
    if (!_running || link.isConnected) return false;
    _onRadioLost();
    return true;
  }

  // ------------------------------------------------------------------ passive (listen-only) pipeline

  void _startPassive() {
    _passiveBest.clear();
    _passiveOrigin = _lastFix == null ? null : (lat: _lastFix!.lat, lon: _lastFix!.lon);
    _passiveFlushDeadline = _clock().add(passiveFlushInterval);
    _collector = _onPassiveHeard;
    _passiveTimer = Timer.periodic(tick, (_) {
      if (_radioGone()) return;
      final deadline = _passiveFlushDeadline;
      if (deadline != null && !_clock().isBefore(deadline)) _flushPassive();
    });
    try {
      _passiveFixSub = location.fixes.listen((f) {
        _lastFix = f;
        _lastFixArrived = _clock();
        _onPassiveFix(f);
      }, onError: (Object _) {});
    } catch (_) {
      _passiveFixSub = null; // no stream: the timer still flushes on elapsed time
    }
    // Don't wait on the GPS stream's own cadence for a starting position: ask once up front too, same helper the
    // ping flows use, so a batch heard before the stream's first fix still has somewhere to land.
    if (_passiveOrigin == null) {
      unawaited(_fix().then((f) {
        if (f != null && _passiveOrigin == null && _running) _passiveOrigin = (lat: f.lat, lon: f.lon);
      }));
    }
  }

  void _onPassiveFix(GeoFix f) {
    final origin = _passiveOrigin;
    if (origin == null) {
      _passiveOrigin = (lat: f.lat, lon: f.lon);
      return;
    }
    if (haversineM(origin.lat, origin.lon, f.lat, f.lon) >= passiveFlushDistanceM) _flushPassive();
  }

  /// Called for every packet the radio hears while listen-only is active (the whole drive, not a short window
  /// after a ping — there is no ping). Filters to flood GRP_TXT with a non-empty path, decryptable on the
  /// channel's own secret; keys the sighting by the LAST path hop (the repeater we actually, physically heard —
  /// see the pipeline note above), keeping the best SNR per repeater since the last flush.
  void _onPassiveHeard(RxPacket rx) {
    final secret = _secret;
    if (secret == null) return;
    final pkt = MeshPacket.tryParse(rx.raw);
    if (pkt == null) return;
    if (pkt.payloadType != PayloadType.grpTxt || !pkt.isFlood || pkt.path.isEmpty) return;
    if (decryptGroupText(secret, pkt.payload) == null) return;
    final repeater = pkt.pathHex.last;
    final snr = _inRange(rx.snrDb, -40, 40);
    final prev = _passiveBest[repeater];
    if (prev != null && (prev.snrDb ?? double.negativeInfinity) >= (snr ?? double.negativeInfinity)) return;
    _passiveBest[repeater] = Echo(
      repeater: repeater,
      snrDb: snr,
      rssiDbm: _inRange(rx.rssiDbm, -160, 0),
      hops: 1, // the last-hop repeater is always a direct hear, whatever the packet's total hop count was
      path: pkt.pathHex,
    );
  }

  /// Emits one rx-kind [DrivePing] per repeater heard since the last flush, then resets the window. Called at
  /// [passiveFlushInterval] elapsed, [passiveFlushDistanceM] moved, or when listen-only stops (so a partial batch
  /// is never silently lost).
  void _flushPassive() {
    final fix = _lastFix;
    final origin = _passiveOrigin ?? (fix == null ? null : (lat: fix.lat, lon: fix.lon));
    if (_passiveBest.isNotEmpty && origin != null) {
      final now = _clock();
      for (final echo in _passiveBest.values) {
        final ping = DrivePing(
          id: _newId(),
          ts: now.toUtc(),
          lat: origin.lat,
          lon: origin.lon,
          gpsAccuracyM: _inRange(fix?.accuracyM, 0, 10000),
          speedMps: _inRange(fix?.speedMps, 0, 150),
          kind: PingKind.rx,
          echoes: [echo],
        );
        if (!_pings.isClosed) _pings.add(ping);
      }
    }
    _passiveBest.clear();
    _passiveOrigin = fix == null ? null : (lat: fix.lat, lon: fix.lon);
    _passiveFlushDeadline = _clock().add(passiveFlushInterval);
  }

  void _stopPassive() {
    _passiveTimer?.cancel();
    _passiveTimer = null;
    final sub = _passiveFixSub;
    _passiveFixSub = null;
    if (sub != null) unawaited(sub.cancel());
    _flushPassive(); // save whatever's pending rather than drop it
    _passiveFlushDeadline = null;
    _collector = null;
  }

  // ------------------------------------------------------------------ auto pinging

  /// (Re)starts or stops the cadence checks for the current config.
  void _startAuto() {
    if (!_running || _stopping || _config.intervalSec <= 0) {
      _stopAuto();
      return;
    }
    _autoTimer ??= Timer.periodic(tick, (_) => _evaluate());
    if (_fixSub == null) {
      try {
        _fixSub = location.fixes.listen((f) {
          _lastFix = f;
          _lastFixArrived = _clock();
          _watchClock(f);
          _evaluate();
        }, onError: (Object _) {});
      } catch (_) {
        _fixSub = null; // no stream: the tick still checks current()
      }
    }
    scheduleMicrotask(_evaluate);
  }

  /// Compares a fresh GPS fix with the phone clock. A cached fix is late by an ever-changing amount, a wrong clock is
  /// off by the same amount every time, so only a steady difference over three fixes counts.
  void _watchClock(GeoFix f) {
    final skew = f.at.difference(_clock());
    final last = _skewLast;
    _skewLast = skew;
    if (skew.abs() <= clockSkewWarnAfter) {
      _skewRun = 0;
      if (_clockSkew != null) {
        _clockSkew = null;
        if (_running) _setStatus(_current.state, _current.message);
      }
      return;
    }
    _skewRun = last != null && (skew - last).abs() < const Duration(seconds: 30) ? _skewRun + 1 : 1;
    if (_skewRun >= 3 && _clockSkew == null && _running) {
      _clockSkew = skew;
      _setStatus(_current.state, _current.message);
    }
  }

  void _stopAuto() {
    _autoTimer?.cancel();
    _autoTimer = null;
    final sub = _fixSub;
    _fixSub = null;
    if (sub != null) unawaited(sub.cancel());
    _dueTimer?.cancel();
    _dueTimer = null;
    _nextPingAt = null;
    _waitingFor = null;
    _metresToGo = null;
  }

  double? _metresLeft(GeoFix? fix) {
    final last = _lastPingAt;
    if (last == null) return 0;
    if (fix == null) return null;
    final moved = haversineM(last.lat, last.lon, fix.lat, fix.lon);
    return math.max(0, _config.minDistanceM - moved).toDouble();
  }

  /// Publishes what we're waiting for, only when something the UI shows has changed.
  void _wait(PingWait? w, double? togo, {String? message}) {
    final rounded = togo?.roundToDouble();
    final msg = message ?? _current.message;
    if (_current.state == EngineState.driving &&
        _waitingFor == w &&
        _metresToGo == rounded &&
        _current.nextPingAt == _nextPingAt &&
        _current.message == msg) {
      return;
    }
    _waitingFor = w;
    _metresToGo = rounded;
    if (!_busy) _setStatus(EngineState.driving, msg);
  }

  void _armDue(Duration d) {
    _dueTimer?.cancel();
    _dueTimer = Timer(d + const Duration(milliseconds: 1), () {
      _dueTimer = null;
      unawaited(_evaluate());
    });
  }

  /// One cadence check: pings now if both the interval and the distance are met.
  Future<void> _evaluate() async {
    if (!_running || _stopping || _busy || _evaluating || _config.intervalSec <= 0) return;
    if (_radioGone()) return;
    final now = _clock();
    final lastTime = _lastPingTime;
    final due = lastTime == null ? now : lastTime.add(_minGap);
    _nextPingAt = due;
    if (now.isBefore(due)) {
      _wait(PingWait.time, _metresLeft(_lastFix));
      _armDue(due.difference(now));
      return;
    }
    final retry = _retryAfter;
    if (retry != null && now.isBefore(retry)) {
      _armDue(retry.difference(now));
      return;
    }
    _evaluating = true;
    try {
      final fix = await _fix();
      if (!_running || _stopping || _busy || _config.intervalSec <= 0) return;
      if (fix == null) {
        _noFixSince ??= now;
        final lt = _noFixTraceAt;
        if (lt == null || _clock().difference(lt) >= const Duration(seconds: 10)) {
          _noFixTraceAt = _clock();
          _emitTrace({'v': 1, 'no_fix': true, 'at': _clock().toUtc().toIso8601String(), 'since_ms': _clock().difference(_noFixSince!).inMilliseconds});
        }
        final long = _clock().difference(_noFixSince!) >= noGpsHintAfter;
        final poor = _poorFixM;
        _wait(PingWait.gps, null,
            message: poor != null
                ? 'GPS is not accurate enough (±${poor.round()} m): waiting to ping'
                : long
                    ? 'No GPS fix. Check that Location is on and allowed for MeshSonar.'
                    : 'No GPS fix: waiting to ping');
        return;
      }
      _noFixSince = null;
      final togo = _metresLeft(fix)!;
      if (togo > 0) {
        _wait(PingWait.distance, togo, message: 'Move ${math.max(1, togo.round())} m more to ping');
        return;
      }
      _waitingFor = null;
      _metresToGo = null;
      await _serial(() async {
        if (!_running || _stopping || _config.intervalSec <= 0) return null;
        // A manual ping may have gone out while we waited for the GPS: it resets the timer and the anchor.
        final t = _lastPingTime;
        if (t != null && _clock().isBefore(t.add(_minGap))) return null;
        if ((_metresLeft(fix) ?? 1) > 0) return null;
        return _ping(fix, startedAt: now);
      });
    } catch (_) {
      // status already reported by _ping; don't hammer a failing radio
      _retryAfter = _clock().add(const Duration(seconds: 5));
    } finally {
      _evaluating = false;
    }
  }

  // ------------------------------------------------------------------ manual

  @override
  Future<DrivePing> pingNow() async {
    if (!_running || _stopping) throw StateError('Not driving: start() first');
    if (_config.listenOnly) throw StateError('Listen-only: this drive transmits nothing, including manual pings');
    return _serial(() async {
      if (!_running || _stopping) throw StateError('Not driving');
      final fix = await _fix();
      if (fix == null) {
        _note('No GPS fix: can\'t ping');
        throw StateError('No GPS fix');
      }
      _lastSkip = null;
      final p = await _ping(fix, manual: true);
      final skip = _lastSkip;
      if (p == null && skip != null) throw PingSkippedException(skip);
      if (p == null) throw StateError('Ping did not complete');
      return p;
    });
  }

  /// Runs pings one at a time (the radio is half-duplex and echoes are matched per ping).
  Future<T> _serial<T>(Future<T> Function() body) {
    final result = _pingChain.then((_) => body());
    final done = result.then((_) {}, onError: (_) {});
    _pingChain = done;
    _inFlight = done;
    return result;
  }

  /// Accuracy of the last fix refused for being too poor to ping from; null when the last fix was fine or absent.
  double? _poorFixM;

  /// How long the engine waits for the platform to produce a fix on request. The phone's "current position" call can sit
  /// for 15 s while a position stream is running (Oct 31 field drive: pings 78-128 s apart at speed).
  Duration fixTimeout = const Duration(seconds: 4);

  /// When that call fails or times out, the position stream's newest fix stands in if it is at most this old (at 13 m/s
  /// that is within about 65 m, and the ping records its accuracy); older than that there is no usable fix.
  Duration staleFixOk = const Duration(seconds: 5);

  DateTime? _lastFixArrived;

  Future<GeoFix?> _fix() async {
    GeoFix? f;
    try {
      f = await location.current().timeout(fixTimeout);
    } catch (_) {
      f = null;
    }
    if (f != null) {
      _lastFix = f;
      _lastFixArrived = _clock();
      final acc = f.accuracyM;
      _poorFixM = (acc != null && acc > maxPingAccuracyM) ? acc : null;
      return _poorFixM == null ? f : null; // a cell-tower guess is not a place to ping from
    }
    _poorFixM = null;
    final last = _lastFix, at = _lastFixArrived;
    if (last != null && at != null) {
      final age = _clock().difference(at);
      final acc = last.accuracyM;
      if (!age.isNegative && age <= staleFixOk && (acc == null || acc <= maxPingAccuracyM)) return last;
    }
    return null;
  }

  // ------------------------------------------------------------------ one ping

  /// Sends one ping at [fix], listens, emits it. Returns null if the ping couldn't be sent or was cut short with
  /// nothing heard (a truncated listen is not evidence of "heard nothing").
  ///
  /// Order matters for latency: the send goes out FIRST; the noise floor is read while the window runs (it is the
  /// background level, the same a moment later), so the ping leaves one radio round trip sooner than it did.
  Future<DrivePing?> _ping(GeoFix fix, {bool manual = false, DateTime? startedAt}) async {
    _busy = true;
    _closeTail();
    final idx = _channelIndex!;
    final secret = _secret!;
    final pingTag = newPingTag();
    final text = formatPingText(pingTag);
    final txDbm = _inRange(_config.txDbm, -10, 40); // the power this ping goes out at, before any mid-listen change
    final heard = <_Heard>[];
    final ctl = <_Ctl>[];
    StreamSubscription<ControlPacket>? ctlSub;
    DateTime? sentAt;
    int? sentTs;
    final waited = _Waited(); // listening time so far; the window's own length is counted in our waits
    Duration? lastEchoAt; // when the newest repeat arrived, as time since the send
    var cutShort = false;
    int? ackMs;
    final id = _newId();
    final liveRepeaters = <String>{};
    _heardSoFar = null;
    try {
      final asked = pingGate.requestPing(manual: manual);
      final decision = asked is Future<PingDecision> ? await asked : asked;
      if (!decision.go) {
        // Skipped, never queued late: the cadence check asks again in a moment, at the then-current position.
        _lastSkip = decision;
        skippedPings[decision.reason!] = (skippedPings[decision.reason!] ?? 0) + 1;
        _retryAfter = _clock().add(pingSkipRetry);
        _emitTrace({'v': 1, 'skipped': decision.reason!.name, 'at': _clock().toUtc().toIso8601String(), 'manual': manual});
        if (_running && !_stopping) _setStatus(EngineState.driving, decision.message);
        return null;
      }
      _setStatus(EngineState.pinging, 'Pinging');
      if (!_running) return null;

      _collector = (rx) {
        final now = _clock();
        heard.add(_Heard(rx, now));
        final ts = sentTs;
        if (ts != null) {
          final pkt = MeshPacket.tryParse(rx.raw);
          final m = pkt == null ? null : matchEcho(pkt, secret, text, timestamp: ts);
          if (m != null) {
            lastEchoAt = now.difference(sentAt!);
            if (liveRepeaters.add(m.repeater) && _running && !_stopping) {
              _heardSoFar = liveRepeaters.length;
              _setStatus(EngineState.pinging,
                  'Heard ${liveRepeaters.length} repeater${liveRepeaters.length == 1 ? '' : 's'} so far');
            }
          }
        }
      };
      sentAt = _clock();
      await link.sendChannelText(idx, text);
      ackMs = _clock().difference(sentAt).inMilliseconds; // command queued + written + the radio's OK
      pingGate.pingSent();
      _lastPingAt = (lat: fix.lat, lon: fix.lon);
      // The interval counts from the moment the ping was asked for (an auto ping: when the cadence check began), so a slow
      // fix or a send that waited behind other commands never stretches the cadence.
      _lastPingTime = startedAt ?? sentAt;
      _retryAfter = null;
      final l = link;
      sentTs = l is MeshCoreCompanionLink ? l.lastSentTimestamp : null;

      int? tag;
      if (discoverNeighbors && l is MeshCoreCompanionLink && (l.firmwareVerCode ?? 0) >= 8) {
        tag = _rng.nextInt(0x7fffffff) + 1;
        ctlSub = l.controlPackets.listen((c) => ctl.add(_Ctl(c)));
        try {
          await l.sendDiscoverRequest(tag);
        } catch (_) {
          tag = null;
        }
      }

      _note('Listening for repeaters');
      double? noise;
      unawaited(link.noiseFloor().then<void>((v) => noise = v, onError: (Object _) {}));
      final base = _window;
      cutShort = !await _listenAdaptive(waited, base, () => lastEchoAt, startedAt == null ? Duration.zero : sentAt.difference(startedAt));
      final windowMs = waited.d.inMilliseconds;
      _heardSoFar = null;
      _collector = null;

      final echoes = _buildEchoes(heard, secret, text, sentTs, sentAt);
      final pktHash = _packetHash(heard, secret, text, sentTs, l is MeshCoreCompanionLink ? l.selfInfo?.name : null);
      final neighbor = tag == null ? null : _bestNeighbor(ctl, tag);
      if (cutShort && echoes.isEmpty && neighbor == null) {
        _emitTrace({'v': 1, 'ping': id, 'tag': pingTag, 'cut_short': true, 'at': sentAt.toUtc().toIso8601String()});
        return null;
      }
      final ping = DrivePing(
        id: id,
        ts: sentAt.toUtc(),
        lat: fix.lat,
        lon: fix.lon,
        gpsAccuracyM: _inRange(fix.accuracyM, 0, 10000),
        speedMps: _inRange(fix.speedMps, 0, 150),
        kind: PingKind.tx,
        noiseFloorDbm: _inRange(noise, -160, 0),
        echoes: echoes,
        neighbor: neighbor,
        pktHash: pktHash,
        txEpochS: sentTs,
        wireTag: pingTag,
        txDbm: txDbm,
      );
      _emitTrace({
        'v': 1,
        'ping': id,
        'tag': pingTag,
        'at': sentAt.toUtc().toIso8601String(),
        'tx_epoch_s': sentTs,
        'ack_ms': ackMs,
        'pkt_hash': pktHash,
        'manual': manual,
        'base_ms': base.inMilliseconds,
        'window_ms': windowMs,
        'echoes': echoes.length,
        'frames': _traceFrames(heard, secret, text, sentTs, sentAt),
      });
      _openTail(id, pingTag, text, sentTs, sentAt, secret);
      if (!_pings.isClosed) _pings.add(ping);
      if (_running && !_stopping) {
        if (_config.intervalSec > 0) {
          _nextPingAt = (startedAt ?? sentAt).add(_minGap);
          _waitingFor = PingWait.time;
          _metresToGo = _config.minDistanceM.toDouble();
        }
        _setStatus(
            EngineState.driving,
            echoes.isEmpty
                ? 'Heard nothing'
                : 'Heard ${echoes.length} repeater${echoes.length == 1 ? '' : 's'}');
      }
      return ping;
    } catch (e) {
      if (_tail == null) _collector = null;
      _emitTrace({'v': 1, 'ping': id, 'tag': pingTag, 'failed': _describe(e), 'at': (sentAt ?? _clock()).toUtc().toIso8601String()});
      if (!link.isConnected) {
        _onRadioLost();
      } else if (_running && !_stopping) {
        _setStatus(EngineState.driving, 'Ping failed: ${_describe(e)}');
      }
      rethrow;
    } finally {
      if (_tail == null) _collector = null;
      await ctlSub?.cancel();
      _busy = false;
      if (_running && !_stopping && _config.intervalSec > 0) scheduleMicrotask(_evaluate);
    }
  }

  void _emitTrace(Map<String, Object?> record) {
    final sink = onTrace;
    if (sink == null) return;
    try {
      sink(record);
    } catch (_) {
      // a failing trace writer must never touch the ping
    }
  }

  /// Max frames kept per ping in the trace (a busy channel can report hundreds of other drivers' pings).
  static const int traceFrameCap = 80;

  List<Map<String, Object?>> _traceFrames(List<_Heard> heard, Uint8List secret, String text, int? ts, DateTime sentAt) {
    final out = <Map<String, Object?>>[];
    final seen = <String>{};
    var dropped = 0;
    for (final h in heard) {
      final pkt = MeshPacket.tryParse(h.rx.raw);
      final c = classifyEcho(pkt, secret, text, timestamp: ts);
      var verdict = switch (c.verdict) {
        EchoVerdict.echo => 'echo',
        EchoVerdict.notGroupText => 'not-group-text',
        EchoVerdict.emptyPath => 'own-tx-no-repeater',
        EchoVerdict.otherChannel => 'other-channel',
        EchoVerdict.otherTimestamp => 'other-timestamp',
        EchoVerdict.otherText => 'other-text',
        EchoVerdict.unparsed => 'unparsed',
      };
      final m = c.match;
      if (m != null && !seen.add(m.repeater)) verdict = 'echo-repeat';
      // Chatter from other drivers/adverts is counted, not listed one by one, once the cap is reached.
      if (out.length >= traceFrameCap && m == null) {
        dropped++;
        continue;
      }
      out.add({
        't': h.arrived.difference(sentAt).inMilliseconds,
        'v': verdict,
        'snr': _inRange(h.rx.snrDb, -40, 40),
        'rssi': _inRange(h.rx.rssiDbm, -160, 0),
        if (pkt != null) 'type': pkt.payloadType,
        if (pkt != null) 'route': pkt.routeType,
        if (m != null) 'rep': m.repeater,
        if (m != null) 'hops': m.hops,
        if (pkt != null && pkt.path.isNotEmpty) 'path': pkt.pathHex,
      });
    }
    if (dropped > 0) out.add({'v': 'omitted', 'n': dropped});
    return out;
  }

  // Late tail: frames after a ping's window, kept for the trace only until the next ping or [traceTail].
  _Tail? _tail;
  Timer? _tailTimer;

  void _openTail(String id, String tag, String text, int? ts, DateTime sentAt, Uint8List secret) {
    _tail = _Tail(id, tag, text, ts, sentAt, secret);
    _collector = (rx) {
      final t = _tail;
      if (t != null && t.frames.length < traceFrameCap * 2) t.frames.add(_Heard(rx, _clock()));
    };
    _tailTimer?.cancel();
    _tailTimer = Timer(traceTail, _closeTail);
  }

  void _closeTail() {
    _tailTimer?.cancel();
    _tailTimer = null;
    final t = _tail;
    if (t == null) return;
    _tail = null;
    _collector = null;
    if (t.frames.isEmpty) return;
    final frames = _traceFrames(t.frames, t.secret, t.text, t.ts, t.sentAt)
        .where((f) => f['v'] == 'echo' || f['v'] == 'echo-repeat' || f['v'] == 'other-timestamp')
        .toList();
    if (frames.isEmpty) return;
    _emitTrace({'v': 1, 'late_for': t.id, 'tag': t.tag, 'frames': frames});
  }

  /// Waits [base] after the send; then, while repeats of THIS ping are still arriving (the newest less than [extendGap]
  /// old), keeps listening, up to [maxListen] and never into the time the next ping is due. A quiet mesh closes at
  /// [base] exactly. Returns false if the radio went away first.
  Future<bool> _listenAdaptive(_Waited waited, Duration base, Duration? Function() lastEcho, Duration lateStart) async {
    if (!await _listen(base)) return false;
    waited.d = base;
    // Only a real listen window extends (tests use windows of a few milliseconds, which stay exactly as set).
    if (!adaptiveListen || base < minAdaptiveBase) return true;
    var ceiling = maxListen;
    if (_config.intervalSec > 0) {
      final room = Duration(seconds: _config.intervalSec) - lateStart - const Duration(seconds: 1); // lateStart: a slow fix already used some
      if (room < ceiling) ceiling = room;
    }
    if (ceiling < base) ceiling = base;
    while (true) {
      final last = lastEcho();
      if (last == null || waited.d >= ceiling || waited.d - last >= extendGap) return true;
      final left = ceiling - waited.d;
      final step = left < const Duration(milliseconds: 500) ? left : const Duration(milliseconds: 500);
      if (!await _listen(step)) return false;
      waited.d += step;
    }
  }

  /// Waits for [window]. Returns false if the radio went away first.
  Future<bool> _listen(Duration window) {
    final c = Completer<bool>();
    final t = Timer(window, () {
      if (!c.isCompleted) c.complete(true);
    });
    void check() {
      if (!c.isCompleted && (!link.isConnected || !_running)) {
        t.cancel();
        c.complete(false);
      }
    }

    // Poll for disconnects without depending on a connection-state stream (CompanionLink has none).
    final poll = Timer.periodic(const Duration(milliseconds: 250), (_) => check());
    return c.future.whenComplete(poll.cancel);
  }

  /// The echo-building step on its own, for tests: [heard] are the packets the radio reported (with arrival times).
  static List<Echo> echoesFor(List<(RxPacket, DateTime)> heard, Uint8List secret, String text, int? sentTs, DateTime sentAt) =>
      _buildEchoes([for (final h in heard) _Heard(h.$1, h.$2)], secret, text, sentTs, sentAt);

  /// For tests.
  static double? inRangeForTest(double? v, double lo, double hi) => _inRange(v, lo, hi);

  static List<Echo> _buildEchoes(List<_Heard> heard, Uint8List secret, String text, int? sentTs, DateTime sentAt) {
    final best = <String, ({Echo echo, int hops, double snr})>{};
    final order = <String>[];
    for (final h in heard) {
      final pkt = MeshPacket.tryParse(h.rx.raw);
      if (pkt == null) continue;
      final m = matchEcho(pkt, secret, text, timestamp: sentTs);
      if (m == null) continue;
      final delay = h.arrived.difference(sentAt).inMilliseconds;
      final echo = Echo(
        repeater: m.repeater,
        snrDb: _inRange(h.rx.snrDb, -40, 40),
        rssiDbm: _inRange(h.rx.rssiDbm, -160, 0),
        hops: m.hops,
        path: m.path,
        delayMs: delay < 0 ? 0 : delay,
      );
      final snr = echo.snrDb ?? double.negativeInfinity;
      final prev = best[m.repeater];
      if (prev == null) {
        order.add(m.repeater);
        best[m.repeater] = (echo: echo, hops: m.hops, snr: snr);
      } else if (m.hops < prev.hops || (m.hops == prev.hops && snr > prev.snr)) {
        // Prefer the copy that reached us most directly: only a 1-hop echo's SNR/RSSI describe the link to this
        // repeater. Among equal hop counts keep the best SNR (MeshMapper's rule).
        best[m.repeater] = (echo: echo, hops: m.hops, snr: snr);
      }
    }
    return [for (final r in order) best[r]!.echo];
  }

  /// Drive Format v1.1 `pkt_hash`: the MeshCore packet hash of what we sent (Packet::calculatePacketHash).
  ///
  /// The channel send reply is a bare RESP_CODE_OK (companion MyMesh.cpp CMD_SEND_CHANNEL_TXT_MSG): the companion
  /// reports no hash or packet for a channel message. But the GRP_TXT it builds is deterministic, so:
  ///  1. a heard repeat of this exact send (matched by MAC, timestamp and text) carries the on-air payload, and its
  ///     hash is the truth (repeats change only the path, which isn't hashed);
  ///  2. otherwise the payload is rebuilt from the timestamp we put in the command, the companion's node name and
  ///     the text (BaseChatMesh::sendGroupMessage). Checked against 301 of 301 #wardriving copies an observer heard
  ///     on Oct 17 (test/radio/packet_hash_test.dart).
  /// Null without the send timestamp (non-companion links) or, with nothing heard, without the node name.
  static String? _packetHash(List<_Heard> heard, Uint8List secret, String text, int? sentTs, String? nodeName) {
    if (sentTs == null) return null;
    for (final h in heard) {
      final pkt = MeshPacket.tryParse(h.rx.raw);
      if (pkt == null || matchEcho(pkt, secret, text, timestamp: sentTs) == null) continue;
      return pkt.hashHex;
    }
    if (nodeName == null) return null;
    return groupTextPacketHashHex(secret, sentTs, nodeName, text);
  }

  Neighbor? _bestNeighbor(List<_Ctl> ctl, int tag) {
    Neighbor? best;
    for (final c in ctl) {
      if (c.pkt.pathLen != 0) continue;
      final d = DiscoverResponse.tryParse(c.pkt.payload);
      if (d == null || d.tag != tag || d.nodeType != 2 /* ADV_TYPE_REPEATER */) continue;
      final n = Neighbor(
        repeater: toHex(d.publicKey),
        localSnrDb: _inRange(c.pkt.snrDb, -40, 40),
        localRssiDbm: _inRange(c.pkt.rssiDbm.toDouble(), -160, 0),
        remoteSnrDb: _inRange(d.remoteSnrDb, -40, 40),
      );
      if (best == null || (n.localSnrDb ?? -99) > (best.localSnrDb ?? -99)) best = n;
    }
    return best;
  }

  static double? _inRange(double? v, double lo, double hi) => (v == null || v.isNaN || v < lo || v > hi) ? null : v;

  static String _describe(Object e) {
    if (e is StateError) return e.message;
    if (e is CompanionException) return e.message;
    if (e is TimeoutException) return 'Radio did not answer';
    return e.toString();
  }

  // ------------------------------------------------------------------ stop

  @override
  Future<void> stop() async {
    if (!_running && _current.state != EngineState.error && _current.state != EngineState.starting) {
      if (_current.state != EngineState.idle) _setStatus(EngineState.idle);
      return;
    }
    final wasRunning = _running;
    _stopping = true;
    if (wasRunning) _setStatus(EngineState.stopping, 'Stopping');
    _stopAuto();
    if (_config.listenOnly) _stopPassive(); // flushes whatever's pending rather than dropping it
    // Let a ping that is already on the air finish its listen window so its data isn't lost.
    final inflight = _inFlight;
    if (inflight != null) {
      await inflight;
    }
    _running = false;
    _stopAuto();
    _closeTail();
    await _rxSub?.cancel();
    _rxSub = null;
    _collector = null;
    _stopping = false;
    _setStatus(EngineState.idle, 'Stopped');
  }
}
