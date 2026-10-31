// Contracts between storage/sync (lib/core), radio (lib/radio) and UI (lib/ui).
// Pure Dart. Implementations live next to this file; the UI depends only on these abstract types,
// so it can be built and tested against fakes.
import 'dart:io';

import 'antenna_profile.dart';
import 'colour_palette.dart';
import 'drive_context_wire.dart' show ContextUploadResult, DriveContextBatch;
import 'driver_summary.dart' show DriverSummary;
import 'model.dart';
import 'map_links.dart';
import 'node_claim.dart';
import 'repeater_reach.dart';
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

  /// The `status` word of a 403 body (`rejected`, `revoked`, `banned`, ...), when the server sent one.
  final String? serverStatus;

  /// The `Retry-After` of a 429 / 503, in seconds, when the server sent one.
  final int? retryAfterSec;

  /// The machine `code` of an error body (`no_such_challenge`, `not_owner`, `no_such_claim` ...), when the server sent one.
  final String? code;

  /// The decoded error body, when it was a JSON object.
  final Map<String, dynamic>? body;
  const CmatException(this.message, {this.status, this.serverStatus, this.retryAfterSec, this.code, this.body});
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

  /// Where the numbers come from, when the server says (`published` = MeshCore's own list, `community-observed` =
  /// measured from observers on the open analyzers). Null = the server did not say.
  final String? basis;

  /// The evidence link for [basis], and a free-text note (e.g. which band, how many observers). Both optional.
  final String? source;
  final String? note;
  const RadioPreset(
      {required this.name, required this.freqMhz, required this.bwKhz, required this.sf, required this.cr, this.basis, this.source, this.note});

  /// Same numbers, with the provenance of [other] when this one has none (site-config carries the numbers, `/v1/regions`
  /// the provenance).
  RadioPreset withProvenance(RadioPreset? other) => other == null || other.freqMhz != freqMhz || other.sf != sf
      ? this
      : RadioPreset(
          name: name, freqMhz: freqMhz, bwKhz: bwKhz, sf: sf, cr: cr, basis: basis ?? other.basis, source: source ?? other.source, note: note ?? other.note);
}

/// Why a region has no radio preset on file, as the server stores it (`regions.settings.radio_preset_none`): a
/// researched country where a published frequency would be a guess or may be illegal. Shown as written.
class PresetNone {
  final String reason;
  final String? source;
  const PresetNone({required this.reason, this.source});

  static PresetNone? tryParse(Object? j) {
    if (j is! Map) return null;
    final reason = j['reason'];
    if (reason is! String || reason.trim().isEmpty) return null;
    final src = j['source'];
    return PresetNone(reason: reason.trim(), source: src is String && src.isNotEmpty ? src : null);
  }
}

/// `GET /api/cmh/site-config`'s region and radio-preset fields. (The endpoint also carries viewerGate,
/// driverRegistration and appLinks; not modeled here, the app doesn't use them.)
class SiteConfig {
  final RegionInfo region;

  /// Null when the region has no suggested preset configured — a real, expected state, not an error.
  final RadioPreset? radioPreset;

  /// Why there is no preset (`radioPresetNone`), when the server says. Only meaningful with a null [radioPreset].
  final PresetNone? radioPresetNone;

  /// The region's IANA time zone (`timezone`, e.g. `America/New_York`), when the server sends it. The server buckets a
  /// region's days in this zone.
  final String? timezone;

  /// What this server accepts beyond the basics (`site-config.capabilities`). Absent key = feature absent (an older
  /// server sends none). Only boolean `true` flags are kept here; the format lists are in [driveFormats] and
  /// [telemetryFormats].
  final Set<String> capabilities;

  /// `capabilities.driveFormats`: the drive upload format ids this server accepts (e.g. `meshsonar.drive.v1.2`).
  /// Empty = not advertised (an older server): the app then sends the baseline format only.
  final List<String> driveFormats;

  /// `capabilities.telemetryFormats`.
  final List<String> telemetryFormats;
  const SiteConfig({
    required this.region,
    this.radioPreset,
    this.radioPresetNone,
    this.timezone,
    this.capabilities = const {},
    this.driveFormats = const [],
    this.telemetryFormats = const [],
  });

  /// The server looks up weather for uploaded drives and serves it (`capabilities.driveEnv`).
  bool get driveEnv => capabilities.contains('driveEnv');

  /// `DELETE /api/cmh/drive-context` exists (`capabilities.driveContextErase`).
  bool get driveContextErase => capabilities.contains('driveContextErase');

  /// The server accepts Drive Format v1.2 (drive context: sensors, radio health, device).
  bool get acceptsDriveV12 => driveFormats.contains(driveFormatV12);

  /// `GET network-repeaters?updated_since=` (`capabilities.networkRepeatersDelta`).
  bool get networkRepeatersDelta => capabilities.contains('networkRepeatersDelta');

  /// `GET driver-summary` (`capabilities.driverSummary`).
  bool get driverSummary => capabilities.contains('driverSummary');

  /// `repeater-reach` accepts `x-driver-key` (`capabilities.reachDriverKey`).
  bool get reachDriverKey => capabilities.contains('reachDriverKey');
  /// `cell-links` accepts `x-driver-key` (`capabilities.cellLinks`): the repeaters heard in one cell.
  bool get cellLinks => capabilities.contains('cellLinks');

  /// Radio claims (`capabilities.nodeClaims`): `claim-start`, `claim-complete`, `claim-status`, `my-radios`, `claim`.
  /// A claim only manages a radio; it never decides whether its data counts.
  bool get nodeClaims => capabilities.contains('nodeClaims');
  /// `repeater-reach` can answer in H3 cells (`res=7..11`): the finest cells the server stores, one per hexagon.
  bool get reachH3 => capabilities.contains('reachH3');
  bool get rfWindow => capabilities.contains('rfWindow');
  bool get snrDaily => capabilities.contains('snrDaily');
}

/// The non-empty list of format id strings under [key] of a `capabilities` object; malformed = empty.
List<String> parseCapabilityList(Object? raw, String key) {
  if (raw is! Map) return const [];
  final v = raw[key];
  if (v is! List) return const [];
  return [for (final e in v) if (e is String && e.isNotEmpty && e.length <= 64) e];
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
  ///
  /// [slugs] asks for just those regions at full outline detail (`?slug=a,b`); without it the whole list comes back with
  /// outlines thinned to about 300 m.
  Future<List<RegionIndexEntry>> regionsIndex({List<String>? slugs});

  /// `DELETE /api/cmh/drive-context?category=<id>` (`capabilities.driveContextErase`): erases the server's copy of one
  /// drive-context category (or `all`) for every drive of this driver. Idempotent. Throws [CmatException].
  Future<ContextEraseResult> deleteDriveContext(String driverKey, String category);

  /// `GET /api/cmh/drive-env?session=<uuid>` (`capabilities.driveEnv`): server-side weather for the driver's own
  /// drive. Throws [CmatException] (404 = the server does not know that drive).
  Future<DriveEnv> driveEnv(String driverKey, String sessionId);

  /// `POST /api/cmh/drive-context` (`capabilities.driveFormats` lists v1.2): context for a drive this driver already
  /// uploaded (per-ping `ctx`, `samples`). Same rules as a v1.2 upload. Throws [CmatException] (404 = the server does
  /// not know that drive).
  Future<ContextUploadResult> uploadDriveContext(String driverKey, DriveContextBatch batch);

  /// `GET /api/cmh/driver-summary` (`capabilities.driverSummary`): the account's history across phones and installs.
  /// Throws [CmatException] (401 unknown key, 403 not allowed with [CmatException.serverStatus], 429 pause).
  Future<DriverSummary> driverSummary(String driverKey) => throw const CmatException('not supported by this client');

  /// `GET /api/cmh/repeater-reach?key=&lat=&lon=` with an approved driver key (`capabilities.reachDriverKey`): where
  /// all MeshSonar drivers (public drives, trimmed) heard one repeater. [lat]/[lon] are the REPEATER's position (never
  /// the phone's). Throws [CmatException] (401 unknown key, 403 not approved, 429 limit). Default: not supported.
  /// [h3] asks for the hexagon shape (`capabilities.reachH3`) at the finest resolution.
  Future<RepeaterReach> repeaterReach(String driverKey, String repeaterKey, {double? lat, double? lon, bool h3 = false}) =>
      throw const CmatException('not supported by this client');

  /// `GET /api/cmh/cell-links?h3=<id>` with an approved driver key (`capabilities.cellLinks`): the repeaters heard in
  /// one coverage cell (public drives, trimmed), with pings and SNR. Throws [CmatException] (401, 403, 429).
  /// Default: not supported.
  Future<CellLinks> cellLinks(String driverKey, String h3) => throw const CmatException('not supported by this client');

  /// `POST /api/cmh/claim-start` (`capabilities.nodeClaims`): asks for a challenge to claim [pubkey] (64 hex, lower
  /// case). kind sign: bytes for the radio to sign (2 min); kind advert: a short code for the repeater's name (15 min).
  /// Throws [CmatException] (409 someone else's pending claim, 400, 401, 403, 429). Default: not supported.
  Future<ClaimChallenge> claimStart(String driverKey, String pubkey, ClaimKind kind) =>
      throw const CmatException('not supported by this client');

  /// `POST /api/cmh/claim-complete` (sign challenges): the 128-hex Ed25519 signature. Throws [CmatException]
  /// (400 malformed, 410 expired or used, 422 signature does not match).
  Future<NodeClaim> claimComplete(String driverKey, String challengeId, String signatureHex) =>
      throw const CmatException('not supported by this client');

  /// `GET /api/cmh/claim-status?challengeId=`: whether the server has seen the code in an advert.
  Future<ClaimStatus> claimStatus(String driverKey, String challengeId) =>
      throw const CmatException('not supported by this client');

  /// `GET /api/cmh/my-radios`: the radios this driver key has claimed.
  Future<List<NodeClaim>> myRadios(String driverKey) => throw const CmatException('not supported by this client');

  /// `DELETE /api/cmh/claim?pubkey=`: gives the radio up (its data stays and keeps counting).
  Future<void> releaseClaim(String driverKey, String pubkey) => throw const CmatException('not supported by this client');

  /// `PATCH /api/cmh/claim`: changes only the keys in [changes] (`displayName`, `positionPublic`, `notes`); a null
  /// value clears that field. Returns the updated claim.
  Future<NodeClaim> updateClaim(String driverKey, String pubkey, Map<String, Object?> changes) =>
      throw const CmatException('not supported by this client');
}

/// The server's answer to a drive-context erase.
class ContextEraseResult {
  final String category;
  final int sessions;
  final int pings;
  final int samples;
  const ContextEraseResult({required this.category, this.sessions = 0, this.pings = 0, this.samples = 0});
}

enum DriveEnvStatus { ready, pending, disabled, unavailable }

/// One hour of server-side weather for a drive (Open-Meteo, ~5 km model value, not a measurement at the driver).
/// Every value null = the source gave none.
class WeatherSnapshot {
  final DateTime at; // UTC hour
  final double? temperatureC;
  final double? humidityPct;
  final double? dewPointC;

  /// Station (surface) pressure, comparable to the phone barometer.
  final double? pressureHpa;
  final double? precipMm;
  final double? cloudPct;
  final double? windMs;
  final double? windDirDeg;
  const WeatherSnapshot({
    required this.at,
    this.temperatureC,
    this.humidityPct,
    this.dewPointC,
    this.pressureHpa,
    this.precipMm,
    this.cloudPct,
    this.windMs,
    this.windDirDeg,
  });
}

/// `GET drive-env`. [attribution] must be shown wherever the values are shown (CC BY 4.0).
class DriveEnv {
  final String session;
  final DriveEnvStatus status;
  final String attribution;
  final List<WeatherSnapshot> snapshots;
  const DriveEnv({required this.session, required this.status, required this.attribution, this.snapshots = const []});
}

/// The credit line Open-Meteo's licence requires wherever its data is shown (also in About).
const String openMeteoCredit = 'Weather data by Open-Meteo.com (CC BY 4.0)';

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

  /// Drive context (Drive Format v1.2), counted separately from pings. Samples: newly stored / already on the server /
  /// refused by the server's validator. Pings: context attached to pings the server already had / pings whose context
  /// the server refused. [contextFallbacks] = drives whose v1.2 upload was refused as a whole and went up as the plain
  /// drive instead (the drive is never lost; its context is tried again next time).
  final int samplesStored;
  final int samplesDuplicate;
  final int samplesRejected;
  final int contextPingsUpdated;
  final int contextRejected;
  final int contextFallbacks;

  /// Set when the server asked the app to slow down (HTTP 429 / 503): seconds to wait, from `Retry-After` or a default.
  final int? retryAfterSec;
  const SyncReport({
    this.sessions = 0,
    this.stored = 0,
    this.duplicate = 0,
    this.rejected = 0,
    this.error,
    this.samplesStored = 0,
    this.samplesDuplicate = 0,
    this.samplesRejected = 0,
    this.contextPingsUpdated = 0,
    this.contextRejected = 0,
    this.contextFallbacks = 0,
    this.retryAfterSec,
  });

  /// True when anything about the drive context happened or went wrong in this sync.
  bool get hasContextActivity =>
      samplesStored + samplesDuplicate + samplesRejected + contextPingsUpdated + contextRejected + contextFallbacks > 0;
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

  /// Create a driver key by itself when this phone has none and the server issues keys openly. Turned off when the
  /// person removes their key, so it never comes back unasked; the request form turns it on again.
  final bool autoKey;

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

  /// Map: write each repeater's name next to its marker (the "Repeater names" map layer). On by default; the layers
  /// sheet switch persists here.
  final bool mapRepeaterLabels;

  /// Which colour set signal strength is drawn in (standard / colour-blind safe / high contrast). Default standard;
  /// written to settings.json only when changed, so an older file reads as standard.
  final ColourPalette colourPalette;

  /// Drive-context categories (lib/core/data_categories.dart ids) the person switched off. Every category is on by
  /// default (opt-out, Andy Oct 2026), so only the off ones are stored, under `collection_off`; ids this version does
  /// not know are kept as they are (a newer app's choice survives a downgrade). Packet headers stay on
  /// [telemetryEnabled].
  final Set<String> collectionOff;

  /// Whether the collection category [id] is switched on (packet headers: [telemetryEnabled]).
  /// Drive-context categories (or `all`) whose erase on the server was asked for but has not gone through yet (offline,
  /// rate limit). Retried automatically; written only when non-empty so a default settings.json is unchanged.
  final Set<String> contextErasePending;

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
    this.autoKey = true,
    this.syncDuringDrive = true,
    this.syncEveryMin = 5,
    this.heardHoldPings = 3,
    this.discoveryMode = false,
    this.regionManual,
    this.regionLast,
    this.units = UnitsPreference.auto,
    this.unitOverrides = const UnitOverrides(),
    this.telemetryEnabled = true,
    this.mapRepeaterLabels = true,
    this.colourPalette = ColourPalette.standard,
    this.collectionOff = const {},
    this.contextErasePending = const {},
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
    bool? autoKey,
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
    bool? mapRepeaterLabels,
    ColourPalette? colourPalette,
    Set<String>? collectionOff,
    Set<String>? contextErasePending,
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
        autoKey: autoKey ?? this.autoKey,
        syncDuringDrive: syncDuringDrive ?? this.syncDuringDrive,
        syncEveryMin: syncEveryMin ?? this.syncEveryMin,
        heardHoldPings: heardHoldPings ?? this.heardHoldPings,
        discoveryMode: discoveryMode ?? this.discoveryMode,
        regionManual: clearRegionManual ? null : (regionManual ?? this.regionManual),
        regionLast: regionLast ?? this.regionLast,
        units: units ?? this.units,
        unitOverrides: unitOverrides ?? this.unitOverrides,
        telemetryEnabled: telemetryEnabled ?? this.telemetryEnabled,
        mapRepeaterLabels: mapRepeaterLabels ?? this.mapRepeaterLabels,
        colourPalette: colourPalette ?? this.colourPalette,
        collectionOff: collectionOff ?? this.collectionOff,
        contextErasePending: contextErasePending ?? this.contextErasePending,
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
        'auto_key': autoKey,
        'sync_during_drive': syncDuringDrive,
        'sync_every_min': syncEveryMin,
        'heard_hold_pings': heardHoldPings,
        'discovery_mode': discoveryMode,
        if (regionManual != null) 'region_manual': regionManual,
        if (regionLast != null) 'region_last': regionLast,
        if (units != UnitsPreference.auto) 'units': units.name,
        if (!unitOverrides.isEmpty) 'unit_overrides': unitOverrides.toJson(),
        if (!telemetryEnabled) 'telemetry_enabled': false,
        if (!mapRepeaterLabels) 'map_repeater_labels': false,
        if (colourPalette != ColourPalette.standard) 'colour_palette': colourPalette.id,
        if (collectionOff.isNotEmpty) 'collection_off': collectionOff.toList()..sort(),
        if (contextErasePending.isNotEmpty) 'context_erase_pending': contextErasePending.toList()..sort(),
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
        autoKey: j['auto_key'] is bool ? j['auto_key'] as bool : true,
        syncDuringDrive: j['sync_during_drive'] is bool ? j['sync_during_drive'] as bool : true,
        syncEveryMin: (_int(j['sync_every_min']) ?? 5).clamp(minSyncEveryMin, maxSyncEveryMin),
        heardHoldPings: (_int(j['heard_hold_pings']) ?? 3).clamp(1, 20),
        discoveryMode: j['discovery_mode'] is bool ? j['discovery_mode'] as bool : false,
        regionManual: _str(j['region_manual']),
        regionLast: _str(j['region_last']),
        units: UnitsPreference.parse(j['units']),
        unitOverrides: UnitOverrides.fromJson(j['unit_overrides']),
        telemetryEnabled: j['telemetry_enabled'] is bool ? j['telemetry_enabled'] as bool : true,
        mapRepeaterLabels: j['map_repeater_labels'] is bool ? j['map_repeater_labels'] as bool : true,
        colourPalette: ColourPalette.parse(j['colour_palette']),
        collectionOff: {
          if (j['collection_off'] case final List l)
            for (final v in l)
              if (v is String && v.isNotEmpty) v,
        },
        contextErasePending: {
          if (j['context_erase_pending'] case final List l)
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
