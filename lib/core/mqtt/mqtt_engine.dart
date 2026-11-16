// The MQTT observer engine (observer-everywhere-mqtt-plan-2026-11-15.md section 3.4, OE2): feeds up to 10 outside
// MeshCore sites ("MQTT feeds" in Settings > Observer) straight from this phone, while it is an observer
// (`ObserverEngineState.sharing`) with a radio connected.
//   * One [_SlotRunner] per enabled slot: its own WebSocket connection (lib/core/mqtt/mqtt_transport.dart), login (a
//     radio-signed JWT, a Keychain password under `mqtt.<slotId>`, or none), topic `meshcore/{IATA}/{PUBKEY}/...`.
//   * Packets: only what AppState hands [onPublicPacket] (already through the privacy filter), checked again by
//     [mqttPacketMessage]. Bounded in-memory queue per slot (120, drop-oldest), never persisted, cleared when the radio
//     goes; at most 120 publishes per slot per minute (the rest wait in the queue, the oldest drop first).
//   * Status: `online` on connect and every 5 minutes; `offline` when a live feed stops on purpose; the same `offline`
//     as the connection's last will, so the broker says it when the link is lost. One topic and one retain rule for all.
//   * Reconnect: jittered backoff 1..30 s; a refused login retries after 5 minutes with a freshly signed token; a radio
//     that cannot sign retries after 10 minutes. Tokens are re-signed about 5 minutes before they end and the slot
//     reconnects cleanly with the new one.
//   * Background: a live connection keeps publishing while the process runs; a connection that drops while the app is
//     behind is not retried until the app is in front again (status "Paused in background").
//   * No location of any kind is used or sent.
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../chat/secret_store.dart';
import '../../radio/radio_api.dart' show RxPacket;
import '../mqtt_contract.dart';
import '../observer_engine.dart';
import '../telemetry.dart' show TelemetryRecord;
import 'mqtt_jwt.dart';
import 'mqtt_payload.dart';
import 'mqtt_transport.dart';

class MqttObserverEngine implements ObserverEngine {
  /// Settings > Observer has 10 slots; anything past the tenth is ignored.
  static const int maxSlots = 10;

  final SecretStore secrets;
  final DateTime Function() clock;
  final MqttTransportFactory _newTransport;
  final Random _random;

  /// Per-slot queue length and publish cap (messages per minute).
  final int queueCap;
  final int ratePerMinute;
  final Duration statusInterval;
  final Duration authRetry;
  final Duration signRetry;

  /// How long Test keeps its connection open after publishing the status message.
  final Duration testLinger;

  final MqttTokenService _tokens;

  /// The secure-store slot of this install's client-id part (2 random bytes, 4 hex characters in the client id).
  static const String installIdSlot = 'meshsonar.mqtt_client_id';
  Future<String>? _install;

  MqttObserverEngine({
    required this.secrets,
    required this.clock,
    MqttTransportFactory? transport,
    Random? random,
    this.queueCap = 120,
    this.ratePerMinute = 120,
    this.statusInterval = const Duration(minutes: 5),
    this.authRetry = const Duration(minutes: 5),
    this.signRetry = const Duration(minutes: 10),
    this.testLinger = const Duration(milliseconds: 500),
    Duration signTimeout = const Duration(seconds: 20),
  }) : _newTransport = transport ?? MqttClientTransport.new,
       _random = random ?? Random.secure(),
       _tokens = MqttTokenService(clock: clock, signTimeout: signTimeout);

  /// This install's part of every client id (WS-OUT 8): random once, then kept in the secure store (like the observer
  /// id), so a broker sees the same client across launches instead of a new one per launch. Without a store it lasts for
  /// this run only.
  Future<String> installId() => _install ??= _loadInstallId();

  Future<String> _loadInstallId() async {
    try {
      final b = await secrets.read(installIdSlot);
      if (b != null && b.length == 2) return _hex(b);
    } catch (_) {}
    final v = _random.nextInt(0x10000);
    final b = Uint8List.fromList([v >> 8, v & 0xff]);
    try {
      await secrets.write(installIdSlot, b);
    } catch (_) {
      // No secure store: still random, just not kept.
    }
    return _hex(b);
  }

  static String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

  ObserverEngineState _state = const ObserverEngineState();
  List<MqttSlotSettings> _slots = const [];
  final Map<String, _SlotRunner> _runners = {};
  final Map<String, ObserverFeedStatus> _idle = {};
  final Map<String, _SentLog> _sent = {};
  final StreamController<List<ObserverFeedStatus>> _changes = StreamController.broadcast();
  List<ObserverFeedStatus> _last = const [];
  Timer? _countEmit;
  bool _disposed = false;

  /// Radio signings done so far (diagnostics, tests).
  int get signings => _tokens.signings;

  /// Packets dropped because a slot's queue was full (diagnostics, tests).
  int get dropped => _runners.values.fold(0, (n, r) => n + r.dropped) + _droppedGone;
  int _droppedGone = 0;

  /// The jittered reconnect delay after [attempt] failures in a row: 1, 2, 4, 8, 16, 30, 30... seconds, each scaled by a
  /// random 50..100 %, never under 1 s.
  Duration backoffDelay(int attempt) {
    final base = min(30, 1 << min(attempt, 5));
    final ms = (base * 1000 * (0.5 + 0.5 * _random.nextDouble())).round();
    return Duration(milliseconds: max(1000, ms));
  }

  // ---------------------------------------------------------------- state

  @override
  void update(ObserverEngineState state) {
    if (_disposed) return;
    final prev = _state;
    _state = state;
    if (prev.radioPublicKey != state.radioPublicKey || !state.connected) _tokens.clear();
    final seen = <String>{};
    _slots = [
      for (final s in state.slots)
        if (seen.add(s.id)) s,
    ].take(maxSlots).toList(growable: false);
    final ids = {for (final s in _slots) s.id};
    for (final id in _runners.keys.toList()) {
      if (!ids.contains(id)) _stopRunner(id);
    }
    _idle.removeWhere((id, _) => !ids.contains(id));
    final signChanged = prev.sign != state.sign;
    for (final slot in _slots) {
      final plan = _plan(slot, state);
      if (plan is _Idle) {
        _stopRunner(slot.id);
        _idle[slot.id] = ObserverFeedStatus(slotId: slot.id, state: plan.state, lastError: plan.why, at: clock());
        continue;
      }
      plan as _Run;
      _idle.remove(slot.id);
      final r = _runners[slot.id];
      if (r != null && r.key == plan.key) {
        r.slot = slot;
        if (signChanged) r.radioChanged();
        r.settingsChanged();
        r.foregroundChanged(state.foreground);
        continue;
      }
      _stopRunner(slot.id);
      final n = _SlotRunner(this, slot, plan.key, plan.iata, plan.publicKey);
      _runners[slot.id] = n;
      n.start();
    }
    _emit();
  }

  _Plan _plan(MqttSlotSettings slot, ObserverEngineState s) {
    if (!slot.enabled) return const _Idle(ObserverFeedState.off);
    if (!s.sharing) return const _Idle(ObserverFeedState.off, 'Observer sharing is off.');
    final pk = s.radioPublicKey;
    if (!s.connected || pk == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(pk)) {
      return const _Idle(ObserverFeedState.waitingForRadio);
    }
    final iata = topicIata(slot, s.regionCode);
    if (iata == null) {
      return const _Idle(ObserverFeedState.error, 'No airport code for the topic: set a 3-letter code for this feed.');
    }
    if (slot.auth == MqttAuth.jwt && s.sign == null) {
      return const _Idle(ObserverFeedState.radioCantSign, 'The connected radio cannot sign a login.');
    }
    final cfg = slot.toJson()
      ..remove('name')
      ..remove('enabled');
    return _Run('${jsonEncode(cfg)}|$iata|${pk.toUpperCase()}', iata, pk.toUpperCase());
  }

  /// The topic's region code: the slot's own (3 letters/digits), else the phone's region when it is a 3-letter code.
  static String? topicIata(MqttSlotSettings slot, String? regionCode) {
    final own = slot.iata?.trim().toUpperCase();
    if (own != null && own.isNotEmpty) return MqttTopics.iataRe.hasMatch(own) ? own : null;
    final r = regionCode?.trim().toUpperCase();
    return r != null && RegExp(r'^[A-Z]{3}$').hasMatch(r) ? r : null;
  }

  void _stopRunner(String id) {
    final r = _runners.remove(id);
    if (r == null) return;
    _droppedGone += r.dropped;
    r.stop();
  }

  // ---------------------------------------------------------------- packets

  @override
  void onPublicPacket(TelemetryRecord record, RxPacket rx) {
    if (_disposed || !_state.active || _runners.isEmpty) return;
    final pk = _state.radioPublicKey;
    if (pk == null || pk.length != 64) return;
    final msg = mqttPacketMessage(record, rx, publicKeyHex: pk);
    if (msg == null) return;
    for (final r in _runners.values) {
      r.enqueue(msg);
    }
  }

  // ---------------------------------------------------------------- status

  @override
  List<ObserverFeedStatus> get statuses {
    final now = clock();
    return [
      for (final s in _slots)
        _withCount(_runners[s.id]?.status ?? _idle[s.id] ?? ObserverFeedStatus(slotId: s.id, state: ObserverFeedState.off), now),
    ];
  }

  ObserverFeedStatus _withCount(ObserverFeedStatus s, DateTime now) => ObserverFeedStatus(
    slotId: s.slotId,
    state: s.state,
    sent24h: _sent[s.slotId]?.total(now) ?? 0,
    lastError: s.lastError,
    at: s.at,
  );

  @override
  Stream<List<ObserverFeedStatus>> get statusChanges => _changes.stream;

  void _emit() {
    if (_disposed) return;
    final now = statuses;
    if (_same(now, _last)) return;
    _last = now;
    _changes.add(now);
  }

  static bool _same(List<ObserverFeedStatus> a, List<ObserverFeedStatus> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].slotId != b[i].slotId ||
          a[i].state != b[i].state ||
          a[i].sent24h != b[i].sent24h ||
          a[i].lastError != b[i].lastError) {
        return false;
      }
    }
    return true;
  }

  void _countSent(String slotId, DateTime at) {
    _sent.putIfAbsent(slotId, _SentLog.new).add(at);
    _countEmit ??= Timer(const Duration(seconds: 1), () {
      _countEmit = null;
      _emit();
    });
  }

  // ---------------------------------------------------------------- shared by runners and Test

  /// `ms` + the radio key's first 8 hex + 6 hex of the slot id + this install's 4 hex [+ suffix]: 20 characters (21 for
  /// Test), within MQTT 3.1.1's 23.
  Future<String> _clientId(String publicKey, String slotId, {String suffix = ''}) async {
    var h = 0x811c9dc5;
    for (final c in slotId.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    final install = await installId();
    return 'ms${publicKey.substring(0, 8).toLowerCase()}${(h & 0xffffff).toRadixString(16).padLeft(6, '0')}$install$suffix';
  }

  /// Username and password for [slot]; throws [MqttSignException] (radio) or [_NoSecret].
  Future<({String? username, String? password, MqttToken? token})> _credentials(
    MqttSlotSettings slot,
    String pk, {
    bool fresh = false,
  }) async {
    switch (slot.auth) {
      case MqttAuth.jwt:
        final sign = _state.sign;
        if (sign == null) throw const MqttSignException('The connected radio cannot sign a login.');
        final aud = (slot.aud == null || slot.aud!.isEmpty) ? slot.host : slot.aud!;
        final t = await _tokens.token(publicKeyHex: pk, aud: aud, ttlSec: slot.ttlSec, sign: sign, fresh: fresh);
        return (username: t.username, password: t.value, token: t);
      case MqttAuth.password:
        final user = slot.username;
        final secret = await secrets.read(slot.secretRef);
        if (user == null || user.isEmpty || secret == null || secret.isEmpty) throw const _NoSecret();
        return (username: user, password: utf8.decode(secret, allowMalformed: true), token: null);
      case MqttAuth.none:
        return (username: null, password: null, token: null);
    }
  }

  /// [will] = the slot's status topic and radio key: the broker publishes `offline` there (with the slot's status retain
  /// flag) when the connection is lost. Test connects without one.
  MqttConnectRequest _request(MqttSlotSettings slot, String clientId, String? user, String? pass,
          {({String topic, String publicKey})? will}) =>
      MqttConnectRequest(
        host: slot.host,
        port: slot.port,
        wsPath: slot.wsPath,
        tls: slot.tls,
        clientId: clientId,
        username: user,
        password: pass,
        willTopic: will?.topic,
        willMessage: will == null ? null : _statusMessage(will.publicKey, online: false),
        willQos: 1,
        willRetain: will != null && statusRetained(slot),
      );

  /// Whether [slot]'s status messages (online, offline, last will) are retained: only for a preset that allows it;
  /// custom slots publish status unretained, as the firmware does. One rule for all three.
  static bool statusRetained(MqttSlotSettings slot) => slot.retainStatus && slot.presetId != null;

  String _statusMessage(String pk, {bool online = true}) => jsonEncode(
    mqttStatusJson(publicKeyHex: pk, at: clock(), model: _state.radioModel, firmware: _state.firmware, online: online),
  );

  // ---------------------------------------------------------------- Test

  @override
  Future<ObserverFeedStatus> test(MqttSlotSettings slot) async {
    ObserverFeedStatus out(ObserverFeedState st, [String? why]) =>
        ObserverFeedStatus(slotId: slot.id, state: st, lastError: why, at: clock());
    final s = _state;
    final pk = s.radioPublicKey?.toUpperCase();
    if (!s.connected || pk == null || pk.length != 64) {
      return out(ObserverFeedState.waitingForRadio, 'Connect a radio to test this feed.');
    }
    final iata = topicIata(slot, s.regionCode);
    if (iata == null) return out(ObserverFeedState.error, 'No airport code for the topic: set a 3-letter code for this feed.');
    ({String? username, String? password, MqttToken? token}) c;
    try {
      c = await _credentials(slot, pk);
    } on MqttSignException catch (e) {
      return out(ObserverFeedState.radioCantSign, e.message);
    } on _NoSecret catch (e) {
      return out(ObserverFeedState.authFailed, e.message);
    }
    final id = await _clientId(pk, slot.id, suffix: 't');
    final t = _newTransport();
    final res = await t.connect(_request(slot, id, c.username, c.password));
    switch (res.outcome) {
      case MqttConnectOutcome.accepted:
        final ok = t.publish(MqttTopics.status(iata, pk), _statusMessage(pk), qos: 1);
        if (testLinger > Duration.zero) await Future<void>.delayed(testLinger);
        await t.disconnect();
        return ok
            ? out(ObserverFeedState.connected)
            : out(ObserverFeedState.error, 'Connected, but the status message was not sent.');
      case MqttConnectOutcome.authRejected:
        await t.disconnect();
        return out(ObserverFeedState.authFailed, res.detail);
      case MqttConnectOutcome.refused:
      case MqttConnectOutcome.failed:
        await t.disconnect();
        return out(ObserverFeedState.error, res.detail);
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    for (final id in _runners.keys.toList()) {
      _stopRunner(id);
    }
    _disposed = true;
    _countEmit?.cancel();
    await _changes.close();
  }
}

sealed class _Plan {
  const _Plan();
}

class _Idle extends _Plan {
  final ObserverFeedState state;
  final String? why;
  const _Idle(this.state, [this.why]);
}

class _Run extends _Plan {
  final String key, iata, publicKey;
  const _Run(this.key, this.iata, this.publicKey);
}

class _NoSecret implements Exception {
  const _NoSecret();
  String get message => 'No username and password saved for this feed.';
}

/// Publishes per minute over the last 24 hours.
class _SentLog {
  final SplayTreeMap<int, int> _perMinute = SplayTreeMap();
  void add(DateTime at) {
    final m = at.millisecondsSinceEpoch ~/ 60000;
    _perMinute[m] = (_perMinute[m] ?? 0) + 1;
  }

  int total(DateTime now) {
    final from = now.millisecondsSinceEpoch ~/ 60000 - 24 * 60;
    _perMinute.removeWhere((m, _) => m <= from);
    return _perMinute.values.fold(0, (a, b) => a + b);
  }
}

/// One enabled slot's connection.
class _SlotRunner {
  final MqttObserverEngine e;
  MqttSlotSettings slot;
  final String key, iata, publicKey;
  _SlotRunner(this.e, this.slot, this.key, this.iata, this.publicKey);

  ObserverFeedState _st = ObserverFeedState.connecting;
  String? _why;
  DateTime? _at;
  final ListQueue<String> _queue = ListQueue();
  final ListQueue<DateTime> _window = ListQueue();
  int dropped = 0;
  MqttTransport? _t;
  Timer? _retry, _statusTimer, _refreshTimer, _drainTimer;
  int _attempt = 0;

  /// The last login failed because no password was saved: any settings change (saving one) retries at once.
  bool _noSecret = false;
  int _gen = 0;
  bool _stopped = false;

  String get _packetsTopic => MqttTopics.packets(iata, publicKey);
  String get _statusTopic => MqttTopics.status(iata, publicKey);

  ObserverFeedStatus get status => ObserverFeedStatus(slotId: slot.id, state: _st, lastError: _why, at: _at);

  void _set(ObserverFeedState s, [String? why]) {
    _st = s;
    _why = why;
    _at = e.clock();
    e._emit();
  }

  void start() => unawaited(_connect());

  /// The feed stops on purpose (turned off, sharing off, radio gone, settings changed, app closing): a live connection
  /// says `offline` first, on the same topic and with the same retain flag as `online`, then disconnects cleanly (a clean
  /// disconnect does not fire the last will).
  void stop() {
    _stopped = true;
    _gen++;
    _cancelTimers();
    _queue.clear();
    final t = _t;
    _t = null;
    if (t == null) return;
    if (_st == ObserverFeedState.connected) _publishStatus(t, online: false);
    unawaited(t.disconnect());
  }

  void _cancelTimers() {
    _retry?.cancel();
    _statusTimer?.cancel();
    _refreshTimer?.cancel();
    _drainTimer?.cancel();
    _retry = _statusTimer = _refreshTimer = _drainTimer = null;
  }

  /// A new radio session (sign function): a slot stuck on "Radio can't sign" or "Auth failed" tries again now.
  void radioChanged() {
    if (_st == ObserverFeedState.radioCantSign || _st == ObserverFeedState.authFailed) {
      _retry?.cancel();
      _attempt = 0;
      unawaited(_connect(fresh: true));
    }
  }

  void settingsChanged() {
    if (_noSecret && _st == ObserverFeedState.authFailed) {
      _retry?.cancel();
      unawaited(_connect());
    }
  }

  void foregroundChanged(bool fg) {
    if (fg && _st == ObserverFeedState.pausedInBackground) {
      _attempt = 0;
      unawaited(_connect());
    }
  }

  void _schedule(Duration d, {bool fresh = false}) {
    _retry?.cancel();
    _retry = Timer(d, () {
      _retry = null;
      unawaited(_connect(fresh: fresh));
    });
  }

  void _backoff() => _schedule(e.backoffDelay(_attempt++));

  Future<void> _connect({bool fresh = false}) async {
    if (_stopped) return;
    final g = ++_gen;
    _retry?.cancel();
    _retry = null;
    if (!e._state.foreground) {
      _set(ObserverFeedState.pausedInBackground);
      return;
    }
    _set(ObserverFeedState.connecting, _why);
    ({String? username, String? password, MqttToken? token}) c;
    try {
      c = await e._credentials(slot, publicKey, fresh: fresh);
      _noSecret = false;
    } on MqttSignException catch (x) {
      if (g != _gen) return;
      _set(ObserverFeedState.radioCantSign, x.message);
      _schedule(e.signRetry, fresh: true);
      return;
    } on _NoSecret catch (x) {
      if (g != _gen) return;
      _noSecret = true;
      _set(ObserverFeedState.authFailed, x.message);
      _schedule(e.authRetry);
      return;
    } catch (x) {
      if (g != _gen) return;
      _set(ObserverFeedState.error, 'Could not prepare the login: $x');
      _backoff();
      return;
    }
    if (g != _gen || _stopped) return;
    final id = await e._clientId(publicKey, slot.id);
    if (g != _gen || _stopped) return;
    final t = e._newTransport();
    t.onDropped = () => _dropped(g);
    _t = t;
    final res = await t.connect(e._request(slot, id, c.username, c.password, will: (topic: _statusTopic, publicKey: publicKey)));
    if (g != _gen || _stopped) {
      await t.disconnect();
      return;
    }
    switch (res.outcome) {
      case MqttConnectOutcome.accepted:
        _attempt = 0;
        _set(ObserverFeedState.connected);
        _publishStatus(t);
        _statusTimer = Timer.periodic(e.statusInterval, (_) {
          final live = _t;
          if (live != null && _st == ObserverFeedState.connected) _publishStatus(live);
        });
        final tok = c.token;
        if (tok != null) {
          var d = tok.expiresAt.difference(e.clock()) - mqttRefreshMargin(slot.ttlSec);
          if (d < const Duration(seconds: 1)) d = const Duration(seconds: 1);
          _refreshTimer = Timer(d, () => _refresh(g));
        }
        _drain();
      case MqttConnectOutcome.authRejected:
        _t = null;
        await t.disconnect();
        _set(ObserverFeedState.authFailed, res.detail);
        _schedule(e.authRetry, fresh: true);
      case MqttConnectOutcome.refused:
      case MqttConnectOutcome.failed:
        _t = null;
        await t.disconnect();
        _set(ObserverFeedState.error, res.detail);
        _backoff();
    }
  }

  /// The token is about to end: sign a new one and reconnect cleanly with it (the queue is kept).
  void _refresh(int g) {
    if (g != _gen || _stopped) return;
    _gen++;
    _cancelTimers();
    final t = _t;
    _t = null;
    if (t != null) unawaited(t.disconnect());
    _attempt = 0;
    unawaited(_connect());
  }

  void _dropped(int g) {
    if (g != _gen || _stopped) return;
    _gen++;
    _t = null;
    _cancelTimers();
    if (!e._state.foreground) {
      _set(ObserverFeedState.pausedInBackground, 'The connection closed while the app was in the background.');
      return;
    }
    _set(ObserverFeedState.error, 'Connection lost.');
    _backoff();
  }

  bool get _accepting =>
      !_stopped &&
      (_st == ObserverFeedState.connected ||
          _st == ObserverFeedState.connecting ||
          _st == ObserverFeedState.error ||
          _st == ObserverFeedState.pausedInBackground);

  void enqueue(String msg) {
    if (!_accepting) return;
    _queue.addLast(msg);
    while (_queue.length > e.queueCap) {
      _queue.removeFirst();
      dropped++;
    }
    _drain();
  }

  void _drain() {
    final t = _t;
    if (_st != ObserverFeedState.connected || t == null) return;
    final now = e.clock();
    while (_window.isNotEmpty && now.difference(_window.first) >= const Duration(minutes: 1)) {
      _window.removeFirst();
    }
    while (_queue.isNotEmpty && _window.length < e.ratePerMinute) {
      if (!t.publish(_packetsTopic, _queue.first)) break;
      _queue.removeFirst();
      _window.addLast(now);
      e._countSent(slot.id, now);
    }
    if (_queue.isNotEmpty && _window.length >= e.ratePerMinute && _drainTimer == null) {
      var d = _window.first.add(const Duration(minutes: 1)).difference(now);
      if (d < const Duration(milliseconds: 10)) d = const Duration(milliseconds: 10);
      _drainTimer = Timer(d, () {
        _drainTimer = null;
        _drain();
      });
    }
  }

  /// Status on [t]: retained only for a preset that allows it ([MqttObserverEngine.statusRetained]), the same rule as the
  /// offline message and the last will.
  void _publishStatus(MqttTransport t, {bool online = true}) {
    t.publish(_statusTopic, e._statusMessage(publicKey, online: online), qos: 1, retain: MqttObserverEngine.statusRetained(slot));
  }
}
