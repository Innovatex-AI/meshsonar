// Per-drive weather from the server (`GET drive-env`, stream 7 WP6), asked lazily and kept on disk so a drive opened
// offline still shows what the server last said. One JSON file per session in its own directory (beside the region
// cache, same atomic-write and LRU pattern as lib/core/region_cache.dart). Pure Dart.
//
// Rules (docs/PLATFORM_CONTRACT.md "Drive weather"):
//   - `ready` is trusted for [readyTtl] (1 h, the server's own cache time), so a server erase or switching Weather off
//     is never out-lived by a stored copy for long; both also clear the whole cache (AppState.clearDriveWeatherCache).
//   - `pending` / `disabled` / `unavailable` can change (the job runs every 30 minutes), but are asked again only after
//     [retryAfter] (5 minutes, the server's own max-age), never in a loop.
//   - A failed ask serves the stored copy flagged `offline`; with nothing stored it throws (the screen offers Retry).
//   - 404 (the server does not know that drive) drops the stored copy: the drive is gone there, so is its weather.
//   - At most [maxPerMinute] asks per minute across all drives (the server allows 60 per driver per minute).
// The attribution is never stored: every answer is re-stamped with [openMeteoCredit] (the licence line).
import 'dart:convert';
import 'dart:io';

import 'api.dart';

/// One answer for a drive: the weather, when we last asked the server, and whether the live ask failed.
class DriveEnvResult {
  final DriveEnv env;
  final DateTime fetchedAt;

  /// True when the server could not be reached (or answered an error) and [env] is the stored copy.
  final bool offline;
  const DriveEnvResult({
    required this.env,
    required this.fetchedAt,
    required this.offline,
  });
}

class DriveEnvCache {
  /// Null = memory only (tests, or no file system).
  final Directory? dir;
  final DateTime Function() clock;
  final Duration readyTtl;
  final Duration retryAfter;
  final int maxEntries;
  final int maxPerMinute;

  DriveEnvCache({
    this.dir,
    DateTime Function()? clock,
    this.readyTtl = const Duration(hours: 1),
    this.retryAfter = const Duration(minutes: 5),
    this.maxEntries = 60,
    this.maxPerMinute = 50,
  }) : clock = clock ?? DateTime.now;

  final Map<String, DriveEnvResult> _mem = {};
  final Map<String, Future<DriveEnvResult>> _inflight = {};
  final List<DateTime> _asked = [];

  /// How many times the server was actually asked (for tests and Diagnostics).
  int serverAsks = 0;

  static final _safeId = RegExp(r'^[A-Za-z0-9-]{1,64}$');

  File? _file(String sessionId) => dir == null || !_safeId.hasMatch(sessionId)
      ? null
      : File('${dir!.path}${Platform.pathSeparator}de_$sessionId.json');

  /// The weather for [sessionId]: the stored answer while it is fresh, else [fetch] (which calls the server). Several
  /// callers at once share one ask. Throws what [fetch] throws when nothing is stored to fall back on.
  Future<DriveEnvResult> get(
    String sessionId,
    Future<DriveEnv> Function() fetch,
  ) {
    final running = _inflight[sessionId];
    if (running != null) return running;
    final f = _get(sessionId, fetch).whenComplete(() {
      _inflight.remove(sessionId); // a block body: returning the removed future would make it wait on itself
    });
    return _inflight[sessionId] = f;
  }

  /// True when the stored [r] needs no ask yet.
  bool isFresh(DriveEnvResult r) {
    final age = clock().difference(r.fetchedAt);
    if (age.isNegative) return false; // the phone clock went back: ask again
    return age < (r.env.status == DriveEnvStatus.ready ? readyTtl : retryAfter);
  }

  Future<DriveEnvResult> _get(
    String sessionId,
    Future<DriveEnv> Function() fetch,
  ) async {
    final stored = _mem[sessionId] ?? await _read(sessionId);
    if (stored != null) {
      _mem[sessionId] = stored;
      if (isFresh(stored)) return stored;
    }
    final now = clock();
    _asked.removeWhere((t) => now.difference(t) >= const Duration(minutes: 1));
    if (_asked.length >= maxPerMinute) {
      return _fallback(
        stored,
        const CmatException(
          'Too many weather lookups just now. Try again in a minute.',
          status: 429,
        ),
      );
    }
    _asked.add(now);
    serverAsks++;
    try {
      final env = await fetch();
      final r = DriveEnvResult(
        env: _stamp(env),
        fetchedAt: clock(),
        offline: false,
      );
      _mem[sessionId] = r;
      await _write(sessionId, r);
      return r;
    } on CmatException catch (e) {
      if (e.status == 404) {
        await forget(sessionId);
        rethrow;
      }
      return _fallback(stored, e);
    } catch (e) {
      return _fallback(stored, e);
    }
  }

  DriveEnvResult _fallback(DriveEnvResult? stored, Object error) {
    if (stored == null) throw error;
    return DriveEnvResult(
      env: stored.env,
      fetchedAt: stored.fetchedAt,
      offline: true,
    );
  }

  static DriveEnv _stamp(DriveEnv e) => DriveEnv(
    session: e.session,
    status: e.status,
    attribution: openMeteoCredit,
    snapshots: e.snapshots,
  );

  /// Drops the stored weather of one drive (the drive was deleted, or weather was erased).
  Future<void> forget(String sessionId) async {
    _mem.remove(sessionId);
    try {
      final f = _file(sessionId);
      if (f != null && await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Drops everything stored. Returns how many files were removed. Never throws.
  Future<int> clear() async {
    _mem.clear();
    var n = 0;
    try {
      final d = dir;
      if (d == null || !await d.exists()) return 0;
      await for (final e in d.list()) {
        if (e is File && _isEntry(e.path)) {
          try {
            await e.delete();
            if (e.path.endsWith('.json')) n++;
          } catch (_) {}
        }
      }
    } catch (_) {}
    return n;
  }

  bool _isEntry(String path) =>
      path.contains('${Platform.pathSeparator}de_') &&
      (path.endsWith('.json') || path.endsWith('.tmp'));

  Future<DriveEnvResult?> _read(String sessionId) async {
    try {
      final f = _file(sessionId);
      if (f == null || !await f.exists()) return null;
      return decodeDriveEnvResult(await f.readAsString(), sessionId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String sessionId, DriveEnvResult r) async {
    try {
      final f = _file(sessionId);
      if (f == null) return;
      await dir!.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(encodeDriveEnvResult(r), flush: true);
      await tmp.rename(f.path);
      await _evict();
    } catch (_) {
      // A full or read-only disk only costs the cache.
    }
  }

  Future<void> _evict() async {
    final files = <(File, DateTime)>[];
    await for (final e in dir!.list()) {
      if (e is File && _isEntry(e.path) && e.path.endsWith('.json')) {
        files.add((e, (await e.stat()).modified));
      }
    }
    if (files.length <= maxEntries) return;
    files.sort((a, b) => a.$2.compareTo(b.$2));
    for (final f in files.take(files.length - maxEntries)) {
      try {
        await f.$1.delete();
      } catch (_) {}
    }
  }
}

/// The on-disk form. No coordinates exist in a [DriveEnv]; nothing else is stored.
String encodeDriveEnvResult(DriveEnvResult r) => jsonEncode({
  'v': 1,
  'session': r.env.session,
  'status': r.env.status.name,
  'at': r.fetchedAt.toUtc().toIso8601String(),
  'snapshots': [
    for (final s in r.env.snapshots)
      {
        'at': s.at.toUtc().toIso8601String(),
        'temperatureC': s.temperatureC,
        'humidityPct': s.humidityPct,
        'dewPointC': s.dewPointC,
        'pressureHpa': s.pressureHpa,
        'precipMm': s.precipMm,
        'cloudPct': s.cloudPct,
        'windMs': s.windMs,
        'windDirDeg': s.windDirDeg,
      },
  ],
});

/// Null when [text] is not a stored answer this build understands.
DriveEnvResult? decodeDriveEnvResult(String text, String sessionId) {
  try {
    final j = jsonDecode(text);
    if (j is! Map || j['v'] != 1) return null;
    final status = DriveEnvStatus.values
        .where((s) => s.name == j['status'])
        .firstOrNull;
    final at = j['at'] is String ? DateTime.tryParse(j['at'] as String) : null;
    if (status == null || at == null) return null;
    double? d(Object? v) =>
        v is num && v.toDouble().isFinite ? v.toDouble() : null;
    final snaps = <WeatherSnapshot>[];
    for (final e in (j['snapshots'] as List?) ?? const []) {
      if (e is! Map) continue;
      final t = e['at'] is String ? DateTime.tryParse(e['at'] as String) : null;
      if (t == null) continue;
      snaps.add(
        WeatherSnapshot(
          at: t.toUtc(),
          temperatureC: d(e['temperatureC']),
          humidityPct: d(e['humidityPct']),
          dewPointC: d(e['dewPointC']),
          pressureHpa: d(e['pressureHpa']),
          precipMm: d(e['precipMm']),
          cloudPct: d(e['cloudPct']),
          windMs: d(e['windMs']),
          windDirDeg: d(e['windDirDeg']),
        ),
      );
    }
    return DriveEnvResult(
      env: DriveEnv(
        session: sessionId,
        status: status,
        attribution: openMeteoCredit,
        snapshots: snaps,
      ),
      fetchedAt: at.toUtc(),
      offline: false,
    );
  } catch (_) {
    return null;
  }
}
