// The account pages of the website, native: devices and keys, a drive's full track, problem reports, the data export.
// All with `x-driver-key` (the app is an anonymous driver by default; no website sign-in is needed).
// Server: meshcore-insights `src/lib/platform/driver-account-handlers.ts` (capability `driverAccount`).
//   GET  driver-devices      -> {v:1, driver, linked, devices[], mm:{linked, keys[]}}
//   POST driver-key-reveal   {kind: driver|mm, id} -> {revealable:true, key, configLink?} | {revealable:false} | 404
//   POST driver-key-rotate   {newKey}              -> {ok, keyHint, revealable}   (the phone made the key itself)
//   GET  driver-drive ?id=   -> {drive, pings[]}
//   POST driver-drive-update {id, label?, hidden?} -> {ok}      POST driver-drive-delete {id} -> {ok}
//   GET  driver-reports      -> {reports[]}
//   GET  driver-export       -> a JSON download
// Parsing is tolerant: a row that cannot be read is skipped, a missing number is null (shown as "not available", never 0).
// Pure Dart: no Flutter imports.
import 'dart:convert';
import 'dart:math';

import 'driver_summary.dart' show ServerDrive;
import 'api.dart' show DriverKeyStatus;

int? _int(Object? v) => v is num && v.isFinite ? v.round() : null;
double? _dbl(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
String? _str(Object? v, [int max = 120]) => v is String && v.isNotEmpty ? (v.length > max ? v.substring(0, max) : v) : null;

DriverKeyStatus _status(Object? s) => switch (s) {
      'approved' => DriverKeyStatus.approved,
      'pending' => DriverKeyStatus.pending,
      'rejected' => DriverKeyStatus.rejected,
      'revoked' || 'banned' => DriverKeyStatus.revoked,
      _ => DriverKeyStatus.unknown,
    };

/// A new driver key for the phone to rotate to: "ms_" + 32 random bytes, base64url without padding (the shape the server
/// issues and `driver-key-rotate` accepts). [random] is injectable for tests; the default is the secure generator.
String newDriverKey([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => r.nextInt(256));
  return 'ms_${base64Url.encode(bytes).replaceAll('=', '')}';
}

/// Does [key] look like a key `driver-key-rotate` accepts.
bool isDriverKeyShape(String key) => RegExp(r'^ms_[A-Za-z0-9_-]{43}$').hasMatch(key);

/// One driver key of the account (a phone). Never carries the key.
class AccountDevice {
  final String id;
  final String display;
  final DriverKeyStatus status;
  final DateTime? createdAt, lastSeenAt;

  /// Last four characters of the key.
  final String? keyHint;

  /// The server holds a sealed copy, so the key can be shown again.
  final bool revealable;
  const AccountDevice({required this.id, required this.display, required this.status, this.createdAt, this.lastSeenAt, this.keyHint, this.revealable = false});

  static AccountDevice? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id'], 64);
    if (id == null) return null;
    return AccountDevice(
      id: id,
      display: _str(j['display'], 60) ?? _str(j['callsign'], 60) ?? 'Driver',
      status: _status(j['status']),
      createdAt: _time(j['createdAt']),
      lastSeenAt: _time(j['lastSeenAt']),
      keyHint: _str(j['keyHint'], 8),
      revealable: j['revealable'] == true,
    );
  }
}

/// A MeshMapper forward key of the account (from MeshMapper's Custom API Endpoint into MeshSonar). Never carries the key.
class MmForwardKey {
  final String id;
  final String keyHint;
  final String? label;
  final DateTime? createdAt, revokedAt, lastBatchAt;
  final int items, items24h;
  final bool revealable;
  const MmForwardKey({required this.id, required this.keyHint, this.label, this.createdAt, this.revokedAt, this.lastBatchAt, this.items = 0, this.items24h = 0, this.revealable = false});

  bool get active => revokedAt == null;

  static MmForwardKey? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id'], 64);
    if (id == null) return null;
    return MmForwardKey(
      id: id,
      keyHint: _str(j['keyHint'], 8) ?? '',
      label: _str(j['label'], 60),
      createdAt: _time(j['createdAt']),
      revokedAt: _time(j['revokedAt']),
      lastBatchAt: _time(j['lastBatchAt']),
      items: _int(j['items']) ?? 0,
      items24h: _int(j['items24h']) ?? 0,
      revealable: j['revealable'] == true,
    );
  }
}

class DriverDevices {
  /// This phone's own key record.
  final AccountDevice driver;

  /// True when the key belongs to a website account, so [devices] can list several phones and [mmKeys] can exist.
  final bool linked;
  final List<AccountDevice> devices;
  final List<MmForwardKey> mmKeys;
  const DriverDevices({required this.driver, required this.linked, required this.devices, required this.mmKeys});

  MmForwardKey? get activeMm {
    for (final k in mmKeys) {
      if (k.active) return k;
    }
    return null;
  }

  static DriverDevices? tryParse(Map<String, dynamic> j) {
    final me = AccountDevice.tryParse(j['driver']);
    if (me == null || j['v'] != 1) return null;
    final devices = [if (j['devices'] is List) for (final d in j['devices'] as List) ?AccountDevice.tryParse(d)];
    final mm = j['mm'];
    return DriverDevices(
      driver: me,
      linked: j['linked'] == true,
      devices: devices.isEmpty ? [me] : devices,
      mmKeys: [if (mm is Map && mm['keys'] is List) for (final k in mm['keys'] as List) ?MmForwardKey.tryParse(k)],
    );
  }
}

/// The answer of `driver-key-reveal`. [key] is null when the server holds no viewable copy.
class RevealedKey {
  final String? key;

  /// MeshMapper only: the `meshmapper://custom-api?...` link MeshMapper imports from the clipboard.
  final String? configLink;
  const RevealedKey({this.key, this.configLink});
  bool get revealable => key != null;
}

/// One repeater that answered a ping on the server's record.
class ServerEcho {
  final String repeaterId;
  final String? name;
  final double? snr, rssi;
  const ServerEcho({required this.repeaterId, this.name, this.snr, this.rssi});
}

/// One ping of a drive as the server holds it (the owner's untrimmed view).
class ServerPing {
  final String id;
  final DateTime at;
  final double lat, lon;
  final double? accuracyM;
  final bool heard;
  final List<ServerEcho> echoes;
  const ServerPing({required this.id, required this.at, required this.lat, required this.lon, required this.heard, this.accuracyM, this.echoes = const []});

  static ServerPing? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id'], 64), at = _time(j['at']), lat = _dbl(j['lat']), lon = _dbl(j['lon']);
    if (id == null || at == null || lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
    return ServerPing(
      id: id,
      at: at,
      lat: lat,
      lon: lon,
      accuracyM: _dbl(j['accM']),
      heard: j['heard'] == true,
      echoes: [
        if (j['echoes'] is List)
          for (final e in (j['echoes'] as List).take(40))
            if (e is Map && _str(e['repeaterId'], 80) != null)
              ServerEcho(repeaterId: _str(e['repeaterId'], 80)!, name: _str(e['name'], 80), snr: _dbl(e['snr']), rssi: _dbl(e['rssi'])),
      ],
    );
  }
}

class ServerDriveDetail {
  final ServerDrive drive;
  final List<ServerPing> pings;

  /// Rows the parser could not read.
  final int skipped;
  const ServerDriveDetail({required this.drive, required this.pings, this.skipped = 0});

  /// Pings heard by at least one repeater.
  int get heardCount => pings.where((p) => p.heard).length;

  /// Distinct repeaters across all pings, by id.
  int get repeaterCount => {for (final p in pings) for (final e in p.echoes) e.repeaterId}.length;

  /// The best SNR of any echo, null when none carried one.
  double? get bestSnr {
    double? b;
    for (final p in pings) {
      for (final e in p.echoes) {
        if (e.snr != null && (b == null || e.snr! > b)) b = e.snr;
      }
    }
    return b;
  }

  static ServerDriveDetail? tryParse(Map<String, dynamic> j) {
    final d = ServerDrive.tryParse(j['drive']);
    if (d == null) return null;
    var skipped = 0;
    final pings = <ServerPing>[];
    final raw = j['pings'];
    if (raw is List) {
      for (final p in raw.take(50000)) {
        final x = ServerPing.tryParse(p);
        if (x == null) {
          skipped++;
        } else {
          pings.add(x);
        }
      }
    }
    pings.sort((a, b) => a.at.compareTo(b.at));
    return ServerDriveDetail(drive: d, pings: pings, skipped: skipped);
  }
}

/// One problem report this account filed (the last 90 days). The admin's notes are never sent.
class ReportRow {
  final String id;
  final DateTime createdAt;
  final String status, category, source, summary;
  final String? driveId;
  const ReportRow({required this.id, required this.createdAt, required this.status, required this.category, required this.source, required this.summary, this.driveId});

  /// Plain words for [status].
  String get statusWords => switch (status) {
        'new' => 'Received. The admin has not looked at it yet.',
        'triaged' => 'The admin has read it and is working on it.',
        'closed' => 'Fixed, answered, or not something we can act on.',
        _ => status,
      };

  String get categoryWords => switch (category) {
        'bug' => 'Something is broken',
        'upload' => 'Uploading drives',
        'radio' => 'Radio or Bluetooth',
        'gps' => 'GPS or location',
        'map' => 'Maps and coverage',
        'idea' => 'An idea',
        _ => 'Something else',
      };

  static ReportRow? tryParse(Object? j) {
    if (j is! Map) return null;
    final id = _str(j['id'], 64), at = _time(j['createdAt']);
    if (id == null || at == null) return null;
    return ReportRow(
      id: id,
      createdAt: at,
      status: _str(j['status'], 16) ?? 'new',
      category: _str(j['category'], 16) ?? 'other',
      source: _str(j['source'], 16) ?? 'app',
      summary: _str(j['summary'], 200) ?? '',
      driveId: _str(j['driveId'], 64),
    );
  }

  static List<ReportRow> parseList(Map<String, dynamic> j) =>
      [if (j['reports'] is List) for (final r in j['reports'] as List) ?ReportRow.tryParse(r)];
}

/// What `DELETE driver-delete` removed, as the server counted it.
class DriverDeleteCounts {
  final int sessions, pings, samples, telemetry, weather, reports;
  const DriverDeleteCounts({this.sessions = 0, this.pings = 0, this.samples = 0, this.telemetry = 0, this.weather = 0, this.reports = 0});

  static DriverDeleteCounts parse(Map<String, dynamic> j) {
    final d = j['deleted'];
    if (d is! Map) return const DriverDeleteCounts();
    return DriverDeleteCounts(
      sessions: _int(d['sessions']) ?? 0,
      pings: _int(d['pings']) ?? 0,
      samples: _int(d['samples']) ?? 0,
      telemetry: _int(d['telemetry']) ?? 0,
      weather: _int(d['weather']) ?? 0,
      reports: _int(d['reports']) ?? 0,
    );
  }
}
