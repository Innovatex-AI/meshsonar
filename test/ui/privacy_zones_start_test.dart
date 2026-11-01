// Where the privacy-zone map opens: zones framed, else the phone's last known position, else the viewed region, else a
// continental view (never the whole world). Plus the pure helper.
import 'package:flutter_map/flutter_map.dart' show MapController;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/settings/privacy_zones_start.dart';

import '../support/regions_559.dart';
import '../support/zones_harness.dart';

void expectNear(LatLng a, double lat, double lon, {double tol = 0.02}) {
  expect(a.latitude, closeTo(lat, tol));
  expect(a.longitude, closeTo(lon, tol));
}

void main() {
  const home = PrivacyZone(lat: 39.9612, lon: -82.9988, radiusM: 300);
  const work = PrivacyZone(lat: 39.7589, lon: -84.1916, radiusM: 300); // Dayton, ~100 km from home

  test('zoneStart: the four tiers in order', () {
    final r = square('CMH', -83.5, 39.5, -82.5, 40.5);
    expect(zoneStart(zones: [home, work], phone: (lat: 1, lon: 2), region: r).kind, ZoneStartKind.zones);
    expect(zoneStart(zones: [home, work]).bounds, isNotNull);
    expect(zoneStart(zones: [], phone: (lat: 41, lon: -81), region: r).kind, ZoneStartKind.phone);
    final reg = zoneStart(zones: [], region: r);
    expect(reg.kind, ZoneStartKind.region);
    expect(reg.bounds, isNotNull);
    expect(zoneStart(zones: [], hub: const LatLng(40, -83)).kind, ZoneStartKind.region);
    final last = zoneStart(zones: []);
    expect(last.kind, ZoneStartKind.fallback);
    expect(last.zoom, greaterThan(2));
    expectNear(last.center, 39.5, -98.5);
  });

  testWidgets('zones: the map frames every zone, not only the first', (tester) async {
    final (_, map) = await pumpZones(tester, setup: (h) => h.zc.server = [home, work]);
    expect(map.camera.visibleBounds.contains(const LatLng(39.9612, -82.9988)), isTrue);
    expect(map.camera.visibleBounds.contains(const LatLng(39.7589, -84.1916)), isTrue);
  });

  testWidgets('no zones: opens on the phone\'s last known position', (tester) async {
    final (h, map) = await pumpZones(tester);
    expect(h.state.phoneFix, isNotNull);
    expectNear(map.camera.center, 39.9612, -82.9988);
    expect(map.camera.zoom, closeTo(14, 0.5));
  });

  testWidgets('no zones, no fix: opens on the viewed region\'s bounds', (tester) async {
    final r = square('SEA', -123.0, 47.0, -121.0, 48.2);
    final (h, map) = await pumpZones(tester, withFix: false, setup: (h) => h.client.regionsIndexResult = [r]);
    await h.state.setViewingRegion('SEA');
    await tester.pumpAndSettle();
    expectNear(map.camera.center, 47.6, -122.0, tol: 0.3);
    expect(map.camera.visibleBounds.contains(const LatLng(47.0, -123.0)), isTrue);
    expect(map.camera.visibleBounds.contains(const LatLng(48.2, -121.0)), isTrue);
  });

  testWidgets('nothing known: continental view, not the whole world', (tester) async {
    final (_, MapController map) = await pumpZones(tester, withFix: false);
    expectNear(map.camera.center, 39.5, -98.5, tol: 1);
    expect(map.camera.zoom, greaterThanOrEqualTo(3));
  });
}
