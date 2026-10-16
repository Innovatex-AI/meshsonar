// Builds the real AppServices from the concrete storage, sync, radio and platform classes.
// This is the only app file that names concrete lib/core and lib/radio classes (see docs/CONTRACTS.md).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../core/cmat_client.dart';
import '../core/drive_store.dart';
import '../core/position_filter.dart';
import '../core/model.dart';
import '../core/repeater_directory.dart';
import '../core/settings_store.dart';
import '../core/sync_service.dart';
import '../platform/geolocator_location.dart';
import '../platform/share.dart';
import '../radio/ble_transport.dart';
import '../radio/companion_link.dart';
import '../radio/simulator.dart';
import '../radio/wardrive_engine.dart';
import 'services.dart';

const String appVersion = '0.2.0'; // keep in step with pubspec.yaml

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

  final store = await JsonlDriveStore.open(root);
  final settingsStore = FileSettingsStore(File('${root.path}${Platform.pathSeparator}settings.json'));
  final app = AppInfo(name: 'MeshSonar', version: appVersion, platform: _platformName());
  const uuid = Uuid();
  // One simulated car: the simulated radio decides which repeaters hear it from the same position the engine records.
  final simLocation = SimulatedLocationSource();

  return AppServices(
    store: store,
    settingsStore: settingsStore,
    cmatClientFactory: (url) => HttpCmatClient(url),
    syncServiceFactory: (client) =>
        DefaultSyncService(store: store, client: client, settings: settingsStore, app: app),
    bluetoothScanner: BleRadioScanner(),
    simulatorScanner: SimulatedRadioScanner(location: simLocation),
    linkFactory: (transport) => MeshCoreCompanionLink(transport),
    // Real GPS, cleaned: parked jitter is held still, poor fixes dropped (lib/core/position_filter.dart).
    location: FilteredLocationSource(GeolocatorLocationSource()),
    simulatedLocation: simLocation,
    engineFactory: (link, location) => DefaultWardriveEngine(link: link, location: location),
    repeaterCache: FileRepeaterCache(File('${root.path}${Platform.pathSeparator}repeaters.json')),
    exportDir: () async {
      final tmp = await getTemporaryDirectory();
      final out = Directory('${tmp.path}${Platform.pathSeparator}meshsonar_export');
      await out.create(recursive: true);
      return out;
    },
    shareFile: shareDriveFile,
    appInfo: app,
    uiPrefsFile: File('${root.path}${Platform.pathSeparator}ui_prefs.json'),
    // The public map is ~17 MB; repeaters rarely move, so refresh weekly (or when the drive area moves >75 km).
    directory: RepeaterDirectory(
        cacheFile: File('${root.path}${Platform.pathSeparator}node_directory.json'), ttl: const Duration(days: 7)),
    clock: DateTime.now,
    newId: () => uuid.v4(),
  );
}
