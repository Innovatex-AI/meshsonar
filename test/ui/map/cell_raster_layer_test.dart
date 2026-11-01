import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show Matrix4;
import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/hex_cells.dart' show HexPoint;
import 'package:meshsonar/ui/map/cell_raster_layer.dart';

MapCamera cam({double zoom = 14, double rotation = 0, LatLng center = const LatLng(40, -83), Size size = const Size(400, 800)}) =>
    MapCamera(crs: const Epsg3857(), center: center, zoom: zoom, rotation: rotation, nonRotatedSize: size);

CellLayerData ring(LatLng c, {int n = 3, double step = 0.002}) {
  final cells = <List<HexPoint>>[];
  for (var i = -n; i <= n; i++) {
    for (var j = -n; j <= n; j++) {
      final lat = c.latitude + i * step, lon = c.longitude + j * step;
      cells.add([HexPoint(lat, lon), HexPoint(lat + step / 2, lon), HexPoint(lat + step / 2, lon + step / 2), HexPoint(lat, lon + step / 2)]);
    }
  }
  return CellLayerData.build(cells.length, (i) => cells[i], (i) => CellStyle(Colors.green.withValues(alpha: 0.3), Colors.green, 1));
}

void main() {
  test('Mercator maths matches flutter_map and round-trips', () {
    final c = cam();
    for (final z in [3.0, 10.0, 14.5, 18.0]) {
      final p = const LatLng(40.126, -82.93);
      final o = c.projectAtZoom(p, z);
      expect(mercX(p.longitude, z), closeTo(o.dx, 1e-6 * math.pow(2, z)));
      expect(mercY(p.latitude, z), closeTo(o.dy, 1e-6 * math.pow(2, z)));
      expect(unmercLat(mercY(p.latitude, z), z), closeTo(p.latitude, 1e-9));
      expect(unmercLon(mercX(p.longitude, z), z), closeTo(p.longitude, 1e-9));
    }
  });

  test('the draw transform puts a cell corner exactly where the camera projects it (zoomed, rotated)', () {
    final data = ring(const LatLng(40, -83));
    for (final rot in [0.0, 30.0, 135.0, -70.0]) {
      final painted = cam(zoom: 15, center: const LatLng(40.001, -83.0007));
      final render = paintCells(data, painted.center, 15, 800, 800, 1);
      final now = cam(zoom: 15.2, rotation: rot, center: const LatLng(40.0012, -83.0004));
      // reproduce drawRender's transform on a point of render space
      final corner = const LatLng(40.002, -82.999);
      final local = Offset(mercX(corner.longitude, 15) - mercX(render.center.longitude, 15), mercY(corner.latitude, 15) - mercY(render.center.latitude, 15));
      final o = now.latLngToScreenOffset(render.center);
      final m = Matrix4.identity()
        ..translateByDouble(o.dx, o.dy, 0, 1)
        ..rotateZ(now.rotationRad)
        ..scaleByDouble(math.pow(2, 0.2).toDouble(), math.pow(2, 0.2).toDouble(), 1, 1);
      final v = m.transform3(Vector3(local.dx, local.dy, 0));
      final want = now.latLngToScreenOffset(corner);
      expect(v[0], closeTo(want.dx, 0.01), reason: 'rotation $rot');
      expect(v[1], closeTo(want.dy, 0.01), reason: 'rotation $rot');
      render.dispose();
    }
  });

  test('renderCovers: stays valid while the view is inside, fails near the edge, on a zoom jump and on new data', () {
    final data = ring(const LatLng(40, -83), n: 6);
    final c0 = cam(zoom: 15);
    final render = paintCells(data, c0.center, 15, 1200, 1200, 1);
    expect(renderCovers(render, c0, data), isTrue);
    // a short drive north keeps it
    expect(renderCovers(render, cam(zoom: 15, center: LatLng(40.0005, -83)), data), isTrue);
    // far off: the screen runs outside the painted area
    expect(renderCovers(render, cam(zoom: 15, center: LatLng(40.01, -83)), data), isFalse);
    expect(renderCovers(render, cam(zoom: 16), data), isFalse, reason: 'a whole zoom level: repaint');
    expect(renderCovers(render, cam(zoom: 15.3), data), isTrue);
    expect(renderCovers(render, c0, CellLayerData(data.shapes, data.styles)), isFalse, reason: 'new data object');
    // rotating in place stays covered (the area is a square sized for any angle)
    final big = paintCells(data, c0.center, 15, 1000, 1000, 1);
    for (final r in [0.0, 45.0, 90.0, 200.0]) {
      expect(renderCovers(big, cam(zoom: 15, rotation: r), data), isTrue, reason: 'rotation $r');
    }
    render.dispose();
    big.dispose();
  });

  test('paintCells culls cells outside the painted area', () {
    final data = ring(const LatLng(40, -83), n: 20); // 41 x 41 cells
    final far = paintCells(data, const LatLng(40, -83), 17, 600, 600, 1);
    final wide = paintCells(data, const LatLng(40, -83), 12, 600, 600, 1);
    expect(far.cellsDrawn, lessThan(40));
    expect(wide.cellsDrawn, greaterThan(far.cellsDrawn));
    far.dispose();
    wide.dispose();
  });

  testWidgets('the layer paints once, then moving the camera repaints the image without re-painting cells', (t) async {
    final data = ring(const LatLng(40, -83), n: 10);
    final controller = MapController();
    await t.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 400,
        height: 800,
        child: FlutterMap(
          mapController: controller,
          options: const MapOptions(initialCenter: LatLng(40, -83), initialZoom: 15),
          children: [CellRasterLayer(key: const Key('cells'), data: data)],
        ),
      ),
    ));
    await t.pump();
    await t.pump();
    final st = t.state<CellRasterLayerState>(find.byKey(const Key('cells')));
    expect(st.paints, 1);
    expect(st.cellsInPicture, greaterThan(0));
    for (var i = 0; i < 20; i++) {
      controller.move(LatLng(40 + i * 0.00002, -83), 15);
      await t.pump(const Duration(milliseconds: 16));
    }
    expect(st.paints, 1, reason: '20 camera moves inside the painted area cost no repaint of the cells');
    controller.move(const LatLng(40.03, -83), 15);
    await t.pump();
    await t.pump();
    expect(st.paints, 2, reason: 'running off the painted area repaints once');
  });
}

