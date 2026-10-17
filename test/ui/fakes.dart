// Hand-written fakes for UI tests. No concrete lib/core or lib/radio classes are used.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';

class FakeDriveStore implements DriveStore {
  final Map<String, DriveSession> sessionsById = {};
  final Map<String, List<DrivePing>> pingsBySession = {};
  final Map<String, Set<String>> synced = {};
  final Map<String, Set<String>> rejected = {};

  /// Sessions renamed since their last sync (cleared by [FakeSyncService]).
  final Set<String> resend = {};
  final List<String> calls = [];

  /// Makes [startSession] fail (e.g. a full disk).
  bool failStart = false;
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
    final list = sessionsById.values.toList()..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return [
      for (final s in list)
        SessionSummary(
          session: s,
          pingCount: pingsBySession[s.id]!.length,
          heardCount: pingsBySession[s.id]!.where((p) => !p.heardNothing).length,
          syncedCount: synced[s.id]!.length,
          rejectedCount: (rejected[s.id] ?? const {}).length,
          sessionResendPending: resend.contains(s.id),
        ),
    ];
  }

  @override
  Future<List<DrivePing>> pings(String sessionId) async => List.of(pingsBySession[sessionId] ?? const []);

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
    return statusResult;
  }

  @override
  Future<UploadResult> upload(String driverKey, DriveBatch batch) async =>
      UploadResult(stored: batch.pings.length, duplicate: 0, rejected: 0);

  @override
  Future<List<RepeaterRef>> repeaters(String driverKey) async => repeaterList;
}

class FakeSyncService implements SyncService {
  final FakeDriveStore store;
  FakeSyncService(this.store);
  final List<String> syncedSessions = [];
  int syncAllCalls = 0;

  /// Set to make the next syncs fail like a network error (pings must stay).
  String? failWith;
  Object? throwError;

  @override
  Future<SyncReport> syncSession(String sessionId) async {
    syncedSessions.add(sessionId);
    if (throwError != null) throw throwError!;
    if (failWith != null) return SyncReport(sessions: 1, error: failWith);
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

class FakeSettingsStore implements SettingsStore {
  Settings saved;
  int saveCount = 0;
  FakeSettingsStore([this.saved = const Settings()]);
  @override
  Future<Settings> load() async => saved;
  @override
  Future<void> save(Settings settings) async {
    saveCount++;
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
}

class FakeLocation implements LocationSource {
  bool permission;
  FakeLocation({this.permission = true});
  @override
  Stream<GeoFix> get fixes => const Stream.empty();
  @override
  Future<GeoFix?> current() async => GeoFix(lat: 40.126, lon: -82.93, at: DateTime.utc(2026, 10, 16));
  @override
  Future<bool> ensurePermission() async => permission;
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
  final store = FakeDriveStore();
  late final FakeSyncService sync = FakeSyncService(store);
  final settings = FakeSettingsStore();
  final bt = FakeScanner(const [
    RadioDevice(id: 'aa:bb', name: 'MeshCore-Truck', rssi: -62),
    RadioDevice(id: 'cc:dd', name: 'MeshCore-Far', rssi: -91),
  ]);
  final sim = FakeScanner(const [RadioDevice(id: 'sim', name: 'MeshSonar Simulator')]);
  final location = FakeLocation();
  final simLocation = FakeLocation();
  final cache = MemoryRepeaterCache();
  final List<FakeCmatClient> clients = [];
  final List<FakeEngine> engines = [];
  final List<File> shared = [];
  LocationSource? engineLocation;
  int _id = 0;

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

  late final AppServices services = AppServices(
    store: store,
    settingsStore: settings,
    cmatClientFactory: (u) {
      final c = FakeCmatClient(u);
      if (clients.isNotEmpty) {
        c.repeaterList = clients.last.repeaterList;
        c.statusResult = clients.last.statusResult;
      }
      clients.add(c);
      return c;
    },
    syncServiceFactory: (_) => sync,
    bluetoothScanner: bt,
    simulatorScanner: sim,
    linkFactory: (_) => FakeLink(selfInfo),
    location: location,
    simulatedLocation: simLocation,
    engineFactory: (link, loc) {
      engineLocation = loc;
      final e = FakeEngine()
        ..startError = engineStartError
        ..pingsBeforeStartError = engineStartPings;
      engines.add(e);
      return e;
    },
    openUrl: (u) async {
      openedUrls.add(u);
      return browserWorks;
    },
    repeaterCache: cache,
    exportDir: () async => Directory.systemTemp,
    shareFile: (f) async => shared.add(f),
    clock: () => DateTime.utc(2026, 10, 16, 18, 0, 0),
    newId: () => 'id-${++_id}',
  );

  late final AppState state = AppState(services);

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
