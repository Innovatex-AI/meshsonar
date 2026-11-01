// Builds the real AppServices from the concrete storage, sync, radio and platform classes.
// This is the only app file that names concrete lib/core and lib/radio classes (see docs/CONTRACTS.md).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/claim_flow.dart' show FileClaimRestoreStore;
import '../core/cmat_client.dart';
import '../core/drive_store.dart';
import '../core/etag_client.dart';
import '../core/gps_health.dart' show BackgroundLocation;
import '../core/idle_region_watcher.dart';
import '../core/position_filter.dart';
import '../core/privacy_zone_store.dart';
import '../core/region_cache.dart';
import '../core/region_lookup.dart';
import '../core/region_stats_api.dart';
import '../core/repeater_directory.dart';
import '../core/repeater_sync.dart';
import '../core/report_draft_store.dart';
import '../core/settings_store.dart';
import '../core/sync_service.dart';
import '../platform/always_location.dart';
import '../platform/app_version.dart';
import '../platform/geolocator_idle_location.dart';
import '../platform/geolocator_location.dart';
import '../platform/location_access.dart';
import '../platform/open_url.dart';
import '../platform/phone_sensors_plus.dart';
import '../chat/store.dart';
import '../platform/chat_database.dart' as chat_db;
import '../platform/secure_storage.dart';
import '../platform/share.dart';
import '../radio/ble_transport.dart';
import '../radio/ble_transport_universal.dart';
import '../radio/companion_link.dart';
import '../radio/radio_api.dart' show NoRadioScanner;
import '../radio/simulator.dart';
import 'build_flags.dart';
import '../radio/wardrive_engine.dart';
import 'services.dart';

String _platformName() {
  if (kIsWeb) return 'web';
  return defaultTargetPlatform.name; // android, iOS, macOS, linux, windows
}

/// Where drives and settings live. App-support is the right place for app data on every platform (on Linux it's
/// `~/.local/share/<app id>`, and it doesn't need the xdg-user-dirs tool that the Documents folder needs, so it also works
/// on minimal desktops). Documents is only a fallback.
Future<Directory> _dataRoot() async {
  Directory base;
  try {
    base = await getApplicationSupportDirectory();
  } catch (_) {
    base = await getApplicationDocumentsDirectory();
  }
  final root = Directory('${base.path}${Platform.pathSeparator}meshsonar');
  await root.create(recursive: true);
  return root;
}

Future<AppServices> buildRealServices() async {
  final root = await _dataRoot();
  Future<ChatStore>? chatStore;

  await BleEngineChoice.load(File('${root.path}${Platform.pathSeparator}ble_engine.txt'));
  final store = await JsonlDriveStore.open(root);
  final settingsStore = FileSettingsStore(File('${root.path}${Platform.pathSeparator}settings.json'));
  // Version comes from the build (pubspec.yaml's `version:`), never a constant here.
  final app = await loadAppInfo(platform: _platformName());
  installSharedEtagClient(Directory('${root.path}${Platform.pathSeparator}etag_cache'));
  const uuid = Uuid();
  // One simulated car: the simulated radio decides which repeaters hear it from the same position the engine records.
  // Only in builds with the Simulator on (lib/app/build_flags.dart); release builds carry none of it.
  final simLocation = simulatorAvailable ? SimulatedLocationSource() : null;
  final realLocation = FilteredLocationSource(GeolocatorLocationSource());

  return AppServices(
    store: store,
    settingsStore: settingsStore,
    cmatClientFactory: (url) => HttpCmatClient(url, client: newCmatWireClient()),
    syncServiceFactory: (client) =>
        DefaultSyncService(store: store, client: client, settings: settingsStore, app: app),
    // The proven engine unless Settings > Diagnostics > Background Bluetooth test switches the experiment on (S1).
    bluetoothScanner: SwitchableRadioScanner(
        reactive: BleRadioScanner(), universal: UniversalBleRadioScanner(), useUniversal: () => BleEngineChoice.universal),
    simulatorScanner: simLocation == null ? const NoRadioScanner() : SimulatedRadioScanner(location: simLocation, ambientTraffic: true),
    linkFactory: (transport) => MeshCoreCompanionLink(transport),
    // Real GPS, cleaned: parked jitter is held still, poor fixes dropped (lib/core/position_filter.dart).
    location: realLocation,
    simulatedLocation: simLocation ?? realLocation,
    engineFactory: (link, location) => DefaultWardriveEngine(link: link, location: location),
    repeaterCache: FileRepeaterCache(File('${root.path}${Platform.pathSeparator}repeaters.json')),
    exportDir: () async {
      final tmp = await getTemporaryDirectory();
      final out = Directory('${tmp.path}${Platform.pathSeparator}meshsonar_export');
      await out.create(recursive: true);
      return out;
    },
    shareFile: shareDriveFile,
    shareFiles: shareDriveFiles,
    openUrl: openExternalUrl,
    appInfo: app,
    uiPrefsFile: File('${root.path}${Platform.pathSeparator}ui_prefs.json'),
    telemetryQueueFile: File('${root.path}${Platform.pathSeparator}telemetry_queue.json'),
    privacyZoneStore: FilePrivacyZoneStore(File('${root.path}${Platform.pathSeparator}privacy_zones.json')),
    claimRestoreStore: FileClaimRestoreStore(File('${root.path}${Platform.pathSeparator}claim_restore.json')),
    // The one problem report that couldn't be sent yet, next to settings.json.
    reportDraftStore: FileReportDraftStore(File('${root.path}${Platform.pathSeparator}report_draft.json')),
    // The public map is ~17 MB; repeaters rarely move, so refresh weekly (or when the drive area moves >75 km).
    directory: RepeaterDirectory(
        cacheFile: File('${root.path}${Platform.pathSeparator}node_directory.json'), ttl: const Duration(days: 7)),
    regionIndexCache: FileRegionIndexCache(File('${root.path}${Platform.pathSeparator}regions_index.json')),
    regionCatalogFetch: (url) async {
      final api = RegionStatsApi(url);
      try {
        return await api.hubRegions();
      } finally {
        api.close();
      }
    },
    idleLocation: GeolocatorIdleLocationSource(),
    lastKnownStore: LastKnownStore(File('${root.path}${Platform.pathSeparator}last_known_fix.json')),
    locationAccess: GeolocatorLocationAccess(),
    backgroundLocation: () async {
      switch (await alwaysLocationState()) {
        case AlwaysLocationState.granted:
          return BackgroundLocation.always;
        case AlwaysLocationState.canUpgrade:
          return BackgroundLocation.whileUsing;
        case AlwaysLocationState.unavailable:
          return BackgroundLocation.unknown;
        case AlwaysLocationState.notApplicable:
          return BackgroundLocation.notApplicable;
      }
    },
    // Region rosters + the network repeater list, stored for offline names and pins (lib/core/repeater_sync.dart).
    repeaterSync: RepeaterSync(store: RepeaterSyncStore(Directory('${root.path}${Platform.pathSeparator}repeater_sync'))),
    regionCache: RegionCache(Directory('${root.path}${Platform.pathSeparator}region_cache')),
    // Drive context sensors (stream 7). The barometer plugin exists on iOS/Android only; elsewhere it is "unsupported".
    barometer: (Platform.isIOS || Platform.isAndroid) ? SensorsPlusBarometer() : null,
    phoneBattery: (Platform.isIOS || Platform.isAndroid) ? BatteryPlusSource() : null,
    deviceDetails: DeviceInfoPlusDetails(appBuild: app.build),
    // Chat: Keychain for channel secrets, SQLite file under Application Support; opened on first use.
    openChatStore: () => chatStore ??= chat_db.openChatStore(KeychainSecretStore()),
    clock: DateTime.now,
    newId: () => uuid.v4(),
  );
}
