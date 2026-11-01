// Shared by the privacy-zone widget tests: a Harness whose client speaks driver-privacy, a screen pump with size / text
// scale / brightness, and a way to tap a latitude/longitude on the zone map.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/core/idle_region_watcher.dart' show LastKnownStore;
import 'package:meshsonar/radio/radio_api.dart' show GeoFix;
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/privacy_zones_screen.dart';

import '../ui/fakes.dart';

class ZonesClient extends FakeCmatClient {
  ZonesClient(super.baseUrl);
  List<PrivacyZone> server = [];
  int trim = 500;
  ZoneScope scope = ZoneScope.account;
  Object? error;
  final List<List<PrivacyZone>> posts = [];

  @override
  Future<DriverPrivacy> driverPrivacy(String driverKey) async {
    if (error != null) throw error!;
    return DriverPrivacy(zones: server, trimM: trim, scope: scope);
  }

  @override
  Future<DriverPrivacy> setDriverPrivacy(String driverKey, {List<PrivacyZone>? zones, int? trimM}) async {
    if (error != null) throw error!;
    if (zones != null) {
      posts.add(zones);
      server = zones;
    }
    if (trimM != null) trim = trimM;
    return DriverPrivacy(zones: server, trimM: trim, scope: scope);
  }
}

class MemLast extends LastKnownStore {
  GeoFix? stored;
  MemLast(this.stored) : super(File('/nonexistent/last.json'));
  @override
  Future<GeoFix?> load() async => stored;
  @override
  Future<void> save(GeoFix fix) async => stored = fix;
}

class ZonesHarness extends Harness {
  bool capable = true;
  @override
  FakeCmatClient newClient(Uri u) => ZonesClient(u);
  ZonesClient get zc => client as ZonesClient;
}


/// Pumps the zone editor alone in an app scope. [withKey] false = a phone that has no driver key yet.
Future<(ZonesHarness, MapController)> pumpZones(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1.0,
  Brightness brightness = Brightness.light,
  bool capable = true,
  bool withKey = true,
  bool withFix = true,
  void Function(ZonesHarness h)? setup,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  final h = ZonesHarness();
  if (withKey) h.approveKey();
  h.location.currentFix = withFix ? () => GeoFix(lat: 39.9612, lon: -82.9988, at: DateTime.utc(2026, 10, 16, 17, 55)) : () => null;
  h.lastKnownStore = MemLast(null);
  h.client.siteConfigResult = SiteConfig(
    region: const RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'),
    capabilities: {if (capable) 'driverPrivacy'},
  );
  setup?.call(h);
  await h.state.init();
  await tester.pumpAndSettle();
  final map = MapController();
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(brightness),
      home: MediaQuery(
        data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale), padding: const EdgeInsets.only(top: 47, bottom: 34)),
        child: PrivacyZonesScreen(showTiles: false, mapController: map),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return (h, map);
}

/// Taps the map at a latitude/longitude.
Future<void> tapMapAt(WidgetTester tester, MapController map, double lat, double lon) async {
  final origin = tester.getTopLeft(find.byKey(const Key('zones-map')));
  final off = map.camera.latLngToScreenOffset(LatLng(lat, lon));
  await tester.tapAt(origin + off);
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pumpAndSettle();
}
