// App telemetry uploader (Andy, Oct 21 2026: ON by default with opt-out; packet HEADERS/metadata only).
// Pure Dart. Batches [TelemetryRecord]s and sends them to `POST <server>/api/cmh/telemetry` (format `meshsonar-telemetry/1`,
// contract: meshcore-insights docs/TELEMETRY_INGEST.md). `DELETE` on the same endpoint erases everything this driver sent.
//
// Rules, all pinned by test/core/telemetry_uploader_test.dart:
//  * Nothing is collected or sent while the Settings toggle is off, or without a driver key; turning it off discards the
//    queue (memory and disk) at once. A server-side erase is a separate, remembered request ([eraseServerData]).
//  * Only [TelemetryRecord]s exist here: no payload bytes, no text, no coordinates, so none can reach the body.
//  * Our own TX pings (and their echoes) are never uploaded: records are held [TelemetryConfig.holdFor] before sending and
//    dropped if their packet hash was one of our transmissions ([excludeHash]).
//  * Rate caps: intake per minute/hour, at most one batch per [TelemetryConfig.minGap] and [TelemetryConfig.maxBatchesPerHour]
//    per hour (the server allows 12/min and 200/h), a bounded queue (oldest dropped) and a bounded disk file.
//  * Failures back off exponentially (Retry-After honoured); a refused key (401/403) pauses for an hour; a batch the server
//    refuses outright (400/413) is dropped rather than retried forever.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'telemetry.dart';

const String telemetryFormat = 'meshsonar-telemetry/1';

/// What came back from the server for one request. A network failure is a thrown exception instead.
class TelemetryHttpResult {
  final int status;
  final int? retryAfterSec;
  final Map<String, dynamic>? body;
  const TelemetryHttpResult(this.status, {this.retryAfterSec, this.body});
}

/// The HTTP side, implemented by HttpCmatClient (lib/core/cmat_client.dart) so the app has one HTTP client for the server.
abstract class TelemetryTransport {
  /// `POST /api/cmh/telemetry` with [body] (UTF-8 JSON) and `x-driver-key`.
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body);

  /// `DELETE /api/cmh/telemetry`: erases every row this driver sent.
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey);
}

class TelemetryConfig {
  /// Packets per request (server cap 500 and 256 KB; 200 is about 40 KB).
  final int batchSize;

  /// Records kept waiting; beyond it the oldest are dropped. At about 200 bytes each the disk file stays near 1 MB.
  final int maxQueue;

  /// A record waits this long before it may be sent, so a ping's hash is known and its echoes can be recognised and dropped.
  final Duration holdFor;

  /// Minimum time between two requests.
  final Duration minGap;
  final int maxBatchesPerHour;

  /// Intake caps (records accepted from the radio); the excess is dropped, not queued.
  final int maxPerMinute;
  final int maxPerHour;

  /// Older than this and the server would refuse the packet (48 h), so it is dropped here.
  final Duration maxAge;
  final Duration baseBackoff;
  final Duration maxBackoff;
  final Duration authBackoff;
  const TelemetryConfig({
    this.batchSize = 200,
    this.maxQueue = 5000,
    this.holdFor = const Duration(seconds: 90),
    this.minGap = const Duration(seconds: 15),
    this.maxBatchesPerHour = 60,
    this.maxPerMinute = 600,
    this.maxPerHour = 20000,
    this.maxAge = const Duration(hours: 47),
    this.baseBackoff = const Duration(seconds: 30),
    this.maxBackoff = const Duration(minutes: 30),
    this.authBackoff = const Duration(hours: 1),
  });
}

final RegExp _versionRe = RegExp(r'^[0-9A-Za-z][0-9A-Za-z.+_-]{0,19}$');
final RegExp _regionRe = RegExp(r'^[A-Z]{3}$');

/// The exact JSON the server receives for [records] (all sharing one [region]). Public so the privacy test can inspect it.
String buildTelemetryBody(List<TelemetryRecord> records, {String? region, String? appVersion, String? platform}) {
  final plat = platform?.toLowerCase();
  final app = <String, dynamic>{
    if (appVersion != null && _versionRe.hasMatch(appVersion)) 'version': appVersion,
    if (plat == 'ios' || plat == 'android') 'platform': plat,
  };
  return jsonEncode({
    'format': telemetryFormat,
    if (app.isNotEmpty) 'app': app,
    if (region != null && _regionRe.hasMatch(region)) 'region': region,
    'packets': [for (final r in records) r.toJson()],
  });
}

class TelemetryUploader {
  final bool Function() enabled;
  final String? Function() driverKey;

  /// True once the server will accept the key (approved). Records are kept, not sent, until then.
  final bool Function() keyApproved;
  final TelemetryTransport? Function() transport;
  final String? appVersion;
  final String? platform;

  /// Where the queue survives restarts. Null = memory only.
  final File? queueFile;
  final TelemetryConfig config;
  final DateTime Function() now;

  /// Schedule the next flush by itself after records arrive. Tests switch it off and call [flush].
  final bool autoSchedule;

  TelemetryUploader({
    required this.enabled,
    required this.driverKey,
    required this.keyApproved,
    required this.transport,
    this.appVersion,
    this.platform,
    this.queueFile,
    this.config = const TelemetryConfig(),
    DateTime Function()? now,
    this.autoSchedule = true,
  }) : now = now ?? DateTime.now;

  final List<TelemetryRecord> _queue = [];
  final LinkedHashSet<String> _ownHashes = LinkedHashSet();
  final LinkedHashSet<String> _seen = LinkedHashSet();
  final List<DateTime> _batchTimes = [];
  DateTime? _nextAttempt;
  DateTime? _lastSend;
  int _failures = 0;
  bool _pendingErase = false;
  bool _dirty = false;
  bool _flushing = false;
  Timer? _timer;
  DateTime? _minuteStart;
  int _minuteCount = 0;
  DateTime? _hourStart;
  int _hourCount = 0;

  int get queued => _queue.length;
  bool get pendingErase => _pendingErase;
  int sent = 0;
  int dropped = 0;

  /// Reads the on-disk queue (if any). Expired and malformed entries are skipped.
  Future<void> load() async {
    final f = queueFile;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      _pendingErase = j['pending_erase'] == true;
      final cutoff = now().subtract(config.maxAge);
      for (final e in (j['records'] as List? ?? const [])) {
        final region = e is Map && e['region'] is String && _regionRe.hasMatch(e['region'] as String) ? e['region'] as String : null;
        final r = TelemetryRecord.tryFromJson(e, region: region);
        if (r != null && r.at.isAfter(cutoff)) _queue.add(r);
      }
      _trim();
    } catch (_) {
      // A damaged queue only costs the queued headers; never block the app on it.
    }
  }

  /// A hash of one of our own transmissions (a ping). Packets with it, our echoes, are never uploaded.
  void excludeHash(String hash) {
    if (hash.isEmpty) return;
    _ownHashes.add(hash.toLowerCase());
    while (_ownHashes.length > 2048) {
      _ownHashes.remove(_ownHashes.first);
    }
    final before = _queue.length;
    _queue.removeWhere((r) => r.packetHash == hash.toLowerCase());
    if (_queue.length != before) _dirty = true;
  }

  /// Queues [r] if telemetry is on and there is a driver key; returns whether it was kept.
  bool add(TelemetryRecord r) {
    if (!enabled()) {
      discard();
      return false;
    }
    if ((driverKey() ?? '').isEmpty) return false; // nothing can be uploaded without a key; do not hoard
    if (telemetryPrivateTypes.contains(r.payloadType)) return false;
    final h = r.packetHash;
    if (h != null && _ownHashes.contains(h)) return false;
    final t = now();
    if (_minuteStart == null || t.difference(_minuteStart!) >= const Duration(minutes: 1)) {
      _minuteStart = t;
      _minuteCount = 0;
    }
    if (_hourStart == null || t.difference(_hourStart!) >= const Duration(hours: 1)) {
      _hourStart = t;
      _hourCount = 0;
    }
    if (_minuteCount >= config.maxPerMinute || _hourCount >= config.maxPerHour) {
      dropped++;
      return false;
    }
    if (h != null) {
      final k = '$h|${r.pathHashes.join()}';
      if (!_seen.add(k)) return false;
      while (_seen.length > 4096) {
        _seen.remove(_seen.first);
      }
    }
    _minuteCount++;
    _hourCount++;
    _queue.add(r);
    _dirty = true;
    _trim();
    _schedule();
    return true;
  }

  void _trim() {
    final over = _queue.length - config.maxQueue;
    if (over > 0) {
      _queue.removeRange(0, over);
      dropped += over;
      _dirty = true;
    }
  }

  /// Drops everything queued, in memory and on disk (the opt-out). Does not touch the server; see [eraseServerData].
  void discard() {
    if (_queue.isEmpty && !_dirty) return;
    _queue.clear();
    _seen.clear();
    _dirty = true;
    unawaited(_save());
  }

  /// Asks the server to erase everything this driver sent. Remembered across restarts until it succeeds. Returns the
  /// server's count, or null if it could not be done yet (it will be retried by [flush]).
  Future<int?> eraseServerData() async {
    _pendingErase = true;
    _dirty = true;
    await _save();
    return _tryErase();
  }

  Future<int?> _tryErase() async {
    final key = driverKey();
    final tx = transport();
    if (key == null || key.isEmpty || tx == null) return null;
    try {
      final r = await tx.deleteTelemetry(key);
      if (r.status == 200) {
        _pendingErase = false;
        _dirty = true;
        final d = r.body?['deleted'];
        await _save();
        return d is num ? d.toInt() : 0;
      }
      if (r.status == 401 || r.status == 403) {
        // The key is not (or no longer) accepted, so the server holds nothing we can still erase with it.
        _pendingErase = false;
        _dirty = true;
        await _save();
        return null;
      }
    } catch (_) {}
    return null;
  }

  void _schedule() {
    if (!autoSchedule || _timer != null) return;
    _timer = Timer(config.minGap, () {
      _timer = null;
      unawaited(flush().whenComplete(() {
        if (_queue.isNotEmpty && enabled()) _schedule();
      }));
    });
  }

  Duration _backoff() {
    var d = config.baseBackoff;
    for (var i = 1; i < _failures && d < config.maxBackoff; i++) {
      d *= 2;
    }
    return d > config.maxBackoff ? config.maxBackoff : d;
  }

  /// Sends at most one batch if one is due. Safe to call often.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _run();
      if (_dirty) await _save();
    } finally {
      _flushing = false;
    }
  }

  Future<void> _run() async {
    if (_pendingErase) await _tryErase();
    if (!enabled() || (driverKey() ?? '').isEmpty) {
      discard();
      return;
    }
    final t = now();
    _queue.removeWhere((r) => r.at.isBefore(t.subtract(config.maxAge)) || (r.packetHash != null && _ownHashes.contains(r.packetHash)));
    if (_queue.isEmpty) {
      await _save();
      return;
    }
    if (!keyApproved()) return;
    final tx = transport();
    if (tx == null) return;
    if (_nextAttempt != null && t.isBefore(_nextAttempt!)) return;
    if (_lastSend != null && t.difference(_lastSend!) < config.minGap) return;
    _batchTimes.removeWhere((b) => t.difference(b) >= const Duration(hours: 1));
    if (_batchTimes.length >= config.maxBatchesPerHour) return;

    final eligible = _queue.where((r) => !r.at.isAfter(t.subtract(config.holdFor))).toList();
    if (eligible.isEmpty) return;
    final region = eligible.first.region;
    final batch = eligible.where((r) => r.region == region).take(config.batchSize).toList();

    final key = driverKey()!;
    final body = utf8.encode(buildTelemetryBody(batch, region: region, appVersion: appVersion, platform: platform));
    _lastSend = t;
    _batchTimes.add(t);
    TelemetryHttpResult res;
    try {
      res = await tx.postTelemetry(key, body);
    } catch (_) {
      _failures++;
      _nextAttempt = now().add(_backoff());
      return;
    }
    final s = res.status;
    if (s == 200) {
      _failures = 0;
      _nextAttempt = null;
      sent += batch.length;
      _removeBatch(batch);
    } else if (s == 401 || s == 403) {
      _failures++;
      _nextAttempt = now().add(config.authBackoff);
    } else if (s == 429 || s >= 500 || s == 408) {
      _failures++;
      final ra = res.retryAfterSec;
      final wait = ra != null && ra > 0 ? Duration(seconds: ra) : _backoff();
      _nextAttempt = now().add(wait > config.maxBackoff ? config.maxBackoff : wait);
    } else {
      // 400 / 413 / other 4xx: the server will never take this batch. Drop it instead of retrying forever.
      dropped += batch.length;
      _removeBatch(batch);
    }
    await _save();
  }

  void _removeBatch(List<TelemetryRecord> batch) {
    final gone = Set<TelemetryRecord>.identity()..addAll(batch);
    _queue.removeWhere(gone.contains);
    _dirty = true;
  }

  Future<void> _save() async {
    final f = queueFile;
    if (f == null) {
      _dirty = false;
      return;
    }
    try {
      if (_queue.isEmpty && !_pendingErase) {
        if (await f.exists()) await f.delete();
        _dirty = false;
        return;
      }
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(
          jsonEncode({
            'v': 1,
            'pending_erase': _pendingErase,
            'records': [
              for (final r in _queue) {...r.toJson(), 'region': r.region},
            ],
          }),
          flush: true);
      await tmp.rename(f.path);
      _dirty = false;
    } catch (_) {
      // Disk trouble costs only the unsent headers.
    }
  }

  /// Persists what is queued and stops the timer (app closing).
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    if (_dirty) await _save();
  }
}
