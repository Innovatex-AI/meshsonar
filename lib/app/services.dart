// Dependency container for the app. main.dart (via wiring.dart) builds the real one; widget tests build
// one from fakes. Everything here is an abstract contract type or a plain function, so the UI never
// depends on a concrete storage, radio or platform class.
import 'dart:convert';
import 'dart:io';

import '../core/api.dart';
import '../core/model.dart';
import '../core/phone_sensors.dart';
import '../core/idle_region_watcher.dart';
import '../core/region_cache.dart';
import '../core/region_lookup.dart';
import '../core/region_stats_api.dart' show HubRegions;
import '../core/repeater_directory.dart';
import '../core/repeater_sync.dart';
import '../core/startup_location.dart';
import '../core/report_draft_store.dart';
import '../radio/radio_api.dart';

/// Local cache of CMAT's repeater list, so names show with no signal.
abstract class RepeaterCache {
  Future<List<RepeaterRef>> load();
  Future<void> save(List<RepeaterRef> repeaters);
}

/// JSON file cache (one array of RepeaterRef).
class FileRepeaterCache implements RepeaterCache {
  final File file;
  FileRepeaterCache(this.file);

  @override
  Future<List<RepeaterRef>> load() async {
    try {
      if (!await file.exists()) return const [];
      final raw = jsonDecode(await file.readAsString());
      if (raw is! List) return const [];
      return raw.map((e) => RepeaterRef.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return const []; // a damaged cache only costs names; never block the app on it
    }
  }

  @override
  Future<void> save(List<RepeaterRef> repeaters) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(repeaters.map((r) => r.toJson()).toList()), flush: true);
    await tmp.rename(file.path);
  }
}

/// In-memory cache (tests, or when no file system is wanted).
class MemoryRepeaterCache implements RepeaterCache {
  List<RepeaterRef> items;
  MemoryRepeaterCache([this.items = const []]);
  @override
  Future<List<RepeaterRef>> load() async => items;
  @override
  Future<void> save(List<RepeaterRef> repeaters) async => items = List.of(repeaters);
}

Future<bool> _noBrowser(Uri url) async => false;

class AppServices {
  final DriveStore store;
  final SettingsStore settingsStore;

  /// Builds a CMAT client for the configured server URL (rebuilt when the user changes it).
  final CmatClient Function(Uri baseUrl) cmatClientFactory;

  /// Builds the sync service for a client (the sync service is tied to one server).
  final SyncService Function(CmatClient client) syncServiceFactory;

  final RadioScanner bluetoothScanner;
  final RadioScanner simulatorScanner;

  /// Wraps a connected transport in the companion protocol (MeshCoreCompanionLink in the real app).
  final CompanionLink Function(ByteTransport transport) linkFactory;

  /// Real GPS.
  final LocationSource location;

  /// Fake GPS used with the simulated radio.
  final LocationSource simulatedLocation;

  final WardriveEngine Function(CompanionLink link, LocationSource location) engineFactory;
  final RepeaterCache repeaterCache;

  /// Where export files are written before sharing.
  final Future<Directory> Function() exportDir;

  /// Opens the platform share sheet for a file.
  final Future<void> Function(File file) shareFile;

  /// Opens the share sheet once for several files (a long drive exported in parts). Null = [shareFile] for each.
  final Future<void> Function(List<File> files)? shareFiles;

  /// Opens a web page in the browser (url_launcher in the real app). Returns false if nothing could open it.
  final Future<bool> Function(Uri url) openUrl;

  /// Name, version and build (from the build via package_info_plus) and platform.
  final AppInfo appInfo;

  /// Where the one unsent problem report is kept. Null = keep it in memory only.
  final ReportDraftStore? reportDraftStore;

  /// Small JSON file for UI-only preferences (first-run intro seen, drive names). Null = keep them in memory only.
  final File? uiPrefsFile;

  /// Where the unsent telemetry headers wait (lib/core/telemetry_uploader.dart). Null = memory only.
  final File? telemetryQueueFile;

  /// Local cache of the last-fetched regions-index (live region awareness). Null = in-memory only for this run
  /// (tests; AppState falls back to a [MemoryRegionIndexCache]).
  final RegionIndexCache? regionIndexCache;

  /// Reads the hub's region catalogue (`/v1/regions`: groups, each region's radio preset with its provenance, and the
  /// reason when there is none). Null = not fetched (tests).
  final Future<HubRegions> Function(String serverUrl)? regionCatalogFetch;

  /// Disk cache (ETag/LRU) for per-region site-config and coverage, with offline/as-of labels. Null = no caching.
  final RegionCache? regionCache;

  /// Low-power GPS for region detection while not driving, and the persisted last-known fix. Null = off (tests).
  final IdleLocationSource? idleLocation;
  final LastKnownStore? lastKnownStore;

  /// Reads location permission without prompting (and asks only when the person taps). Null = not shown (tests).
  final LocationAccessProbe? locationAccess;

  /// Region roster + network repeater list sync with its on-disk store. Null = off (tests).
  final RepeaterSync? repeaterSync;

  /// Phone sensors for the drive context (stream 7, lib/platform/phone_sensors_plus.dart). Null = this phone/build
  /// has none (tests, desktop): the category says so and nothing is read.
  final BarometerSource? barometer;
  final PhoneBatterySource? phoneBattery;
  final DeviceDetailsSource? deviceDetails;

  final DateTime Function() clock;
  final String Function() newId;

  const AppServices({
    required this.store,
    required this.settingsStore,
    required this.cmatClientFactory,
    required this.syncServiceFactory,
    required this.bluetoothScanner,
    required this.simulatorScanner,
    required this.linkFactory,
    required this.location,
    required this.simulatedLocation,
    required this.engineFactory,
    required this.repeaterCache,
    required this.exportDir,
    required this.shareFile,
    this.shareFiles,
    required this.newId,
    required this.clock,
    this.openUrl = _noBrowser,
    this.appInfo = const AppInfo(name: 'MeshSonar'),
    this.uiPrefsFile,
    this.telemetryQueueFile,
    this.directory,
    this.reportDraftStore,
    this.regionIndexCache,
    this.regionCatalogFetch,
    this.regionCache,
    this.idleLocation,
    this.lastKnownStore,
    this.locationAccess,
    this.repeaterSync,
    this.barometer,
    this.phoneBattery,
    this.deviceDetails,
  });

  /// Public node directory (map.meshcore.io) for names/positions CMAT doesn't know. Null = not used (tests).
  final RepeaterDirectory? directory;
}
