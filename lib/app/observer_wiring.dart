// The observer side of AppState, in one place (release 0.38 foundation): whether this phone is an observer
// ([observerSharing]), its mode, the status heartbeat, the Home observer (step O3; lib/core/home_observer.dart,
// lib/ui/settings/home_observer_screen.dart) with its keep-awake and radio auto-reconnect, and the observer-engine slot
// that feeds outside MQTT sites (lib/core/observer_engine.dart). Moved out of app_state.dart unchanged so the observer
// work never has to edit that file; app_state.dart calls only the hooks marked "called by AppState" below.
part of 'app_state.dart';

mixin _ObserverWiring on ChangeNotifier {
  AppState get _s => this as AppState;

  /// The person erased what the server holds: a new observer id from now on, and home mode is over (the server's erase
  /// removed the home observer too).
  Future<void> _afterServerErase() async {
    final s = _s;
    await s.observerIdentity.rotate();
    s._observerKey = null;
    _home.stopHeartbeat();
    _home.status = null;
    final h = s._settings.homeObserver;
    if (h != null && h.on) {
      s._settings = s._settings.copyWith(homeObserver: h.copyWith(on: false));
      try {
        await s.services.settingsStore.save(s._settings);
      } catch (_) {}
      _applyObserverState();
    }
    notifyListeners();
  }

  // ---------- home observer (step O3; lib/core/home_observer.dart, lib/ui/settings/home_observer_screen.dart) ----------
  late final HomeObserverService _home = HomeObserverService(
    transport: () {
      final c = _s.client;
      return c is HomeObserverTransport ? c as HomeObserverTransport : null;
    },
    driverKey: () => _s.keyApproved ? _s._settings.driverKey : null,
    observerId: _s.observerIdentity.load,
    // Every connected phone sends a status heartbeat while sharing is on (contract section 8.3), not only a home observer.
    active: () => observerSharing,
    connected: () => _s.connected,
    config: () => homeObserverActive ? _s._settings.homeObserver : null,
    mode: () => observerMode.wire,
    radio: () => _s._telemetryObserver(observerMode)?.radio.toJson() ?? const <String, dynamic>{},
    autoTimer: _s.services.observerHeartbeatTimer,
  );

  /// Sharing is on for a real radio, the disclosure was seen and the server took the key: this phone is an observer now.
  bool get observerSharing =>
      _s._settings.telemetryEnabled && _s._radioKind != RadioKind.simulator && _s._telemetryDisclosed() && _s.keyApproved;

  /// What this phone is right now (contract section 8): `drive` while a drive records, `home` with Home observer on,
  /// else `background`.
  ObserverMode get observerMode =>
      _s.driving ? ObserverMode.drive : (homeObserverActive ? ObserverMode.home : ObserverMode.background);

  /// The server's 64-hex key for this phone's observer (from the last v2 answer); null until one came back.
  String? get observerKey => _s._observerKey ?? _home.lastKey;

  /// The home observer service (status, heartbeat count).
  HomeObserverService get homeObserverService => _home;

  /// Home mode is on (saved), sharing is on and this is a real radio: packets go as `observer.mode = home`, no cell.
  bool get homeObserverActive =>
      (_s._settings.homeObserver?.on ?? false) && _s._settings.telemetryEnabled && _s._radioKind != RadioKind.simulator;

  /// Keeps the screen awake while home mode is on (set by the UI root; wakelock).
  void Function(bool on)? keepAwakeHook;
  bool _homeAwake = false;
  bool _homeUserDisconnect = false;
  bool _homeReconnecting = false;
  StreamSubscription<LinkState>? _homeLinkSub;

  /// Turns home mode on at [lat]/[lon] (or moves it): saves the choice, registers it with the server (`PUT`), keeps the
  /// screen awake, reconnects the radio by itself and sends the heartbeat. Returns what the server said.
  Future<HomeCallOutcome> startHomeObserver(double lat, double lon, HomeLocationPublic p) async {
    final cfg = HomeObserverConfig(on: true, lat: lat, lon: lon, locationPublic: p);
    await _s.updateSettings(_s._settings.copyWith(homeObserver: cfg, telemetryEnabled: true));
    final o = await _home.register(cfg);
    _applyObserverState();
    unawaited(refreshHomeObserverStatus());
    notifyListeners();
    return o;
  }

  /// Turns home mode off: `DELETE` on the server (back to a mobile observer, home position hidden), heartbeat and keep-awake
  /// stop. The position stays saved on this phone for next time.
  Future<HomeCallOutcome> stopHomeObserver() async {
    final h = _s._settings.homeObserver;
    if (h != null) await _s.updateSettings(_s._settings.copyWith(homeObserver: h.copyWith(on: false)));
    final o = await _home.unregister();
    _applyObserverState();
    notifyListeners();
    return o;
  }

  /// Reads `GET /observer/me` for the status card.
  Future<HomeCallOutcome> refreshHomeObserverStatus() async {
    final o = await _home.refreshStatus(key: _s._observerKey ?? _home.lastKey, now: _s.services.clock().toUtc());
    notifyListeners();
    return o;
  }

  /// Heartbeat, keep-awake and auto-reconnect follow home mode and the radio link; the observer engine follows too.
  /// Called by AppState after a settings change and at launch.
  void _applyObserverState() {
    final on = homeObserverActive;
    if (observerSharing && _s.connected) {
      _home.startHeartbeat();
    } else {
      _home.stopHeartbeat();
    }
    if (on != _homeAwake) {
      _homeAwake = on;
      keepAwakeHook?.call(on);
    }
    _homeLinkSub ??= _s.radioSessions.linkStates.listen(_onHomeLink);
    _updateObserverEngine();
  }

  void _onHomeLink(LinkState st) {
    if (st == LinkState.disconnected && homeObserverActive && !_homeUserDisconnect && !_s.driving) unawaited(_reconnectHome());
    _applyObserverState();
  }

  /// Home mode: the radio dropped (out of range, rebooted, Bluetooth hiccup). Keep trying until it is back, home mode is
  /// turned off or the person disconnects.
  Future<void> _reconnectHome() async {
    final s = _s;
    final device = s._device, kind = s._radioKind, expected = s._radioKey;
    if (_homeReconnecting || device == null || kind == RadioKind.none) return;
    _homeReconnecting = true;
    s.diagnostics.add('Home observer: the radio dropped; reconnecting');
    try {
      final session = await s.radioSessions.reconnect(
        s.scannerFor(kind),
        device,
        keepGoing: () => homeObserverActive && !_homeUserDisconnect && !s.driving && identical(s._device, device),
        delay: (n) => Duration(seconds: n <= 1 ? 2 : math.min(60, 5 * n)),
        expectedKeyHex: expected,
        onConnected: (session) async {
          s._selfInfo = session.selfInfo;
          unawaited(s._telemetrySub?.cancel());
          s._telemetrySub = AppState._observerStream(session.link).listen(s._onTelemetryRx, onError: (Object _) {});
        },
      );
      if (session != null) s.diagnostics.add('Home observer: radio reconnected');
    } catch (e) {
      s._logError('Home observer reconnect failed', e);
    } finally {
      _homeReconnecting = false;
      _applyObserverState();
      notifyListeners();
    }
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

  /// A radio link just came up (connect or reconnect by the person).
  void _observerOnConnected() {
    _homeUserDisconnect = false;
    _applyObserverState();
  }

  /// The person ended the link: home mode does not pull it back.
  void _observerOnUserDisconnect() {
    _homeUserDisconnect = true;
    _home.stopHeartbeat();
  }

  /// The app came to the front or went behind.
  void _observerForegroundChanged(bool fg) {
    if (fg == _observerForeground) return;
    _observerForeground = fg;
    _updateObserverEngine();
  }

  /// A packet passed the privacy filter ([record] non-null): the engine gets it only while this phone is an observer.
  void _feedObserverEngine(TelemetryRecord record, RxPacket rx) {
    if (observerSharing) observerEngine.onPublicPacket(record, rx);
  }

  void _disposeObserver() {
    _homeLinkSub?.cancel();
    _home.dispose();
    if (_homeAwake) keepAwakeHook?.call(false);
    unawaited(observerEngine.dispose());
  }
}
