// Uploads locally saved drives to CMAT (MeshSonar Drive Format v1, and v1.2 when the server accepts it).
//
// - Unsynced pings go up in requests of at most 5,000, each carrying the session.
// - Pings are marked synced only after the server answers 200 (stored and duplicate both count as synced).
// - Pings the server rejects stay on the device (and in exports) but are recorded so they aren't re-sent forever.
//   The server lists at most 20 rejections per answer; when it rejected more than it listed, the rest of the chunk is
//   re-sent (already-stored pings come back as duplicates) until every rejected ping is identified.
// - A drive with nothing left to send but an ended_at the server hasn't heard yet, or whose details changed (a
//   rename), gets one upload with no pings, so the server learns the end time and the new name.
// - 403 = key not approved: nothing is changed locally. Network errors stop that session and keep everything.
//
// Drive context (stream 7 WP5). Only when the server's site-config lists `meshsonar.drive.v1.2` (the injected
// [capabilities] provider; unknown = plain v1) AND there is something to say, the body is Drive Format v1.2: the
// session's device and radio extras, `session.enrich.weather`, each ping's `ctx` and up to 2,000 `samples` per request
// (lib/core/drive_context_wire.dart). Everything else is byte-identical to before.
//   - What the server already has is tracked beside the drive (ContextSyncLedger): ping ctx rides with its ping and
//     is marked when that ping is confirmed; samples are marked per `src|ts` key; the session part by fingerprint.
//   - Context recorded after its ping was confirmed (a race), or for drives uploaded before v1.2, goes through
//     `POST drive-context` (pings) and a ping-less v1.2 upload (samples, device, radio extras).
//   - Opt-out: a category that is off is never put in a body (and AppState strips its unsent context from disk).
//   - A v1.2 request answered 400 as a whole is repeated once as the plain drive for that session (this run), so the
//     drive is never lost; a ping whose ctx the server refuses is re-sent without it. Refused samples / ctx are
//     counted in the [SyncReport], never hidden.
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';

import 'api.dart';
import 'cmat_client.dart';
import 'data_categories.dart';
import 'drive_context.dart';
import 'drive_context_wire.dart';
import 'drive_store.dart';
import 'model.dart';

const int maxPingsPerUpload = 5000;

class DefaultSyncService implements SyncService {
  final DriveStore store;
  final CmatClient client;
  final SettingsStore settings;
  final AppInfo app;
  final int chunkSize;

  /// The upload server's site-config (its capabilities), asked once per sync. Null, a null answer or a failure =
  /// unknown = the plain v1 body. The app wires its cached upload-server config here.
  Future<SiteConfig?> Function()? capabilities;

  /// Whether a collection category is on. The app adds the disclosure gate (nothing is uploaded that a person has not
  /// been told about); without it the saved settings decide.
  bool Function(String categoryId)? categoryOn;

  /// Used when [store] doesn't implement [SyncLedger] (e.g. a fake store in tests); lasts for this object's lifetime.
  final _MemoryLedger _memLedger = _MemoryLedger();
  Future<void> _last = Future<void>.value();

  /// Sessions whose v1.2 upload was refused as a whole this run; they go up as the plain drive until the app restarts.
  final Set<String> _plainOnly = {};

  DefaultSyncService({
    required this.store,
    required this.client,
    required this.settings,
    this.app = const AppInfo(name: 'MeshSonar'), // the app passes its real version (package_info_plus)
    this.chunkSize = maxPingsPerUpload,
    this.capabilities,
    this.categoryOn,
  }) : assert(chunkSize > 0 && chunkSize <= maxPingsPerUpload);

  SyncLedger get _ledger => store is SyncLedger ? store as SyncLedger : _memLedger;

  /// One sync at a time, so overlapping calls never upload the same pings twice.
  Future<T> _serial<T>(Future<T> Function() op) {
    final r = _last.then((_) => op());
    _last = r.then<void>((_) {}, onError: (_) {});
    return r;
  }

  Future<(String?, String?, _Run?)> _prepare() async {
    final s = await settings.load();
    final key = s.driverKey;
    if (key == null || key.isEmpty) return (null, 'no driver key; request one in Settings', null);
    if (s.keyStatus != DriverKeyStatus.approved) return (null, 'key not approved', null);
    return (key, null, await _run(s));
  }

  Future<_Run> _run(Settings s) async {
    bool on(String id) => categoryOn?.call(id) ?? s.collectionOn(id);
    final st = store;
    final ctx = st is DriveContextLedger ? st as DriveContextLedger : null;
    final sent = st is ContextSyncLedger ? st as ContextSyncLedger : null;
    var accepts = false;
    if (ctx != null && sent != null && capabilities != null) {
      try {
        accepts = (await capabilities!())?.acceptsDriveV12 == true;
      } catch (_) {}
    }
    return _Run(
      v12: accepts,
      ctx: ctx,
      sent: sent,
      off: {for (final c in dataCategories) if (c.id != CategoryId.packetHeaders && !on(c.id)) c.id},
      weatherOn: on(CategoryId.weather),
    );
  }

  @override
  Future<SyncReport> syncSession(String sessionId) => _serial(() async {
        final (key, err, run) = await _prepare();
        if (key == null) return SyncReport(error: err);
        final r = await _syncOne(key, sessionId, run!);
        return _report([r]);
      });

  @override
  Future<SyncReport> syncAll() => _serial(() async {
        final (key, err, run) = await _prepare();
        if (key == null) return SyncReport(error: err);
        final results = <_SessionResult>[];
        final list = await store.sessions();
        // Oldest first, so a long backlog drains in drive order.
        for (final s in list.reversed) {
          final r = await _syncOne(key, s.session.id, run!);
          results.add(r);
          if (r.fatal) break; // key problem: every other session would fail the same way
        }
        return _report(results);
      });

  /// Delivers only drive context (samples, device and radio extras, ping context) of drives that have nothing else
  /// waiting: drives uploaded before the server accepted v1.2, or context recorded after its ping was confirmed. Drives
  /// with pings, a new name or an end time still to send are left to the normal sync, which carries their context.
  Future<SyncReport> syncContextOnly() => _serial(() async {
        final (key, err, run) = await _prepare();
        if (key == null) return SyncReport(error: err);
        if (!run!.v12) return const SyncReport();
        final results = <_SessionResult>[];
        for (final s in (await store.sessions()).reversed) {
          final r = await _syncOne(key, s.session.id, run, contextOnly: true);
          results.add(r);
          if (r.fatal) break;
        }
        return _report(results);
      });

  SyncReport _report(List<_SessionResult> rs) {
    var up = 0, stored = 0, dup = 0, rej = 0, ss = 0, sd = 0, sr = 0, cu = 0, cr = 0, cf = 0;
    String? firstError;
    for (final r in rs) {
      if (r.uploaded) up++;
      stored += r.stored;
      dup += r.duplicate;
      rej += r.rejected;
      ss += r.samplesStored;
      sd += r.samplesDuplicate;
      sr += r.samplesRejected;
      cu += r.ctxUpdated;
      cr += r.ctxRejected;
      if (r.fellBack) cf++;
      firstError ??= r.error;
    }
    return SyncReport(
      sessions: up,
      stored: stored,
      duplicate: dup,
      rejected: rej,
      error: firstError,
      samplesStored: ss,
      samplesDuplicate: sd,
      samplesRejected: sr,
      contextPingsUpdated: cu,
      contextRejected: cr,
      contextFallbacks: cf,
    );
  }

  Future<_SessionResult> _syncOne(String key, String sessionId, _Run run, {bool contextOnly = false}) async {
    final r = _SessionResult();
    final session = await store.session(sessionId);
    if (session == null) {
      r.error = 'no such drive: $sessionId';
      return r;
    }
    // A Simulator drive is made-up data: it must never reach the community map.
    if (session.isSimulated) return r;
    final ledger = _ledger;
    // Read before the uploads, so a rename made while they run stays marked for the next sync.
    final resendToken = await ledger.sessionResendToken(sessionId);
    final rejectedBefore = await ledger.rejectedIds(sessionId);
    final pending = (await store.unsyncedPings(sessionId)).where((p) => !rejectedBefore.contains(p.id)).toList();

    try {
      final told = session.endedAt == null ? null : await ledger.endReported(sessionId);
      final endUntold = session.endedAt != null && (told == null || !told.isAtSameMomentAs(session.endedAt!));
      if (contextOnly && (pending.isNotEmpty || endUntold || resendToken != null)) return r;

      final sc = run.v12 && !_plainOnly.contains(sessionId) ? await _loadContext(run, sessionId) : null;
      for (var i = 0; i < pending.length; i += chunkSize) {
        final chunk = pending.sublist(i, i + chunkSize > pending.length ? pending.length : i + chunkSize);
        await _uploadChunk(key, session, chunk, r, run, sc);
      }
      final forced = pending.isEmpty && (endUntold || resendToken != null);
      // Samples beyond the first request, a changed device / radio part, or the end time / rename: ping-less uploads.
      final sessionUploads = await _uploadSessionOnly(key, session, run, sc, r, force: forced);
      if (forced && !sessionUploads) {
        // Nothing else to carry the session: one upload with no pings tells the server the end time / new details.
        await client.upload(key, DriveBatch(app: app, session: session, pings: const []));
        r.uploaded = true;
      }
      // Every upload above carried this session as read, including its ended_at.
      if (session.endedAt != null && (pending.isNotEmpty || endUntold)) {
        await ledger.markEndReported(sessionId, session.endedAt!);
      }
      if (resendToken != null) await ledger.clearSessionResend(sessionId, resendToken);
      await _uploadLate(key, session, run, sc, r);
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

  // ------------------------------------------------------------------ drive context

  /// What of this session's context the server does not have yet, minus every category that is off.
  Future<_SessionCtx?> _loadContext(_Run run, String sessionId) async {
    final ctx = run.ctx, sent = run.sent;
    if (ctx == null || sent == null) return _SessionCtx();
    try {
      final sc = _SessionCtx();
      final sentPings = await sent.ctxSentPingIds(sessionId);
      for (final e in (await ctx.pingContexts(sessionId)).entries) {
        if (sentPings.contains(e.key)) continue;
        final c = e.value.without(run.off);
        if (wireCtx(c) != null) sc.pingCtx[e.key] = c;
      }
      final sentSamples = await sent.samplesSentKeys(sessionId);
      final all = [
        for (final x in await ctx.samples(sessionId))
          if (!sentSamples.contains(sampleKey(x))) x.without(run.off),
      ]..sort((a, b) {
          final t = a.ts.compareTo(b.ts);
          return t != 0 ? t : a.src.index.compareTo(b.src.index);
        });
      sc.samplesLeft.addAll(all.where((x) => wireSample(x) != null));
      final session = (await ctx.sessionContext(sessionId))?.without(run.off);
      sc.device = session?.device;
      sc.companion = session?.companionExt;
      final mark = _sessionMark(sc.device, sc.companion);
      sc.sessionMark = mark;
      sc.sessionUnsent = mark != null && mark != await sent.sessionContextMark(sessionId);
      return sc;
    } catch (_) {
      return _SessionCtx(); // unreadable context never blocks the drive itself (the weather flag still goes)
    }
  }

  String? _sessionMark(DeviceDetails? d, CompanionDetails? c) {
    final dj = wireDevice(d), cj = wireCompanionExt(c);
    if (dj == null && cj == null) return null;
    return jsonEncode({'device': dj, 'companion': cj});
  }

  /// The context part of one request, or null when the body should be the plain drive (nothing to say).
  ContextUpload? _contextFor(_Run run, _SessionCtx? sc, List<DrivePing> pings, List<DriveSample> samples,
      {Set<String> withoutCtx = const {}}) {
    if (sc == null || sc.disabled) return null;
    final cu = ContextUpload(
      weather: run.weatherOn,
      device: sc.device,
      companion: sc.companion,
      pingContexts: {
        for (final p in pings)
          if (!withoutCtx.contains(p.id) && sc.pingCtx[p.id] != null) p.id: sc.pingCtx[p.id]!,
      },
      samples: samples,
    );
    return (cu.hasContext || run.weatherOn) ? cu : null;
  }

  /// Posts one drive-upload body. A v1.2 body answered 400 as a whole is repeated once as the plain drive for this
  /// session (this run). Returns the answer and whether the context part was really sent.
  Future<(UploadResult, bool)> _post(
      String key, DriveSession session, List<DrivePing> pings, ContextUpload? cu, _SessionResult r, _SessionCtx? sc) async {
    try {
      return (await client.upload(key, DriveBatch(app: app, session: session, pings: pings, context: cu)), cu != null);
    } on CmatException catch (e) {
      if (cu == null || e.status != 400) rethrow;
      _plainOnly.add(session.id);
      sc?.disabled = true;
      r.fellBack = true;
      return (await client.upload(key, DriveBatch(app: app, session: session, pings: pings)), false);
    }
  }

  /// After a 200 that carried [slice]: the samples are the server's (stored, duplicate or refused: refused ones would
  /// be refused again, so they are done too) and the session part is delivered.
  Future<void> _afterContext(String sessionId, _Run run, _SessionCtx sc, UploadResult res, List<DriveSample> slice,
      _SessionResult r, {required bool hadSession}) async {
    if (slice.isNotEmpty) {
      await run.sent!.markSamplesSent(sessionId, slice.map(sampleKey));
      final keys = slice.map(sampleKey).toSet();
      sc.samplesLeft.removeWhere((x) => keys.contains(sampleKey(x)));
      if (res is DetailedUploadResult) {
        r.samplesStored += res.samplesStored;
        r.samplesDuplicate += res.samplesDuplicate;
        r.samplesRejected += res.samplesRejected;
      }
    }
    if (hadSession && sc.sessionMark != null) {
      await run.sent!.markSessionContext(sessionId, sc.sessionMark!);
      sc.sessionUnsent = false;
    }
  }

  /// Uploads one chunk; marks confirmed pings synced and rejected pings rejected, only after 200 answers.
  Future<void> _uploadChunk(
      String key, DriveSession session, List<DrivePing> chunk, _SessionResult r, _Run run, _SessionCtx? sc) async {
    final ledger = _ledger;
    var toSend = chunk;
    final rejectedIds = <String>{};
    final withoutCtx = <String>{}; // pings re-sent without ctx because the server refused it
    var firstRound = true;
    // Bounded: each extra round identifies at least one more rejected ping (usually 20).
    for (var round = 0; round <= chunk.length + 1; round++) {
      final slice = firstRound && sc != null && !sc.disabled ? sc.samplesLeft.take(maxSamplesPerUpload).toList() : <DriveSample>[];
      final cu = _contextFor(run, sc, toSend, slice, withoutCtx: withoutCtx);
      final (res, withContext) = await _post(key, session, toSend, cu, r, sc);
      r.uploaded = true;
      if (withContext && sc != null) {
        await _afterContext(session.id, run, sc, res, slice, r, hadSession: sc.device != null || sc.companion != null);
      }
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
      final ctxRefused = <String>{};
      if (res is DetailedUploadResult) {
        for (final rej in res.rejections) {
          String? id;
          if (rej.index >= 0 && rej.index < toSend.length) {
            id = toSend[rej.index].id;
          } else if (rej.id != null) {
            final hit = toSend.where((p) => p.id.toLowerCase() == rej.id!.toLowerCase());
            if (hit.isNotEmpty) id = hit.first.id;
          }
          if (id == null) continue;
          named.add(id);
          // The drive must never be lost to its context: a ping refused for its ctx is sent again without it.
          if (withContext && sc != null && sc.pingCtx.containsKey(id) && !withoutCtx.contains(id) && rej.reason.toLowerCase().startsWith('ctx')) {
            ctxRefused.add(id);
          }
        }
      }
      final realNamed = named.difference(ctxRefused);
      rejectedIds.addAll(realNamed);
      if (ctxRefused.isNotEmpty) {
        withoutCtx.addAll(ctxRefused);
        r.ctxRejected += ctxRefused.length;
        r.rejected -= ctxRefused.length; // they are stored by the next round, not lost
        await run.sent!.markCtxSent(session.id, ctxRefused); // refused ctx is not retried forever
        for (final id in ctxRefused) {
          sc!.pingCtx.remove(id);
        }
      }
      final unidentified = res.rejected - named.length;
      if (unidentified <= 0) {
        // Every rejected ping in this answer is identified; the rest are confirmed.
        final confirmed = toSend.where((p) => !named.contains(p.id)).toList();
        if (rejectedIds.isNotEmpty) await ledger.markRejected(session.id, rejectedIds);
        await store.markSynced(session.id, confirmed.map((p) => p.id));
        if (withContext && sc != null) {
          final delivered = [for (final p in confirmed) if (sc.pingCtx.containsKey(p.id)) p.id];
          if (delivered.isNotEmpty) {
            await run.sent!.markCtxSent(session.id, delivered);
            delivered.forEach(sc.pingCtx.remove);
          }
        }
        if (ctxRefused.isEmpty) return;
        toSend = toSend.where((p) => ctxRefused.contains(p.id)).toList();
        continue;
      }
      if (named.isEmpty) {
        // The server rejected pings without saying which. Don't mark anything; try again next sync.
        r.error ??= '${res.rejected} pings rejected without details; will retry';
        return;
      }
      toSend = toSend.where((p) => !realNamed.contains(p.id)).toList();
    }
  }

  /// Ping-less uploads for what a ping chunk does not carry: samples left over (more than 2,000), a device / radio part
  /// the server has not confirmed (drives uploaded before v1.2), and, when [force], the end time or a rename. Returns
  /// whether at least one request went out.
  Future<bool> _uploadSessionOnly(String key, DriveSession session, _Run run, _SessionCtx? sc, _SessionResult r,
      {required bool force}) async {
    var any = false;
    while (true) {
      final live = sc != null && !sc.disabled;
      final need = live && (sc.samplesLeft.isNotEmpty || sc.sessionUnsent);
      if (!(need || (force && !any))) return any;
      final slice = live ? sc.samplesLeft.take(maxSamplesPerUpload).toList() : <DriveSample>[];
      final cu = _contextFor(run, sc, const [], slice);
      final (res, withContext) = await _post(key, session, const [], cu, r, sc);
      r.uploaded = true;
      any = true;
      if (withContext && sc != null) {
        await _afterContext(session.id, run, sc, res, slice, r, hadSession: sc.device != null || sc.companion != null);
      } else if (!withContext) {
        return any; // fell back (or nothing contextual to send): the plain drive went up, context waits for next time
      }
      if (slice.isEmpty) return any; // nothing more can progress
    }
  }

  /// Context of pings the server already holds (recorded after the ping was confirmed, or the drive went up before
  /// v1.2): `POST drive-context`, up to 2,000 pings per request. The server merges it into the ping (first write wins),
  /// so a repeat changes nothing; a ping it does not know ("unknown ping") or refuses is done, never retried.
  Future<void> _uploadLate(String key, DriveSession session, _Run run, _SessionCtx? sc, _SessionResult r) async {
    if (sc == null || sc.disabled || sc.pingCtx.isEmpty) return;
    final unsynced = (await store.unsyncedPings(session.id)).map((p) => p.id).toSet();
    final rejected = await _ledger.rejectedIds(session.id);
    final late = [
      for (final p in await store.pings(session.id))
        if (sc.pingCtx.containsKey(p.id) && !unsynced.contains(p.id) && !rejected.contains(p.id)) p.id,
    ];
    for (var i = 0; i < late.length; i += maxSamplesPerUpload) {
      final ids = late.sublist(i, i + maxSamplesPerUpload > late.length ? late.length : i + maxSamplesPerUpload);
      final batch = DriveContextBatch(
          session: session.id, pings: [for (final id in ids) PingContextEntry(id, sc.pingCtx[id]!)]);
      ContextUploadResult res;
      try {
        res = await client.uploadDriveContext(key, batch);
      } on CmatException catch (e) {
        // 404: the server does not hold this drive (yet); 429: slow down. Neither is a failure of the drive: the
        // context stays queued for the next sync.
        if (e.status == 404 || e.status == 429) return;
        rethrow;
      }
      r.ctxUpdated += res.pingsUpdated;
      r.ctxRejected += res.rejected;
      await run.sent!.markCtxSent(session.id, ids);
      ids.forEach(sc.pingCtx.remove);
    }
  }
}

class _Run {
  final bool v12;
  final DriveContextLedger? ctx;
  final ContextSyncLedger? sent;
  final Set<String> off;
  final bool weatherOn;
  const _Run({required this.v12, required this.ctx, required this.sent, required this.off, required this.weatherOn});
}

/// One session's context that the server does not have yet.
class _SessionCtx {
  final Map<String, PingContext> pingCtx = {};
  final List<DriveSample> samplesLeft = [];
  DeviceDetails? device;
  CompanionDetails? companion;
  String? sessionMark;
  bool sessionUnsent = false;

  /// The server refused a v1.2 body for this session this run: nothing contextual is sent any more.
  bool disabled = false;
}

class _SessionResult {
  bool uploaded = false;
  int stored = 0;
  int duplicate = 0;
  int rejected = 0;
  int samplesStored = 0;
  int samplesDuplicate = 0;
  int samplesRejected = 0;
  int ctxUpdated = 0;
  int ctxRejected = 0;
  bool fellBack = false;
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
  @override
  Future<String?> sessionResendToken(String sessionId) async => null; // stores without a ledger can't mark renames
  @override
  Future<void> clearSessionResend(String sessionId, String token) async {}
}
