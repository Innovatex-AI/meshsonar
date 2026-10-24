// Grid clustering for big point layers (the global "All MeshCore repeaters" layer, ~5-20k points, and the region
// roster). Design: meshsonar-infra docs/planning (stream-1-maps.md section 4.4). Pure Dart: no Flutter imports.
//
// How it works:
// - Every point is projected once to normalised Web Mercator (x, y in [0, 1), the same projection flutter_map's
//   EPSG:3857 uses; one world is 256 * 2^zoom pixels wide).
// - For each integer zoom 0..maxZoom the world is cut into square cells of [ClusterIndex.cellPx] screen pixels. Cells
//   are addressed by a Morton (Z-order) code, so the cell of a point at zoom z is its finest code shifted right by
//   2 * (maxZoom - z). Sorting the points ONCE by their finest code therefore sorts them for every zoom, and each
//   cluster of every level is one contiguous run of that single sorted order: building all levels is one integer sort
//   plus one linear scan per level, and the members of any cluster are a slice of [ClusterIndex.order].
// - Cluster centre = mean of its members (in Mercator), count, dominant band (most common band, lowest wins a tie),
//   member bounds. A cell holding one point is a single. At zoom >= maxZoom every point is drawn on its own.
// - Cluster ids are stable: they depend only on the cell (Morton code + zoom), never on the data or its order.
// - Viewport query: for each visible cell, a binary search in that level's sorted cell codes (or a scan of the level
//   when it has fewer clusters than the viewport has cells), so cost is O(visible), not O(points).
// - Antimeridian: cells are aligned to lon -180, so no cell straddles it; queries whose x range leaves [0, 1) are split
//   and the copies are returned shifted by a whole world so a painter can draw the wrapped world without seams.
// - Poles: latitudes are clamped to the Mercator limit (+-85.0511), as flutter_map does.
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

/// The Web Mercator latitude limit (EPSG:3857), the same flutter_map clamps to.
const double kMercatorMaxLat = 85.0511287798066;

/// Normalised Web Mercator x in [0, 1). Longitudes outside +-180 wrap; 180 maps to 0 (the same meridian as -180).
double mercatorX(double lon) {
  final x = (lon + 180.0) / 360.0;
  final w = x - x.floorToDouble();
  return w >= 1.0 ? 0.0 : w;
}

/// Normalised Web Mercator y in [0, 1) (0 = north edge). Latitudes are clamped to +-[kMercatorMaxLat].
double mercatorY(double lat) {
  final l = lat.clamp(-kMercatorMaxLat, kMercatorMaxLat) * math.pi / 180.0;
  final s = math.sin(l);
  final y = 0.5 - math.log((1 + s) / (1 - s)) / (4 * math.pi);
  return y.clamp(0.0, 1.0 - 1e-12);
}

/// Longitude for a Mercator x (any x; wrapped into -180..180).
double lonFromMercatorX(double x) {
  final w = x - x.floorToDouble();
  return w * 360.0 - 180.0;
}

/// Latitude for a Mercator y in [0, 1].
double latFromMercatorY(double y) {
  final n = math.pi * (1 - 2 * y);
  return math.atan((math.exp(n) - math.exp(-n)) / 2) * 180.0 / math.pi;
}

/// Pixels per world (one Mercator unit) at [zoom], with flutter_map's 256 px tiles.
double worldPixels(double zoom) => 256.0 * math.pow(2, zoom);

/// On-screen radius of a cluster bubble for [count] members (a single point is [singleRadiusPx]). Shared by the
/// painter and the hit test so what you see is what you can tap.
double clusterRadiusPx(int count, {double singleRadiusPx = 5}) {
  if (count <= 1) return singleRadiusPx;
  final r = 10.0 + 3.0 * (math.log(count) / math.ln2);
  return r > 30 ? 30 : r;
}

/// The count text drawn in a cluster: "7", "999", "1.2k", "12k", "1.3M".
String clusterLabel(int count) {
  if (count < 1000) return '$count';
  if (count < 10000) {
    final k = (count / 100).floor() / 10;
    final s = k.toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}k';
  }
  if (count < 1000000) return '${(count / 1000).floor()}k';
  final m = (count / 100000).floor() / 10;
  final s = m.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}M';
}

/// Interleaves the low 20 bits of [x] and [y] (x in the even bits).
int _morton(int x, int y) => _spread(x) | (_spread(y) << 1);

int _spread(int v) {
  var x = v & 0xFFFFF; // 20 bits
  x = (x | (x << 16)) & 0x0000FFFF0000FFFF;
  x = (x | (x << 8)) & 0x00FF00FF00FF00FF;
  x = (x | (x << 4)) & 0x0F0F0F0F0F0F0F0F;
  x = (x | (x << 2)) & 0x3333333333333333;
  x = (x | (x << 1)) & 0x5555555555555555;
  return x;
}

/// Bands above this are clamped (the dominant-band histogram has this many slots).
const int kMaxClusterBands = 16;

/// One zoom level of a [ClusterIndex]: its clusters, sorted by cell code. Plain typed lists, so the whole index moves
/// between isolates cheaply.
class ClusterLevel {
  final int zoom;

  /// Cells per world axis at this zoom.
  final int cellsPerAxis;

  /// Morton code of each cluster's cell, ascending.
  final Int64List cell;

  /// Cluster centre (mean of members), normalised Mercator.
  final Float64List x, y;
  final Int32List count;

  /// Most common member band (lowest wins a tie).
  final Uint8List band;

  /// Members are `order[start[i] .. start[i + 1])` of the index.
  final Int32List start;

  /// Member bounds, normalised Mercator, 4 per cluster: minX, minY, maxX, maxY.
  final Float64List bounds;

  const ClusterLevel({
    required this.zoom,
    required this.cellsPerAxis,
    required this.cell,
    required this.x,
    required this.y,
    required this.count,
    required this.band,
    required this.start,
    required this.bounds,
  });

  int get length => cell.length;

  /// Index of the cluster in [cellCode], or -1.
  int find(int cellCode) {
    var lo = 0, hi = cell.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = cell[mid];
      if (v == cellCode) return mid;
      if (v < cellCode) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return -1;
  }
}

/// Bounds in degrees.
class GeoBounds {
  final double south, west, north, east;
  const GeoBounds({required this.south, required this.west, required this.north, required this.east});

  @override
  bool operator ==(Object other) =>
      other is GeoBounds && other.south == south && other.west == west && other.north == north && other.east == east;
  @override
  int get hashCode => Object.hash(south, west, north, east);
  @override
  String toString() => 'GeoBounds($south, $west, $north, $east)';
}

/// What a viewport query returns: the clusters and singles to draw, index-aligned. [x] already carries the whole-world
/// shift for wrapped copies (so x may be < 0 or >= 1).
class ClusterSlice {
  /// Zoom level the items came from (maxZoom = individual points).
  final int level;
  final Float64List x, y;
  final Int32List count;
  final Uint8List band;

  /// Point index for a single (count 1), else -1.
  final Int32List point;

  /// Index into that level's clusters (for bounds/members), -1 for an individual point at the singles level.
  final Int32List cluster;

  const ClusterSlice({
    required this.level,
    required this.x,
    required this.y,
    required this.count,
    required this.band,
    required this.point,
    required this.cluster,
  });

  int get length => x.length;

  static final ClusterSlice empty = ClusterSlice(
    level: 0,
    x: Float64List(0),
    y: Float64List(0),
    count: Int32List(0),
    band: Uint8List(0),
    point: Int32List(0),
    cluster: Int32List(0),
  );
}

/// The result of a tap on a clustered layer.
class ClusterTap {
  /// Stable id: depends only on the cell and zoom (singles: `-(pointIndex + 1)`).
  final int id;

  /// Number of points under the tap (1 for a single).
  final int count;

  /// The point for a single; null for a cluster.
  final int? point;

  /// Where the item is drawn, degrees.
  final double lat, lon;

  /// The members' bounds (for a single: its own position).
  final GeoBounds bounds;

  /// Every member point index when the members all sit within about 4 m of each other (a stack of repeaters on one
  /// tower, which zooming in never separates); otherwise empty.
  final List<int> colocated;

  const ClusterTap({
    required this.id,
    required this.count,
    required this.point,
    required this.lat,
    required this.lon,
    required this.bounds,
    this.colocated = const [],
  });

  bool get isCluster => point == null;
}

/// A precomputed, immutable clustering of a fixed point set at every integer zoom.
class ClusterIndex {
  /// Points given (including any that were skipped for a non-finite position).
  final int pointCount;

  /// From this zoom on, points are drawn individually.
  final int maxZoom;

  /// Cluster cell size in screen pixels (a power of two from 16 to 256).
  final int cellPx;

  /// Per point (index-aligned with the input): normalised Mercator, NaN for a skipped point.
  final Float64List px, py;

  /// Per point band (clamped to 0..[kMaxClusterBands]-1).
  final Uint8List pointBand;

  /// Valid point indices sorted by finest cell code (then index).
  final Int32List order;

  /// Levels 0..maxZoom (index = zoom). Level [maxZoom] groups the individual points by cell for viewport queries.
  final List<ClusterLevel> levels;

  const ClusterIndex._({
    required this.pointCount,
    required this.maxZoom,
    required this.cellPx,
    required this.px,
    required this.py,
    required this.pointBand,
    required this.order,
    required this.levels,
  });

  /// Number of points actually indexed (finite positions).
  int get indexedCount => order.length;

  /// Builds on this isolate. [lat]/[lon] are index-aligned degrees; [band] is an optional category per point
  /// (colour bucket). Points with a non-finite coordinate are skipped (they keep their index; nothing draws them).
  static ClusterIndex buildSync(Float64List lat, Float64List lon, {Uint8List? band, int maxZoom = 14, int cellPx = 64}) {
    if (lat.length != lon.length || (band != null && band.length != lat.length)) {
      throw ArgumentError('lat, lon and band must have the same length');
    }
    if (cellPx < 16 || cellPx > 256 || (cellPx & (cellPx - 1)) != 0) {
      throw ArgumentError.value(cellPx, 'cellPx', 'must be a power of two from 16 to 256');
    }
    final shift = (math.log(256 / cellPx) / math.ln2).round(); // cells per tile axis = 2^shift
    final finestBits = maxZoom + shift; // bits per axis at the finest level
    if (maxZoom < 0 || finestBits > 19) {
      throw ArgumentError.value(maxZoom, 'maxZoom', 'too deep for cellPx $cellPx');
    }
    final n = lat.length;
    if (n >= (1 << 24)) throw ArgumentError('too many points ($n)');
    final px = Float64List(n), py = Float64List(n);
    final pb = Uint8List(n);
    final finestN = 1 << finestBits;
    final packed = Int64List(n);
    var valid = 0;
    for (var i = 0; i < n; i++) {
      final la = lat[i], lo = lon[i];
      if (!la.isFinite || !lo.isFinite) {
        px[i] = double.nan;
        py[i] = double.nan;
        continue;
      }
      final x = mercatorX(lo), y = mercatorY(la);
      px[i] = x;
      py[i] = y;
      final b = band == null ? 0 : band[i];
      pb[i] = b >= kMaxClusterBands ? kMaxClusterBands - 1 : b;
      var ix = (x * finestN).floor(), iy = (y * finestN).floor();
      if (ix >= finestN) ix = finestN - 1;
      if (iy >= finestN) iy = finestN - 1;
      packed[valid++] = (_morton(ix, iy) << 24) | i;
    }
    final sorted = Int64List.sublistView(packed, 0, valid)..sort();
    final order = Int32List(valid);
    final codes = Int64List(valid);
    for (var k = 0; k < valid; k++) {
      order[k] = sorted[k] & 0xFFFFFF;
      codes[k] = sorted[k] >> 24;
    }
    final levels = <ClusterLevel>[];
    final hist = Int32List(kMaxClusterBands);
    for (var z = 0; z <= maxZoom; z++) {
      final drop = 2 * (maxZoom - z);
      // First pass: count clusters.
      var m = 0;
      int? prev;
      for (var k = 0; k < valid; k++) {
        final c = codes[k] >> drop;
        if (c != prev) {
          m++;
          prev = c;
        }
      }
      final cell = Int64List(m);
      final cx = Float64List(m), cy = Float64List(m);
      final cnt = Int32List(m);
      final cb = Uint8List(m);
      final st = Int32List(m + 1);
      final bd = Float64List(m * 4);
      var j = -1;
      prev = null;
      double sx = 0, sy = 0, minX = 0, minY = 0, maxX = 0, maxY = 0;
      void close() {
        if (j < 0) return;
        final c = cnt[j];
        cx[j] = sx / c;
        cy[j] = sy / c;
        bd[j * 4] = minX;
        bd[j * 4 + 1] = minY;
        bd[j * 4 + 2] = maxX;
        bd[j * 4 + 3] = maxY;
        var best = 0;
        for (var b = 1; b < kMaxClusterBands; b++) {
          if (hist[b] > hist[best]) best = b;
        }
        cb[j] = best;
        hist.fillRange(0, kMaxClusterBands, 0);
      }

      for (var k = 0; k < valid; k++) {
        final c = codes[k] >> drop;
        final i = order[k];
        final x = px[i], y = py[i];
        if (c != prev) {
          close();
          j++;
          prev = c;
          cell[j] = c;
          st[j] = k;
          sx = 0;
          sy = 0;
          minX = maxX = x;
          minY = maxY = y;
        }
        cnt[j]++;
        sx += x;
        sy += y;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
        hist[pb[i]]++;
      }
      close();
      st[m] = valid;
      levels.add(ClusterLevel(
        zoom: z,
        cellsPerAxis: 1 << (z + shift),
        cell: cell,
        x: cx,
        y: cy,
        count: cnt,
        band: cb,
        start: st,
        bounds: bd,
      ));
    }
    return ClusterIndex._(
      pointCount: n,
      maxZoom: maxZoom,
      cellPx: cellPx,
      px: px,
      py: py,
      pointBand: pb,
      order: order,
      levels: List.unmodifiable(levels),
    );
  }

  /// Builds off the UI isolate (`Isolate.run`) when there are at least [isolateThreshold] points; the typed lists are
  /// copied in and the finished index is handed back without a copy.
  static Future<ClusterIndex> build(
    Float64List lat,
    Float64List lon, {
    Uint8List? band,
    int maxZoom = 14,
    int cellPx = 64,
    int isolateThreshold = 2000,
  }) async {
    if (lat.length < isolateThreshold) return buildSync(lat, lon, band: band, maxZoom: maxZoom, cellPx: cellPx);
    return Isolate.run(() => buildSync(lat, lon, band: band, maxZoom: maxZoom, cellPx: cellPx), debugName: 'cluster-index');
  }

  /// The level used to draw at a (fractional) camera [zoom].
  int levelFor(double zoom) {
    if (!zoom.isFinite || zoom <= 0) return 0;
    final z = zoom.floor();
    return z >= maxZoom ? maxZoom : z;
  }

  /// Members (point indices) of cluster [i] of level [level], in cell order.
  Int32List members(int level, int i) {
    final l = levels[level];
    return Int32List.sublistView(order, l.start[i], l.start[i + 1]);
  }

  /// Stable id of cluster [i] at [level].
  int clusterId(int level, int i) => (levels[level].cell[i] << 5) | level;

  /// Everything to draw inside the Mercator rectangle [x0, x1] x [y0, y1] at camera [zoom]. x may extend past 0 or 1
  /// (a camera over the antimeridian or zoomed out past one world); copies are returned shifted by whole worlds. At
  /// most 3 world copies are considered.
  ClusterSlice query(double x0, double y0, double x1, double y1, double zoom) {
    if (order.isEmpty || !(x1 >= x0) || !(y1 >= y0)) return ClusterSlice.empty;
    final level = levelFor(zoom);
    final l = levels[level];
    final singles = level >= maxZoom;
    final nCells = l.cellsPerAxis;
    final ys0 = y0 < 0 ? 0.0 : y0, ys1 = y1 > 1 ? 1.0 : y1;
    if (ys1 < ys0) return ClusterSlice.empty;
    final iy0 = (ys0 * nCells).floor().clamp(0, nCells - 1), iy1 = (ys1 * nCells).floor().clamp(0, nCells - 1);

    final ox = <double>[], oy = <double>[];
    final oc = <int>[], ob = <int>[], op = <int>[], ocl = <int>[];
    void emitCluster(int i, double shiftX) {
      final c = l.count[i];
      if (singles || c == 1) {
        for (var k = l.start[i]; k < l.start[i + 1]; k++) {
          final p = order[k];
          final x = px[p] + shiftX, y = py[p];
          if (x < x0 || x > x1 || y < y0 || y > y1) continue;
          ox.add(x);
          oy.add(y);
          oc.add(1);
          ob.add(pointBand[p]);
          op.add(p);
          ocl.add(singles ? -1 : i);
        }
        return;
      }
      ox.add(l.x[i] + shiftX);
      oy.add(l.y[i]);
      oc.add(c);
      ob.add(l.band[i]);
      op.add(-1);
      ocl.add(i);
    }

    final wStart = x0.floor(), wEnd = x1.floor();
    for (var w = wStart; w <= wEnd && w - wStart < 3; w++) {
      final a = math.max(x0 - w, 0.0), b = math.min(x1 - w, 1.0 - 1e-12);
      if (b < a) continue;
      final ix0 = (a * nCells).floor(), ix1 = (b * nCells).floor().clamp(0, nCells - 1);
      final visibleCells = (ix1 - ix0 + 1) * (iy1 - iy0 + 1);
      if (visibleCells >= l.length) {
        for (var i = 0; i < l.length; i++) {
          // Cell centre test against the cell range, then exact per-item test happens in emit (singles) or here.
          final cx = l.x[i], cy = l.y[i];
          if (singles || l.count[i] == 1) {
            emitCluster(i, w.toDouble());
          } else if (cx + w >= x0 && cx + w <= x1 && cy >= y0 && cy <= y1) {
            emitCluster(i, w.toDouble());
          }
        }
      } else {
        for (var iy = iy0; iy <= iy1; iy++) {
          for (var ix = ix0; ix <= ix1; ix++) {
            final i = l.find(_morton(ix, iy));
            if (i < 0) continue;
            if (singles || l.count[i] == 1) {
              emitCluster(i, w.toDouble());
            } else {
              final cx = l.x[i] + w, cy = l.y[i];
              if (cx >= x0 && cx <= x1 && cy >= y0 && cy <= y1) emitCluster(i, w.toDouble());
            }
          }
        }
      }
    }
    return ClusterSlice(
      level: level,
      x: Float64List.fromList(ox),
      y: Float64List.fromList(oy),
      count: Int32List.fromList(oc),
      band: Uint8List.fromList(ob),
      point: Int32List.fromList(op),
      cluster: Int32List.fromList(ocl),
    );
  }

  /// The nearest single or cluster to the Mercator point ([x], [y]) at camera [zoom], within [radiusPx] screen pixels
  /// (or, for a cluster, within its drawn bubble if that is bigger). Null when nothing is that close. [x] may be in
  /// any world copy.
  ClusterTap? hitTest(double x, double y, double zoom, {double radiusPx = 22, double singleRadiusPx = 5}) {
    if (order.isEmpty || !x.isFinite || !y.isFinite) return null;
    final scale = worldPixels(zoom);
    final reach = math.max(radiusPx, 30.0) / scale; // 30 = largest bubble
    final s = query(x - reach, y - reach, x + reach, y + reach, zoom);
    var best = -1;
    var bestD = double.infinity;
    for (var k = 0; k < s.length; k++) {
      final dx = (s.x[k] - x) * scale, dy = (s.y[k] - y) * scale;
      final d = math.sqrt(dx * dx + dy * dy);
      final limit = math.max(radiusPx, clusterRadiusPx(s.count[k], singleRadiusPx: singleRadiusPx));
      if (d <= limit && d < bestD) {
        bestD = d;
        best = k;
      }
    }
    if (best < 0) return null;
    final level = s.level;
    final p = s.point[best];
    final ci = s.cluster[best];
    final lat = latFromMercatorY(s.y[best]), lon = lonFromMercatorX(s.x[best]);
    if (p >= 0) {
      // A single: also report any other points drawn on the same spot (within about 1 px at this zoom, or ~4 m).
      final here = <int>[];
      final tol = math.max(1.0 / scale, 1e-7);
      for (var k = 0; k < s.length; k++) {
        final q = s.point[k];
        if (q >= 0 && (s.x[k] - s.x[best]).abs() <= tol && (s.y[k] - s.y[best]).abs() <= tol) here.add(q);
      }
      here.sort();
      return ClusterTap(
        id: -(p + 1),
        count: 1,
        point: p,
        lat: lat,
        lon: lon,
        bounds: GeoBounds(south: lat, west: lon, north: lat, east: lon),
        colocated: here.length > 1 ? List.unmodifiable(here) : const [],
      );
    }
    final l = levels[level];
    final bd = l.bounds;
    final b = GeoBounds(
      south: latFromMercatorY(bd[ci * 4 + 3]),
      west: lonFromMercatorX(bd[ci * 4]),
      north: latFromMercatorY(bd[ci * 4 + 1]),
      east: lonFromMercatorX(bd[ci * 4 + 2]),
    );
    final together = (bd[ci * 4 + 2] - bd[ci * 4]) <= 1e-7 && (bd[ci * 4 + 3] - bd[ci * 4 + 1]) <= 1e-7;
    final mem = together ? (members(level, ci).toList()..sort()) : const <int>[];
    return ClusterTap(
      id: clusterId(level, ci),
      count: l.count[ci],
      point: null,
      lat: lat,
      lon: lon,
      bounds: b,
      colocated: List.unmodifiable(mem),
    );
  }
}
