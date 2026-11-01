// The empty map's first frame (no fix, no pings): the viewed region's bounds, else its centre, else the continent.
// Regression: a fresh install viewing Aachen opened centred somewhere else (the mean of the loaded repeaters).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/region_center.dart';

Widget _map({LatLng? center, LatLngBounds? bounds}) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 600,
          child: CoverageMap(pings: const [], showTiles: false, fallbackCenter: center, fallbackBounds: bounds),
        ),
      ),
    );

MapOptions _options(WidgetTester t) => t.widget<FlutterMap>(find.byType(FlutterMap)).options;

void main() {
  final aachen = LatLngBounds(const LatLng(50.6, 5.9), const LatLng(50.95, 6.3));

  testWidgets('viewed region with bounds: the map frames the bounds', (t) async {
    await t.pumpWidget(_map(center: aachen.center, bounds: aachen));
    await t.pump();
    final fit = _options(t).initialCameraFit;
    expect(fit, isA<FitBounds>());
    final f = fit as FitBounds;
    expect(f.bounds.south, closeTo(50.6, 1e-6));
    expect(f.bounds.east, closeTo(6.3, 1e-6));
  });

  testWidgets('viewed region with only a centre: opens on it', (t) async {
    await t.pumpWidget(_map(center: const LatLng(50.78, 6.08)));
    await t.pump();
    expect(_options(t).initialCenter, const LatLng(50.78, 6.08));
    expect(_options(t).initialZoom, 8);
    expect(_options(t).initialCameraFit, isNull);
  });

  testWidgets('nothing known: the continental view, not the whole world', (t) async {
    await t.pumpWidget(_map());
    await t.pump();
    expect(_options(t).initialCenter, continentalCenter);
    expect(_options(t).initialZoom, continentalZoom);
  });
}
