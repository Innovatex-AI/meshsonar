// Contracts between storage/sync (lib/core), radio (lib/radio) and UI (lib/ui).
// Pure Dart. Implementations live next to this file; the UI depends only on these abstract types,
// so it can be built and tested against fakes.
import 'dart:io';

import 'antenna_profile.dart';
import 'model.dart';
import 'region_lookup.dart';
import 'server_url.dart';
import 'units.dart';

/// Per-session numbers for lists.
class SessionSummary {
  final DriveSession session;
  final int pingCount;

  /// tx pings only. Used for the heard-% guard: an all-rx (discovery/listen-only) drive has no tx pings at all, so
  /// "0% heard" would misread as a failed drive rather than a successful listen session (see [lib/ui/drive_stats.
  /// dart]'s `heardPercent`, which already guards on tx pings the same way). Defaults to [pingCount] when not given,
  /// matching every caller's old all-tx assumption.
  final int txCount;

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
    int? txCount,
    required this.heardCount,
    required this.syncedCount,
    this.rejectedCount = 0,
    this.sessionResendPending = false,
  }) : txCount = txCount ?? pingCount;

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

/// Which MeshSonar region a server URL resolves to, from `GET /api/cmh/site-config`. There is no separate
/// human-readable region name on the wire; [url]'s host is the recognisable part to show.
class RegionInfo {
  final String slug;
  final String url;
  const RegionInfo({required this.slug, required this.url});
}

/// A region's suggested MeshCore radio/channel parameters (`GET /api/cmh/site-config`'s `radioPreset`).
/// Informational only: the app only ever reads the connected radio's own live RF parameters off the hardware
/// ([Radio] in model.dart) and never pushes a preset to it — this is a side-by-side comparison, not a control.
class RadioPreset {
  final String name;
  final double freqMhz;
  final double bwKhz;
  final int sf;
  final int cr;
  const RadioPreset({required this.name, required this.freqMhz, required this.bwKhz, required this.sf, required this.cr});
}

/// `GET /api/cmh/site-config`'s region and radio-preset fields. (The endpoint also carries viewerGate,
/// driverRegistration and appLinks; not modeled here, the app doesn't use them.)
class SiteConfig {
  final RegionInfo region;

  /// Null when the region has no suggested preset configured — a real, expected state, not an error.
  final RadioPreset? radioPreset;

  /// What this server accepts beyond the basics (stream 7 server request S1, `site-config.capabilities`). Absent key
  /// = feature absent; no server sends any today. Only boolean flags are kept.
  final Set<String> capabilities;
  const SiteConfig({required this.region, this.radioPreset, this.capabilities = const {}});

  /// The server looks up weather for uploaded drives and serves it (`capabilities.driveEnv`, S1 + S4).
  bool get driveEnv => capabilities.contains('driveEnv');
}

/// The true flags of a `capabilities` object; anything malformed counts as absent.
Set<String> parseCapabilities(Object? raw) => {
      if (raw is Map)
        for (final e in raw.entries)
          if (e.key is String && e.value == true) e.key as String,
    };

/// One measured coverage cell from `GET /api/cmh/public-coverage` — the same cells the website's `/coverage` map
/// draws, network-wide (every driver, not just this phone). A square or an H3 hexagon depending on
/// [PublicCoverage]'s grid. Mirrors meshcore-insights `CoverageCell` (`src/lib/platform/types.ts`) field for
/// field, minus `sources` (the per-source MeshSonar/MeshMapper split): the source filter is out of scope for this
/// pass, so it's left unparsed rather than modeled unused.
class CoverageCell {
  /// Centre of the cell (a square's centre, or an H3 hexagon's centre).
  final double lat;
  final double lon;
  final int pings;
  final int heard;
  final double? bestSnr;
  final double? medianSnr;
  final int repeaters;
  final String lastAt;

  /// Lower-case H3 hex id, present only on the hexagon grid.
  final String? h3;

  /// Mean noise floor (dBm) of the cell's attempts; null with no readings, absent from servers before migration
  /// 0025.
  final double? noiseFloor;
  const CoverageCell({
    required this.lat,
    required this.lon,
    required this.pings,
    required this.heard,
    required this.bestSnr,
    required this.medianSnr,
    required this.repeaters,
    required this.lastAt,
    this.h3,
    this.noiseFloor,
  });
}

/// Which grid [PublicCoverage.cells] sit on. Squares were the only grid before the H3 migration (still the
/// fallback for an older server); [res] (7, 8 or 9) and [pending] (pings not yet assigned an H3 id) are only
/// meaningful for the hexagon grid.
enum CoverageGridKind { square, h3 }

class CoverageGrid {
  final CoverageGridKind kind;

  /// Square side in degrees. Always set (even on the hexagon grid, where it mirrors the wire's legacy top-level
  /// `cellDeg`, unused for drawing) so callers never need a null check just to read it.
  final double cellDeg;

  /// H3 resolution; null on the square grid.
  final int? res;

  /// Pings still waiting for an H3 id; 0 on the square grid.
  final int pending;
  const CoverageGrid.square({required this.cellDeg}) : kind = CoverageGridKind.square, res = null, pending = 0;
  const CoverageGrid.h3({required this.res, required this.cellDeg, this.pending = 0}) : kind = CoverageGridKind.h3;
}

/// `GET /api/cmh/public-coverage` (public, no driver key): network-wide measured coverage cells, the same data the
/// website's `/coverage` page renders. The server also sends `totals` (headline stats); not modeled here, nothing
/// in the app reads it yet (the always-on map layer only needs the cells and the grid).
class PublicCoverage {
  final List<CoverageCell> cells;
  final String asOf;
  final CoverageGrid grid;
  const PublicCoverage({required this.cells, required this.asOf, required this.grid});
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

  /// The server's active region and its suggested radio preset (if any). Public: no driver key needed.
  Future<SiteConfig> siteConfig();

  /// Network-wide measured coverage cells (the website's `/coverage` map data). Public: no driver key needed.
  /// [res] (H3 7..11), [since] (only cells measured after it) and [source] (`all`, `meshsonar`, `meshmapper`) are the
  /// website's own layer filters ([until] = coverage as of that instant, exclusive); all optional, the server defaults apply when omitted.
  Future<PublicCoverage> publicCoverage({int? res, DateTime? since, DateTime? until, String? source});

  /// Every MeshSonar region this server (or federation) knows about (`GET /api/cmh/regions-index`): code, slug,
  /// name, URL, bbox and boundary — used entirely on-device for live, local region awareness (lib/core/
  /// region_lookup.dart), never to decide a ping's region (the server already does that at upload time
  /// regardless of connectivity). Public: no driver key needed.
  Future<List<RegionIndexEntry>> regionsIndex();
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

  /// Discovery / listen-only mode: the next drive transmits nothing at all (not even the `MS:<tag>` ping) and only
  /// records what it overhears. Locked while a drive is active (the UI disables the switch rather than silently
  /// ignoring a mid-drive change) — see [WardriveConfig.listenOnly].
  final bool discoveryMode;

  /// Region the person picked in the switcher (code, e.g. DAY); null = follow the phone's GPS region.
  final String? regionManual;

  /// Last region the app viewed or detected, so a cold start offline shows it instead of a blank.
  final String? regionLast;

  /// Metric / imperial / auto (phone locale).
  final UnitsPreference units;

  /// Per-quantity exceptions to [units] (distance, speed, height, temperature, pressure); empty = all follow it.
  final UnitOverrides unitOverrides;

  /// Share packet headers and radio metrics (never message content) to build the live packet feed. On by default;
  /// this is the opt-out. See lib/core/telemetry.dart.
  final bool telemetryEnabled;

  /// Drive-context categories (lib/core/data_categories.dart ids) the person switched off. Every category is on by
  /// default (opt-out, Andy Oct 2026), so only the off ones are stored, under `collection_off`; ids this version does
  /// not know are kept as they are (a newer app's choice survives a downgrade). Packet headers stay on
  /// [telemetryEnabled].
  final Set<String> collectionOff;

  /// Whether the collection category [id] is switched on (packet headers: [telemetryEnabled]).
  bool collectionOn(String id) => id == 'packet_headers' ? telemetryEnabled : !collectionOff.contains(id);

  /// A copy with category [id] switched [on].
  Settings withCollection(String id, bool on) => id == 'packet_headers'
      ? copyWith(telemetryEnabled: on)
      : copyWith(collectionOff: on ? ({...collectionOff}..remove(id)) : {...collectionOff, id});

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
    this.discoveryMode = false,
    this.regionManual,
    this.regionLast,
    this.units = UnitsPreference.auto,
    this.unitOverrides = const UnitOverrides(),
    this.telemetryEnabled = true,
    this.collectionOff = const {},
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
    bool? discoveryMode,
    String? regionManual,
    bool clearRegionManual = false,
    String? regionLast,
    UnitsPreference? units,
    UnitOverrides? unitOverrides,
    bool? telemetryEnabled,
    Set<String>? collectionOff,
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
        discoveryMode: discoveryMode ?? this.discoveryMode,
        regionManual: clearRegionManual ? null : (regionManual ?? this.regionManual),
        regionLast: regionLast ?? this.regionLast,
        units: units ?? this.units,
        unitOverrides: unitOverrides ?? this.unitOverrides,
        telemetryEnabled: telemetryEnabled ?? this.telemetryEnabled,
        collectionOff: collectionOff ?? this.collectionOff,
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
        'discovery_mode': discoveryMode,
        if (regionManual != null) 'region_manual': regionManual,
        if (regionLast != null) 'region_last': regionLast,
        if (units != UnitsPreference.auto) 'units': units.name,
        if (!unitOverrides.isEmpty) 'unit_overrides': unitOverrides.toJson(),
        if (!telemetryEnabled) 'telemetry_enabled': false,
        if (collectionOff.isNotEmpty) 'collection_off': collectionOff.toList()..sort(),
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
        discoveryMode: j['discovery_mode'] is bool ? j['discovery_mode'] as bool : false,
        regionManual: _str(j['region_manual']),
        regionLast: _str(j['region_last']),
        units: UnitsPreference.parse(j['units']),
        unitOverrides: UnitOverrides.fromJson(j['unit_overrides']),
        telemetryEnabled: j['telemetry_enabled'] is bool ? j['telemetry_enabled'] as bool : true,
        collectionOff: {
          if (j['collection_off'] case final List l)
            for (final v in l)
              if (v is String && v.isNotEmpty) v,
        },
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
