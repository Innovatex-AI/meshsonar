// The observer side of AppState, in one place (release 0.38 foundation): whether this phone is an observer
// ([observerSharing]), its mode, the status heartbeat (lib/core/observer_status.dart), bringing a dropped radio back, and
// the observer-engine slot that feeds outside MQTT sites (lib/core/observer_engine.dart). app_state.dart calls only the
// hooks marked "called by AppState" below.
//
// Observer everywhere (Andy, Nov 15 2026; meshsonar-infra docs/planning/observer-everywhere-mqtt-plan-2026-11-15.md): the
// app is an observer whenever a radio is connected and the app runs, ON by default with one opt-out
// (Settings.telemetryEnabled = Share with MeshSonar). There is no Home observer and no Drive observer mode any more: a drive
// only adds its exact position to the packets heard while it records (`observer.mode = drive`, plan D1).
part of 'app_state.dart';

mixin _ObserverWiring on ChangeNotifier {
  AppState get _s => this as AppState;

  /// The person erased what the server holds: a new observer id from now on.
  Future<void> _afterServerErase() async {
    final s = _s;
    await s.observerIdentity.rotate();
    s._observerKey = null;
    _observerStatus.lastKey = null;
    _observerStatus.status = null;
    notifyListeners();
  }

  // ---------- status heartbeat (lib/core/observer_status.dart) ----------
  late final ObserverStatusService _observerStatus = ObserverStatusService(
    transport: () {
      final c = _s.client;
      return c is ObserverStatusTransport ? c as ObserverStatusTransport : null;
    },
    driverKey: () => _s.keyApproved ? _s._settings.driverKey : null,
    observerId: _s.observerIdentity.load,
    // Every connected phone sends a status heartbeat while sharing is on (contract section 8.3).
    active: () => observerSharing,
    connected: () => _s.connected,
    mode: () => observerMode.wire,
    radio: () => _s._telemetryObserver(observerMode)?.radio.toJson() ?? const <String, dynamic>{},
    autoTimer: _s.services.observerHeartbeatTimer,
  );

  /// Sharing is on for a real radio, the disclosure was seen and the server took the key: this phone is an observer now.
  bool get observerSharing =>
      _s._settings.telemetryEnabled && _s._radioKind != RadioKind.simulator && _s._telemetryDisclosed() && _s.keyApproved;

  /// What this phone is right now (contract section 8): `drive` while a drive records, else `background`.
  ObserverMode get observerMode => _s.driving ? ObserverMode.drive : ObserverMode.background;

  /// The server's 64-hex key for this phone's observer (from the last v2 answer); null until one came back.
  String? get observerKey => _s._observerKey ?? _observerStatus.lastKey;

  /// The status heartbeat and the last `GET /observer/me` answer (Settings > Observer reads it).
  ObserverStatusService get observerStatusService => _observerStatus;

  /// Reads `GET /observer/me` (packets heard in 24 h, last packet, last heartbeat) for this phone.
  Future<ObserverCallOutcome> refreshObserverStatus() async {
    final o = await _observerStatus.refreshStatus(key: observerKey, now: _s.services.clock().toUtc());
    notifyListeners();
    return o;
  }

  /// The radio link dropped by itself (out of range, rebooted, Bluetooth hiccup) outside a drive: the app's saved-radio
  /// auto-connect brings it back (set by main.dart to AlertsRuntime's LaunchReconnect, which honours Settings > Radio >
  /// Auto-connect and a radio released on purpose). A drive has its own reconnect loop in AppState.
  void Function()? onRadioDropped;
  bool _userDisconnect = false;
  StreamSubscription<LinkState>? _linkSub;

  /// The heartbeat follows sharing and the radio link; the observer engine follows too. Called by AppState after a
  /// settings change and at launch.
  void _applyObserverState() {
    if (observerSharing && _s.connected) {
      _observerStatus.startHeartbeat();
    } else {
      _observerStatus.stopHeartbeat();
    }
    _linkSub ??= _s.radioSessions.linkStates.listen(_onLink);
    _updateObserverEngine();
  }

  void _onLink(LinkState st) {
    if (st == LinkState.disconnected && !_userDisconnect && !_s.driving && _s._device != null) onRadioDropped?.call();
    _applyObserverState();
  }

  // ---------- observer engine (MQTT feeds to other sites; lib/core/observer_engine.dart) ----------

  /// The engine feeding outside MQTT sites (Settings > Observer). [NoObserverEngine] when the build has none.
  late final ObserverEngine observerEngine = _s.services.observerEngineFactory?.call() ?? const NoObserverEngine();
  bool _observerForeground = true;

  /// Tells the engine where things stand (sharing, link, foreground, radio, region, slots). Runs with every
  /// [_applyObserverState], i.e. after a connect, a link change, a settings change and at launch.
  void _updateObserverEngine() {
    final s = _s;
    final info = s._selfInfo;
    final session = s.radioSessions.session;
    final link = s.radioSessions.link;
    observerEngine.update(ObserverEngineState(
      sharing: observerSharing,
      connected: s.connected,
      foreground: _observerForeground,
      radioPublicKey: info?.publicKey.toLowerCase(),
      radioModel: link is MeshCoreCompanionLink ? link.companionDetails?.model : null,
      firmware: info?.firmware,
      regionCode: s._currentRegion?.code,
      slots: s._settings.mqttSlots,
      sign: session?.sign,
    ));
  }

  // ---------- hooks called by AppState ----------

  /// A radio link just came up (connect or reconnect).
  void _observerOnConnected() {
    _userDisconnect = false;
    _applyObserverState();
  }

  /// The person ended the link: nothing pulls it back by itself.
  void _observerOnUserDisconnect() {
    _userDisconnect = true;
    _observerStatus.stopHeartbeat();
  }

  /// The app came to the front or went behind.
  void _observerForegroundChanged(bool fg) {
    if (fg == _observerForeground) return;
    _observerForeground = fg;
    _updateObserverEngine();
  }

  /// A packet passed the privacy filter ([record] non-null): the engine gets it only while this phone is an observer, and
  /// only when it is traffic this phone overheard (WS-OUT 4, observer-and-data-platform-plan-2026-11-16.md): an echo of
  /// one of our own pings never goes to an outside site, public or not, and neither does any packet on the drive channel
  /// (the System channel the pings use). Packets heard while a ping of ours is in flight wait until its hash is known.
  void _feedObserverEngine(TelemetryRecord record, RxPacket rx) {
    if (!observerSharing) {
      _mqttHeld.clear();
      return;
    }
    if (_mqttOwn(record) || _onDriveChannel(rx)) return;
    if (_mqttPingsOpen > 0) {
      _mqttHeld.add((record, rx));
      while (_mqttHeld.length > _mqttHeldMax) {
        _mqttHeld.removeAt(0);
      }
      return;
    }
    observerEngine.onPublicPacket(record, rx);
  }

  /// A group packet that proves under the drive channel's key (a # channel; a drive on Public is never dropped wholesale,
  /// its own echoes still are by hash).
  bool _onDriveChannel(RxPacket rx) {
    final name = _s._settings.channel.trim();
    if (!name.startsWith('#')) return false;
    final p = MeshPacket.tryParse(rx.raw);
    if (p == null || !telemetryGroupTypes.contains(p.payloadType)) return false;
    return ShareableChannels(() => [hashtagSecret16(name)])(p.payload);
  }

  // ---------- own-ping echoes for the MQTT feeds ----------

  /// Hashes of our own pings: their echoes never go to an MQTT feed.
  final Set<String> _mqttOwnHashes = <String>{};

  /// Own pings sent whose hash is not known yet (their listen window is still open).
  int _mqttPingsOpen = 0;
  final List<(TelemetryRecord, RxPacket)> _mqttHeld = [];
  Timer? _mqttHoldTimer;
  static const int _mqttHeldMax = 512;

  /// The longest a ping may stay unresolved before held packets are released (the uploader's echo window).
  static const Duration mqttEchoHold = Duration(seconds: 90);

  /// An echo of one of our own transmissions (marked own, or its hash is one of our pings).
  bool _mqttOwn(TelemetryRecord record) {
    if (record.own) return true;
    final h = record.packetHash?.toLowerCase();
    return h != null && _mqttOwnHashes.contains(h);
  }

  /// One of our own pings is going out now: hold packets until its hash is known ([_observerPingResolved]).
  void _observerPingSent(DateTime at) {
    _mqttPingsOpen++;
    _mqttHoldTimer?.cancel();
    _mqttHoldTimer = Timer(mqttEchoHold, () {
      // No ping resolved for the whole echo window (a drive stopped mid-ping): stop holding.
      _mqttHoldTimer = null;
      _mqttPingsOpen = 0;
      _releaseMqttHeld();
    });
  }

  /// A ping of ours resolved: [hash] (null when unknown) is ours, so its echoes are dropped. [tx] = this is the ping a
  /// [_observerPingSent] opened (a transmitted one), so its window closes.
  void _observerPingResolved(String? hash, {required bool tx}) {
    if (hash != null && hash.isNotEmpty) {
      _mqttOwnHashes.add(hash.toLowerCase());
      while (_mqttOwnHashes.length > 2048) {
        _mqttOwnHashes.remove(_mqttOwnHashes.first);
      }
    }
    if (tx && _mqttPingsOpen > 0) _mqttPingsOpen--;
    if (_mqttPingsOpen == 0) {
      _mqttHoldTimer?.cancel();
      _mqttHoldTimer = null;
    }
    _releaseMqttHeld();
  }

  /// Sends what was held when no window is open any more; echoes of our own pings are dropped.
  void _releaseMqttHeld() {
    if (_mqttPingsOpen > 0 || _mqttHeld.isEmpty) return;
    final held = List.of(_mqttHeld);
    _mqttHeld.clear();
    if (!observerSharing) return;
    for (final (r, rx) in held) {
      if (!_mqttOwn(r)) observerEngine.onPublicPacket(r, rx);
    }
  }

  @visibleForTesting
  void debugObserverPingSent(DateTime at) => _observerPingSent(at);

  void _disposeObserver() {
    _mqttHoldTimer?.cancel();
    _mqttHeld.clear();
    _linkSub?.cancel();
    _observerStatus.dispose();
    unawaited(observerEngine.dispose());
  }
}
