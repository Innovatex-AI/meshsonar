// Hexagon / square cell layers drawn from a cached picture instead of thousands of widgets-worth of polygons per frame.
//
// Why: flutter_map's PolygonLayer projects and re-culls EVERY polygon each time the camera moves, and the camera moves every
// frame while following a car. With 4,000 network cells that was 7 ms of build time per frame on a fast Mac (more on a phone),
// plus a 100+ ms stall whenever the host rebuilt the list. (Measured: docs/MAP_PERFORMANCE.md.)
//
// How: the cells are painted ONCE into a picture around the view (about 1.6x the screen, at the zoom it was painted for) and
// rasterised to an image on the raster thread. Every frame after that is one image draw with the camera's transform: constant
// cost, whatever the number of cells. The picture is repainted only when
//   * the cell data or its colours changed,
//   * the zoom moved more than [rezoomLevels] from the painted zoom (the image would be blurry or tiny), or
//   * the view is about to run off the painted area (a drive scrolls the map until it does).
// Until the new picture is ready the old one keeps drawing, so nothing flickers. Cells are culled by bounding box when painted.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/hex_cells.dart' show HexPoint;

/// Fill and outline of one kind of cell.
@immutable
class CellStyle {
  final Color fill;
  final Color border;
  final double borderWidth;
  const CellStyle(this.fill, this.border, [this.borderWidth = 1.0]);

  @override
  bool operator ==(Object other) => other is CellStyle && other.fill == fill && other.border == border && other.borderWidth == borderWidth;

  @override
  int get hashCode => Object.hash(fill, border, borderWidth);
}

/// One cell: its outline as lat/lon pairs and a bounding box for culling.
class CellShape {
  final Float64List ll; // lat0, lon0, lat1, lon1, ...
  final double minLat, maxLat, minLon, maxLon;
  final int style;
  CellShape._(this.ll, this.minLat, this.maxLat, this.minLon, this.maxLon, this.style);

  factory CellShape(List<HexPoint> boundary, int style) {
    final ll = Float64List(boundary.length * 2);
    var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
    for (var i = 0; i < boundary.length; i++) {
      final b = boundary[i];
      ll[2 * i] = b.lat;
      ll[2 * i + 1] = b.lon;
      minLat = math.min(minLat, b.lat);
      maxLat = math.max(maxLat, b.lat);
      minLon = math.min(minLon, b.lon);
      maxLon = math.max(maxLon, b.lon);
    }
    return CellShape._(ll, minLat, maxLat, minLon, maxLon, style);
  }

  int get points => ll.length ~/ 2;
}

/// Everything the layer draws, prepared once. Compare by identity: a new object means "repaint".
class CellLayerData {
  final List<CellShape> shapes;
  final List<CellStyle> styles;
  const CellLayerData(this.shapes, this.styles);
  static const CellLayerData empty = CellLayerData([], []);

  /// Builds the data from [count] cells: [boundary] gives each outline, [styleOf] each cell's look (equal looks share one entry).
  factory CellLayerData.build(int count, List<HexPoint> Function(int i) boundary, CellStyle Function(int i) styleOf) {
    final styles = <CellStyle>[];
    final index = <CellStyle, int>{};
    final shapes = <CellShape>[];
    for (var i = 0; i < count; i++) {
      final st = styleOf(i);
      final si = index.putIfAbsent(st, () {
        styles.add(st);
        return styles.length - 1;
      });
      shapes.add(CellShape(boundary(i), si));
    }
    return CellLayerData(shapes, styles);
  }

  bool get isEmpty => shapes.isEmpty;
}

/// Web-Mercator pixel coordinates (flutter_map's default CRS) at [zoom].
double mercX(double lon, double zoom) => 256 * math.pow(2, zoom) * (lon + 180) / 360;
double mercY(double lat, double zoom) {
  final s = math.sin(lat.clamp(-85.05112878, 85.05112878) * math.pi / 180);
  return 256 * math.pow(2, zoom) * (0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi));
}

double unmercLon(double x, double zoom) => x / (256 * math.pow(2, zoom)) * 360 - 180;
double unmercLat(double y, double zoom) {
  final n = math.pi - 2 * math.pi * y / (256 * math.pow(2, zoom));
  return 180 / math.pi * math.atan(0.5 * (math.exp(n) - math.exp(-n)));
}

/// A painted area: the picture, its centre and zoom, its size in logical pixels, and (once rasterised) the image.
class CellRender {
  final ui.Picture picture;
  ui.Image? image;
  final LatLng center;
  final double zoom;
  final double width, height;
  final double ratio;
  final CellLayerData data;
  final int cellsDrawn;
  CellRender(this.picture, this.center, this.zoom, this.width, this.height, this.ratio, this.data, this.cellsDrawn);

  void dispose() {
    picture.dispose();
    image?.dispose();
  }
}

/// Paints the cells of [data] visible in a [width] x [height] (logical px) area centred on [center] at [zoom].
CellRender paintCells(CellLayerData data, LatLng center, double zoom, double width, double height, double ratio) {
  final cx = mercX(center.longitude, zoom), cy = mercY(center.latitude, zoom);
  final west = unmercLon(cx - width / 2, zoom), east = unmercLon(cx + width / 2, zoom);
  final north = unmercLat(cy - height / 2, zoom), south = unmercLat(cy + height / 2, zoom);
  final fills = List<ui.Path?>.filled(data.styles.length, null);
  var drawn = 0;
  for (final s in data.shapes) {
    if (s.maxLat < south || s.minLat > north || s.maxLon < west || s.minLon > east) continue;
    drawn++;
    final path = fills[s.style] ??= ui.Path();
    final n = s.points;
    if (n < 3) continue;
    path.moveTo(mercX(s.ll[1], zoom) - cx, mercY(s.ll[0], zoom) - cy);
    for (var i = 1; i < n; i++) {
      path.lineTo(mercX(s.ll[2 * i + 1], zoom) - cx, mercY(s.ll[2 * i], zoom) - cy);
    }
    path.close();
  }
  final rec = ui.PictureRecorder();
  final canvas = Canvas(rec);
  canvas.scale(ratio);
  canvas.translate(width / 2, height / 2);
  for (var i = 0; i < fills.length; i++) {
    final p = fills[i];
    if (p == null) continue;
    final st = data.styles[i];
    canvas.drawPath(p, Paint()..color = st.fill);
    canvas.drawPath(
      p,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = st.borderWidth
        ..strokeJoin = StrokeJoin.round
        ..color = st.border,
    );
  }
  return CellRender(rec.endRecording(), center, zoom, width, height, ratio, data, drawn);
}

/// Decides whether [render] still serves [camera]: same data, a zoom close enough, and the whole screen inside the painted area.
bool renderCovers(CellRender render, MapCamera camera, CellLayerData data, {double rezoomLevels = 0.45, double inset = 0.06}) {
  if (!identical(render.data, data)) return false;
  if ((camera.zoom - render.zoom).abs() > rezoomLevels) return false;
  final s = math.pow(2, camera.zoom - render.zoom).toDouble();
  final o = camera.latLngToScreenOffset(render.center);
  final rot = camera.rotationRad;
  final cr = math.cos(rot), sr = math.sin(rot);
  final size = camera.nonRotatedSize;
  final hw = render.width / 2 * (1 - inset) * s, hh = render.height / 2 * (1 - inset) * s;
  for (final c in [Offset.zero, Offset(size.width, 0), Offset(0, size.height), Offset(size.width, size.height)]) {
    // screen -> render axes: undo the rotation about the origin point.
    final d = c - o;
    final lx = d.dx * cr + d.dy * sr;
    final ly = -d.dx * sr + d.dy * cr;
    if (lx.abs() > hw || ly.abs() > hh) return false;
  }
  return true;
}

/// Draws [render] with [camera]'s transform (an image when rasterised, else the picture).
void drawRender(Canvas canvas, CellRender render, MapCamera camera) {
  final o = camera.latLngToScreenOffset(render.center);
  final s = math.pow(2, camera.zoom - render.zoom).toDouble();
  canvas.save();
  canvas.translate(o.dx, o.dy);
  canvas.rotate(camera.rotationRad);
  canvas.scale(s);
  final img = render.image;
  if (img != null) {
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(-render.width / 2, -render.height / 2, render.width, render.height),
      Paint()..filterQuality = FilterQuality.medium,
    );
  } else {
    canvas.drawPicture(render.picture);
  }
  canvas.restore();
}

/// A flutter_map child layer drawing [data] from a cached picture.
class CellRasterLayer extends StatefulWidget {
  final CellLayerData data;

  /// The picture is repainted when the camera zoom moves this many levels from the painted one.
  final double rezoomLevels;

  /// Pixel budget of the cached image (width x height x ratio^2); the ratio drops to fit.
  final double maxPixels;
  const CellRasterLayer({super.key, required this.data, this.rezoomLevels = 0.45, this.maxPixels = 12e6});

  /// Pictures painted by every cell layer so far (the health recorder samples the difference).
  static int totalPaints = 0;

  @override
  State<CellRasterLayer> createState() => CellRasterLayerState();
}

class CellRasterLayerState extends State<CellRasterLayer> {
  CellRender? _render;
  bool _scheduled = false;
  int _gen = 0;

  /// Painted pictures so far and cells in the newest one (tests, the health recorder).
  int paints = 0;
  int get cellsInPicture => _render?.cellsDrawn ?? 0;

  @override
  void dispose() {
    _gen++;
    _render?.dispose();
    super.dispose();
  }

  void _schedule(MapCamera camera, double dpr) {
    if (_scheduled) return;
    _scheduled = true;
    final snapshot = camera;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!mounted) return;
      _paint(snapshot, dpr);
    });
  }

  void _paint(MapCamera camera, double dpr) {
    final data = widget.data;
    final size = camera.nonRotatedSize;
    final diag = math.sqrt(size.width * size.width + size.height * size.height);
    // A square that covers the screen at ANY rotation, with margin to drive in before the next paint.
    final side = (diag * 1.5).clamp(300.0, 4000.0);
    var ratio = math.min(dpr, 1.5);
    ratio = math.min(ratio, math.sqrt(widget.maxPixels / (side * side)));
    final zoom = (camera.zoom * 4).round() / 4;
    final r = paintCells(data, camera.center, zoom, side, side, ratio);
    final old = _render;
    _render = r;
    paints++;
    CellRasterLayer.totalPaints++;
    old?.dispose();
    if (mounted) setState(() {});
    final gen = ++_gen;
    r.picture
        .toImage((side * ratio).ceil(), (side * ratio).ceil())
        .then((img) {
          if (!mounted || gen != _gen || _render != r) {
            img.dispose();
            return;
          }
          r.image = img;
          setState(() {});
        })
        .catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final data = widget.data;
    if (data.isEmpty) {
      if (_render != null) {
        _render!.dispose();
        _render = null;
      }
      return const SizedBox.shrink();
    }
    final r = _render;
    if (r == null || !renderCovers(r, camera, data, rezoomLevels: widget.rezoomLevels)) _schedule(camera, dpr);
    if (r == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(size: Size.infinite, painter: _CellPainter(r, camera)),
      ),
    );
  }
}

class _CellPainter extends CustomPainter {
  final CellRender render;
  final MapCamera camera;
  _CellPainter(this.render, this.camera);

  @override
  void paint(Canvas canvas, Size size) => drawRender(canvas, render, camera);

  @override
  bool shouldRepaint(_CellPainter old) => true;
}
