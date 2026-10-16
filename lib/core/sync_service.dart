// Uploads locally saved drives to CMAT (MeshSonar Drive Format v1).
//
// - Unsynced pings go up in requests of at most 5,000, each carrying the session.
// - Pings are marked synced only after the server answers 200 (stored and duplicate both count as synced).
// - Pings the server rejects stay on the device (and in exports) but are recorded so they aren't re-sent forever.
//   The server lists at most 20 rejections per answer; when it rejected more than it listed, the rest of the chunk is
//   re-sent (already-stored pings come back as duplicates) until every rejected ping is identified.
// - A drive with nothing left to send but an ended_at the server hasn't heard yet gets one upload with no pings, so
//   the server learns the end time.
// - 403 = key not approved: nothing is changed locally. Network errors stop that session and keep everything.
// Pure Dart: no Flutter imports.
import 'dart:async';

import 'api.dart';
import 'cmat_client.dart';
import 'drive_store.dart';
import 'model.dart';

const int maxPingsPerUpload = 5000;

class DefaultSyncService implements SyncService {
  final DriveStore store;
  final CmatClient client;
  final SettingsStore settings;
  final AppInfo app;
  final int chunkSize;

  /// Used when [store] doesn't implement [SyncLedger] (e.g. a fake store in tests); lasts for this object's lifetime.
  final _MemoryLedger _memLedger = _MemoryLedger();
  Future<void> _last = Future<void>.value();

  DefaultSyncService({
    required this.store,
    required this.client,
    required this.settings,
    this.app = const AppInfo(name: 'MeshSonar', version: '0.1.0'),
    this.chunkSize = maxPingsPerUpload,
  }) : assert(chunkSize > 0 && chunkSize <= maxPingsPerUpload);

  SyncLedger get _ledger => store is SyncLedger ? store as SyncLedger : _memLedger;

  /// One sync at a time, so overlapping calls never upload the same pings twice.
  Future<T> _serial<T>(Future<T> Function() op) {
    final r = _last.then((_) => op());
    _last = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  Future<(String?, String?)> _key() async {
    final s = await settings.load();
    final key = s.driverKey;
    if (key == null || key.isEmpty) return (null, 'no driver key; request one in Settings');
    if (s.keyStatus != DriverKeyStatus.approved) return (null, 'key not approved');
    return (key, null);
  }

  @override
  Future<SyncReport> syncSession(String sessionId) => _serial(() async {
        final (key, err) = await _key();
        if (key == null) return SyncReport(error: err);
        final r = await _syncOne(key, sessionId);
        return SyncReport(sessions: r.uploaded ? 1 : 0, stored: r.stored, duplicate: r.duplicate, rejected: r.rejected, error: r.error);
      });

  @override
  Future<SyncReport> syncAll() => _serial(() async {
        final (key, err) = await _key();
        if (key == null) return SyncReport(error: err);
        var sessions = 0, stored = 0, duplicate = 0, rejected = 0;
        String? firstError;
        final list = await store.sessions();
        // Oldest first, so a long backlog drains in drive order.
        for (final s in list.reversed) {
          final r = await _syncOne(key, s.session.id);
          if (r.uploaded) sessions++;
          stored += r.stored;
          duplicate += r.duplicate;
          rejected += r.rejected;
          firstError ??= r.error;
          if (r.fatal) break; // key problem: every other session would fail the same way
        }
        return SyncReport(sessions: sessions, stored: stored, duplicate: duplicate, rejected: rejected, error: firstError);
      });

  Future<_SessionResult> _syncOne(String key, String sessionId) async {
    final r = _SessionResult();
    final session = await store.session(sessionId);
    if (session == null) {
      r.error = 'no such drive: $sessionId';
      return r;
    }
    final ledger = _ledger;
    final rejectedBefore = await ledger.rejectedIds(sessionId);
    final pending = (await store.unsyncedPings(sessionId)).where((p) => !rejectedBefore.contains(p.id)).toList();

    try {
      for (var i = 0; i < pending.length; i += chunkSize) {
        final chunk = pending.sublist(i, i + chunkSize > pending.length ? pending.length : i + chunkSize);
        await _uploadChunk(key, session, chunk, r);
      }
      if (session.endedAt != null) {
        final told = await ledger.endReported(sessionId);
        if (pending.isNotEmpty) {
          // The last chunk carried ended_at.
          await ledger.markEndReported(sessionId, session.endedAt!);
        } else if (told == null || !told.isAtSameMomentAs(session.endedAt!)) {
          await client.upload(key, DriveBatch(app: app, session: session, pings: const []));
          r.uploaded = true;
          await ledger.markEndReported(sessionId, session.endedAt!);
        }
      }
    } on CmatException catch (e) {
      r.error = switch (e.status) {
        403 => 'key not approved',
        401 => 'driver key not recognised by the server',
        _ => e.message,
      };
      r.fatal = e.status == 401 || e.status == 403;
    }
    return r;
  }

  /// Uploads one chunk; marks confirmed pings synced and rejected pings rejected, only after 200 answers.
  Future<void> _uploadChunk(String key, DriveSession session, List<DrivePing> chunk, _SessionResult r) async {
    final ledger = _ledger;
    var toSend = chunk;
    final rejectedIds = <String>{};
    var firstRound = true;
    // Bounded: each extra round identifies at least one more rejected ping (usually 20).
    for (var round = 0; round <= chunk.length; round++) {
      final res = await client.upload(key, DriveBatch(app: app, session: session, pings: toSend));
      r.uploaded = true;
      if (firstRound) {
        r.stored += res.stored;
        r.duplicate += res.duplicate;
        r.rejected += res.rejected;
        firstRound = false;
      } else {
        // Re-sends only reveal pings already counted; count anything newly stored (shouldn't normally happen).
        r.stored += res.stored;
      }
      final named = <String>{};
      if (res is DetailedUploadResult) {
        for (final rej in res.rejections) {
          if (rej.index >= 0 && rej.index < toSend.length) {
            named.add(toSend[rej.index].id);
          } else if (rej.id != null) {
            final hit = toSend.where((p) => p.id.toLowerCase() == rej.id!.toLowerCase());
            if (hit.isNotEmpty) named.add(hit.first.id);
          }
        }
      }
      rejectedIds.addAll(named);
      if (res.rejected <= named.length) {
        // Every rejected ping in this answer is identified; the rest are confirmed.
        final confirmed = toSend.where((p) => !named.contains(p.id)).map((p) => p.id).toList();
        if (rejectedIds.isNotEmpty) await ledger.markRejected(session.id, rejectedIds);
        await store.markSynced(session.id, confirmed);
        return;
      }
      if (named.isEmpty) {
        // The server rejected pings without saying which. Don't mark anything; try again next sync.
        r.error ??= '${res.rejected} pings rejected without details; will retry';
        return;
      }
      toSend = toSend.where((p) => !named.contains(p.id)).toList();
    }
  }
}

class _SessionResult {
  bool uploaded = false;
  int stored = 0;
  int duplicate = 0;
  int rejected = 0;
  String? error;
  bool fatal = false;
}

class _MemoryLedger implements SyncLedger {
  final Map<String, Set<String>> _rejected = {};
  final Map<String, DateTime> _ended = {};
  @override
  Future<void> markRejected(String sessionId, Iterable<String> pingIds) async =>
      (_rejected[sessionId] ??= {}).addAll(pingIds);
  @override
  Future<Set<String>> rejectedIds(String sessionId) async => {...?_rejected[sessionId]};
  @override
  Future<DateTime?> endReported(String sessionId) async => _ended[sessionId];
  @override
  Future<void> markEndReported(String sessionId, DateTime endedAt) async => _ended[sessionId] = endedAt;
}
