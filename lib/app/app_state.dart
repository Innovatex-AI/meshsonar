// App-wide state: settings, radio connection, the running drive, live stats and sync.
// A plain ChangeNotifier (no state-management packages). The UI reads it through AppScope.
//
// Save-first rule: every ping the engine finishes is appended to the DriveStore before anything else
// happens to it. If a write fails, the ping stays in memory and is retried on the next ping and at Stop,
// and the user is told. Sync failures never touch stored pings.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/api.dart';
import '../core/heard.dart';
import '../core/model.dart';
import '../core/repeater_directory.dart';
import '../radio/radio_api.dart';
import 'messages.dart';
import 'services.dart';

enum RadioKind { none, bluetooth, simulator }

class AppState extends ChangeNotifier {
  final AppServices services;
  AppState(this.services);

  // ---------- settings ----------
  Settings _settings = const Settings();
  Settings get settings => _settings;
  bool _loaded = false;
  bool get loaded => _loaded;

  CmatClient? _client;
  CmatClient get client {
    final url = Uri.tryParse(_settings.serverUrl) ?? Uri.parse(const Settings().serverUrl);
    if (_client == null || _client!.baseUrl != url) _client = services.cmatClientFactory(url);
    return _client!;
  }

  SyncService? _sync;
  CmatClient? _syncClient;
  SyncService get _syncService {
    final c = client;
    if (_sync == null || !identical(_syncClient, c)) {
      _syncClient = c;
      _sync = services.syncServiceFactory(c);
    }
    return _sync!;
  }

  bool get hasKey => (_settings.driverKey ?? '').isNotEmpty;
  bool get keyApproved => hasKey && _settings.keyStatus == DriverKeyStatus.approved;

  /// Last few characters only; the full key is never shown.
  String get maskedKey {
    final k = _settings.driverKey ?? '';
    if (k.isEmpty) return '';
    return '••••${k.length > 4 ? k.substring(k.length - 4) : ''}';
  }

  // ---------- messages ----------
  /// One plain-language message for a snackbar/banner. Cleared once shown.
  String? _notice;
  String? takeNotice() {
    final n = _notice;
    _notice = null;
    return n;
  }

  String? get pendingNotice => _notice;

  void _say(String msg) {
    _notice = msg;
    notifyListeners();
  }

  // ---------- radio ----------
  RadioKind _radioKind = RadioKind.none;
  RadioKind get radioKind => _radioKind;
  RadioDevice? _device;
  RadioDevice? get device => _device;
  CompanionLink? _link;
  SelfInfo? _selfInfo;
  SelfInfo? get selfInfo => _selfInfo;
  bool _connecting = false;
  bool get connecting => _connecting;
  String? _connectError;
  String? get connectError => _connectError;
  bool get connected => _link != null && _link!.isConnected;

  String get connectionLabel {
    if (_connecting) return 'Connecting…';
    if (!connected) return 'Not connected';
    if (_radioKind == RadioKind.simulator) return 'Simulator';
    return _selfInfo?.name ?? _device?.name ?? 'Radio';
  }

  RadioScanner scannerFor(RadioKind kind) =>
      kind == RadioKind.simulator ? services.simulatorScanner : services.bluetoothScanner;

  LocationSource get _locationSource =>
      _radioKind == RadioKind.simulator ? services.simulatedLocation : services.location;

  /// The location source a drive uses with the current radio (read-only; the Drive screen's map follows it).
  LocationSource get activeLocation => _locationSource;

  Future<bool> connect(RadioDevice device, RadioKind kind) async {
    if (driving) {
      _say('Stop the drive before switching radios.');
      return false;
    }
    await disconnect(quiet: true);
    _connecting = true;
    _connectError = null;
    _device = device;
    _radioKind = kind;
    notifyListeners();
    ByteTransport? transport;
    try {
      transport = await scannerFor(kind).connect(device).timeout(const Duration(seconds: 25));
      final link = services.linkFactory(transport);
      final info = await link.start().timeout(const Duration(seconds: 20));
      _link = link;
      _selfInfo = info;
      _connecting = false;
      notifyListeners();
      return true;
    } catch (e) {
      try {
        await transport?.disconnect();
      } catch (_) {}
      _connecting = false;
      _link = null;
      _selfInfo = null;
      _device = null;
      _radioKind = RadioKind.none;
      _connectError = e is TimeoutException
          ? 'The radio didn\'t answer. Make sure it\'s on, nearby, and not connected to another app.'
          : 'Couldn\'t connect to ${device.name}. ${friendlyError(e, action: 'Connecting')}';
      notifyListeners();
      return false;
    }
  }

  /// Connects to the simulator's single device.
  Future<bool> connectSimulator() async {
    try {
      final lists = await services.simulatorScanner.scan(timeout: const Duration(seconds: 2)).toList();
      final all = lists.expand((l) => l).toList();
      final dev = all.isNotEmpty ? all.first : const RadioDevice(id: 'simulator', name: 'MeshSonar Simulator');
      return await connect(dev, RadioKind.simulator);
    } catch (e) {
      _connectError = friendlyError(e, action: 'Starting the simulator');
      notifyListeners();
      return false;
    }
  }

  Future<void> disconnect({bool quiet = false}) async {
    if (driving) await stopDrive();
    final link = _link;
    _link = null;
    _selfInfo = null;
    _device = null;
    _radioKind = RadioKind.none;
    if (link != null) {
      try {
        await link.close();
      } catch (_) {}
    }
    if (!quiet) notifyListeners();
  }

  // ---------- drive ----------
  WardriveEngine? _engine;
  EngineStatus _status = const EngineStatus(EngineState.idle);
  EngineStatus get status => _status;
  DriveSession? _session;
  DriveSession? get currentSession => _session;
  bool get driving => _session != null;
  bool _busy = false; // starting/stopping
  bool get busy => _busy;
  bool _pinging = false;
  bool get pinging => _pinging;

  final List<DrivePing> _recent = [];
  List<DrivePing> get recentPings => List.unmodifiable(_recent);

  /// Every ping of the current drive, oldest first (the map and the ping log use the whole drive).
  final List<DrivePing> _drivePings = [];
  List<DrivePing> get drivePings => List.unmodifiable(_drivePings);

  /// Who's in range: repeaters heard this drive; "live" until not heard for settings.heardHoldPings pings.
  final HeardTracker heard = HeardTracker();

  /// Prefix → repeater (name, key, position) from CMAT's list plus any extra directories.
  RepeaterLookup _lookup = RepeaterLookup.empty;
  RepeaterLookup get lookup => _lookup;
  List<RepeaterRef> _extraRepeaters = const [];

  /// Adds repeaters from another source (e.g. a public node map) used after CMAT's list.
  void setExtraRepeaters(List<RepeaterRef> list) {
    _extraRepeaters = list;
    _rebuildLookup();
    notifyListeners();
  }

  void _rebuildLookup() {
    _lookup = RepeaterLookup([(RepeaterSource.cmat, _repeaters), (RepeaterSource.publicMap, _extraRepeaters)]);
    _nameCache.clear(); // names from either list may have changed
    heard.relookup(_lookup);
  }

  /// Antenna type for the next drive ("internal" or "external"); saved to settings.
  Future<void> setAntennaType(String type) async {
    final t = type == 'external' ? 'external' : 'internal';
    final a = _settings.antenna;
    await updateSettings(_settings.copyWith(antenna: Antenna(type: t, gainDbi: a.gainDbi, heightM: a.heightM)));
  }
  static const int recentLimit = 50;

  int _pingCount = 0;
  int _heardCount = 0;
  int _syncedCount = 0;
  int get pingCount => _pingCount;
  int get heardCount => _heardCount;
  int get syncedCount => _syncedCount;
  int? get heardPercent => _pingCount == 0 ? null : (100 * _heardCount / _pingCount).round();

  final Set<String> _seenPingIds = {};
  final List<DrivePing> _unsaved = [];
  int get unsavedCount => _unsaved.length;
  Future<void> _writeChain = Future.value();
  StreamSubscription<DrivePing>? _pingSub;
  StreamSubscription<EngineStatus>? _statusSub;

  /// Stats for the drive screen when not driving: the last finished drive stays visible.
  DriveSession? _lastSession;
  DriveSession? get lastSession => _lastSession;

  // ---------- uploads during / at the end of a drive (Agent 4) ----------
  /// When the last upload (during a drive, at Stop, or a manual sync) finished without error.
  DateTime? _lastUploadAt;
  DateTime? get lastUploadAt => _lastUploadAt;

  /// Plain-language reason the last upload failed; null after a successful one.
  String? _lastUploadError;
  String? get lastUploadError => _lastUploadError;

  bool _uploading = false;

  /// An upload is running (the periodic in-drive upload, the one at Stop, or a manual sync).
  bool get uploading => _uploading || _syncing.isNotEmpty;

  /// The drive that just stopped (for the "View drive report" card); cleared when a new drive starts or it's deleted.
  String? _lastFinishedSessionId;
  String? get lastFinishedSessionId => _lastFinishedSessionId;

  /// Period of the in-drive upload timer for a [Settings.syncEveryMin] value. Tests shorten it.
  @visibleForTesting
  Duration Function(int minutes) syncPeriodFor = (m) => Duration(minutes: m);

  Timer? _driveSyncTimer;
  Duration? _driveSyncPeriod;
  Future<void>? _driveSyncInFlight;

  /// Whether the in-drive upload timer should be running with the current settings.
  bool get _wantDriveSync => driving && _settings.autoSync && _settings.syncDuringDrive && keyApproved;

  /// Starts, restarts (new period) or stops the in-drive upload timer to match the settings.
  void _scheduleDriveSync() {
    if (!_wantDriveSync) {
      _cancelDriveSync();
      return;
    }
    final period = syncPeriodFor(_settings.syncEveryMin);
    if (_driveSyncTimer != null && _driveSyncPeriod == period) return;
    _driveSyncTimer?.cancel();
    _driveSyncPeriod = period;
    _driveSyncTimer = Timer.periodic(period, (_) => _driveSyncTick());
  }

  void _cancelDriveSync() {
    _driveSyncTimer?.cancel();
    _driveSyncTimer = null;
    _driveSyncPeriod = null;
  }

  /// One in-drive upload of the current drive's saved pings. Never overlaps another; failures are quiet (status
  /// line only) and retried on the next tick.
  void _driveSyncTick() {
    if (_driveSyncInFlight != null || _busy || !_wantDriveSync) return;
    final sid = _session?.id;
    if (sid == null) return;
    _driveSyncInFlight = _uploadQuietly(sid).whenComplete(() => _driveSyncInFlight = null);
  }

  Future<void> _uploadQuietly(String sessionId) async {
    _uploading = true;
    notifyListeners();
    try {
      await _writeChain; // only pings already saved on the phone are sent
      final r = await _syncService.syncSession(sessionId);
      if (r.error != null) {
        _lastUploadError = friendlySyncError(r.error!);
        final l = r.error!.toLowerCase();
        if (l.contains('403') || l.contains('not approved') || l.contains('not recognised')) {
          unawaited(refreshKeyStatus(quiet: true));
        }
      } else {
        _lastUploadAt = services.clock();
        _lastUploadError = null;
      }
    } catch (e) {
      _lastUploadError = friendlyError(e, action: 'Upload');
      if (e is CmatException && e.status == 403) unawaited(refreshKeyStatus(quiet: true));
    } finally {
      _uploading = false;
      await refreshSessions(); // updates syncedCount live
    }
  }

  Future<void> startDrive({String? label}) async {
    if (driving || _busy) return;
    final link = _link;
    if (link == null || !link.isConnected) {
      _say('Connect a radio (or the simulator) first.');
      return;
    }
    _busy = true;
    notifyListeners();
    final location = _locationSource;
    try {
      final ok = await location.ensurePermission();
      if (!ok) {
        _say('MeshSonar needs location access to record where each ping was sent. '
            'Turn on location for MeshSonar in your phone\'s settings.');
        return;
      }
      final s = _settings;
      final info = _selfInfo;
      final session = DriveSession(
        id: services.newId(),
        startedAt: services.clock().toUtc(),
        label: (label == null || label.trim().isEmpty) ? null : label.trim(),
        channel: s.channel,
        radio: info?.radio ?? const Radio(),
        antenna: s.antenna,
        companion: Companion(
          publicKey: info?.publicKey.toLowerCase(),
          name: info?.name,
          firmware: info?.firmware,
        ),
      );
      await services.store.startSession(session);
      _session = session;
      _lastSession = null;
      _lastFinishedSessionId = null;
      _recent.clear();
      _drivePings.clear();
      heard
        ..holdPings = s.heardHoldPings
        ..reset();
      _seenPingIds.clear();
      _pingCount = 0;
      _heardCount = 0;
      _syncedCount = 0;

      final engine = services.engineFactory(link, location);
      _engine = engine;
      _status = engine.current;
      _pingSub = engine.pings.listen(_onPing, onError: (Object e) => _say(friendlyError(e, action: 'A ping')));
      _statusSub = engine.status.listen((st) {
        _status = st;
        notifyListeners();
      });
      final txW = info?.radio.txDbm == null ? null : _dbmToWatts(info!.radio.txDbm!);
      await engine.start(WardriveConfig(
        channel: s.channel,
        intervalSec: s.intervalSec,
        minDistanceM: s.minDistanceM,
        txPowerW: txW,
      ));
      _scheduleDriveSync();
      unawaited(refreshSessions());
    } catch (e) {
      // The session row may exist with no pings; close it so it doesn't look "still driving".
      final sid = _session?.id;
      _cancelDriveSync();
      await _teardownEngine();
      if (sid != null) {
        try {
          await services.store.endSession(sid, services.clock().toUtc());
        } catch (_) {}
      }
      _session = null;
      _say('Couldn\'t start the drive. ${friendlyError(e, action: 'Starting')}');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  static double _dbmToWatts(double dbm) => math.pow(10, dbm / 10) / 1000;

  void _onPing(DrivePing ping) {
    if (!_seenPingIds.add(ping.id)) return;
    final sid = _session?.id;
    if (sid == null) return;
    _pingCount++;
    if (!ping.heardNothing && ping.kind == PingKind.tx) _heardCount++;
    _recent.insert(0, ping);
    if (_recent.length > recentLimit) _recent.removeLast();
    _drivePings.add(ping);
    heard.addPing(ping);
    // First GPS fix of the drive: make sure the public node directory covers this area (no-op when fresh).
    if (_drivePings.length == 1) unawaited(refreshDirectory(lat: ping.lat, lon: ping.lon));
    notifyListeners();
    _enqueueWrite(sid, ping);
  }

  void _enqueueWrite(String sessionId, DrivePing ping) {
    _writeChain = _writeChain.then((_) async {
      // Retry anything that failed earlier first, in order.
      final pending = [..._unsaved, ping];
      _unsaved.clear();
      for (var i = 0; i < pending.length; i++) {
        try {
          await services.store.appendPing(sessionId, pending[i]);
        } catch (e) {
          _unsaved.addAll(pending.sublist(i));
          _say('Couldn\'t save a ping to this device; will retry. ${friendlyError(e, action: 'Saving')}');
          return;
        }
      }
    });
  }

  Future<void> _flushWrites() async {
    await _writeChain;
    final sid = _session?.id;
    if (_unsaved.isNotEmpty && sid != null) {
      final pending = List.of(_unsaved);
      _unsaved.clear();
      for (var i = 0; i < pending.length; i++) {
        try {
          await services.store.appendPing(sid, pending[i]);
        } catch (e) {
          _unsaved.addAll(pending.sublist(i));
          break;
        }
      }
    }
  }

  Future<DrivePing?> pingNow() async {
    final engine = _engine;
    if (engine == null || !driving) {
      _say('Start a drive first.');
      return null;
    }
    if (_pinging) return null;
    _pinging = true;
    notifyListeners();
    try {
      final p = await engine.pingNow();
      _onPing(p); // de-duplicated against the stream
      return p;
    } catch (e) {
      _say(friendlyError(e, action: 'The ping'));
      return null;
    } finally {
      _pinging = false;
      notifyListeners();
    }
  }

  Future<void> stopDrive() async {
    final session = _session;
    if (session == null || _busy) return;
    _busy = true;
    _cancelDriveSync();
    notifyListeners();
    try {
      try {
        await _engine?.stop();
      } catch (e) {
        _say(friendlyError(e, action: 'Stopping'));
      }
      // Let any ping emitted during stop arrive, then write everything.
      await Future<void>.microtask(() {});
      await _teardownEngine();
      await _flushWrites();
      try {
        await services.store.endSession(session.id, services.clock().toUtc());
      } catch (e) {
        _say(friendlyError(e, action: 'Closing the drive'));
      }
      if (_unsaved.isNotEmpty) {
        _say('${_unsaved.length} ping(s) couldn\'t be saved to this device. Export the drive before closing the app.');
      }
      _lastSession = session.copyWith(endedAt: services.clock().toUtc());
      _lastFinishedSessionId = session.id;
      _session = null;
      _status = const EngineStatus(EngineState.idle);
    } finally {
      _busy = false;
      notifyListeners();
    }
    // An in-drive upload may still be running; let it finish so the final one sends what's left plus ended_at.
    final inFlight = _driveSyncInFlight;
    if (inFlight != null) await inFlight;
    await refreshSessions();
    if (_settings.autoSync && keyApproved) {
      await syncSession(session.id, quietIfNothing: true);
    } else if (_settings.autoSync && hasKey && !keyApproved) {
      _say('Drive saved. It will upload once your driver key is approved.');
    } else {
      _say('Drive saved on this phone.');
    }
  }

  Future<void> _teardownEngine() async {
    // Not awaited: nothing depends on the cancel finishing, and some stream cancels complete late.
    unawaited(_pingSub?.cancel());
    unawaited(_statusSub?.cancel());
    _pingSub = null;
    _statusSub = null;
    _engine = null;
  }

  String get statusLine {
    final st = _status;
    if (st.message != null && st.message!.isNotEmpty) return st.message!;
    switch (st.state) {
      case EngineState.idle:
        return connected ? 'Ready. Press Start drive.' : 'Connect a radio to begin.';
      case EngineState.starting:
        return 'Starting…';
      case EngineState.driving:
        final next = st.nextPingAt;
        if (next == null) return 'Driving.';
        final secs = next.difference(services.clock()).inSeconds;
        return secs > 0 ? 'Driving. Next ping in ${secs}s.' : 'Driving. Ping due.';
      case EngineState.pinging:
        return 'Pinging… listening for repeaters.';
      case EngineState.stopping:
        return 'Stopping…';
      case EngineState.error:
        return 'Radio problem. Check the connection.';
    }
  }

  // ---------- sessions ----------
  List<SessionSummary> _sessions = const [];
  List<SessionSummary> get sessions => _sessions;
  bool _sessionsLoading = false;
  bool get sessionsLoading => _sessionsLoading;
  String? _sessionsError;
  String? get sessionsError => _sessionsError;

  Future<void> refreshSessions() async {
    _sessionsLoading = true;
    try {
      _sessions = await services.store.sessions();
      _sessionsError = null;
      final cur = _session ?? _lastSession;
      if (cur != null) {
        for (final s in _sessions) {
          if (s.session.id == cur.id) {
            _syncedCount = s.syncedCount;
            if (_session == null) {
              _pingCount = s.pingCount;
              _heardCount = s.heardCount;
            }
          }
        }
      }
    } catch (e) {
      _sessionsError = 'Couldn\'t read saved drives. ${friendlyError(e, action: 'Reading')}';
    } finally {
      _sessionsLoading = false;
      notifyListeners();
    }
  }

  // ---------- sync ----------
  final Set<String> _syncing = {};
  bool isSyncing(String sessionId) => _syncing.contains(sessionId);
  bool get anySyncing => _syncing.isNotEmpty;
  String? _lastSyncMessage;
  String? get lastSyncMessage => _lastSyncMessage;
  bool _lastSyncFailed = false;
  bool get lastSyncFailed => _lastSyncFailed;

  bool _canSync() {
    if (!hasKey) {
      _say('Request a driver key in Settings before syncing. Your drives are saved on this phone.');
      return false;
    }
    if (_settings.keyStatus != DriverKeyStatus.approved) {
      _say('Your driver key is ${_settings.keyStatus.name}. Drives upload once it\'s approved; tap Refresh in Settings.');
      return false;
    }
    return true;
  }

  Future<SyncReport?> syncSession(String sessionId, {bool quietIfNothing = false}) async {
    if (!_canSync()) return null;
    if (driving && _session?.id == sessionId) {
      await _flushWrites();
    }
    _syncing.add(sessionId);
    notifyListeners();
    try {
      final r = await _syncService.syncSession(sessionId);
      _handleReport(r, quietIfNothing: quietIfNothing);
      return r;
    } catch (e) {
      _syncFailed(friendlyError(e, action: 'Sync'), e);
      return null;
    } finally {
      _syncing.remove(sessionId);
      await refreshSessions();
    }
  }

  Future<SyncReport?> syncAll() async {
    if (!_canSync()) return null;
    _syncing.add('*');
    notifyListeners();
    try {
      final r = await _syncService.syncAll();
      _handleReport(r);
      return r;
    } catch (e) {
      _syncFailed(friendlyError(e, action: 'Sync'), e);
      return null;
    } finally {
      _syncing.remove('*');
      await refreshSessions();
    }
  }

  void _handleReport(SyncReport r, {bool quietIfNothing = false}) {
    if (r.error != null) {
      _syncFailed(friendlySyncError(r.error!), null);
      final l = r.error!.toLowerCase();
      if (l.contains('403') || l.contains('not approved') || l.contains('not recognised')) {
        unawaited(refreshKeyStatus(quiet: true));
      }
      return;
    }
    _lastSyncFailed = false;
    _lastUploadAt = services.clock();
    _lastUploadError = null;
    final parts = <String>['Uploaded ${r.stored} new ping${r.stored == 1 ? '' : 's'}'];
    if (r.duplicate > 0) parts.add('${r.duplicate} already on the server');
    if (r.rejected > 0) parts.add('${r.rejected} rejected');
    _lastSyncMessage = '${parts.join(', ')}.';
    if (quietIfNothing && r.stored == 0 && r.duplicate == 0 && r.rejected == 0) {
      _say('Drive saved. Nothing new to upload.');
    } else {
      _say(_lastSyncMessage!);
    }
  }

  void _syncFailed(String msg, Object? e) {
    _lastSyncFailed = true;
    _lastSyncMessage = msg;
    _lastUploadError = msg;
    _say(msg);
    if (e is CmatException && e.status == 403) unawaited(refreshKeyStatus(quiet: true));
  }

  // ---------- export / delete ----------
  Future<void> exportAndShare(String sessionId) async {
    try {
      final dir = await services.exportDir();
      final file = await services.store.exportSession(sessionId, services.appInfo, dir);
      await services.shareFile(file);
    } catch (e) {
      _say(friendlyError(e, action: 'Export'));
    }
  }

  Future<bool> deleteSession(String sessionId) async {
    if (_session?.id == sessionId) {
      _say('Stop the drive before deleting it.');
      return false;
    }
    try {
      await services.store.deleteSession(sessionId);
      if (_lastFinishedSessionId == sessionId) _lastFinishedSessionId = null;
      if (_lastSession?.id == sessionId) {
        _lastSession = null;
        _pingCount = 0;
        _heardCount = 0;
        _syncedCount = 0;
        _recent.clear();
      }
      await refreshSessions();
      _say('Drive deleted.');
      return true;
    } catch (e) {
      _say(friendlyError(e, action: 'Delete'));
      return false;
    }
  }

  // ---------- settings / key ----------
  Future<void> init() async {
    try {
      _settings = await services.settingsStore.load();
    } catch (e) {
      _settings = const Settings();
      _notice = 'Settings couldn\'t be read, so defaults are in use.';
    }
    try {
      _setRepeaters(await services.repeaterCache.load());
    } catch (_) {}
    unawaited(_loadDirectory());
    _loaded = true;
    notifyListeners();
    await refreshSessions();
    if (keyApproved) unawaited(refreshRepeaters(quiet: true));
  }

  Future<void> updateSettings(Settings s) async {
    _settings = s;
    _scheduleDriveSync(); // in-drive upload follows the toggles, the period and the key status
    _applyPingCadence(s);
    notifyListeners();
    try {
      await services.settingsStore.save(s);
    } catch (e) {
      _say('Couldn\'t save settings. ${friendlyError(e, action: 'Saving')}');
    }
  }

  /// Auto-ping interval/distance changed mid-drive: the running engine picks them up at once.
  void _applyPingCadence(Settings s) {
    final engine = _engine;
    if (engine == null || !driving) return;
    final txDbm = _selfInfo?.radio.txDbm;
    engine.updateConfig(WardriveConfig(
      channel: s.channel,
      intervalSec: s.intervalSec,
      minDistanceM: s.minDistanceM,
      txPowerW: txDbm == null ? null : _dbmToWatts(txDbm),
    ));
  }

  bool _keyBusy = false;
  bool get keyBusy => _keyBusy;
  String? _keyError;
  String? get keyError => _keyError;

  Future<bool> requestKey({required String name, String? callsign, String? email}) async {
    _keyBusy = true;
    _keyError = null;
    notifyListeners();
    try {
      final r = await client.requestKey(
        name: name.trim(),
        callsign: _blankToNull(callsign),
        email: _blankToNull(email),
      );
      await updateSettings(_settings.copyWith(driverKey: r.key, keyStatus: r.status, display: r.display));
      if (r.status == DriverKeyStatus.approved) unawaited(refreshRepeaters(quiet: true));
      return true;
    } catch (e) {
      _keyError = friendlyError(e, action: 'The key request');
      return false;
    } finally {
      _keyBusy = false;
      notifyListeners();
    }
  }

  Future<void> refreshKeyStatus({bool quiet = false}) async {
    final key = _settings.driverKey;
    if (key == null || key.isEmpty) return;
    _keyBusy = true;
    _keyError = null;
    notifyListeners();
    try {
      final r = await client.status(key);
      await updateSettings(_settings.copyWith(keyStatus: r.status, display: r.display));
      if (r.status == DriverKeyStatus.approved) unawaited(refreshRepeaters(quiet: true));
    } catch (e) {
      if (e is CmatException && e.status == 401) {
        await updateSettings(_settings.copyWith(keyStatus: DriverKeyStatus.unknown));
      }
      if (!quiet) _keyError = friendlyError(e, action: 'Checking the key');
    } finally {
      _keyBusy = false;
      notifyListeners();
    }
  }

  Future<void> forgetKey() => updateSettings(_settings.copyWith(clearKey: true));

  static String? _blankToNull(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

  // ---------- repeater names ----------
  List<RepeaterRef> _repeaters = const [];
  List<RepeaterRef> get repeaters => _repeaters;
  DateTime? _repeatersAt;
  DateTime? get repeatersUpdatedAt => _repeatersAt;

  void _setRepeaters(List<RepeaterRef> list) {
    _repeaters = list;
    _nameCache.clear();
    _rebuildLookup();
  }

  final Map<String, String?> _nameCache = {};

  /// Name of the repeater whose key starts with [prefix], if exactly one known repeater matches.
  String? repeaterName(String prefix) {
    final p = prefix.toLowerCase();
    return _nameCache.putIfAbsent(p, () {
      final m = _lookup.resolve(p);
      return (m.ref == null || m.ref!.name.isEmpty) ? null : m.ref!.name;
    });
  }

  /// Name if known, else the hex prefix.
  String repeaterLabel(String prefix) => repeaterName(prefix) ?? prefix.toLowerCase();

  Future<void> refreshRepeaters({bool quiet = false}) async {
    if (!quiet) unawaited(refreshDirectory(force: true)); // a manual refresh also refetches the public node map
    final key = _settings.driverKey;
    if (key == null || key.isEmpty) {
      if (!quiet) _say('Request a driver key first.');
      return;
    }
    try {
      final list = await client.repeaters(key);
      _repeatersAt = services.clock();
      // An empty answer never wipes names we already have (names are only a display aid).
      if (list.isNotEmpty || _repeaters.isEmpty) {
        _setRepeaters(list);
        await services.repeaterCache.save(list);
      }
      if (!quiet) _say('Updated ${list.length} repeater names.');
      notifyListeners();
    } catch (e) {
      if (!quiet) _say(friendlyError(e, action: 'Updating repeater names'));
    }
  }

  // ---------- public node directory (map.meshcore.io; Agent 2) ----------
  DirectorySnapshot? _directory;

  /// The cached public node directory (repeaters near the last drive area), or null.
  DirectorySnapshot? get directory => _directory;

  void _applyDirectory(DirectorySnapshot? s) {
    if (s == null || identical(s, _directory)) return;
    _directory = s;
    setExtraRepeaters(s.repeaters);
  }

  Future<void> _loadDirectory() async {
    final d = services.directory;
    if (d == null) return;
    try {
      final s = await d.load();
      _applyDirectory(s);
      if (s != null && d.isStale(s)) await refreshDirectory(); // once a day, around the last area used
    } catch (_) {}
  }

  /// Refreshes the public node directory around [lat]/[lon] (default: the last drive position, else the cached
  /// centre). Respects the directory's 24 h cache unless [force]. Never throws; offline just keeps the cache.
  Future<void> refreshDirectory({double? lat, double? lon, bool force = false}) async {
    final d = services.directory;
    if (d == null) return;
    if (lat == null || lon == null) {
      final last = _drivePings.isNotEmpty ? _drivePings.last : null;
      lat = last?.lat ?? _directory?.centerLat;
      lon = last?.lon ?? _directory?.centerLon;
    }
    if (lat == null || lon == null) return;
    try {
      _applyDirectory(await d.refresh(lat: lat, lon: lon, force: force));
    } catch (_) {}
  }

  @override
  void dispose() {
    _cancelDriveSync();
    _pingSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }
}
