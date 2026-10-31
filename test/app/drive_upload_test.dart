// In-drive uploads and the upload at Stop (AppState). Real async with a shortened timer period.
// ignore_for_file: overridden_fields
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/map_links.dart';
import 'package:meshsonar/core/repeater_reach.dart';
import 'package:meshsonar/core/drive_context_wire.dart';
import 'package:meshsonar/core/driver_summary.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/sync_service.dart';

import '../ui/fakes.dart';

/// Records each call, can be slowed down, and remembers whether the session had ended when it was called.
class RecordingSync extends FakeSyncService {
  RecordingSync(super.store);
  Duration delay = Duration.zero;
  int running = 0;
  int maxRunning = 0;
  final List<DateTime?> endedAtSeen = [];

  @override
  Future<SyncReport> syncSession(String sessionId) async {
    running++;
    maxRunning = running > maxRunning ? running : maxRunning;
    endedAtSeen.add(store.sessionsById[sessionId]?.endedAt);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return await super.syncSession(sessionId);
    } finally {
      running--;
    }
  }
}

class UploadHarness extends Harness {
  @override
  late final RecordingSync sync = RecordingSync(store);
}

const tick = Duration(milliseconds: 50);

Future<void> wait(Duration d) => Future<void>.delayed(d);

/// Waits (up to 3 s, for slow CI) until [cond] holds. Timers never fire early, only late, so positive checks poll.
Future<void> until(bool Function() cond, {String? reason}) async {
  final sw = Stopwatch()..start();
  while (!cond()) {
    if (sw.elapsed > const Duration(seconds: 3)) fail('timed out waiting${reason == null ? '' : ': $reason'}');
    await wait(const Duration(milliseconds: 5));
  }
}

Future<UploadHarness> driving({Settings? settings, bool approved = true}) async {
  final h = UploadHarness();
  // Period = syncEveryMin × [tick]; default to 1 min (one tick) unless the test says otherwise.
  h.settings.saved = (settings ?? const Settings(syncEveryMin: 1)).copyWith(
    driverKey: approved ? 'secretkey-abcdef-1234' : null,
    keyStatus: approved ? DriverKeyStatus.approved : DriverKeyStatus.none,
  );
  h.state.syncPeriodFor = (m) => tick * m;
  await h.state.init();
  expect(await h.state.connectSimulator(), isTrue);
  await h.state.startDrive();
  expect(h.state.driving, isTrue);
  return h;
}

Future<void> emit(Harness h, String id) async {
  h.engines.last.emit(heardPing(id, const [Echo(repeater: 'a1b2', snrDb: 5, hops: 1)]));
  await wait(Duration.zero);
  await wait(Duration.zero);
}

void main() {
  test('uploads the current drive on schedule and updates syncedCount live', () async {
    final h = await driving();
    final sid = h.state.currentSession!.id;
    await emit(h, 'p1');
    await emit(h, 'p2');
    await until(() => h.state.syncedCount == 2);
    expect(h.sync.syncedSessions.first, sid);
    expect(h.state.lastUploadAt, isNotNull);
    expect(h.state.lastUploadError, isNull);
    expect(h.state.uploading, isFalse);
    await emit(h, 'p3');
    await until(() => h.state.syncedCount == 3);
    expect(h.sync.syncedSessions.length, greaterThanOrEqualTo(2));
    expect(h.sync.endedAtSeen.every((e) => e == null), isTrue);
    await h.state.stopDrive();
  });

  test('stops at Stop; the final upload runs after the session has ended_at', () async {
    final h = await driving();
    final sid = h.state.currentSession!.id;
    await emit(h, 'p1');
    await until(() => h.state.syncedCount == 1 && !h.state.uploading);
    await emit(h, 'p2');
    final before = h.sync.syncedSessions.length;
    await h.state.stopDrive();
    expect(h.sync.syncedSessions.length, before + 1);
    expect(h.sync.endedAtSeen.last, isNotNull);
    expect(h.store.synced[sid], {'p1', 'p2'});
    expect(h.state.lastFinishedSessionId, sid);
    await wait(tick * 4);
    expect(h.sync.syncedSessions.length, before + 1, reason: 'no more in-drive uploads after Stop');
  });

  test('respects the toggles and the key', () async {
    for (final s in [
      const Settings(syncDuringDrive: false, syncEveryMin: 1),
      const Settings(autoSync: false, syncEveryMin: 1),
    ]) {
      final h = await driving(settings: s);
      await emit(h, 'p1');
      await wait(tick * 3);
      expect(h.sync.syncedSessions, isEmpty, reason: '$s');
      await h.state.stopDrive();
      expect(h.sync.syncedSessions.length, s.autoSync ? 1 : 0);
    }
    final noKey = await driving(approved: false);
    await emit(noKey, 'p1');
    await wait(tick * 3);
    expect(noKey.sync.syncedSessions, isEmpty);
    await noKey.state.stopDrive();
  });

  test('turning it on mid-drive starts uploads; a longer period restarts the timer', () async {
    final h = await driving(settings: const Settings(syncDuringDrive: false));
    await emit(h, 'p1');
    await wait(tick * 2);
    expect(h.sync.syncedSessions, isEmpty);
    await h.state.updateSettings(h.state.settings.copyWith(syncDuringDrive: true, syncEveryMin: 1));
    await until(() => h.sync.syncedSessions.isNotEmpty && !h.state.uploading);
    await h.state.updateSettings(h.state.settings.copyWith(syncEveryMin: 10)); // 400 ms in this test
    final n = h.sync.syncedSessions.length;
    await wait(tick * 4);
    expect(h.sync.syncedSessions.length, n);
    await h.state.updateSettings(h.state.settings.copyWith(syncDuringDrive: false));
    await wait(tick * 8);
    expect(h.sync.syncedSessions.length, n);
    await h.state.stopDrive();
  });

  test('never overlaps: a slow upload skips ticks until it finishes', () async {
    final h = await driving();
    h.sync.delay = tick * 3;
    await emit(h, 'p1');
    await until(() => h.sync.syncedSessions.length >= 2);
    expect(h.sync.maxRunning, 1);
    await h.state.stopDrive();
    expect(h.sync.maxRunning, 1);
  });

  test('failures are quiet and retried on the next tick', () async {
    final h = await driving();
    await emit(h, 'p1');
    h.state.takeNotice();
    h.sync.failWith = 'SocketException: network is unreachable';
    await until(() => h.state.lastUploadError != null);
    expect(h.state.pendingNotice, isNull, reason: 'in-drive upload failures only show on the status line');
    expect(h.state.syncedCount, 0);
    h.sync.failWith = null;
    await until(() => h.state.syncedCount == 1);
    expect(h.state.lastUploadError, isNull);
    await h.state.stopDrive();
  });

  test('with the real sync service, the final upload carries ended_at', () async {
    final h = RealSyncHarness();
    h.approveKey();
    h.settings.saved = h.settings.saved.copyWith(syncEveryMin: 1);
    h.state.syncPeriodFor = (m) => tick * m;
    await h.state.init();
    await h.state.connectSimulator();
    await h.state.startDrive();
    await emit(h, 'p1');
    await emit(h, 'p2');
    await until(() => h.uploads.isNotEmpty && !h.state.uploading);
    expect(h.uploads.length, 1);
    expect(h.uploads.first.pings.map((p) => p.id), ['p1', 'p2']);
    expect(h.uploads.first.session.endedAt, isNull);
    await emit(h, 'p3');
    await h.state.stopDrive();
    final last = h.uploads.last;
    // p3 goes up in the final upload (or in a tick that landed just before Stop); the final one has ended_at.
    expect(last.session.endedAt, isNotNull);
    expect([for (final b in h.uploads) ...b.pings.map((p) => p.id)], ['p1', 'p2', 'p3']);
    expect(h.state.lastUploadAt, isNotNull);
  });

  test('a drive fully uploaded mid-drive still tells the server its end time at Stop', () async {
    final h = RealSyncHarness();
    h.approveKey();
    h.settings.saved = h.settings.saved.copyWith(syncEveryMin: 1);
    h.state.syncPeriodFor = (m) => tick * m;
    await h.state.init();
    await h.state.connectSimulator();
    await h.state.startDrive();
    await emit(h, 'p1');
    await until(() => h.uploads.isNotEmpty && !h.state.uploading);
    await h.state.stopDrive();
    expect(h.uploads.last.pings, isEmpty);
    expect(h.uploads.last.session.endedAt, isNotNull);
  });
}

class RecordingClient implements CmatClient {
  @override
  Future<RepeaterReach> repeaterReach(String driverKey, String repeaterKey, {double? lat, double? lon}) => throw UnimplementedError();
  @override
  Future<CellLinks> cellLinks(String driverKey, String h3) => throw UnimplementedError();
  @override
  final Uri baseUrl = Uri.parse('https://example.org');
  final List<DriveBatch> uploads;
  RecordingClient(this.uploads);
  @override
  Future<DriverSummary> driverSummary(String driverKey) => throw UnimplementedError();
  @override
  Future<KeyRequestResult> requestKey({required String name, String? callsign, String? email}) => throw UnimplementedError();
  @override
  Future<({DriverKeyStatus status, String display})> status(String driverKey) async =>
      (status: DriverKeyStatus.approved, display: 'KD8XYZ');
  @override
  Future<UploadResult> upload(String driverKey, DriveBatch batch) async {
    uploads.add(batch);
    return UploadResult(stored: batch.pings.length, duplicate: 0, rejected: 0);
  }

  @override
  Future<List<RepeaterRef>> repeaters(String driverKey) async => const [];

  @override
  Future<ProblemReportResult> reportProblem(String driverKey, String body) => throw UnimplementedError();

  @override
  Future<SiteConfig> siteConfig() => throw UnimplementedError();

  @override
  Future<PublicCoverage> publicCoverage({int? res, DateTime? since, DateTime? until, String? source}) => throw UnimplementedError();

  @override
  Future<List<RegionIndexEntry>> regionsIndex({List<String>? slugs}) => throw UnimplementedError();

  @override
  Future<ContextEraseResult> deleteDriveContext(String driverKey, String category) => throw UnimplementedError();

  @override
  Future<DriveEnv> driveEnv(String driverKey, String sessionId) => throw UnimplementedError();

  /// Late drive context (POST drive-context): recorded, like [uploads].
  final List<DriveContextBatch> lateUploads = [];
  @override
  Future<ContextUploadResult> uploadDriveContext(String driverKey, DriveContextBatch batch) async {
    lateUploads.add(batch);
    return ContextUploadResult(pingsUpdated: batch.pings.length);
  }
}

/// Harness whose sync service is the real DefaultSyncService over the fake store.
class RealSyncHarness extends Harness {
  final List<DriveBatch> uploads = [];
  late final RecordingClient rec = RecordingClient(uploads);

  @override
  late final AppServices services = () {
    final b = super.services;
    return AppServices(
      store: b.store,
      settingsStore: b.settingsStore,
      cmatClientFactory: b.cmatClientFactory,
      syncServiceFactory: (_) => DefaultSyncService(store: store, client: rec, settings: settings),
      bluetoothScanner: b.bluetoothScanner,
      simulatorScanner: b.simulatorScanner,
      linkFactory: b.linkFactory,
      location: b.location,
      simulatedLocation: b.simulatedLocation,
      engineFactory: b.engineFactory,
      repeaterCache: b.repeaterCache,
      exportDir: b.exportDir,
      shareFile: b.shareFile,
      newId: b.newId,
      clock: () => DateTime.now().toUtc(),
    );
  }();
}
