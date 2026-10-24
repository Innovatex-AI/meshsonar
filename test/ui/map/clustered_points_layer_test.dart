// ClusteredPointsLayer inside a real FlutterMap (no tile layer, as the app runs under test): one painter, viewport
// culling, LOD, its own hit testing, and fall-through of taps that miss.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/cluster_index.dart';
import 'package:meshsonar/ui/map/layers/clustered_points_layer.dart';

const _size = Size(400, 600);

ClusterIndex index(List<LatLng> pts, {List<int>? bands}) => ClusterIndex.buildSync(
  Float64List.fromList([for (final p in pts) p.latitude]),
  Float64List.fromList([for (final p in pts) p.longitude]),
  band: bands == null ? null : Uint8List.fromList(bands),
);

class Probe {
  final taps = <ClusterTap>[];
  final mapTaps = <LatLng>[];
  final controller = MapController();
}

Widget harness(
  Probe probe,
  ClusterIndex idx, {
  required LatLng center,
  required double zoom,
  double rotation = 0,
  Uint8List? kind,
  int? selected,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: _size.width,
        height: _size.height,
        child: FlutterMap(
          mapController: probe.controller,
          options: MapOptions(
            initialCenter: center,
            initialZoom: zoom,
            initialRotation: rotation,
            onTap: (_, p) => probe.mapTaps.add(p),
          ),
          children: [
            ClusteredPointsLayer(
              layerKey: 'layer-test',
              index: idx,
              kind: kind,
              selectedPoint: selected,
              bandColors: const [Colors.green, Colors.blue, Colors.amber, Colors.grey],
              haloColor: Colors.white,
              labelColor: Colors.black,
              onTap: probe.taps.add,
            ),
          ],
        ),
      ),
    ),
  ),
);

ClusteredPointsPainter painterOf(WidgetTester t) =>
    t.widget<CustomPaint>(find.byKey(const ValueKey('layer-test-paint'))).painter! as ClusteredPointsPainter;

/// Where [p] is on screen (global coordinates; the map sits at the top-left of the test window).
Offset screenOf(Probe probe, LatLng p) => probe.controller.camera.latLngToScreenOffset(p);

Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('draws with one painter at the camera\'s own projection', (t) async {
    final pts = [const LatLng(40, -83), const LatLng(40.01, -82.99), const LatLng(39.99, -83.02)];
    final probe = Probe();
    await t.pumpWidget(harness(probe, index(pts), center: const LatLng(40, -83), zoom: 14));
    await settle(t);
    expect(find.byType(CustomPaint), findsWidgets);
    final painter = painterOf(t);
    expect(painter.slice.length, 3);
    final cam = probe.controller.camera;
    for (var k = 0; k < painter.slice.length; k++) {
      final p = pts[painter.slice.point[k]];
      final mine = painter.offsetOf(k), theirs = cam.getOffsetFromOrigin(p);
      expect((mine - theirs).distance, lessThan(0.01), reason: 'same projection as flutter_map (point $k)');
    }
    expect(painter.debugSingles, 3);
    expect(painter.debugClusters, 0);
  });

  testWidgets('20k points: only the viewport is queried and drawn', (t) async {
    final r = math.Random(1);
    final pts = [for (var i = 0; i < 20000; i++) LatLng(25 + r.nextDouble() * 24, -125 + r.nextDouble() * 58)];
    final idx = index(pts);
    final probe = Probe();
    await t.pumpWidget(harness(probe, idx, center: const LatLng(40, -83), zoom: 11));
    await settle(t);
    final city = painterOf(t);
    expect(city.slice.length, lessThan(200), reason: 'a city view, not the continent');
    // Zoomed out over the US: clusters only, bounded by the 64 px grid, all points accounted for in view.
    probe.controller.move(const LatLng(37, -96), 3);
    await settle(t);
    final us = painterOf(t);
    expect(us.debugClusters, greaterThan(0));
    expect(us.slice.length, lessThan(150));
    var total = 0;
    for (var k = 0; k < us.slice.length; k++) {
      total += us.slice.count[k];
    }
    expect(total, greaterThan(15000), reason: 'most of the points are inside a zoom-3 US view');
  });

  testWidgets('tap on a single reports it and does not reach the map; a miss falls through to the map', (t) async {
    final pts = [const LatLng(40, -83), const LatLng(40.003, -82.995)];
    final probe = Probe();
    await t.pumpWidget(harness(probe, index(pts), center: const LatLng(40.0015, -82.9975), zoom: 16));
    await settle(t);
    await t.tapAt(screenOf(probe, pts[1]) + const Offset(6, 4));
    await t.pump(const Duration(milliseconds: 400));
    expect(probe.taps, hasLength(1));
    expect(probe.taps.single.point, 1);
    expect(probe.taps.single.isCluster, isFalse);
    expect(probe.mapTaps, isEmpty);

    await t.tapAt(screenOf(probe, pts[0]) + const Offset(0, 120));
    await t.pump(const Duration(milliseconds: 400));
    expect(probe.taps, hasLength(1), reason: 'nothing near: the layer does not take the tap');
    expect(probe.mapTaps, hasLength(1));
  });

  testWidgets('tap on a cluster, then fit the camera to it: zoom goes up and the members split', (t) async {
    final pts = [for (var k = 0; k < 12; k++) LatLng(40 + (k % 4) * 0.01, -83 + (k ~/ 4) * 0.01)];
    final probe = Probe();
    final idx = index(pts);
    await t.pumpWidget(harness(probe, idx, center: const LatLng(40.015, -82.99), zoom: 6));
    await settle(t);
    final p = painterOf(t);
    expect(p.debugClusters, 1);
    await t.tapAt(screenOf(probe, LatLng(latFromMercatorY(p.slice.y[0]), lonFromMercatorX(p.slice.x[0]))));
    await t.pump(const Duration(milliseconds: 400));
    final tap = probe.taps.single;
    expect(tap.isCluster, isTrue);
    expect(tap.count, 12);
    final before = probe.controller.camera.zoom;
    probe.controller.fitCamera(cameraFitForCluster(tap, probe.controller.camera));
    await settle(t);
    expect(probe.controller.camera.zoom, greaterThan(before + 4));
    expect(painterOf(t).debugSingles, 12);
  });

  testWidgets('LOD: below zoom 5 a single is drawn small and a tap on it asks to zoom in', (t) async {
    final pts = [const LatLng(40, -83)];
    final probe = Probe();
    await t.pumpWidget(harness(probe, index(pts), center: const LatLng(40, -83), zoom: 3));
    await settle(t);
    await t.tapAt(screenOf(probe, pts[0]));
    await t.pump(const Duration(milliseconds: 400));
    final tap = probe.taps.single;
    expect(tap.isCluster, isTrue, reason: 'reported as a one-member cluster, so the host zooms in');
    expect(tap.colocated, [0]);
    final fit = cameraFitForCluster(tap, probe.controller.camera);
    probe.controller.fitCamera(fit);
    await settle(t);
    expect(probe.controller.camera.zoom, 5);
  });

  testWidgets('hit testing follows a rotated map', (t) async {
    final pts = [const LatLng(40, -83), const LatLng(40.002, -82.996)];
    final probe = Probe();
    await t.pumpWidget(harness(probe, index(pts), center: const LatLng(40.001, -82.998), zoom: 16, rotation: 50));
    await settle(t);
    await t.tapAt(screenOf(probe, pts[1]));
    await t.pump(const Duration(milliseconds: 400));
    expect(probe.taps.single.point, 1);
  });

  testWidgets('map-level hit test (clusterTapAt) agrees with the layer', (t) async {
    final pts = [const LatLng(40, -83), const LatLng(40.003, -82.995)];
    final probe = Probe();
    final idx = index(pts);
    await t.pumpWidget(harness(probe, idx, center: const LatLng(40.0015, -82.9975), zoom: 16));
    await settle(t);
    final cam = probe.controller.camera;
    expect(clusterTapAt(idx, cam, const LatLng(40.00301, -82.99501))!.point, 1);
    expect(clusterTapAt(idx, cam, const LatLng(40.0015, -82.9975)), isNull);
  });

  testWidgets('room servers and a selected point paint without errors; an empty index paints nothing', (t) async {
    final pts = [const LatLng(40, -83), const LatLng(40.001, -82.999)];
    final probe = Probe();
    await t.pumpWidget(harness(probe, index(pts), center: const LatLng(40, -83), zoom: 16, kind: Uint8List.fromList([3, 2]), selected: 0));
    await settle(t);
    expect(t.takeException(), isNull);
    expect(painterOf(t).debugSingles, 2);
    await t.pumpWidget(harness(Probe(), index(const []), center: const LatLng(40, -83), zoom: 16));
    await settle(t);
    expect(painterOf(t).slice.length, 0);
  });
}
