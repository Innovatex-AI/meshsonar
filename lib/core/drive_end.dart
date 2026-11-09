// Drive privacy for exact observer positions (phone observer contract section 8.7, Nov 9 2026; fail closed).
//
// While a drive records, observer packets carry the exact drive position (`pos`, section 8.2). The server holds them as
// pending. When the drive stops and its trim is known, the app confirms the window it keeps:
//   POST /api/cmh/observer/drive-end
//   {"id", "drive_ref", "started_at", "ended_at", "keep_from", "keep_until", "hidden"}
// Positions outside [keep_from, keep_until] (or all of them with `hidden` / keep null) are dropped server-side (the cell is
// kept); the rest are confirmed. Unconfirmed positions are dropped after 12 h. The request is queued on disk (survives an
// app kill) and retried until the server answers 2xx. Pure Dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

/// One point of the drive's track, enough to compute the trim window.
class TrackPoint {
  final DateTime at;
  final double lat;
  final double lon;
  const TrackPoint(this.at, this.lat, this.lon);
}

double _metres(double la1, double lo1, double la2, double lo2) {
  const r = 6371000.0;
  final p1 = la1 * math.pi / 180, p2 = la2 * math.pi / 180;
  final dp = p2 - p1, dl = (lo2 - lo1) * math.pi / 180;
  final a = math.sin(dp / 2) * math.sin(dp / 2) + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// The kept window of a drive with start / end trim [trimM]: from the first point farther than [trimM] from the start to
/// the last point farther than [trimM] from the end. Null when nothing is kept (a drive that never left the trim circles,
/// no track). A trim of 0 keeps the whole track.
({DateTime from, DateTime until})? driveKeepWindow(List<TrackPoint> track, double trimM) {
  if (track.isEmpty) return null;
  if (trimM <= 0) return (from: track.first.at, until: track.last.at);
  final s = track.first, e = track.last;
  DateTime? from, until;
  for (final p in track) {
    if (_metres(p.lat, p.lon, s.lat, s.lon) > trimM) {
      from = p.at;
      break;
    }
  }
  for (final p in track.reversed) {
    if (_metres(p.lat, p.lon, e.lat, e.lon) > trimM) {
      until = p.at;
      break;
    }
  }
  if (from == null || until == null || until.isBefore(from)) return null;
  return (from: from, until: until);
}

/// One drive-end confirmation waiting to reach the server.
class DriveEndRecord {
  final String observerId;

  /// The drive's id as uploaded (the session id); null when the drive is not uploaded.
  final String? driveRef;
  final DateTime startedAt;
  final DateTime endedAt;
  final DateTime? keepFrom;
  final DateTime? keepUntil;
  final bool hidden;

  /// Not sent before this time: the drive's last packets (held 90 s on the phone) must reach the server first.
  final DateTime notBefore;
  const DriveEndRecord({
    required this.observerId,
    required this.driveRef,
    required this.startedAt,
    required this.endedAt,
    required this.keepFrom,
    required this.keepUntil,
    required this.hidden,
    required this.notBefore,
  });

  /// The same drive with nothing kept (discarded / hidden on this phone before it was sent).
  DriveEndRecord asHidden() => DriveEndRecord(
        observerId: observerId,
        driveRef: driveRef,
        startedAt: startedAt,
        endedAt: endedAt,
        keepFrom: null,
        keepUntil: null,
        hidden: true,
        notBefore: notBefore,
      );

  static String _ts(DateTime t) => t.toUtc().toIso8601String();

  /// The request body (contract section 8.7). keep_* both null or both set.
  Map<String, dynamic> toWire() {
    final keep = !hidden && keepFrom != null && keepUntil != null;
    return {
      'id': observerId,
      'drive_ref': driveRef,
      'started_at': _ts(startedAt),
      'ended_at': _ts(endedAt),
      'keep_from': keep ? _ts(keepFrom!) : null,
      'keep_until': keep ? _ts(keepUntil!) : null,
      'hidden': hidden,
    };
  }

  Map<String, dynamic> toJson() => {...toWire(), 'not_before': _ts(notBefore)};

  static DriveEndRecord? tryFromJson(Object? j) {
    if (j is! Map) return null;
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
    final id = j['id'], s = t(j['started_at']), e = t(j['ended_at']);
    if (id is! String || s == null || e == null) return null;
    return DriveEndRecord(
      observerId: id,
      driveRef: j['drive_ref'] is String ? j['drive_ref'] as String : null,
      startedAt: s,
      endedAt: e,
      keepFrom: t(j['keep_from']),
      keepUntil: t(j['keep_until']),
      hidden: j['hidden'] == true,
      notBefore: t(j['not_before']) ?? e,
    );
  }
}

/// The HTTP side: `POST /api/cmh/observer/drive-end`. Returns the status; a network failure throws.
abstract class DriveEndTransport {
  Future<int> driveEnd(String driverKey, Map<String, dynamic> body);
}

/// The durable queue of drive-end confirmations.
class DriveEndQueue {
  final File? file;
  final DateTime Function() now;
  DriveEndQueue({this.file, DateTime Function()? now}) : now = now ?? DateTime.now;

  final List<DriveEndRecord> _items = [];
  bool _loaded = false;
  bool _flushing = false;

  /// How long a confirmation waits for its drive's upload (the server drops pending positions after 12 h).
  static const Duration waitForDrive = Duration(hours: 11);

  List<DriveEndRecord> get pending => List.unmodifiable(_items);
  int sent = 0;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final f = file;
    if (f == null) return;
    try {
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString());
      if (j is Map && j['items'] is List) {
        for (final e in j['items'] as List) {
          final r = DriveEndRecord.tryFromJson(e);
          if (r != null) _items.add(r);
        }
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final f = file;
    if (f == null) return;
    try {
      if (_items.isEmpty) {
        if (await f.exists()) await f.delete();
        return;
      }
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode({'v': 1, 'items': [for (final r in _items) r.toJson()]}), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// Queues [r] (on disk before anything else).
  Future<void> add(DriveEndRecord r) async {
    await load();
    _items.add(r);
    await _save();
  }

  /// The drive [driveRef] was deleted or hidden on this phone before its confirmation went: nothing of it is kept.
  Future<void> hide(String driveRef) async {
    await load();
    var changed = false;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i].driveRef == driveRef && !_items[i].hidden) {
        _items[i] = _items[i].asHidden();
        changed = true;
      }
    }
    if (changed) await _save();
  }

  /// Sends every due confirmation; keeps what fails (network, 5xx, 429, 401/403, 404 = server without 8.7 yet) for the
  /// next try. A 400 (the server will never take it) is dropped.
  ///
  /// [uploaded]: the drive [DriveEndRecord.driveRef] is on the server (the server hides the whole window for a drive_ref it
  /// does not know as this driver's, contract 8.7a), so a confirmation waits for its drive's upload, at most until
  /// [waitForDrive] after the stop (then it goes anyway: the server's 12 h rule drops the positions either way).
  Future<void> flush(DriveEndTransport? tx, String? driverKey, {Future<bool> Function(String driveRef)? uploaded}) async {
    await load();
    if (tx == null || driverKey == null || driverKey.isEmpty || _flushing) return;
    _flushing = true;
    try {
      final t = now();
      for (final r in [..._items]) {
        if (t.isBefore(r.notBefore)) continue;
        final ref = r.driveRef;
        if (ref != null && !r.hidden && uploaded != null && t.isBefore(r.endedAt.add(waitForDrive))) {
          var ok = false;
          try {
            ok = await uploaded(ref);
          } catch (_) {}
          if (!ok) continue;
        }
        int status;
        try {
          status = await tx.driveEnd(driverKey, r.toWire());
        } catch (_) {
          break; // offline: try again later
        }
        if ((status >= 200 && status < 300) || status == 400 || status == 422) {
          _items.remove(r);
          if (status < 300) sent++;
          await _save();
        }
      }
    } finally {
      _flushing = false;
    }
  }
}
