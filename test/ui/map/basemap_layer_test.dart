// The vector basemap's tile path (ui/map/basemap_layer.dart): our tiles through the shared MeshTileProvider (cache, gate,
// stats), a 204 "empty tile" is a tile and not a failure, failures count toward the OpenFreeMap fallback, pack-covered
// tiles are never requested, and every map shows the credit of the source drawn.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/ui/map/basemap_layer.dart';
import 'package:meshsonar/ui/map/overlays/mini_map_credit.dart';
import 'package:meshsonar/ui/map/tile_source.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

import 'tile_source_test.dart' show MemCache, ScriptClient;

void main() {
  late BasemapHealth health;
  setUp(() {
    health = BasemapHealth(client: () => throw StateError('no probe in these tests'));
  });

  NetworkBasemapTileProvider provider(ScriptClient c, {bool Function(int, int, int)? skip}) => NetworkBasemapTileProvider(
    source: BasemapSource.ours,
    urlTemplate: () => OurBasemap.tileUrl,
    tiles: MeshTileProvider(client: c, cache: MemCache(), gate: TileFetchGate(), stats: MapTileStats(), shouldSkip: skip),
    health: health,
  );

  test('asks our server for z/x/y.bin and returns the vector bytes', () async {
    final c = ScriptClient()..handler = (r) async => http.StreamedResponse(Stream.value([26, 3, 1, 2]), 200);
    final b = await provider(c).provide(TileIdentity(13, 2207, 3102));
    expect(c.sent.single.toString(), 'https://api.meshsonar.com/basemap/t/na-20261108/13/2207/3102.bin');
    expect(b, [26, 3, 1, 2]);
  });

  test('204 is an empty tile (not a failure, nothing counted against the server)', () async {
    final c = ScriptClient()..handler = (r) async => http.StreamedResponse(const Stream.empty(), 204);
    final p = provider(c);
    for (var i = 0; i < 5; i++) {
      expect(await p.provide(TileIdentity(14, 4414 + i, 6205)), isEmpty);
    }
    expect(health.sourceFor(inside: true), BasemapSource.ours);
    expect(p.tiles.gate.isOpen, isFalse);
  });

  test('4 failed tiles in a row move the map to OpenFreeMap; each failure is an empty tile, never a crash', () async {
    final c = ScriptClient()..handler = (r) async => http.StreamedResponse(const Stream.empty(), 502);
    final p = NetworkBasemapTileProvider(
      source: BasemapSource.ours,
      urlTemplate: () => OurBasemap.tileUrl,
      // a gate that never opens its breaker, so every tile reaches the server
      tiles: MeshTileProvider(client: c, cache: MemCache(), gate: TileFetchGate(failuresToOpen: 100), stats: MapTileStats()),
      health: health,
    );
    for (var i = 0; i < 4; i++) {
      await expectLater(p.provide(TileIdentity(12, 1100 + i, 1550)), throwsA(isA<ProviderException>()));
    }
    expect(health.sourceFor(inside: true), BasemapSource.openFreeMap);
  });

  test('a tile an installed pack draws is not requested', () async {
    final c = ScriptClient();
    await expectLater(provider(c, skip: (z, x, y) => true).provide(TileIdentity(12, 1, 1)), throwsA(isA<ProviderException>()));
    expect(c.sent, isEmpty);
  });

  test('OpenFreeMap: its TileJSON URL template, max zoom 14', () async {
    final c = ScriptClient()..handler = (r) async => http.StreamedResponse(Stream.value([1]), 200);
    final p = NetworkBasemapTileProvider(
      source: BasemapSource.openFreeMap,
      urlTemplate: () => health.openFreeMapTileUrl,
      tiles: MeshTileProvider(client: c, cache: MemCache(), gate: TileFetchGate(), stats: MapTileStats()),
      health: health,
    );
    await p.provide(TileIdentity(13, 2207, 3102));
    expect(c.sent.single.host, 'tiles.openfreemap.org');
    expect(p.maximumZoom, 14);
  });

  Widget mapAt(LatLng c, {List<Widget> extra = const []}) => MaterialApp(
    home: SizedBox(
      width: 300,
      height: 200,
      child: FlutterMap(key: ValueKey(c), options: MapOptions(initialCenter: c, initialZoom: 12), children: [const BasemapLayer(), ...extra, const MiniMapCredit()]),
    ),
  );

  testWidgets('every map credits the source it draws: ours in Ohio, OpenFreeMap in London', (tester) async {
    BasemapHealth.instance = BasemapHealth(client: () => throw StateError('offline test'));
    final drawn = <BasemapSource>[];
    BasemapLayer.debugBuilder = (s, dark) {
      drawn.add(s);
      return const SizedBox.shrink();
    };
    addTearDown(() {
      BasemapLayer.debugBuilder = null;
      BasemapHealth.instance = BasemapHealth();
    });
    await tester.pumpWidget(mapAt(const LatLng(39.96, -83.0)));
    expect(drawn.last, BasemapSource.ours);
    expect(find.text('Protomaps © OpenStreetMap contributors'), findsOneWidget);
    await tester.pumpWidget(mapAt(const LatLng(51.5, -0.12)));
    await tester.pump();
    expect(drawn.last, BasemapSource.openFreeMap);
    expect(find.text('OpenFreeMap © OpenStreetMap contributors'), findsOneWidget);
    expect(find.textContaining('openstreetmap.org'), findsNothing);
  });

  testWidgets('the Satellite names (labels look) are drawn only from OUR tiles: nothing over OpenFreeMap, whose style has no label-only look', (tester) async {
    BasemapHealth.instance = BasemapHealth(client: () => throw StateError('offline test'));
    final drawn = <(BasemapSource, BasemapLook)>[];
    BasemapLayer.debugBuilder = (s, dark) {
      drawn.add((s, BasemapLayer.debugLook ?? BasemapLook.road));
      return const SizedBox.shrink();
    };
    addTearDown(() {
      BasemapLayer.debugBuilder = null;
      BasemapLayer.debugLook = null;
      BasemapHealth.instance = BasemapHealth();
    });
    Widget labelsAt(LatLng c) => MaterialApp(
      home: SizedBox(
        width: 300,
        height: 200,
        child: FlutterMap(key: ValueKey(c), options: MapOptions(initialCenter: c, initialZoom: 12), children: const [BasemapLayer(look: BasemapLook.labels, dark: true)]),
      ),
    );
    await tester.pumpWidget(labelsAt(const LatLng(39.96, -83.0)));
    expect(drawn, [(BasemapSource.ours, BasemapLook.labels)], reason: 'inside our extract: our names over the imagery');
    drawn.clear();
    await tester.pumpWidget(labelsAt(const LatLng(51.5, -0.12)));
    await tester.pump();
    expect(drawn, isEmpty, reason: 'London is outside the extract: imagery only, no names');
  });
}
