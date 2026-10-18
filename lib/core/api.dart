// Contracts between storage/sync (lib/core), radio (lib/radio) and UI (lib/ui).
// Pure Dart. Implementations live next to this file; the UI depends only on these abstract types,
// so it can be built and tested against fakes.
import 'dart:io';

import 'antenna_profile.dart';
import 'model.dart';
import 'server_url.dart';

/// Per-session numbers for lists.
class SessionSummary {
  final DriveSession session;
  final int pingCount;

  /// tx pings with at least one echo or a neighbor exchange.
  final int heardCount;

  /// Pings the server has confirmed (stored or duplicate).
  final int syncedCount;

  /// Pings the server rejected. They stay on the phone and in exports but are never re-sent, so they are not
  /// "waiting to upload".
  final int rejectedCount;

  /// The drive's details (e.g. its name) changed since the server last saw them; the next sync re-sends the session
  /// even if every ping is already uploaded.
  final bool sessionResendPending;
  const SessionSummary({
    required this.session,
    required this.pingCount,
    required this.heardCount,
    required this.syncedCount,
    this.rejectedCount = 0,
    this.sessionResendPending = false,
  });

  /// Pings still waiting to upload (neither confirmed nor rejected).
  int get unsyncedCount {
    final n = pingCount - syncedCount - rejectedCount;
    return n < 0 ? 0 : n;
  }

  /// Whether a sync of this drive would send anything.
  bool get hasSomethingToSync => unsyncedCount > 0 || sessionResendPending;
}

/// Local, crash-safe storage on the device. Every ping is written the moment it's captured.
abstract class DriveStore {
  Future<void> startSession(DriveSession session);

  /// Appends one ping durably (flushed before the future completes).
  Future<void> appendPing(String sessionId, DrivePing ping);
  Future<void> endSession(String sessionId, DateTime endedAt);

  /// Sets the drive's name (null or blank clears it), rewrites the stored session and marks it to be re-sent on the
  /// next sync so the server gets the new name too.
  Future<void> renameSession(String sessionId, String? label);
  Future<DriveSession?> session(String sessionId);

  /// Newest first.
  Future<List<SessionSummary>> sessions();
  Future<List<DrivePing>> pings(String sessionId);
  Future<List<DrivePing>> unsyncedPings(String sessionId);
  Future<void> markSynced(String sessionId, Iterable<String> pingIds);
  Future<void> deleteSession(String sessionId);

  /// Writes one Drive Format v1 file ({format, app, session, pings}) and returns it.
  Future<File> exportSession(String sessionId, AppInfo app, Directory outDir);
}

enum DriverKeyStatus { none, pending, approved, rejected, revoked, unknown }

class KeyRequestResult {
  final String driverId;
  final String key; // shown once by the server; store it
  final DriverKeyStatus status;
  final String display;
  const KeyRequestResult({required this.driverId, required this.key, required this.status, required this.display});
}

class UploadResult {
  final int stored;
  final int duplicate;
  final int rejected;
  final List<String> rejectionReasons;
  const UploadResult({required this.stored, required this.duplicate, required this.rejected, this.rejectionReasons = const []});
}

/// Thrown by CmatClient with the server's reason (HTTP status kept for decisions, e.g. 403 = not approved).
class CmatException implements Exception {
  final int? status;
  final String message;
  const CmatException(this.message, {this.status});
  @override
  String toString() => 'CmatException($status): $message';
}

/// HTTP client for CMAT's MeshSonar endpoints (docs/MESHSONAR_DRIVE_FORMAT.md). Base URL is configurable:
/// any community's server that implements the spec works.
abstract class CmatClient {
  Uri get baseUrl;
  Future<KeyRequestResult> requestKey({required String name, String? callsign, String? email});
  Future<({DriverKeyStatus status, String display})> status(String driverKey);
  Future<UploadResult> upload(String driverKey, DriveBatch batch);
  Future<List<RepeaterRef>> repeaters(String driverKey);

  /// Files a problem report. [body] is the exact JSON text the person reviewed; it is sent byte for byte.
  Future<ProblemReportResult> reportProblem(String driverKey, String body);
}

/// The server's answer to a filed problem report.
class ProblemReportResult {
  final String id;
  final String? status;
  const ProblemReportResult({required this.id, this.status});
}

class SyncReport {
  final int sessions;
  final int stored;
  final int duplicate;
  final int rejected;
  final String? error; // first error, if any session failed
  const SyncReport({this.sessions = 0, this.stored = 0, this.duplicate = 0, this.rejected = 0, this.error});
}

/// Uploads unsynced pings (≤5,000 per request), marks them synced only after the server confirms.
abstract class SyncService {
  Future<SyncReport> syncSession(String sessionId);
  Future<SyncReport> syncAll();
}

/// User settings, persisted as JSON on the device.
class Settings {
  final String serverUrl;
  final String? driverKey;
  final DriverKeyStatus keyStatus;
  final String? display;
  final String channel;

  /// Auto-ping every N seconds while driving (10–120; Ping now works any time).
  final int intervalSec;

  /// Skip an auto-ping if we haven't moved this far since the last one.
  final int minDistanceM;

  /// The one antenna setting of MeshSonar 0.3.x. Kept in the file, read-only, to prefill each radio's first
  /// [antennaProfiles] entry; drives no longer use it.
  final Antenna antenna;

  /// How each radio's antenna is set up, keyed by the companion's public key (lower-case hex). Drives use the
  /// connected radio's profile.
  final Map<String, AntennaProfile> antennaProfiles;

  /// Upload the drive when it ends (if the key is approved).
  final bool autoSync;

  /// Also upload during a drive, every [syncEveryMin] minutes (needs [autoSync]).
  final bool syncDuringDrive;
  final int syncEveryMin;

  /// Keep a repeater "live" in the heard panel/map for this many pings after it was last heard, then grey it out.
  final int heardHoldPings;

  /// Allowed ranges (UI sliders and clamping).
  static const int minIntervalSec = 10, maxIntervalSec = 120;
  static const int minDistance = 15, maxDistance = 500;
  static const int minSyncEveryMin = 1, maxSyncEveryMin = 30;

  const Settings({
    this.serverUrl = defaultServerUrl,
    this.driverKey,
    this.keyStatus = DriverKeyStatus.none,
    this.display,
    this.channel = '#wardriving',
    this.intervalSec = 30,
    this.minDistanceM = 100,
    this.antenna = const Antenna(type: 'internal'),
    this.antennaProfiles = const {},
    this.autoSync = true,
    this.syncDuringDrive = true,
    this.syncEveryMin = 5,
    this.heardHoldPings = 3,
  });

  Settings copyWith({
    String? serverUrl,
    String? driverKey,
    DriverKeyStatus? keyStatus,
    String? display,
    String? channel,
    int? intervalSec,
    int? minDistanceM,
    Map<String, AntennaProfile>? antennaProfiles,
    bool? autoSync,
    bool? syncDuringDrive,
    int? syncEveryMin,
    int? heardHoldPings,
    bool clearKey = false,
  }) =>
      Settings(
        serverUrl: serverUrl ?? this.serverUrl,
        driverKey: clearKey ? null : (driverKey ?? this.driverKey),
        keyStatus: clearKey ? DriverKeyStatus.none : (keyStatus ?? this.keyStatus),
        display: clearKey ? null : (display ?? this.display),
        channel: channel ?? this.channel,
        intervalSec: intervalSec ?? this.intervalSec,
        minDistanceM: minDistanceM ?? this.minDistanceM,
        antenna: antenna, // the 0.3.x setting is read-only: always kept as loaded
        antennaProfiles: antennaProfiles ?? this.antennaProfiles,
        autoSync: autoSync ?? this.autoSync,
        syncDuringDrive: syncDuringDrive ?? this.syncDuringDrive,
        syncEveryMin: syncEveryMin ?? this.syncEveryMin,
        heardHoldPings: heardHoldPings ?? this.heardHoldPings,
      );

  Map<String, dynamic> toJson() => {
        'server_url': serverUrl,
        'driver_key': driverKey,
        'key_status': keyStatus.name,
        'display': display,
        'channel': channel,
        'interval_sec': intervalSec,
        'min_distance_m': minDistanceM,
        'antenna': antenna.toJson(),
        'antenna_profiles': {for (final e in antennaProfiles.entries) e.key: e.value.toJson()},
        'auto_sync': autoSync,
        'sync_during_drive': syncDuringDrive,
        'sync_every_min': syncEveryMin,
        'heard_hold_pings': heardHoldPings,
      };
  factory Settings.fromJson(Map<String, dynamic> j) => Settings(
        serverUrl: _str(j['server_url']) ?? defaultServerUrl,
        driverKey: _str(j['driver_key']),
        keyStatus: DriverKeyStatus.values.firstWhere((s) => s.name == j['key_status'], orElse: () => DriverKeyStatus.none),
        display: _str(j['display']),
        channel: _str(j['channel']) ?? '#wardriving',
        // 0 used to mean "manual only"; auto-ping is now always 10–120 s (Ping now still works any time)
        intervalSec: (_int(j['interval_sec']) ?? 30).clamp(minIntervalSec, maxIntervalSec),
        minDistanceM: (_int(j['min_distance_m']) ?? 100).clamp(minDistance, maxDistance),
        antenna: _antennaFrom(j['antenna']),
        antennaProfiles: _profilesFrom(j['antenna_profiles']),
        autoSync: j['auto_sync'] is bool ? j['auto_sync'] as bool : true,
        syncDuringDrive: j['sync_during_drive'] is bool ? j['sync_during_drive'] as bool : true,
        syncEveryMin: (_int(j['sync_every_min']) ?? 5).clamp(minSyncEveryMin, maxSyncEveryMin),
        heardHoldPings: (_int(j['heard_hold_pings']) ?? 3).clamp(1, 20),
      );

  /// A string field; anything else is null so the default applies.
  static String? _str(Object? v) => v is String ? v : null;

  /// Any JSON number (30 or 30.0) as an int; anything else (missing, text, NaN) is null so the default applies.
  static int? _int(Object? v) => (v is num && v.isFinite) ? v.round() : null;

  /// Antenna type is "internal" or "external"; anything older/unknown becomes internal (the default).
  static Antenna _antennaFrom(Object? raw) {
    Antenna a;
    try {
      a = Antenna.fromJson(raw is Map ? raw.cast<String, dynamic>() : const {});
    } catch (_) {
      a = const Antenna(); // odd values in one field never cost the rest of the settings
    }
    final t = a.type == 'external' ? 'external' : 'internal';
    return Antenna(type: t, gainDbi: a.gainDbi, heightM: a.heightM);
  }

  /// Saved radios with lower-case keys; a profile that doesn't parse is dropped on its own.
  static Map<String, AntennaProfile> _profilesFrom(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if ((e.key, AntennaProfile.tryParse(e.value)) case (final String key, final AntennaProfile p)) key.toLowerCase(): p,
    };
  }
}

abstract class SettingsStore {
  Future<Settings> load();
  Future<void> save(Settings settings);
}
