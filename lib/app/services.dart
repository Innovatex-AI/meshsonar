// Dependency container for the app. main.dart (via wiring.dart) builds the real one; widget tests build
// one from fakes. Everything here is an abstract contract type or a plain function, so the UI never
// depends on a concrete storage, radio or platform class.
import 'dart:convert';
import 'dart:io';

import '../core/api.dart';
import '../core/model.dart';
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

  final AppInfo appInfo;
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
    required this.newId,
    required this.clock,
    this.appInfo = const AppInfo(name: 'MeshSonar', version: '0.1.0'),
  });
}
