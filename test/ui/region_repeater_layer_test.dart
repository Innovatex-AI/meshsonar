// The "Region repeaters" layer (the viewed region's roster) on CoverageMap. The roster used to be one Marker widget per
// repeater with a name tooltip; it is now the clustered painter (layer key 'layer-repeaters-paint') and a tap opens the
// repeater sheet (name, hash prefix, status). Only positioned rows are drawn.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/map_layers.dart';

RegionRepeater rep(String k, double? lat) => RegionRepeater(
  key: k * 32,
  hashPrefix: k,
  name: 'R$k',
  lat: lat,
  lon: lat == null ? null : -83.0,
  status: RepeaterActivity.active,
);

void main() {
  test('MapLayers: regionRepeaters is off by default and part of equality', () {
    expect(const MapLayers().regionRepeaters, isFalse);
    expect(
      const MapLayers().copyWith(regionRepeaters: true),
      isNot(const MapLayers()),
    );
  });

  final roster = [rep('aa', 40.0), rep('bb', null)];
  Widget map(bool on) => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 400,
          child: CoverageMap(
            pings: const [],
            showTiles: false,
            fallbackCenter: const LatLng(40.0, -83.0),
            layers: MapLayers(regionRepeaters: on),
            regionRepeaters: roster,
          ),
        ),
      ),
    ),
  );

  testWidgets('draws the positioned roster only when the layer is on; a tap opens its sheet', (t) async {
    await t.pumpWidget(map(false));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('layer-repeaters-paint')), findsNothing);

    await t.pumpWidget(map(true));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('layer-repeaters-paint')), findsOneWidget);

    // The map is centred on 40, -83 (the 'aa' repeater): tap the middle of the 400 x 400 map.
    await t.tapAt(const Offset(200, 200));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('repeater-sheet')), findsOneWidget);
    expect(find.text('Raa'), findsOneWidget);
    expect(find.text('AA'), findsOneWidget, reason: 'hash prefix, as the old tooltip showed');
    expect(find.byKey(const Key('repeater-sheet-status')), findsOneWidget);
    expect(find.byKey(const Key('repeater-sheet-open')), findsNothing, reason: 'no host link given');
  });

  testWidgets('a tap away from the only positioned repeater opens nothing (the unpositioned one is not drawn)', (t) async {
    await t.pumpWidget(map(true));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await t.tapAt(const Offset(60, 340));
    await t.pump(const Duration(milliseconds: 600)); // past the map's double-tap window
    await t.pumpAndSettle();
    expect(find.byKey(const Key('repeater-sheet')), findsNothing);
  });
}
