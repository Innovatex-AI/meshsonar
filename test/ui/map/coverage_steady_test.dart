// Build 72 ("the coverage is jumpy", iPad): how steady a coverage tile layer is over one pan and one zoom step across
// meta.hexFromZoom, in numbers. Every viewport tile answers after a delay (a slow network), so the frames in between are the
// ones that matter: a hole where coverage was a moment ago is a "drop".
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/coverage_v2.dart';
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/map/coverage_tiles_layer.dart';

const _meta = CoverageMeta(hexFromZoom: 13, predictedFromZoom: 8, version: 7);
const _centre = LatLng(40.0, -83.0);

/// A synthetic tile: 4 features spread over the tile (points below the hexagon zoom, small squares from it up).
CoverageTileData _tile(int z, int x, int y) {
  final w = tileLon(x.toDouble(), z), e = tileLon(x + 1.0, z), n = tileLat(y.toDouble(), z), s = tileLat(y + 1.0, z);
  final hex = z >= _meta.hexFromZoom;
  final ll = <double>[];
  final starts = <int>[0];
  for (final (fy, fx) in const [(0.25, 0.25), (0.25, 0.75), (0.75, 0.25), (0.75, 0.75)]) {
    final lat = n + (s - n) * fy, lon = w + (e - w) * fx;
    if (hex) {
      final d = (e - w) * 0.05;
      ll.addAll([lat, lon, lat + d, lon, lat + d, lon + d, lat, lon + d]);
    } else {
      ll.addAll([lat, lon]);
    }
    starts.add(ll.length ~/ 2);
  }
  return CoverageTileData(Float64List.fromList(ll), Int32List.fromList(starts), Uint8List.fromList([3, 3, 3, 3]), Int32List.fromList([5, 5, 5, 5]), Float32List(4), List.filled(4, ''));
}

class _Rig {
  final fetches = <String>[];
  late final CoverageTileStore store;
  final MapController map = MapController();
  Duration delay = const Duration(milliseconds: 400);
  int parentBuilds = 0;
  late StateSetter rebuildParent;
  double clearance = 0;

  _Rig() {
    store = CoverageTileStore(
      CoverageV2Client(Uri.parse('https://x.test'), client: MockClient((r) async {
        fetches.add(r.url.path);
        await Future<void>.delayed(delay);
        return http.Response.bytes(Uint8List.fromList([1]), 200);
      })),
      decode: (b, l, z, x, y) async => _tile(z, x, y),
    );
  }

  Future<CoverageTilesLayerState> pump(WidgetTester t, Size size, double zoom) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        rebuildParent = setState;
        parentBuilds++;
        // What the Drive screen does around the map: a bottom clearance that changes with the panel, panels shown and closed.
        return Stack(children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: map,
              options: MapOptions(initialCenter: _centre, initialZoom: zoom),
              children: [
                CoverageTilesLayer(
                  layer: CoverageTileLayer.measured,
                  store: store,
                  meta: _meta,
                  colors: CoverageBandColors.of(ColourPalette.standard, Brightness.light),
                ),
              ],
            ),
          ),
          Positioned(left: 0, right: 0, bottom: 0, height: 88 + clearance, child: const ColoredBox(color: Color(0xFFFFFFFF))),
        ]);
      }),
    ));
    await t.pump();
    return t.state<CoverageTilesLayerState>(find.byType(CoverageTilesLayer));
  }
}

Future<void> _frames(WidgetTester t, {int n = 40, int ms = 50}) async {
  for (var i = 0; i < n; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

void main() {
  for (final (name, size) in const [('iPad Pro 11 (834x1194)', Size(834, 1194)), ('iPhone 17 Pro (402x874)', Size(402, 874))]) {
    testWidgets('$name: one pan and zoom steps across the hexagon zoom, counted', (t) async {
      final rig = _Rig();
      final layer = await rig.pump(t, size, 12.6);
      await _frames(t);
      expect(layer.cellCount, greaterThan(0), reason: 'the dot tiles are in');
      final perScreen = rig.fetches.length;
      // ignore: avoid_print
      print('STEADY $name start z12.6: tiles per screen=$perScreen capacity=${rig.store.capacity} concurrent=${rig.store.maxConcurrent}');

      final problems = <String>[];
      Future<void> move(String what, void Function() go, {int maxDrops = 0, int? maxSwaps}) async {
        layer.stats.reset();
        final before = rig.fetches.length;
        go();
        await t.pump();
        // 40 frames of 50 ms (2 s): in how many of them is there a hole where coverage was?
        var holeFrames = layer.holes > 0 ? 1 : 0;
        for (var i = 0; i < 40; i++) {
          await t.pump(const Duration(milliseconds: 50));
          if (layer.holes > 0) holeFrames++;
        }
        // ignore: avoid_print
        print('STEADY $name $what: fetches=${rig.fetches.length - before} holeFrames=$holeFrames/41 ${layer.stats} cells=${layer.cellCount}');
        if (holeFrames > maxDrops) problems.add('$what: $holeFrames frames with a hole where coverage was');
        if (maxSwaps != null && layer.stats.dataSwaps > maxSwaps) problems.add('$what: the picture changed ${layer.stats.dataSwaps} times (at most $maxSwaps)');
        if (layer.cellCount == 0) problems.add('$what: nothing drawn at the end');
      }

      await move('pan one screen east (dots)', () => rig.map.move(LatLng(_centre.latitude, _centre.longitude + 360 / (256 * (1 << 12)) * size.width * 0.8), 12.6));
      await move('zoom in 12.6 -> 13.4 (dots to hexagons)', () => rig.map.move(rig.map.camera.center, 13.4), maxSwaps: 1);
      await move('zoom in 13.4 -> 14.4', () => rig.map.move(rig.map.camera.center, 14.4), maxSwaps: 1);
      await move('zoom out 14.4 -> 13.4', () => rig.map.move(rig.map.camera.center, 13.4), maxSwaps: 1);
      await move('zoom out 13.4 -> 12.6 (hexagons to dots)', () => rig.map.move(rig.map.camera.center, 12.6), maxSwaps: 1);
      // A place none of whose coarser tiles were ever loaded: jump there zoomed in, then zoom out twice.
      const far = LatLng(40.6, -82.0);
      rig.map.move(far, 14.4);
      await t.pump();
      await _frames(t);
      await move('fresh area, zoom out 14.4 -> 13.4', () => rig.map.move(far, 13.4), maxSwaps: 1);
      await move('fresh area, zoom out 13.4 -> 12.6 (hexagons to dots)', () => rig.map.move(far, 12.6), maxSwaps: 1);
      // A quick zoom through three levels: only the last level's tiles are worth fetching.
      rig.delay = const Duration(milliseconds: 400);
      layer.stats.reset();
      final b4 = rig.fetches.length;
      for (final zz in const [13.4, 14.4, 15.4]) {
        rig.map.move(far, zz);
        await t.pump(const Duration(milliseconds: 16));
      }
      await _frames(t);
      // ignore: avoid_print
      print('STEADY $name quick zoom 12.6 -> 15.4 in 3 frames: fetches=${rig.fetches.length - b4} ${layer.stats} cells=${layer.cellCount}');

      // Panel events around the map: a panel shown and closed, the Drive panel's detent and clearance changing. None of them
      // may fetch a coverage tile or change the picture.
      layer.stats.reset();
      final before = rig.fetches.length;
      for (final c in const [0.0, 314.0, 0.0, 56.0, 0.0]) {
        rig.rebuildParent(() => rig.clearance = c);
        await t.pump();
        await t.pump(const Duration(milliseconds: 300));
      }
      // ignore: avoid_print
      print('STEADY $name 5 panel/clearance rebuilds: fetches=${rig.fetches.length - before} ${layer.stats}');
      expect(rig.fetches.length - before, 0, reason: 'a panel or clearance change fetched coverage tiles');
      expect(layer.stats.dataSwaps, 0);
      expect(layer.stats.dropFrames, 0);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('the hold ends after kCoverageHold: a dead connection never leaves dots at a hexagon zoom for good', (t) async {
    final rig = _Rig();
    final layer = await rig.pump(t, const Size(402, 874), 12.6);
    await _frames(t);
    final dots = layer.cellCount;
    expect(dots, greaterThan(0));
    rig.delay = const Duration(minutes: 5); // the hexagon tiles never arrive
    rig.map.move(_centre, 13.4);
    await t.pump();
    expect(layer.holding, isTrue);
    expect(layer.cellCount, dots, reason: 'the dot picture stays, whole');
    await t.pump(kCoverageHold - const Duration(milliseconds: 200));
    expect(layer.holding, isTrue);
    await t.pump(const Duration(milliseconds: 300));
    expect(layer.holding, isFalse);
    expect(layer.cellCount, 0, reason: 'Nov 8 rule: at a hexagon zoom a point tile never stands in; the gap is honest');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(minutes: 6));
  });

  testWidgets('a jump to somewhere else with a zoom change does not hold a picture of the old place', (t) async {
    final rig = _Rig();
    final layer = await rig.pump(t, const Size(402, 874), 12.6);
    await _frames(t);
    rig.map.move(const LatLng(41.5, -81.7), 14.2);
    await t.pump();
    expect(layer.holding, isFalse);
    await _frames(t);
    expect(layer.cellCount, greaterThan(0));
  });

  group('store', () {
    test('room grows with the screen and never shrinks; concurrency is capped at 12', () {
      final store = CoverageTileStore(CoverageV2Client(Uri.parse('https://x.test')));
      expect((store.capacity, store.maxConcurrent), (400, 6));
      store.ensureRoom(capacity: 30 * 3 * 3 * 2, concurrent: 15); // an 11-inch iPad at a fractional zoom
      expect((store.capacity, store.maxConcurrent), (540, 12));
      store.ensureRoom(capacity: 100, concurrent: 3); // a phone opened afterwards
      expect((store.capacity, store.maxConcurrent), (540, 12));
    });

    test('prune drops queued requests of that layer for tiles no longer in view; the others run', () async {
      final asked = <String>[];
      final store = CoverageTileStore(
        CoverageV2Client(Uri.parse('https://x.test'), client: MockClient((r) async {
          asked.add(r.url.path);
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return http.Response.bytes(Uint8List.fromList([1]), 200);
        })),
        maxConcurrent: 2,
        decode: (b, l, z, x, y) async => _tile(z, x, y),
      );
      String key(CoverageTileLayer l, int x) => coverageTileKey(l, 'p', 1, 13, x, 0);
      for (var x = 0; x < 10; x++) {
        store.want(CoverageTileLayer.measured, 'p', 1, 13, x, 0);
        store.want(CoverageTileLayer.predicted, 'p', 1, 13, x, 0);
      }
      expect(store.loading(key(CoverageTileLayer.measured, 0)), isTrue);
      // The map moved on: only measured tiles 8 and 9 are in view now. Two requests are already on the wire.
      final dropped = store.prune(CoverageTileLayer.measured, {key(CoverageTileLayer.measured, 8), key(CoverageTileLayer.measured, 9)});
      expect(dropped, greaterThanOrEqualTo(7));
      expect(store.loading(key(CoverageTileLayer.measured, 3)), isFalse);
      await store.idle();
      final measured = asked.where((p) => p.contains('/measured/')).length, predicted = asked.where((p) => p.contains('/predicted/')).length;
      expect(predicted, 10, reason: 'another layer is not pruned');
      expect(measured, lessThanOrEqualTo(3), reason: 'only the tiles in view (and what was already on the wire)');
      expect(store.has(key(CoverageTileLayer.measured, 8)) && store.has(key(CoverageTileLayer.measured, 9)), isTrue);
    });
  });
}
