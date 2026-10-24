// Idle region detection wired into AppState (WP-R4): while not driving, fixes from the idle stream move the region
// tracker; same preset notifies and switches the view, a different preset prompts; the radio is never touched.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/app/services.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/idle_region_watcher.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/radio/radio_api.dart';

import 'fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
const day = RegionIndexEntry(code: 'DAY', slug: 'day', name: 'Dayton, US', url: 'https://day.meshsonar.com', bbox: [-84.5, 39.5, -83.6, 40.2]);

class _Idle implements IdleLocationSource {
  final ctl = StreamController<GeoFix>.broadcast();
  int subs = 0;
  @override
  Stream<GeoFix> fixes({required bool background}) {
    subs++;
    return ctl.stream;
  }

  @override
  Future<bool> hasAlways() async => false;
  @override
  Future<bool> permitted() async => true;
}

class _MemStore extends LastKnownStore {
  GeoFix? saved;
  _MemStore() : super(File('/nonexistent/none.json'));
  @override
  Future<GeoFix?> load() async => null;
  @override
  Future<void> save(GeoFix fix) async => saved = fix;
}

class _IdleHarness extends Harness {
  final idle = _Idle();
  final lastKnown = _MemStore();
  final bool differentPreset;
  _IdleHarness({this.differentPreset = false});
  @override
  FakeCmatClient newClient(Uri u) => FakeCmatClient(u)
    ..siteConfigResult = SiteConfig(
        region: RegionInfo(slug: 'day', url: 'https://day.meshsonar.com'),
        radioPreset: differentPreset ? const RadioPreset(name: 'Narrow', freqMhz: 869.618, bwKhz: 62.5, sf: 8, cr: 8) : const RadioPreset(name: 'Same', freqMhz: 910.525, bwKhz: 62.5, sf: 7, cr: 5));

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
      openUrl: b.openUrl,
      repeaterCache: b.repeaterCache,
      exportDir: b.exportDir,
      shareFile: b.shareFile,
      clock: b.clock,
      newId: b.newId,
      regionIndexCache: b.regionIndexCache,
      idleLocation: idle,
      lastKnownStore: lastKnown,
    );
  }
}

GeoFix at(int n, double lat, double lon) => GeoFix(lat: lat, lon: lon, at: DateTime.utc(2026, 10, 24, 12).add(Duration(minutes: n)));

void main() {
  testWidgets('same preset: idle movement into another region notifies and the view follows; position is persisted', (tester) async {
    final h = _IdleHarness();
    h.client.regionsIndexResult = const [cmh, day];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    expect(h.state.currentRegion?.code, 'CMH');
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    expect(h.idle.subs, 1);

    for (var i = 0; i < 3; i++) {
      h.idle.ctl.add(at(i, 39.9, -84.0 - i * 0.01));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(h.state.currentRegion?.code, 'DAY');
    await tester.pump(const Duration(milliseconds: 100));
    expect(h.state.viewingRegion?.code, 'DAY');
    expect(h.state.presetPrompt, isNull);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Entered Dayton, US'), findsOneWidget);
    expect(h.lastKnown.saved?.lon, closeTo(-84.02, 1e-9));
    await tester.pumpAndSettle();
  });

  testWidgets('different preset: the view is held and a prompt is raised; nothing is switched silently', (tester) async {
    final h = _IdleHarness(differentPreset: true);
    h.client.regionsIndexResult = const [cmh, day];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    for (var i = 0; i < 3; i++) {
      h.idle.ctl.add(at(i, 39.9, -84.0 - i * 0.01));
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(h.state.currentRegion?.code, 'DAY');
    expect(h.state.presetPrompt, isNotNull);
    expect(h.state.viewingRegion?.code, 'CMH');
    await tester.pumpAndSettle();
  });

  testWidgets('a drive pauses the idle stream (the engine feeds the tracker); stopping resumes it', (tester) async {
    useTallScreen(tester);
    final h = _IdleHarness();
    h.client.regionsIndexResult = const [cmh, day];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    expect(h.idle.subs, 1);
    await h.state.startDrive();
    await tester.pump(const Duration(milliseconds: 50));
    await h.state.stopDrive();
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
    expect(h.idle.subs, 2, reason: 're-subscribed after the drive');
  });
}
