// Shared helpers for the Settings restructure tests (stream 6): a harness with real on-disk caches in a temp folder,
// a telemetry-capable client, and scrolling helpers for the settings list.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/region_cache.dart';
import 'package:meshsonar/core/repeater_directory.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/ui/app.dart';

import 'fakes.dart';

Finder get settingsList =>
    find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;

/// Scrolls [key] into view, clear of the bottom bar.
Future<void> showSetting(WidgetTester tester, String key, {double step = 200}) async {
  await tester.scrollUntilVisible(find.byKey(Key(key)), step, scrollable: settingsList);
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

Future<void> openSettingsTab(WidgetTester tester) async {
  await tester.tap(find.text('Settings'));
  await tester.pumpAndSettle();
}

/// Lets real file I/O (temp folders) finish, then settles the UI. Each awaited file call needs the real event loop
/// once and then a pump to deliver its result, so this alternates the two a number of times.
Future<void> settleIo(WidgetTester tester, {int rounds = 25, bool Function()? until}) async {
  // With [until], keep going (up to 20x the rounds) until it holds: under a loaded full-suite run file calls are slow.
  final limit = until == null ? rounds : rounds * 20;
  for (var i = 0; i < limit; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    if (until != null && i >= rounds && until()) break;
  }
  await tester.pumpAndSettle();
}

class TeleClient extends FakeCmatClient implements TelemetryTransport {
  TeleClient(super.baseUrl);
  int deletes = 0;
  @override
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body) async =>
      const TelemetryHttpResult(200, body: {'stored': 1});

  @override
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey) async {
    deletes++;
    return const TelemetryHttpResult(200, body: {'deleted': 7});
  }
}

/// [Harness] plus a real region cache and public node map file in [dir], and a client that can erase telemetry.
class DiskHarness extends Harness {
  final Directory dir;
  DiskHarness(this.dir);

  late final RegionCache regionCache = RegionCache(Directory('${dir.path}/region_cache'));
  late final File nodeMapFile = File('${dir.path}/node_directory.json');
  // Fixed clock and a long TTL: the seeded map is never "stale", so no test reaches for the network.
  late final RepeaterDirectory nodeMap =
      RepeaterDirectory(cacheFile: nodeMapFile, clock: () => DateTime.utc(2026, 10, 16, 18), ttl: const Duration(days: 3650));

  @override
  FakeCmatClient newClient(Uri u) => TeleClient(u);

  TeleClient get tele => state.client as TeleClient;

  @override
  AppServices buildServices() {
    final b = super.buildServices();
    return AppServices(
      store: b.store,
      settingsStore: b.settingsStore,
      cmatClientFactory: b.cmatClientFactory,
      syncServiceFactory: b.syncServiceFactory,
      bluetoothScanner: b.bluetoothScanner,
      simulatorScanner: b.simulatorScanner,
      linkFactory: b.linkFactory,
      location: b.location,
      simulatedLocation: b.simulatedLocation,
      engineFactory: b.engineFactory,
      repeaterCache: b.repeaterCache,
      exportDir: b.exportDir,
      shareFile: b.shareFile,
      openUrl: b.openUrl,
      newId: b.newId,
      clock: b.clock,
      regionIndexCache: b.regionIndexCache,
      regionCache: regionCache,
      directory: nodeMap,
    );
  }

  /// init() reads real files, so it runs outside the test's fake clock.
  Future<void> pumpDiskApp(WidgetTester tester) async {
    await tester.runAsync(state.init);
    await tester.pumpWidget(MeshSonarApp(state: state));
    await tester.pump();
  }

  /// Writes a small node map cache file (the shape RepeaterDirectory.load reads).
  void seedNodeMap() {
    nodeMapFile.parent.createSync(recursive: true);
    nodeMapFile.writeAsStringSync(jsonEncode({
      'fetched_at': '2026-10-16T17:00:00Z',
      'center': {'lat': 40.0, 'lon': -83.0},
      'radius_km': 150,
      'total_nodes': 1,
      'source': 'test',
      'repeaters': [
        {'key': 'aa11', 'name': 'Hilltop', 'lat': 40.1, 'lon': -83.1},
      ],
    }));
  }
}
