// App telemetry uploader (Andy, Oct 21 2026: ON by default with opt-out). Pure Dart. Batches [TelemetryRecord]s and sends
// them to `POST <server>/api/cmh/telemetry`, format `meshsonar-telemetry/2` (the phone observer, contract meshsonar-infra
// docs/planning/phone-observer-contract-v2-2026-11-08.md) with an `observer` block, or `meshsonar-telemetry/1` (headers
// only, meshcore-insights docs/TELEMETRY_INGEST.md) when there is no observer id yet or the server refused v2 with a 400
// about the format (then v1 for the rest of the run). `DELETE` on the same endpoint erases everything this driver sent.
//
// Rules, all pinned by test/core/telemetry_uploader_test.dart:
//  * Nothing is collected or sent while the Settings toggle is off, or without a driver key; turning it off discards the
//    queue (memory and disk) at once. A server-side erase is a separate, remembered request ([eraseServerData]).
//  * Only [TelemetryRecord]s exist here: raw bytes only of public packet types (the record enforces it), an H3 res-7 cell at
//    most, never coordinates, names or the radio's public key; the observer id is random per install.
//  * Our own TX pings (and their echoes) are never uploaded: records are held [TelemetryConfig.holdFor] before sending and
//    dropped if their packet hash was one of our transmissions ([excludeHash]).
//  * Cadence (contract section 6): in the foreground a batch at most every [TelemetryConfig.minGap] (5 s); in the background
//    every [TelemetryConfig.backgroundGap] (60 s) or as soon as [TelemetryConfig.backgroundBatch] (50) packets are ready.
//  * Rate caps: intake per minute/hour, at most [TelemetryConfig.maxBatchesPerHour] batches per hour (the server allows
//    12/min and 200/h; past half of it the gap widens to spread the rest), a bounded queue (oldest dropped) and a bounded
//    disk file.
//  * Failures back off exponentially (Retry-After honoured); a refused key (401/403) pauses for an hour; a batch the server
//    refuses outright (400/413) is dropped rather than retried forever.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'telemetry.dart';

const String telemetryFormat = 'meshsonar-telemetry/1';
const String telemetryFormatV2 = 'meshsonar-telemetry/2';

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
  /// Packets per request (server cap 500 and 256 KB for v1 / 512 KB for v2; 200 v2 packets with raw are under 200 KB).
  final int batchSize;

  /// Records kept waiting; beyond it the oldest are dropped. At about 200 bytes each the disk file stays near 1 MB.
  final int maxQueue;

  /// A record waits this long before it may be sent, so a ping's hash is known and its echoes can be recognised and dropped.
  final Duration holdFor;

  /// Minimum time between two requests; the foreground flush cadence (5 s).
  final Duration minGap;

  /// Background cadence: a batch when this long passed since the last one ...
  final Duration backgroundGap;

  /// ... or as soon as this many packets are ready to send.
  final int backgroundBatch;
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
    this.minGap = const Duration(seconds: 5),
    this.backgroundGap = const Duration(seconds: 60),
    this.backgroundBatch = 50,
    this.maxBatchesPerHour = 180,
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
final RegExp _observerIdRe = RegExp(r'^[0-9a-f]{32}$');
final RegExp _modelRe = RegExp(r'^[0-9A-Za-z][0-9A-Za-z ._+-]{0,39}$');
final RegExp _firmwareRe = RegExp(r'^[0-9A-Za-z][0-9A-Za-z._+-]{0,19}$');
final RegExp _antennaRe = RegExp(r'^[a-z0-9_-]{1,24}$');

/// A free-text radio field made to fit a contract token: characters outside [allowed] dropped, trimmed, cut to [max];
/// null when nothing valid is left (the field is then left out, never sent malformed).
String? telemetryToken(String? v, RegExp re, {required int max, bool spaces = false}) {
  if (v == null) return null;
  var t = v.replaceAll(RegExp(spaces ? r'[^0-9A-Za-z ._+-]' : r'[^0-9A-Za-z._+-]'), '').trim();
  t = t.replaceFirst(RegExp(r'^[^0-9A-Za-z]+'), '');
  if (t.length > max) t = t.substring(0, max).trimRight();
  return re.hasMatch(t) ? t : null;
}

/// The radio context of the `observer` block (contract section 2): model, firmware, preset and antenna profile. Every
/// field optional; never a name or a public key.
class TelemetryRadio {
  final String? model;
  final String? firmware;
  final double? freqMhz;
  final double? bwKhz;
  final int? sf;
  final int? cr;
  final String? antenna;
  const TelemetryRadio({this.model, this.firmware, this.freqMhz, this.bwKhz, this.sf, this.cr, this.antenna});

  Map<String, dynamic> toJson() {
    final m = telemetryToken(model, _modelRe, max: 40, spaces: true);
    final f = telemetryToken(firmware, _firmwareRe, max: 20);
    final a = antenna != null && _antennaRe.hasMatch(antenna!) ? antenna : null;
    return {
      'model': ?m,
      'firmware': ?f,
      if (freqMhz != null && freqMhz!.isFinite && freqMhz! > 100 && freqMhz! < 3000) 'freq_mhz': freqMhz,
      if (bwKhz != null && bwKhz!.isFinite && bwKhz! > 0 && bwKhz! <= 1000) 'bw_khz': bwKhz,
      if (sf != null && sf! >= 5 && sf! <= 12) 'sf': sf,
      if (cr != null && cr! >= 5 && cr! <= 8) 'cr': cr,
      'antenna': ?a,
    };
  }
}

/// Who heard the batch: the random per-install observer id (32 lower hex) and the radio context. The mode comes from the
/// batch's records.
class TelemetryObserver {
  final String id;
  final TelemetryRadio radio;
  const TelemetryObserver({required this.id, this.radio = const TelemetryRadio()});

  bool get valid => _observerIdRe.hasMatch(id);
}

/// The exact `meshsonar-telemetry/2` JSON for [records] (one region, one [mode]). Public so the privacy tests can inspect it.
String buildTelemetryBodyV2(
  List<TelemetryRecord> records, {
  required TelemetryObserver observer,
  ObserverMode mode = ObserverMode.background,
  String? region,
  String? appVersion,
  String? platform,
}) {
  final plat = platform?.toLowerCase();
  final app = <String, dynamic>{
    if (appVersion != null && _versionRe.hasMatch(appVersion)) 'version': appVersion,
    if (plat == 'ios' || plat == 'android') 'platform': plat,
  };
  final radio = observer.radio.toJson();
  return jsonEncode({
    'format': telemetryFormatV2,
    if (app.isNotEmpty) 'app': app,
    if (region != null && _regionRe.hasMatch(region)) 'region': region,
    'observer': {
      'id': observer.id,
      'mode': mode.wire,
      if (radio.isNotEmpty) 'radio': radio,
    },
    'packets': [for (final r in records) r.toJsonV2()],
  });
}

/// A 400 from a server that does not know `meshsonar-telemetry/2`: its error mentions the format.
bool isFormatRefusal(TelemetryHttpResult r) {
  if (r.status != 400) return false;
  final b = r.body;
  if (b == null) return false;
  return jsonEncode(b).toLowerCase().contains('format');
}

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

  /// The observer block for v2 (random id + radio context); null = not known yet, the batch goes as v1 (headers only).
  final TelemetryObserver? Function()? observer;

  /// Called after the server confirmed an erase (the app then starts a new observer id and ends home mode).
  final void Function()? onServerErased;

  /// Called with the server's `observer` answer to a v2 batch (`{"key": .., "kind": ..}`), so the app can say which
  /// observer this phone is.
  final void Function(Map<String, dynamic> observer)? onObserver;

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
    this.observer,
    this.onServerErased,
    this.onObserver,
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

  bool _foreground = true;
  bool _v1Only = false;

  /// The server refused `meshsonar-telemetry/2` this run: v1 (headers only) is sent until the app restarts.
  bool get v1Only => _v1Only;

  /// The app is in front (5 s cadence) or in the background (60 s or 50 packets). Changing it reschedules.
  bool get foreground => _foreground;
  set foreground(bool v) {
    if (v == _foreground) return;
    _foreground = v;
    _timer?.cancel();
    _timer = null;
    if (_queue.isNotEmpty) _schedule();
  }

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
    if (!r.mayLeavePhone) return false; // private types, and group packets whose channel was not checked
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
        onServerErased?.call();
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
    final t = now();
    // Wake when the oldest record has waited out the hold-back, and not before the cadence allows a batch.
    var wait = _foreground ? _gap(t) : config.backgroundGap;
    if (_queue.isNotEmpty) {
      final ready = _queue.first.at.add(config.holdFor).difference(t);
      if (ready > wait) wait = ready;
    }
    if (!_foreground && _readyCount(t) >= config.backgroundBatch) wait = _gap(t);
    if (_lastSend != null) {
      final sinceLast = t.difference(_lastSend!);
      final left = _gap(t) - sinceLast;
      if (left > wait) wait = left;
    }
    if (wait < const Duration(milliseconds: 200)) wait = const Duration(milliseconds: 200);
    _timer = Timer(wait, () {
      _timer = null;
      unawaited(flush().whenComplete(() {
        if (_queue.isNotEmpty && enabled()) _schedule();
      }));
    });
  }

  /// The gap between two requests now: [TelemetryConfig.minGap], widened once half of the hourly budget is used so the
  /// rest is spread over the hour instead of running out.
  Duration _gap(DateTime t) {
    final inHour = _batchTimes.where((b) => t.difference(b) < const Duration(hours: 1)).length;
    if (config.maxBatchesPerHour > 0 && inHour * 2 >= config.maxBatchesPerHour) {
      final spread = Duration(milliseconds: 3600000 ~/ config.maxBatchesPerHour);
      return spread > config.minGap ? spread : config.minGap;
    }
    return config.minGap;
  }

  /// Records past the hold-back (the queue is in arrival order, so they are at its start).
  int _readyCount(DateTime t) {
    final cut = t.subtract(config.holdFor);
    var n = 0;
    for (final r in _queue) {
      if (r.at.isAfter(cut)) break;
      n++;
    }
    return n;
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
    _batchTimes.removeWhere((b) => t.difference(b) >= const Duration(hours: 1));
    if (_lastSend != null && t.difference(_lastSend!) < _gap(t)) return;
    if (_batchTimes.length >= config.maxBatchesPerHour) return;

    final eligible = _queue.where((r) => !r.at.isAfter(t.subtract(config.holdFor))).toList();
    if (eligible.isEmpty) return;
    // Background: a batch every minute, or sooner once enough packets are ready.
    if (!_foreground &&
        eligible.length < config.backgroundBatch &&
        _lastSend != null &&
        t.difference(_lastSend!) < config.backgroundGap) {
      return;
    }
    final region = eligible.first.region;
    final mode = eligible.first.mode;
    final batch = eligible.where((r) => r.region == region && r.mode == mode).take(config.batchSize).toList();

    final key = driverKey()!;
    final obs = _v1Only ? null : observer?.call();
    final v2 = obs != null && obs.valid;
    List<int> bodyFor(bool asV2) => utf8.encode(asV2
        ? buildTelemetryBodyV2(batch, observer: obs!, mode: mode, region: region, appVersion: appVersion, platform: platform)
        : buildTelemetryBody(batch, region: region, appVersion: appVersion, platform: platform));
    _lastSend = t;
    _batchTimes.add(t);
    TelemetryHttpResult res;
    try {
      res = await tx.postTelemetry(key, bodyFor(v2));
      if (v2 && isFormatRefusal(res)) {
        // A server without v2 (contract section 1): the same batch again as v1 now, and v1 for the rest of this run.
        _v1Only = true;
        res = await tx.postTelemetry(key, bodyFor(false));
      }
    } catch (_) {
      _failures++;
      _nextAttempt = now().add(_backoff());
      return;
    }
    final s = res.status;
    if (s == 200) {
      final o = res.body?['observer'];
      if (v2 && !_v1Only && o is Map) onObserver?.call(o.cast<String, dynamic>());
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
              for (final r in _queue) r.toQueueJson(),
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
