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
import 'package:meshsonar/ui/settings/settings_index.dart';
import 'package:meshsonar/ui/settings/settings_pages.dart';

import 'fakes.dart';

Finder get settingsList =>
    find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;

/// The Settings page (one level down, build 76) that holds the row with widget key [key]; null = on the first level.
String? settingsPageOfKey(String key) {
  for (final e in settingsEntries) {
    if (e.id == key) return e.page;
  }
  if (key.startsWith('battery-mode')) return null;
  for (final (prefix, page) in const [
    ('battery-', 'battery'),
    ('meshtrack-', 'meshtrack'),
    ('collect-', 'sharing'),
    ('mqtt-', 'observer'),
    ('observer-status', 'observer'),
    ('telemetry-location', 'observer'),
    ('telemetry-erase', 'observer'),
    ('storage-', 'storage-items'),
    ('unit-', 'units'),
    ('profile-', 'profile'),
    ('site-', 'account-advanced'),
    ('auto-sync', 'uploads'),
    ('sync-', 'uploads'),
    ('diagnostics-power', 'diagnostics-advanced'),
    ('power-counter', 'diagnostics-advanced'),
    ('ble-diagnostics', 'diagnostics-advanced'),
    ('claim-', 'claims'),
    ('ping-preview', 'driving-advanced'),
    ('wardrive-counters', 'driving-advanced'),
    ('listen-window', 'driving-advanced'),
  ]) {
    if (key.startsWith(prefix)) return page;
  }
  return null;
}

/// Opens Settings page [id] from the first level (going back first when another page is open).
Future<void> openSettingsPageRow(WidgetTester tester, String id) async {
  if (find.byKey(Key('settings-page-$id')).evaluate().isNotEmpty) return;
  if (find.byType(SettingsPageScreen).evaluate().isNotEmpty) {
    await tester.pageBack();
    await tester.pumpAndSettle();
  }
  // The units page opens from a button in the Units row, not from a row of its own.
  final row = find.byKey(Key(id == 'units' ? 'units-per-quantity' : 'page-$id'));
  await tester.scrollUntilVisible(row, 200, scrollable: settingsList);
  await tester.ensureVisible(row);
  await tester.pumpAndSettle();
  await tester.tap(row);
  await tester.pumpAndSettle();
}

/// Back from a Settings page to the first level (no-op when none is open).
Future<void> closeSettingsPage(WidgetTester tester) async {
  if (find.byType(SettingsPageScreen).evaluate().isEmpty) return;
  await tester.pageBack();
  await tester.pumpAndSettle();
}

/// Scrolls [key] into view, clear of the bottom bar. A row that lives on a page one level down opens that page first.
Future<void> showSetting(WidgetTester tester, String key, {double step = 200}) async {
  if (find.byKey(Key(key)).evaluate().isEmpty) {
    final page = settingsPageOfKey(key);
    if (page != null) {
      await openSettingsPageRow(tester, page);
    } else {
      await closeSettingsPage(tester);
    }
  }
  await tester.scrollUntilVisible(find.byKey(Key(key)), step, scrollable: settingsList);
  await tester.ensureVisible(find.byKey(Key(key)));
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
      observerEngineFactory: b.observerEngineFactory,
      planRepository: b.planRepository,
      incomingLinks: b.incomingLinks,
      secretStore: b.secretStore,
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
