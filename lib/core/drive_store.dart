// Local, crash-safe drive storage: one directory per session.
//
//   <root>/sessions/<session id>/
//     session.json   the DriveSession; rewritten atomically (temp file + rename) on start and end
//     pings.jsonl    one DrivePing JSON per line; appended and flushed before appendPing completes
//     synced.txt     append-only ping ids the server has confirmed (stored or duplicate)
//     rejected.txt   append-only ping ids the server rejected (kept locally, never re-sent)
//     end_sent.txt   ended_at the server has been told about (so a finished drive is reported once)
//     resend.txt     present when the session's details changed (a rename) since the server last saw them; holds a
//                    token so a rename during an upload isn't cleared by that upload
//     samples.jsonl  drive context (stream 7): one DriveSample per line (radio health, phone readings; no
//                    coordinates); appended and flushed like pings.jsonl
//     ctx.jsonl      drive context per ping: {"ping": <id>, "ctx": {...}} per line, last record per ping wins
//     context.json   drive context per session (phone/app details, radio identity); rewritten atomically
//   None of the context files is read by the upload or the export: their bytes are exactly what they were before.
//
// A crash mid-write can leave a truncated last line in pings.jsonl; readers skip it, and the next append trims it
// first so a new ping is never glued onto the broken one.
//
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'api.dart';
import 'drive_context.dart';
import 'model.dart';
import 'storage_usage.dart';

/// Extra bookkeeping the sync service needs beyond [DriveStore]. [JsonlDriveStore] implements it; the sync service
/// falls back to in-memory tracking for stores that don't.
abstract class SyncLedger {
  /// Records pings the server rejected. They stay in the store and exports, but [DriveStore.unsyncedPings] excludes them.
  Future<void> markRejected(String sessionId, Iterable<String> pingIds);
  Future<Set<String>> rejectedIds(String sessionId);

  /// The ended_at the server last confirmed for this session, or null.
  Future<DateTime?> endReported(String sessionId);
  Future<void> markEndReported(String sessionId, DateTime endedAt);

  /// Non-null when the session itself (e.g. its label) must be sent again; the value identifies that change.
  Future<String?> sessionResendToken(String sessionId);

  /// Clears the re-send mark, but only if it is still [token] (a newer change keeps it set).
  Future<void> clearSessionResend(String sessionId, String token);
}

/// Closes drives left open by a crash or an app kill (ended_at null), using the last ping's time, or the start time
/// for a drive with no pings. [except] are sessions still recording. Returns the ids closed. Never throws for one bad
/// drive; it's skipped and tried again next launch.
Future<List<String>> closeOrphanedSessions(DriveStore store, {Set<String> except = const {}}) async {
  final closed = <String>[];
  for (final x in await store.sessions()) {
    final s = x.session;
    if (s.endedAt != null || except.contains(s.id)) continue;
    try {
      var end = s.startedAt;
      for (final p in await store.pings(s.id)) {
        if (p.ts.isAfter(end)) end = p.ts;
      }
      await store.endSession(s.id, end.toUtc());
      closed.add(s.id);
    } catch (_) {}
  }
  return closed;
}

class JsonlDriveStore implements DriveStore, SyncLedger, StorageSized, DriveContextLedger {
  final Directory root;
  final Directory _sessionsDir;
  final Map<String, Future<void>> _locks = {};
  final Set<String> _repaired = {};
  final Set<String> _repairedFiles = {}; // '<session>/<file>' of context files already tail-repaired this run

  JsonlDriveStore._(this.root) : _sessionsDir = Directory(p.join(root.path, 'sessions'));

  static Future<JsonlDriveStore> open(Directory root) async {
    final s = JsonlDriveStore._(root);
    await s._sessionsDir.create(recursive: true);
    return s;
  }

  static final _safeId = RegExp(r'^[A-Za-z0-9_-]{1,100}$');

  /// Bytes every drive on this phone uses (Settings > Data & storage).
  @override
  Future<int> bytesUsed() => bytesOnDisk(_sessionsDir);

  Directory _dir(String sessionId) {
    if (!_safeId.hasMatch(sessionId)) throw ArgumentError.value(sessionId, 'sessionId', 'not a valid session id');
    return Directory(p.join(_sessionsDir.path, sessionId));
  }

  File _file(String sessionId, String name) => File(p.join(_dir(sessionId).path, name));

  /// Runs [op] after every earlier operation on the same session has finished, so writes never interleave.
  Future<T> _locked<T>(String sessionId, Future<T> Function() op) {
    final prev = _locks[sessionId] ?? Future<void>.value();
    final result = prev.then((_) => op());
    final done = result.then<void>((_) {}, onError: (_) {});
    _locks[sessionId] = done;
    done.then((_) {
      if (identical(_locks[sessionId], done)) _locks.remove(sessionId);
    });
    return result;
  }

  // ---- writes ----

  static Future<void> _writeAtomic(File f, String content) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(f.path);
  }

  Future<void> _appendLines(File f, Iterable<String> lines) async {
    final text = lines.map((l) => '$l\n').join();
    if (text.isEmpty) return;
    await f.writeAsString(text, mode: FileMode.append, flush: true);
  }

  /// Cuts a crash-truncated last line (no trailing newline) so the next append starts on a fresh line.
  Future<void> _repairTail(File f) async {
    if (!await f.exists()) return;
    final raf = await f.open(mode: FileMode.append);
    try {
      final len = await raf.length();
      if (len == 0) return;
      await raf.setPosition(len - 1);
      final last = await raf.read(1);
      if (last.isNotEmpty && last[0] == 0x0a) return;
      // Find the last newline and truncate after it.
      const block = 4096;
      var end = len;
      var keep = 0;
      while (end > 0) {
        final start = end - block < 0 ? 0 : end - block;
        await raf.setPosition(start);
        final bytes = await raf.read(end - start);
        final i = bytes.lastIndexOf(0x0a);
        if (i >= 0) {
          keep = start + i + 1;
          break;
        }
        end = start;
      }
      await raf.truncate(keep);
      await raf.flush();
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> startSession(DriveSession session) => _locked(session.id, () async {
        final dir = _dir(session.id);
        await dir.create(recursive: true);
        await _writeAtomic(_file(session.id, 'session.json'), jsonEncode(session.toJson()));
      });

  @override
  Future<void> appendPing(String sessionId, DrivePing ping) => _locked(sessionId, () async {
        if (!await _dir(sessionId).exists()) throw StateError('no such session: $sessionId');
        final f = _file(sessionId, 'pings.jsonl');
        if (_repaired.add(sessionId)) await _repairTail(f);
        await _appendLines(f, [jsonEncode(ping.toJson())]);
      });

  @override
  Future<void> endSession(String sessionId, DateTime endedAt) => _locked(sessionId, () async {
        final s = await _readSession(sessionId);
        if (s == null) throw StateError('no such session: $sessionId');
        await _writeAtomic(_file(sessionId, 'session.json'), jsonEncode(s.copyWith(endedAt: endedAt.toUtc()).toJson()));
      });

  int _resendSeq = 0;

  @override
  Future<void> renameSession(String sessionId, String? label) => _locked(sessionId, () async {
        final s = await _readSession(sessionId);
        if (s == null) throw StateError('no such session: $sessionId');
        final v = label?.trim();
        final renamed = DriveSession(
          id: s.id,
          startedAt: s.startedAt,
          endedAt: s.endedAt,
          label: (v == null || v.isEmpty) ? null : v,
          channel: s.channel,
          radio: s.radio,
          antenna: s.antenna,
          companion: s.companion,
        );
        await _writeAtomic(_file(sessionId, 'session.json'), jsonEncode(renamed.toJson()));
        final token = '${DateTime.now().toUtc().microsecondsSinceEpoch}-${++_resendSeq}';
        await _writeAtomic(_file(sessionId, 'resend.txt'), token);
      });

  @override
  Future<String?> sessionResendToken(String sessionId) => _locked(sessionId, () => _readResend(sessionId));

  Future<String?> _readResend(String sessionId) async {
    final f = _file(sessionId, 'resend.txt');
    try {
      if (!await f.exists()) return null;
      final t = (await f.readAsString()).trim();
      return t.isEmpty ? 'resend' : t;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> clearSessionResend(String sessionId, String token) => _locked(sessionId, () async {
        if (await _readResend(sessionId) != token) return;
        final f = _file(sessionId, 'resend.txt');
        if (await f.exists()) await f.delete();
      });

  @override
  Future<void> markSynced(String sessionId, Iterable<String> pingIds) => _locked(sessionId, () async {
        if (!await _dir(sessionId).exists()) return;
        await _appendLines(_file(sessionId, 'synced.txt'), pingIds);
      });

  @override
  Future<void> markRejected(String sessionId, Iterable<String> pingIds) => _locked(sessionId, () async {
        if (!await _dir(sessionId).exists()) return;
        await _appendLines(_file(sessionId, 'rejected.txt'), pingIds);
      });

  @override
  Future<void> markEndReported(String sessionId, DateTime endedAt) => _locked(sessionId, () async {
        if (!await _dir(sessionId).exists()) return;
        await _writeAtomic(_file(sessionId, 'end_sent.txt'), endedAt.toUtc().toIso8601String());
      });

  @override
  Future<void> deleteSession(String sessionId) => _locked(sessionId, () async {
        final dir = _dir(sessionId);
        if (await dir.exists()) await dir.delete(recursive: true);
        _repaired.remove(sessionId);
        _repairedFiles.removeWhere((k) => k.startsWith('$sessionId/'));
      });

  // ---- drive context (DriveContextLedger) ----

  static const _samplesFile = 'samples.jsonl';
  static const _ctxFile = 'ctx.jsonl';
  static const _contextFile = 'context.json';

  Future<void> _appendContextLines(String sessionId, String name, List<String> lines) async {
    if (!await _dir(sessionId).exists()) throw StateError('no such session: $sessionId');
    if (lines.isEmpty) return;
    final f = _file(sessionId, name);
    if (_repairedFiles.add('$sessionId/$name')) await _repairTail(f);
    await _appendLines(f, lines);
  }

  @override
  Future<void> appendSamples(String sessionId, Iterable<DriveSample> samples) => _locked(sessionId, () async {
        final lines = [for (final x in samples) if (!x.isEmpty) jsonEncode(x.toJson())];
        await _appendContextLines(sessionId, _samplesFile, lines);
      });

  @override
  Future<void> appendPingContext(String sessionId, String pingId, PingContext ctx) => _locked(sessionId, () async {
        final lines = [if (!ctx.isEmpty) jsonEncode({'ping': pingId, 'ctx': ctx.toJson()})];
        await _appendContextLines(sessionId, _ctxFile, lines);
      });

  @override
  Future<void> writeSessionContext(String sessionId, SessionContext ctx) => _locked(sessionId, () async {
        if (!await _dir(sessionId).exists()) throw StateError('no such session: $sessionId');
        final f = _file(sessionId, _contextFile);
        if (ctx.isEmpty) {
          if (await f.exists()) await f.delete();
          return;
        }
        await _writeAtomic(f, jsonEncode(ctx.toJson()));
      });

  /// Readable JSON objects of a JSONL file, in order; broken lines (a crash mid-write) are skipped.
  Future<List<Map<String, dynamic>>> _readJsonl(String sessionId, String name) async {
    final f = _file(sessionId, name);
    if (!await f.exists()) return [];
    final out = <Map<String, dynamic>>[];
    final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      try {
        final v = jsonDecode(line);
        if (v is Map) out.add(v.cast<String, dynamic>());
      } catch (_) {}
    }
    return out;
  }

  Future<List<DriveSample>> _readSamples(String sessionId) async {
    final out = <DriveSample>[];
    for (final j in await _readJsonl(sessionId, _samplesFile)) {
      try {
        out.add(DriveSample.fromJson(j));
      } catch (_) {}
    }
    return out;
  }

  Future<Map<String, PingContext>> _readPingContexts(String sessionId) async {
    final out = <String, PingContext>{};
    for (final j in await _readJsonl(sessionId, _ctxFile)) {
      final id = j['ping'], c = j['ctx'];
      if (id is! String || c is! Map) continue;
      out[id] = PingContext.fromJson(c.cast<String, dynamic>());
    }
    out.removeWhere((_, c) => c.isEmpty);
    return out;
  }

  Future<SessionContext?> _readSessionContext(String sessionId) async {
    for (final name in [_contextFile, '$_contextFile.tmp']) {
      final f = _file(sessionId, name);
      try {
        if (!await f.exists()) continue;
        final c = SessionContext.fromJson((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
        return c.isEmpty ? null : c;
      } catch (_) {}
    }
    return null;
  }

  @override
  Future<List<DriveSample>> samples(String sessionId) => _locked(sessionId, () => _readSamples(sessionId));

  @override
  Future<Map<String, PingContext>> pingContexts(String sessionId) =>
      _locked(sessionId, () => _readPingContexts(sessionId));

  @override
  Future<SessionContext?> sessionContext(String sessionId) => _locked(sessionId, () => _readSessionContext(sessionId));

  @override
  Future<ContextStripResult> stripCategories(String sessionId, Set<String> categoryIds) => _locked(sessionId, () async {
        if (categoryIds.isEmpty || !await _dir(sessionId).exists()) return const ContextStripResult();

        var samplesChanged = 0;
        final samples = await _readSamples(sessionId);
        final keptSamples = <DriveSample>[];
        for (final x in samples) {
          final y = x.without(categoryIds);
          if (jsonEncode(y.toJson()) != jsonEncode(x.toJson())) samplesChanged++;
          if (!y.isEmpty) keptSamples.add(y);
        }
        if (samplesChanged > 0) {
          await _writeAtomic(_file(sessionId, _samplesFile), keptSamples.map((x) => '${jsonEncode(x.toJson())}\n').join());
          _repairedFiles.add('$sessionId/$_samplesFile');
        }

        var ctxChanged = 0;
        final ctx = await _readPingContexts(sessionId);
        final keptCtx = <String, PingContext>{};
        for (final e in ctx.entries) {
          final y = e.value.without(categoryIds);
          if (jsonEncode(y.toJson()) != jsonEncode(e.value.toJson())) ctxChanged++;
          if (!y.isEmpty) keptCtx[e.key] = y;
        }
        if (ctxChanged > 0) {
          await _writeAtomic(
              _file(sessionId, _ctxFile),
              keptCtx.entries.map((e) => '${jsonEncode({'ping': e.key, 'ctx': e.value.toJson()})}\n').join());
          _repairedFiles.add('$sessionId/$_ctxFile');
        }

        var sessionChanged = false;
        final sc = await _readSessionContext(sessionId);
        if (sc != null) {
          final y = sc.without(categoryIds);
          if (jsonEncode(y.toJson()) != jsonEncode(sc.toJson())) {
            sessionChanged = true;
            final f = _file(sessionId, _contextFile);
            if (y.isEmpty) {
              if (await f.exists()) await f.delete();
            } else {
              await _writeAtomic(f, jsonEncode(y.toJson()));
            }
          }
        }
        return ContextStripResult(pingContexts: ctxChanged, samples: samplesChanged, session: sessionChanged);
      });

  // ---- reads ----

  Future<DriveSession?> _readSession(String sessionId) async {
    for (final name in ['session.json', 'session.json.tmp']) {
      final f = _file(sessionId, name);
      try {
        if (!await f.exists()) continue;
        return DriveSession.fromJson((jsonDecode(await f.readAsString()) as Map).cast<String, dynamic>());
      } catch (_) {
        // Unreadable (e.g. a temp file cut short by a crash): try the next one.
      }
    }
    return null;
  }

  /// Every readable ping, first copy of each id kept, in file order. Broken lines (a crash mid-write) are skipped.
  Future<List<DrivePing>> _readPings(String sessionId) async {
    final f = _file(sessionId, 'pings.jsonl');
    if (!await f.exists()) return [];
    final out = <DrivePing>[];
    final seen = <String>{};
    final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    for (final line in const LineSplitter().convert(text)) {
      if (line.trim().isEmpty) continue;
      try {
        final ping = DrivePing.fromJson((jsonDecode(line) as Map).cast<String, dynamic>());
        if (seen.add(ping.id)) out.add(ping);
      } catch (_) {
        // Truncated or corrupt line: skip it, keep the rest.
      }
    }
    return out;
  }

  Future<Set<String>> _readIds(String sessionId, String name) async {
    final f = _file(sessionId, name);
    if (!await f.exists()) return {};
    final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
    return const LineSplitter().convert(text).map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();
  }

  @override
  Future<DriveSession?> session(String sessionId) => _locked(sessionId, () => _readSession(sessionId));

  @override
  Future<List<DrivePing>> pings(String sessionId) => _locked(sessionId, () => _readPings(sessionId));

  @override
  Future<List<DrivePing>> unsyncedPings(String sessionId) => _locked(sessionId, () async {
        final done = await _readIds(sessionId, 'synced.txt')..addAll(await _readIds(sessionId, 'rejected.txt'));
        return (await _readPings(sessionId)).where((p) => !done.contains(p.id)).toList();
      });

  @override
  Future<Set<String>> rejectedIds(String sessionId) => _locked(sessionId, () => _readIds(sessionId, 'rejected.txt'));

  @override
  Future<DateTime?> endReported(String sessionId) => _locked(sessionId, () async {
        final f = _file(sessionId, 'end_sent.txt');
        try {
          if (!await f.exists()) return null;
          return DateTime.parse((await f.readAsString()).trim()).toUtc();
        } catch (_) {
          return null;
        }
      });

  @override
  Future<List<SessionSummary>> sessions() async {
    final out = <SessionSummary>[];
    if (!await _sessionsDir.exists()) return out;
    await for (final e in _sessionsDir.list()) {
      if (e is! Directory) continue;
      final id = p.basename(e.path);
      if (!_safeId.hasMatch(id)) continue;
      final summary = await _locked(id, () async {
        final s = await _readSession(id);
        if (s == null) return null;
        final pings = await _readPings(id);
        final synced = await _readIds(id, 'synced.txt');
        final rejected = await _readIds(id, 'rejected.txt');
        final txPings = pings.where((p) => p.kind == PingKind.tx);
        return SessionSummary(
          session: s,
          pingCount: pings.length,
          txCount: txPings.length,
          heardCount: txPings.where((p) => p.echoes.isNotEmpty || p.neighbor != null).length,
          syncedCount: pings.where((p) => synced.contains(p.id)).length,
          rejectedCount: pings.where((p) => rejected.contains(p.id) && !synced.contains(p.id)).length,
          sessionResendPending: await _readResend(id) != null,
        );
      });
      if (summary != null) out.add(summary);
    }
    out.sort((a, b) => b.session.startedAt.compareTo(a.session.startedAt));
    return out;
  }

  /// `meshsonar-<started yyyyMMdd-HHmm, UTC>-<first 8 of id>.json`
  static String exportFileName(DriveSession s) {
    final t = s.startedAt.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}';
    final short = s.id.length > 8 ? s.id.substring(0, 8) : s.id;
    return 'meshsonar-$stamp-$short.json';
  }

  @override
  Future<File> exportSession(String sessionId, AppInfo app, Directory outDir) async {
    final (s, pings, ctx) = await _locked(
        sessionId,
        () async => (
              await _readSession(sessionId),
              await _readPings(sessionId),
              exportContextJson(
                samples: await _readSamples(sessionId),
                pingContexts: await _readPingContexts(sessionId),
                session: await _readSessionContext(sessionId),
              ),
            ));
    if (s == null) throw StateError('no such session: $sessionId');
    await outDir.create(recursive: true);
    final f = File(p.join(outDir.path, exportFileName(s)));
    // The drive itself is exactly the upload body; the driver's recorded context rides along as `context` (their own
    // file; nothing of it is uploaded).
    await _writeAtomic(f, jsonEncode({...DriveBatch(app: app, session: s, pings: pings).toJson(), 'context': ?ctx}));
    return f;
  }
}
