// Hand-written fakes for UI tests. No concrete lib/core or lib/radio classes are used.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_context.dart';
import 'package:meshsonar/core/drive_context_wire.dart';
import 'package:meshsonar/core/phone_sensors.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/idle_region_watcher.dart';
import 'package:meshsonar/core/offline_packs.dart' show NetworkKind, NetworkMonitor;
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_stats_api.dart' show HubRegions;
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';

class FakeDriveStore implements DriveStore, DriveContextLedger, ContextSyncLedger {
  /// The drive context recorded beside each drive (stream 7).
  final FakeContextLedger ctx = FakeContextLedger();

  @override
  Future<Set<String>> ctxSentPingIds(String sessionId) => ctx.ctxSentPingIds(sessionId);
  @override
  Future<void> markCtxSent(String sessionId, Iterable<String> pingIds) => ctx.markCtxSent(sessionId, pingIds);
  @override
  Future<Set<String>> samplesSentKeys(String sessionId) => ctx.samplesSentKeys(sessionId);
  @override
  Future<void> markSamplesSent(String sessionId, Iterable<String> keys) => ctx.markSamplesSent(sessionId, keys);
  @override
  Future<String?> sessionContextMark(String sessionId) => ctx.sessionContextMark(sessionId);
  @override
  Future<void> markSessionContext(String sessionId, String mark) => ctx.markSessionContext(sessionId, mark);
  @override
  Future<ContextStripResult> stripUnsentCategories(String sessionId, Set<String> categoryIds) =>
      ctx.stripUnsentCategories(sessionId, categoryIds);

  @override
  Future<void> appendSamples(String sessionId, Iterable<DriveSample> samples) => ctx.appendSamples(sessionId, samples);
  @override
  Future<void> appendPingContext(String sessionId, String pingId, PingContext c) => ctx.appendPingContext(sessionId, pingId, c);
  @override
  Future<void> writeSessionContext(String sessionId, SessionContext c) => ctx.writeSessionContext(sessionId, c);
  @override
  Future<List<DriveSample>> samples(String sessionId) => ctx.samples(sessionId);
  @override
  Future<Map<String, PingContext>> pingContexts(String sessionId) => ctx.pingContexts(sessionId);
  @override
  Future<SessionContext?> sessionContext(String sessionId) => ctx.sessionContext(sessionId);
  @override
  Future<ContextStripResult> stripCategories(String sessionId, Set<String> categoryIds) =>
      ctx.stripCategories(sessionId, categoryIds);

  final Map<String, DriveSession> sessionsById = {};
  final Map<String, List<DrivePing>> pingsBySession = {};
  final Map<String, Set<String>> synced = {};
  final Map<String, Set<String>> rejected = {};

  /// Sessions renamed since their last sync (cleared by [FakeSyncService]).
  final Set<String> resend = {};
  final List<String> calls = [];

  /// Makes [startSession] fail (e.g. a full disk).
  bool failStart = false;

  /// Makes [sessions] fail (set after the app's first load), and [pings] fail for these drive ids (a damaged file).
  bool failSessions = false;
  final Set<String> failPings = {};
  bool failAppend = false;
  int exportCount = 0;

  @override
  Future<void> startSession(DriveSession session) async {
    if (failStart) throw const FileSystemException('disk full');
    calls.add('start');
    sessionsById[session.id] = session;
    pingsBySession[session.id] = [];
    synced[session.id] = {};
  }

  @override
  Future<void> appendPing(String sessionId, DrivePing ping) async {
    if (failAppend) throw const FileSystemException('disk full');
    calls.add('append');
    pingsBySession[sessionId]!.add(ping);
  }

  @override
  Future<void> endSession(String sessionId, DateTime endedAt) async {
    calls.add('end');
    sessionsById[sessionId] = sessionsById[sessionId]!.copyWith(endedAt: endedAt);
  }

  @override
  Future<void> renameSession(String sessionId, String? label) async {
    calls.add('rename');
    final s = sessionsById[sessionId];
    if (s == null) throw StateError('no such session: $sessionId');
    final v = label?.trim();
    sessionsById[sessionId] = DriveSession(
      id: s.id,
      startedAt: s.startedAt,
      endedAt: s.endedAt,
      label: (v == null || v.isEmpty) ? null : v,
      channel: s.channel,
      radio: s.radio,
      antenna: s.antenna,
      companion: s.companion,
    );
    resend.add(sessionId);
  }

  @override
  Future<DriveSession?> session(String sessionId) async => sessionsById[sessionId];

  @override
  Future<List<SessionSummary>> sessions() async {
    if (failSessions) throw const FileSystemException('drive folder unreadable');
    final list = sessionsById.values.toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return [
      for (final s in list)
        SessionSummary(
          session: s,
          pingCount: pingsBySession[s.id]!.length,
          txCount: pingsBySession[s.id]!.where((p) => p.kind == PingKind.tx).length,
          heardCount: pingsBySession[s.id]!.where((p) => p.kind == PingKind.tx && !p.heardNothing).length,
          syncedCount: synced[s.id]!.length,
          rejectedCount: (rejected[s.id] ?? const {}).length,
          sessionResendPending: resend.contains(s.id),
        ),
    ];
  }

  @override
  Future<List<DrivePing>> pings(String sessionId) async {
    if (failPings.contains(sessionId)) throw const FileSystemException('damaged drive file');
    return List.of(pingsBySession[sessionId] ?? const []);
  }

  @override
  Future<List<DrivePing>> unsyncedPings(String sessionId) async =>
      pingsBySession[sessionId]!
          .where((p) => !synced[sessionId]!.contains(p.id) && !(rejected[sessionId]?.contains(p.id) ?? false))
          .toList();

  @override
  Future<void> markSynced(String sessionId, Iterable<String> pingIds) async => synced[sessionId]!.addAll(pingIds);

  @override
  Future<void> deleteSession(String sessionId) async {
    calls.add('delete');
    sessionsById.remove(sessionId);
    pingsBySession.remove(sessionId);
    synced.remove(sessionId);
    rejected.remove(sessionId);
    resend.remove(sessionId);
    ctx.forget(sessionId);
  }

  @override
  Future<File> exportSession(String sessionId, AppInfo app, Directory outDir) async {
    exportCount++;
    return File('${outDir.path}/drive-$sessionId.json');
  }

  /// Adds a finished session directly (for list tests).
  void seed(DriveSession s, List<DrivePing> pings, {int syncedFirst = 0, int rejectedLast = 0}) {
    sessionsById[s.id] = s;
    pingsBySession[s.id] = List.of(pings);
    synced[s.id] = pings.take(syncedFirst).map((p) => p.id).toSet();
    rejected[s.id] = pings.skip(pings.length - rejectedLast).map((p) => p.id).toSet();
  }
}

class FakeCmatClient implements CmatClient {
  @override
  final Uri baseUrl;
  FakeCmatClient(this.baseUrl);

  KeyRequestResult requestResult =
      const KeyRequestResult(driverId: 'd1', key: 'secretkey-abcdef-1234', status: DriverKeyStatus.pending, display: 'KD8XYZ');
  Object? requestError;
  ({DriverKeyStatus status, String display}) statusResult = (status: DriverKeyStatus.approved, display: 'KD8XYZ');
  List<RepeaterRef> repeaterList = const [];
  int requestCalls = 0;
  int statusCalls = 0;
  Object? statusError;
  Completer<void>? statusGate;
  String? lastStatusKey;
  Map<String, String?>? lastRequest;

  @override
  Future<KeyRequestResult> requestKey({required String name, String? callsign, String? email}) async {
    requestCalls++;
    lastRequest = {'name': name, 'callsign': callsign, 'email': email};
    if (requestError != null) throw requestError!;
    return requestResult;
  }

  @override
  Future<({DriverKeyStatus status, String display})> status(String driverKey) async {
    statusCalls++;
    if (statusGate != null) await statusGate!.future;
    if (statusError != null) throw statusError!;
    lastStatusKey = driverKey;
    return statusResult;
  }

  /// Every drive-upload body this client was asked to send, in order.
  final List<DriveBatch> uploads = [];

  @override
  Future<UploadResult> upload(String driverKey, DriveBatch batch) async {
    uploads.add(batch);
    return UploadResult(stored: batch.pings.length, duplicate: 0, rejected: 0);
  }

  @override
  Future<List<RepeaterRef>> repeaters(String driverKey) async => repeaterList;

  /// What [siteConfig] answers. Null (the default) behaves like a server with no site-config endpoint — it throws,
  /// same as a real 404 would — so every test that doesn't care about regions/presets sees `AppState.siteConfig`
  /// stay null, exactly like before this feature existed.
  SiteConfig? siteConfigResult;
  Object? siteConfigError;
  int siteConfigCalls = 0;

  @override
  Future<SiteConfig> siteConfig() async {
    siteConfigCalls++;
    if (siteConfigError != null) throw siteConfigError!;
    final c = siteConfigResult;
    if (c == null) throw const CmatException('no site-config endpoint', status: 404);
    return c;
  }

  /// What [publicCoverage] answers. Null (the default) behaves like a server with no public-coverage endpoint —
  /// it throws, same as a real 404 would — so every test that doesn't care about the network-coverage layer sees
  /// `AppState.networkCoverage` stay null, exactly like before this feature existed.
  PublicCoverage? publicCoverageResult;
  Object? publicCoverageError;
  int publicCoverageCalls = 0;
  int? lastCoverageRes;
  String? lastCoverageSource;
  DateTime? lastCoverageSince;
  DateTime? lastCoverageUntil;

  @override
  Future<PublicCoverage> publicCoverage({int? res, DateTime? since, DateTime? until, String? source}) async {
    publicCoverageCalls++;
    lastCoverageUntil = until;
    lastCoverageRes = res;
    lastCoverageSource = source;
    lastCoverageSince = since;
    if (publicCoverageError != null) throw publicCoverageError!;
    final c = publicCoverageResult;
    if (c == null) throw const CmatException('no public-coverage endpoint', status: 404);
    return c;
  }

  /// What [regionsIndex] answers. Empty (the default) is a legitimate wire answer too ("no regions configured"),
  /// not a stand-in for "no endpoint" — tests that want a fetch failure set [regionsIndexError] instead.
  List<RegionIndexEntry> regionsIndexResult = const [];
  Object? regionsIndexError;
  int regionsIndexCalls = 0;

  /// What `regionsIndex(slugs: ...)` answers (full-detail outlines) and the slug lists it was asked for.
  List<RegionIndexEntry> regionsIndexDetailResult = const [];
  final List<List<String>> regionsIndexDetailAsks = [];

  @override
  Future<List<RegionIndexEntry>> regionsIndex({List<String>? slugs}) async {
    if (slugs != null) {
      regionsIndexDetailAsks.add(slugs);
      return [for (final r in regionsIndexDetailResult) if (slugs.contains(r.slug)) r];
    }
    regionsIndexCalls++;
    if (regionsIndexError != null) throw regionsIndexError!;
    return regionsIndexResult;
  }

  /// `DELETE drive-context` (stream 7 WP5): the categories asked for, what the server answers, or the error thrown.
  final List<String> erasedCategories = [];
  ContextEraseResult eraseCounts = const ContextEraseResult(category: 'all', sessions: 3, pings: 120, samples: 340);
  Object? eraseError;
  Completer<void>? eraseGate;

  @override
  Future<ContextEraseResult> deleteDriveContext(String driverKey, String category) async {
    erasedCategories.add(category);
    if (eraseGate != null) await eraseGate!.future;
    if (eraseError != null) throw eraseError!;
    return ContextEraseResult(category: category, sessions: eraseCounts.sessions, pings: eraseCounts.pings, samples: eraseCounts.samples);
  }

  /// `POST drive-context`: nothing is stored, the batches are kept for assertions.
  final List<DriveContextBatch> lateBatches = [];

  @override
  Future<ContextUploadResult> uploadDriveContext(String driverKey, DriveContextBatch batch) async {
    lateBatches.add(batch);
    return ContextUploadResult(pingsUpdated: batch.pings.length);
  }

  /// Members added to [CmatClient] later (0.4.0's `reportProblem`) don't break every UI test: a fake that needs one
  /// overrides it (see `ReportingCmatClient` in fakes_m1.dart); calling one that isn't faked fails loudly.
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSyncService implements SyncService {
  final FakeDriveStore store;
  FakeSyncService(this.store);
  final List<String> syncedSessions = [];
  int syncAllCalls = 0;

  /// Set to make the next syncs fail like a network error (pings must stay).
  String? failWith;
  Object? throwError;

  /// With [failWith]: the wait the server asked for (HTTP 429 / 503).
  int? failRetryAfterSec;

  @override
  Future<SyncReport> syncSession(String sessionId) async {
    syncedSessions.add(sessionId);
    if (throwError != null) throw throwError!;
    if (failWith != null) return SyncReport(sessions: 1, error: failWith, retryAfterSec: failRetryAfterSec);
    final un = await store.unsyncedPings(sessionId);
    await store.markSynced(sessionId, un.map((p) => p.id));
    store.resend.remove(sessionId);
    return SyncReport(sessions: 1, stored: un.length);
  }

  @override
  Future<SyncReport> syncAll() async {
    syncAllCalls++;
    var stored = 0;
    for (final id in store.sessionsById.keys.toList()) {
      final r = await syncSession(id);
      if (r.error != null) return r;
      stored += r.stored;
    }
    return SyncReport(sessions: store.sessionsById.length, stored: stored);
  }
}

/// Settings JSON (0.4.0 `antenna_profiles`) giving [Harness.selfInfo]'s radio a saved antenna, so tests that connect
/// and start a drive aren't stopped by the once-per-radio antenna setup (spec m1-app-0.4.0 §4).
const testAntennaProfiles = {
  'abcdef0123': {'mount': 'insideCar', 'gain_dbi': null, 'height_m': 1.2, 'updated_at': '2026-10-16T17:00:00.000Z'},
};

class FakeSettingsStore implements SettingsStore {
  Settings saved;
  int saveCount = 0;

  /// When the saved settings have no antenna profiles, [load] adds [testAntennaProfiles] (via JSON, so this compiles
  /// before and after 0.4.0). Off for tests about the antenna setup itself.
  final bool seedAntennaProfile;
  FakeSettingsStore([this.saved = const Settings(), this.seedAntennaProfile = false]);

  /// The app creates a driver key by itself on a phone with none. Off here so a test about a no-key phone stays one;
  /// tests about the automatic key set it (or keep `autoKey` in the saved settings and set this true).
  bool autoKeyOn = false;
  @override
  Future<Settings> load() async {
    final base = autoKeyOn ? saved : saved.copyWith(autoKey: false);
    if (!seedAntennaProfile) return base;
    final j = base.toJson();
    final existing = j['antenna_profiles'];
    if (existing is Map && existing.isNotEmpty) return base;
    return Settings.fromJson({...j, 'antenna_profiles': testAntennaProfiles});
  }
  /// When set, [save] throws it (and keeps [saved] as it was).
  Object? failSave;
  @override
  Future<void> save(Settings settings) async {
    saveCount++;
    if (failSave != null) throw failSave!;
    saved = settings;
  }
}

class FakeTransport implements ByteTransport {
  bool _connected = true;
  @override
  Stream<Uint8List> get incoming => const Stream.empty();
  @override
  Future<void> send(Uint8List frame) async {}
  @override
  Future<void> disconnect() async => _connected = false;
  @override
  bool get isConnected => _connected;
}

class FakeScanner implements RadioScanner {
  final List<RadioDevice> devices;
  Object? scanError;
  Object? connectError;
  int connects = 0;
  FakeScanner(this.devices);
  @override
  Stream<List<RadioDevice>> scan({Duration timeout = const Duration(seconds: 8)}) {
    if (scanError != null) return Stream.error(scanError!);
    return Stream.value(devices);
  }

  @override
  Future<ByteTransport> connect(RadioDevice device) async {
    connects++;
    if (connectError != null) throw connectError!;
    return FakeTransport();
  }
}

class FakeLink implements CompanionLink {
  bool _open = true;
  final SelfInfo info;
  FakeLink(this.info);
  @override
  Future<SelfInfo> start() async => info;
  @override
  Future<int> ensureChannel(String name) async => 1;
  @override
  Future<void> sendChannelText(int channelIndex, String text) async {}
  @override
  Stream<RxPacket> get rxPackets => const Stream.empty();
  @override
  Future<double?> noiseFloor() async => null;
  @override
  Future<void> close() async => _open = false;
  @override
  bool get isConnected => _open;

  /// The radio went away (Bluetooth off, out of range): [isConnected] turns false without [close].
  void drop() => _open = false;
}

class FakeLocation implements LocationSource {
  bool permission;

  /// What [current] answers. Default: a fix in Columbus (what every older test expects).
  GeoFix? Function() currentFix;

  /// [current] throws this instead (null = no error).
  Object? currentError;

  /// [current] waits this long first (a slow, indoor fix).
  Duration currentDelay;

  /// [current] waits for this to complete first, when set (tests decide exactly when the fix "arrives").
  Completer<void>? currentGate;
  int currentCalls = 0;
  FakeLocation({this.permission = true, GeoFix? Function()? currentFix, this.currentError, this.currentDelay = Duration.zero})
      : currentFix = currentFix ?? (() => GeoFix(lat: 40.126, lon: -82.93, at: DateTime.utc(2026, 10, 16)));
  /// Push live GPS fixes here (the stream the engine, the live map and the puck all listen to).
  final fixController = StreamController<GeoFix>.broadcast();
  @override
  Stream<GeoFix> get fixes => fixController.stream;
  @override
  Future<GeoFix?> current() async {
    currentCalls++;
    if (currentDelay > Duration.zero) await Future<void>.delayed(currentDelay);
    if (currentGate != null) await currentGate!.future;
    if (currentError != null) throw currentError!;
    return currentFix();
  }

  @override
  Future<bool> ensurePermission() async => permission;
}

/// Location permission as the test sets it; [request] moves to [afterRequest].
class FakeLocationAccess implements LocationAccessProbe {
  LocationAccess access;
  LocationAccess afterRequest;
  int checks = 0, requests = 0, appSettingsOpened = 0, locationSettingsOpened = 0;
  FakeLocationAccess([this.access = LocationAccess.granted, LocationAccess? afterRequest])
      : afterRequest = afterRequest ?? LocationAccess.granted;
  @override
  Future<LocationAccess> check() async {
    checks++;
    return access;
  }

  @override
  Future<LocationAccess> request() async {
    requests++;
    return access = afterRequest;
  }

  @override
  Future<bool> openAppSettings() async {
    appSettingsOpened++;
    return true;
  }

  @override
  Future<bool> openLocationSettings() async {
    locationSettingsOpened++;
    return true;
  }
}

/// Engine driven by the test: call [emit] to finish a ping.
class FakeEngine implements WardriveEngine {
  final _pings = StreamController<DrivePing>.broadcast();
  final _status = StreamController<EngineStatus>.broadcast();
  EngineStatus _current = const EngineStatus(EngineState.idle);
  WardriveConfig? config;
  bool stopped = false;
  int _n = 0;
  final List<DrivePing> Function(int n)? script;
  FakeEngine({this.script});

  /// Makes [start] fail (e.g. the channel can't be joined), after emitting [pingsBeforeStartError].
  Object? startError;
  List<DrivePing> pingsBeforeStartError = const [];

  @override
  Stream<DrivePing> get pings => _pings.stream;
  @override
  Stream<EngineStatus> get status => _status.stream;
  @override
  EngineStatus get current => _current;

  void setStatus(EngineStatus s) {
    _current = s;
    _status.add(s);
  }

  @override
  Future<void> start(WardriveConfig config) async {
    this.config = config;
    if (startError != null) {
      for (final p in pingsBeforeStartError) {
        _pings.add(p);
      }
      await Future<void>.delayed(Duration.zero);
      throw startError!;
    }
    setStatus(const EngineStatus(EngineState.driving, message: 'Driving. Listening on #wardriving.'));
  }

  /// Every config pushed mid-drive (settings changed while driving).
  final List<WardriveConfig> updates = [];
  @override
  void updateConfig(WardriveConfig config) {
    updates.add(config);
    this.config = config;
  }

  void emit(DrivePing p) => _pings.add(p);

  @override
  Future<DrivePing> pingNow() async {
    _n++;
    final p = heardPing('now-$_n', [const Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]);
    _pings.add(p); // the real engine also emits on the stream; AppState must de-duplicate
    return p;
  }

  /// Links the app handed back after a radio drop; [resumeError] makes the next resume fail.
  final List<CompanionLink> resumedOn = [];
  Object? resumeError;
  @override
  Future<void> resumeOnLink(CompanionLink link) async {
    if (resumeError != null) throw resumeError!;
    resumedOn.add(link);
    setStatus(const EngineStatus(EngineState.driving, message: 'Driving. Listening on #wardriving.'));
  }

  @override
  Future<void> stop() async {
    stopped = true;
    setStatus(const EngineStatus(EngineState.idle));
  }
}

DrivePing heardPing(String id, List<Echo> echoes, {DateTime? ts}) => DrivePing(
      id: id,
      ts: ts ?? DateTime.utc(2026, 10, 16, 18, 0, 0),
      lat: 40.126,
      lon: -82.93,
      echoes: echoes,
    );

DrivePing silentPing(String id) => heardPing(id, const []);

class Harness {
  /// The default radio already has an antenna profile (see [testAntennaProfiles]); false = a radio never set up.
  final bool antennaProfile;
  Harness({this.antennaProfile = true});

  final store = FakeDriveStore();
  late final FakeSyncService sync = FakeSyncService(store);
  late final settings = FakeSettingsStore(const Settings(), antennaProfile);
  final bt = FakeScanner(const [
    RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck', rssi: -62),
    RadioDevice(id: 'cc:dd', name: 'MeshCore-Far', rssi: -91),
  ]);
  final sim = FakeScanner(const [RadioDevice(id: 'sim', name: 'MeshSonar Simulator')]);
  final location = FakeLocation();
  final simLocation = FakeLocation();
  final cache = MemoryRepeaterCache();
  final regionIndexCache = MemoryRegionIndexCache();

  /// The hub catalogue read (`/v1/regions`); null = not fetched, as before.
  Future<HubRegions> Function(String serverUrl)? regionCatalogFetch;
  final List<FakeCmatClient> clients = [];
  final List<FakeEngine> engines = [];

  /// Every link the app opened, oldest first.
  final List<FakeLink> links = [];

  /// Builds the link instead of a plain [FakeLink] (claim tests use one that can log in and sign).
  FakeLink Function(SelfInfo info)? linkMaker;
  final List<File> shared = [];
  LocationSource? engineLocation;
  int _id = 0;

  /// Optional services (null = off, as before). Set them before [services] is first read.
  LocationAccessProbe? locationAccess;
  RepeaterSync? repeaterSync;
  LastKnownStore? lastKnownStore;
  BarometerSource? barometer;
  PhoneBatterySource? phoneBattery;
  DeviceDetailsSource? deviceDetails;
  File? uiPrefsFile;
  DateTime clockNow = DateTime.utc(2026, 10, 16, 18, 0, 0);

  /// The next engine's start fails with this (and first emits [engineStartPings]).
  Object? engineStartError;
  List<DrivePing> engineStartPings = const [];

  /// URLs the app asked the browser to open.
  final List<Uri> openedUrls = [];
  bool browserWorks = true;

  SelfInfo selfInfo = const SelfInfo(
    publicKey: 'ABCDEF0123',
    name: 'Truck Radio',
    radio: Radio(freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5, txDbm: 22),
    firmware: 'v1.9.0',
  );

  FakeCmatClient get client => state.client as FakeCmatClient;

  /// The client the app gets for a server URL (subclasses return richer fakes). Keeps repeaters/status across rebuilds.
  FakeCmatClient newClient(Uri u) => FakeCmatClient(u);

  FakeCmatClient makeClient(Uri u) {
    final c = newClient(u);
    if (clients.isNotEmpty) {
      c.repeaterList = clients.last.repeaterList;
      c.statusResult = clients.last.statusResult;
    }
    clients.add(c);
    return c;
  }

  WardriveEngine makeEngine(CompanionLink link, LocationSource loc) {
    engineLocation = loc;
    final e = FakeEngine()
      ..startError = engineStartError
      ..pingsBeforeStartError = engineStartPings;
    engines.add(e);
    return e;
  }

  Future<bool> recordOpenUrl(Uri u) async {
    openedUrls.add(u);
    return browserWorks;
  }

  String nextId() => 'id-${++_id}';

  late final AppServices services = buildServices();

  /// The app's services built from these fakes (subclasses add more, e.g. M1Harness in fakes_m1.dart).
  AppServices buildServices() => AppServices(
    store: store,
    settingsStore: settings,
    cmatClientFactory: makeClient,
    syncServiceFactory: (_) => sync,
    bluetoothScanner: bt,
    simulatorScanner: sim,
    linkFactory: (_) {
      final l = linkMaker?.call(selfInfo) ?? FakeLink(selfInfo);
      links.add(l);
      return l;
    },
    location: location,
    simulatedLocation: simLocation,
    engineFactory: makeEngine,
    openUrl: recordOpenUrl,
    repeaterCache: cache,
    exportDir: () async => Directory.systemTemp,
    shareFile: (f) async => shared.add(f),
    clock: () => clockNow,
    newId: nextId,
    regionIndexCache: regionIndexCache,
    regionCatalogFetch: regionCatalogFetch,
    locationAccess: locationAccess,
    repeaterSync: repeaterSync,
    lastKnownStore: lastKnownStore,
    barometer: barometer,
    phoneBattery: phoneBattery,
    deviceDetails: deviceDetails,
    uiPrefsFile: uiPrefsFile,
  );

  late final AppState state = AppState(services)..retryPendingAtLaunch = false;

  Future<void> pumpApp(WidgetTester tester) async {
    await state.init();
    await tester.pumpWidget(MeshSonarApp(state: state));
    await tester.pump();
  }

  void approveKey() {
    settings.saved = const Settings(driverKey: 'secretkey-abcdef-1234', keyStatus: DriverKeyStatus.approved, display: 'KD8XYZ');
  }
}

/// Bigger surface so whole screens fit (in-car tablets/phones in landscape too).
void useTallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.5;
  addTearDown(tester.view.reset);
}

/// Network seam for the offline-pack download policy: set [kind] and call [emit] to simulate a change.
class FakeNetworkMonitor implements NetworkMonitor {
  NetworkKind kind;
  FakeNetworkMonitor([this.kind = NetworkKind.wifi]);
  final _c = StreamController<NetworkKind>.broadcast();
  @override
  Future<NetworkKind> current() async => kind;
  @override
  Stream<NetworkKind> get changes => _c.stream;
  void emit(NetworkKind k) {
    kind = k;
    _c.add(k);
  }
}

/// In-memory drive context (same contract as JsonlDriveStore's ctx.jsonl / samples.jsonl / context.json).
class FakeContextLedger implements DriveContextLedger, ContextSyncLedger {
  final Map<String, List<DriveSample>> samplesBySession = {};
  final Map<String, Map<String, PingContext>> ctxBySession = {};
  final Map<String, SessionContext> sessionBySession = {};

  // What the server already has (ContextSyncLedger).
  final Map<String, Set<String>> ctxSent = {};
  final Map<String, Set<String>> samplesSent = {};
  final Map<String, String> sessionMark = {};

  @override
  Future<Set<String>> ctxSentPingIds(String sessionId) async => {...?ctxSent[sessionId]};
  @override
  Future<void> markCtxSent(String sessionId, Iterable<String> pingIds) async => (ctxSent[sessionId] ??= {}).addAll(pingIds);
  @override
  Future<Set<String>> samplesSentKeys(String sessionId) async => {...?samplesSent[sessionId]};
  @override
  Future<void> markSamplesSent(String sessionId, Iterable<String> keys) async => (samplesSent[sessionId] ??= {}).addAll(keys);
  @override
  Future<String?> sessionContextMark(String sessionId) async => sessionMark[sessionId];
  @override
  Future<void> markSessionContext(String sessionId, String mark) async => sessionMark[sessionId] = mark;

  @override
  Future<ContextStripResult> stripUnsentCategories(String sessionId, Set<String> categoryIds) async {
    var pings = 0, samples = 0;
    final c = ctxBySession[sessionId];
    if (c != null) {
      for (final id in c.keys.toList()) {
        if (ctxSent[sessionId]?.contains(id) ?? false) continue;
        final before = c[id]!;
        final after = before.without(categoryIds);
        if (after.toJson().length == before.toJson().length) continue;
        pings++;
        after.isEmpty ? c.remove(id) : c[id] = after;
      }
    }
    final s = samplesBySession[sessionId];
    if (s != null) {
      final next = <DriveSample>[];
      for (final x in s) {
        if (samplesSent[sessionId]?.contains(sampleKey(x)) ?? false) {
          next.add(x);
          continue;
        }
        final y = x.without(categoryIds);
        if (y.toJson().length != x.toJson().length) samples++;
        if (!y.isEmpty) next.add(y);
      }
      samplesBySession[sessionId] = next;
    }
    return ContextStripResult(pingContexts: pings, samples: samples);
  }

  @override
  Future<void> appendSamples(String sessionId, Iterable<DriveSample> samples) async {
    final keep = [for (final s in samples) if (!s.isEmpty) s];
    if (keep.isEmpty) return;
    (samplesBySession[sessionId] ??= []).addAll(keep);
  }

  @override
  Future<void> appendPingContext(String sessionId, String pingId, PingContext ctx) async {
    if (ctx.isEmpty) return;
    (ctxBySession[sessionId] ??= {})[pingId] = ctx;
  }

  @override
  Future<void> writeSessionContext(String sessionId, SessionContext ctx) async {
    if (ctx.isEmpty) {
      sessionBySession.remove(sessionId);
    } else {
      sessionBySession[sessionId] = ctx;
    }
  }

  @override
  Future<List<DriveSample>> samples(String sessionId) async => List.of(samplesBySession[sessionId] ?? const []);

  @override
  Future<Map<String, PingContext>> pingContexts(String sessionId) async => Map.of(ctxBySession[sessionId] ?? const {});

  @override
  Future<SessionContext?> sessionContext(String sessionId) async => sessionBySession[sessionId];

  @override
  Future<ContextStripResult> stripCategories(String sessionId, Set<String> categoryIds) async {
    var pings = 0, samples = 0;
    var session = false;
    final c = ctxBySession[sessionId];
    if (c != null) {
      for (final id in c.keys.toList()) {
        final before = c[id]!;
        final after = before.without(categoryIds);
        if (after.toJson().length == before.toJson().length) continue;
        pings++;
        if (after.isEmpty) {
          c.remove(id);
        } else {
          c[id] = after;
        }
      }
    }
    final s = samplesBySession[sessionId];
    if (s != null) {
      final next = <DriveSample>[];
      for (final x in s) {
        final y = x.without(categoryIds);
        if (y.toJson().length != x.toJson().length) samples++;
        if (!y.isEmpty) next.add(y);
      }
      samplesBySession[sessionId] = next;
    }
    final ses = sessionBySession[sessionId];
    if (ses != null) {
      final after = ses.without(categoryIds);
      if (after.toJson().length != ses.toJson().length) {
        session = true;
        if (after.isEmpty) {
          sessionBySession.remove(sessionId);
        } else {
          sessionBySession[sessionId] = after;
        }
      }
    }
    return ContextStripResult(pingContexts: pings, samples: samples, session: session);
  }

  /// Forgets a session's context (the drive was deleted).
  void forget(String sessionId) {
    samplesBySession.remove(sessionId);
    ctxBySession.remove(sessionId);
    sessionBySession.remove(sessionId);
  }
}

/// Phone barometer fake: a controllable stream; [fail] makes listening fail like a phone without a barometer.
class FakeBarometer implements BarometerSource {
  StreamController<double>? ctl;
  bool fail;
  int listens = 0;
  FakeBarometer({this.fail = false});
  bool get listening => ctl != null && ctl!.hasListener;

  @override
  Stream<double> readings() {
    listens++;
    if (fail) return Stream<double>.error(StateError('UNAVAILABLE: Barometer is not available on this device'));
    final c = StreamController<double>();
    ctl = c;
    c.onCancel = () => ctl = null;
    return c.stream;
  }

  void emit(double hpa) => ctl?.add(hpa);
}

class FakeBattery implements PhoneBatterySource {
  PhoneBatteryReading? reading;
  final StreamController<PhoneBatteryState> states = StreamController<PhoneBatteryState>.broadcast();
  int reads = 0;
  FakeBattery([this.reading = const PhoneBatteryReading(levelPct: 64, state: PhoneBatteryState.unplugged, lowPower: false)]);
  @override
  Future<PhoneBatteryReading?> read() async {
    reads++;
    return reading;
  }

  @override
  Stream<PhoneBatteryState> get stateChanges => states.stream;
}

class FakeDeviceDetails implements DeviceDetailsSource {
  DeviceDetails? details = DeviceDetails(os: 'ios', osVersion: '18.6', model: 'iPhone15,2', appBuild: '23');
  int reads = 0;
  @override
  Future<DeviceDetails?> read() async {
    reads++;
    return details;
  }
}

// ---- shell navigation (five tabs: Chat, Map, Analyze, Plan, More). Old tab names map to where the screen lives now.

/// Taps a bottom-bar / rail destination by its label.
Future<void> tapShellTab(WidgetTester tester, String label) async {
  // A sheet the app opened by itself (antenna setup after a connect) covers the tab bar: dismiss it first.
  for (var i = 0; i < 3 && find.byType(BottomSheet).evaluate().isNotEmpty; i++) {
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
  }
  final bar = find.byKey(const Key('shell-tabs')).evaluate().isNotEmpty
      ? find.byKey(const Key('shell-tabs'))
      : find.byKey(const Key('shell-rail'));
  await tester.tap(find.descendant(of: bar, matching: find.text(label)));
  await settleLive(tester);
}

/// pumpAndSettle for a screen that may be on a live drive. The sonar dot (lib/ui/map/live_puck.dart) animates for as
/// long as GPS fixes keep arriving, so the tree is never fully idle; this pumps until quiet or [limit], then carries on.
Future<void> settleLive(WidgetTester tester, {Duration limit = const Duration(seconds: 3)}) async {
  try {
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, limit);
  } on FlutterError {
    // Still animating: expected on a live drive.
  }
}

/// Old "Drive" tab.
Future<void> openDriveTab(WidgetTester tester) => tapShellTab(tester, 'Map');

/// Old "Region" tab: Analyze, Region view.
Future<void> openRegionTab(WidgetTester tester) async {
  await tapShellTab(tester, 'Analyze');
  await tester.tap(find.descendant(of: find.byKey(const Key('analyze-segments')), matching: find.text('Region')));
  await tester.pumpAndSettle();
}

/// Old "Drives" tab: Analyze, Drives view.
Future<void> openDrivesTab(WidgetTester tester) async {
  await tapShellTab(tester, 'Analyze');
  await tester.tap(find.descendant(of: find.byKey(const Key('analyze-segments')), matching: find.text('Drives')));
  await tester.pumpAndSettle();
}

/// Old "Radio" tab: More, Radio.
Future<void> openRadioTab(WidgetTester tester) async {
  await _openMoreRow(tester, 'more-radio');
}

/// Old "Settings" tab: More, Settings.
Future<void> openSettingsTab(WidgetTester tester) async {
  await _openMoreRow(tester, 'more-settings');
}

/// Opens a row of the More list (scrolling to it first: at large text sizes it is below the fold).
Future<void> _openMoreRow(WidgetTester tester, String key) async {
  await tapShellTab(tester, 'More');
  for (var i = 0; i < 3 && find.byType(BottomSheet).evaluate().isNotEmpty; i++) {
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
  }
  final row = find.byKey(Key(key));
  final scrollable = find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(row, 120, scrollable: scrollable);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}
