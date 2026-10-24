import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/map_layers.dart';

RegionRepeater rep(String k, double? lat) => RegionRepeater(
  key: k * 32,
  hashPrefix: k,
  name: 'R$k',
  lat: lat,
  lon: lat == null ? null : -83.0,
);

void main() {
  test('MapLayers: regionRepeaters is off by default and part of equality', () {
    expect(const MapLayers().regionRepeaters, isFalse);
    expect(
      const MapLayers().copyWith(regionRepeaters: true),
      isNot(const MapLayers()),
    );
  });

  Widget map(bool on) => MaterialApp(
    home: SizedBox(
      width: 400,
      height: 400,
      child: CoverageMap(
        pings: const [],
        showTiles: false,
        layers: MapLayers(regionRepeaters: on),
        regionRepeaters: [rep('aa', 40.0), rep('bb', null)],
      ),
    ),
  );

  testWidgets('draws a pin per positioned repeater only when the layer is on', (
    t,
  ) async {
    await t.pumpWidget(map(false));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byKey(ValueKey('region-repeater-${'aa' * 32}')), findsNothing);
    await t.pumpWidget(map(true));
    await t.pump(const Duration(milliseconds: 100));
    expect(
      find.byKey(ValueKey('region-repeater-${'aa' * 32}')),
      findsOneWidget,
    );
    expect(find.byKey(ValueKey('region-repeater-${'bb' * 32}')), findsNothing);
  });
}
