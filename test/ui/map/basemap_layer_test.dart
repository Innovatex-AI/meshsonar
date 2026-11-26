// The vector basemap's tile path (ui/map/basemap_layer.dart): our tiles through the shared MeshTileProvider (cache, gate,
// stats), a 204 "empty tile" is a tile and not a failure, failures count toward the OpenFreeMap fallback,
// and every map shows the credit of the source drawn.
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

  NetworkBasemapTileProvider provider(ScriptClient c) => NetworkBasemapTileProvider(
    source: BasemapSource.ours,
    urlTemplate: () => OurBasemap.tileUrl,
    tiles: MeshTileProvider(client: c, cache: MemCache(), gate: TileFetchGate(), stats: MapTileStats()),
    health: health,
    retryDelays: const [Duration(milliseconds: 5), Duration(milliseconds: 10)],
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
      retryDelays: const [Duration(milliseconds: 5), Duration(milliseconds: 10)],
    );
    for (var i = 0; i < 4; i++) {
      await expectLater(p.provide(TileIdentity(12, 1100 + i, 1550)), throwsA(isA<ProviderException>()));
    }
    expect(c.sent, hasLength(12), reason: 'each tile is asked three times (the retries) before it counts as failed');
    expect(health.sourceFor(inside: true), BasemapSource.openFreeMap);
    expect(p.tiles.gate.isOpen, isFalse, reason: 'a server that answers 502 is a network that works: the breaker stays closed');
  });

  // Build 72: a few failed tiles must not blank the map, a failed tile is asked again and never kept as "empty".
  test('a tile that fails twice and then answers is drawn: no exception, the server is not counted as failing', () async {
    var n = 0;
    final c = ScriptClient()
      ..handler = (r) async => ++n <= 2 ? throw http.ClientException('connection reset') : http.StreamedResponse(Stream.value([26, 3, 1, 2]), 200);
    final p = provider(c);
    expect(await p.provide(TileIdentity(14, 4418, 6204)), [26, 3, 1, 2]);
    expect(c.sent, hasLength(3));
    expect(health.sourceFor(inside: true), BasemapSource.ours);
    expect(p.tiles.gate.isOpen, isFalse);
  });

  test('a tile that keeps failing is thrown as retryable (nothing is kept for it) and asked again on the next request', () async {
    var up = false;
    final c = ScriptClient()..handler = (r) async => up ? http.StreamedResponse(Stream.value([7]), 200) : throw http.ClientException('no route');
    final p = provider(c);
    await expectLater(
      p.provide(TileIdentity(14, 4418, 6204)),
      throwsA(isA<ProviderException>().having((e) => e.retryable, 'retryable', Retryable.retry).having((e) => e.statusCode, 'status', isNull)),
    );
    up = true;
    p.tiles.gate.setPhoneOnline(true); // the network is back
    expect(await p.provide(TileIdentity(14, 4418, 6204)), [7], reason: 'the same tile, asked again, is fetched: no empty answer was cached');
  });

  test('with no network (the gate is shut) nothing is counted against our server: no switch to OpenFreeMap over a map that cannot load', () async {
    final c = ScriptClient()..handler = (r) async => throw http.ClientException('no route');
    final p = provider(c);
    p.tiles.gate.setPhoneOnline(false);
    for (var i = 0; i < 6; i++) {
      await expectLater(p.provide(TileIdentity(12, 1100 + i, 1550)), throwsA(isA<ProviderException>()));
    }
    expect(c.sent, isEmpty);
    expect(health.sourceFor(inside: true), BasemapSource.ours);
  });

  test('404 (no tile there) is an empty tile for the renderer: status 404, not retryable, asked once', () async {
    final c = ScriptClient()..handler = (r) async => http.StreamedResponse(const Stream.empty(), 404);
    final p = provider(c);
    await expectLater(
      p.provide(TileIdentity(14, 1, 1)),
      throwsA(isA<ProviderException>().having((e) => e.statusCode, 'status', 404).having((e) => e.retryable, 'retryable', Retryable.none)),
    );
    expect(c.sent, hasLength(1));
    expect(health.sourceFor(inside: true), BasemapSource.ours);
  });

  test('the map background is the style\'s own: a Dark map with a tile missing stays dark', () {
    expect(basemapBackgroundColor(BasemapSource.ours, dark: true), const Color(0xFF121417));
    expect(basemapBackgroundColor(BasemapSource.ours, dark: false), const Color(0xFFFAFAFA));
    expect(basemapBackgroundColor(BasemapSource.ours, dark: false, look: BasemapLook.topo), const Color(0xFFE9E2CE));
    expect(basemapBackgroundColor(BasemapSource.ours, dark: true, look: BasemapLook.topo), const Color(0xFF161A15));
    expect(basemapBackgroundColor(BasemapSource.ours, dark: true, look: BasemapLook.labels), isNull);
    expect(parseStyleColor('rgb(18, 20, 23)'), const Color(0xFF121417));
    expect(parseStyleColor('hsl(0,0%,0%)'), isNull);
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
