// Region boundary geometry on typed arrays: point-in-polygon (holes honoured), distance to the nearest edge and
// planar area. The server's `regions-index` carries ~180k vertices for 559 regions as nested JSON lists; walking
// those dynamically on every GPS fix is slow and allocation-heavy, so each boundary is converted once into flat
// [Float64List]s (with a bounding box per ring, so a ring that cannot contain the fix costs four compares) and the
// result is remembered per boundary object. Pure Dart: no Flutter imports.
import 'dart:math' as math;
import 'dart:typed_data';

/// One linear ring: x/y pairs (lon, lat) plus its bounding box.
class _Ring {
  final Float64List xy; // x0,y0,x1,y1,...
  final double minX, minY, maxX, maxY;
  const _Ring(this.xy, this.minX, this.minY, this.maxX, this.maxY);

  int get count => xy.length ~/ 2;

  bool boxHas(double lon, double lat) => lon >= minX && lon <= maxX && lat >= minY && lat <= maxY;

  /// Ray cast (even-odd). A fix exactly on an edge is decided by the usual half-open rule, which is consistent
  /// between two rings sharing that edge (one side gets it, never both, never neither) for exactly shared vertices.
  bool contains(double lon, double lat) {
    var inside = false;
    final n = count;
    var xj = xy[(n - 1) * 2], yj = xy[(n - 1) * 2 + 1];
    for (var i = 0; i < n; i++) {
      final xi = xy[i * 2], yi = xy[i * 2 + 1];
      if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
      xj = xi;
      yj = yi;
    }
    return inside;
  }

  /// Signed shoelace area in square degrees, scaled by cos(lat) of the ring's middle so it is roughly equal-area.
  double areaDeg2() {
    final n = count;
    var s = 0.0;
    var xj = xy[(n - 1) * 2], yj = xy[(n - 1) * 2 + 1];
    for (var i = 0; i < n; i++) {
      final xi = xy[i * 2], yi = xy[i * 2 + 1];
      s += xj * yi - xi * yj;
      xj = xi;
      yj = yi;
    }
    return s.abs() / 2 * math.cos((minY + maxY) / 2 * math.pi / 180).abs();
  }
}

/// One polygon: the outer ring first, then holes.
class _Poly {
  final List<_Ring> rings;
  const _Poly(this.rings);

  bool contains(double lon, double lat) {
    final outer = rings.first;
    if (!outer.boxHas(lon, lat) || !outer.contains(lon, lat)) return false;
    for (var i = 1; i < rings.length; i++) {
      if (rings[i].boxHas(lon, lat) && rings[i].contains(lon, lat)) return false;
    }
    return true;
  }
}

/// A GeoJSON `Polygon` / `MultiPolygon` on typed arrays. Build with [PreparedBoundary.of] (cached per boundary
/// object) or [PreparedBoundary.tryBuild].
class PreparedBoundary {
  final List<_Poly> _polys;
  PreparedBoundary._(this._polys);

  static final Expando<PreparedBoundary> _cache = Expando('PreparedBoundary');
  static final Expando<bool> _bad = Expando('PreparedBoundary.bad');

  /// The prepared form of [boundary], built once per map object. Null for a malformed boundary (it then matches nothing).
  static PreparedBoundary? of(Map<String, dynamic> boundary) {
    final hit = _cache[boundary];
    if (hit != null) return hit;
    if (_bad[boundary] == true) return null;
    final built = tryBuild(boundary);
    if (built == null) {
      _bad[boundary] = true;
    } else {
      _cache[boundary] = built;
    }
    return built;
  }

  static PreparedBoundary? tryBuild(Map<String, dynamic> boundary) {
    try {
      final c = boundary['coordinates'];
      if (c is! List) return null;
      final polys = <_Poly>[];
      void addPoly(Object? p) {
        if (p is! List) return;
        final rings = <_Ring>[];
        for (final r in p) {
          final ring = _ring(r);
          if (ring != null) rings.add(ring);
        }
        if (rings.isNotEmpty) polys.add(_Poly(rings));
      }

      if (boundary['type'] == 'Polygon') {
        addPoly(c);
      } else if (boundary['type'] == 'MultiPolygon') {
        for (final p in c) {
          addPoly(p);
        }
      } else {
        return null;
      }
      return polys.isEmpty ? null : PreparedBoundary._(polys);
    } catch (_) {
      return null;
    }
  }

  static _Ring? _ring(Object? raw) {
    if (raw is! List) return null;
    final pts = <double>[];
    var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
    for (final p in raw) {
      // One unreadable vertex makes the whole ring untrustworthy: the ring is dropped, not patched.
      if (p is! List || p.length < 2) return null;
      final x = p[0], y = p[1];
      if (x is! num || y is! num) return null;
      final dx = x.toDouble(), dy = y.toDouble();
      if (!dx.isFinite || !dy.isFinite) return null;
      pts
        ..add(dx)
        ..add(dy);
      if (dx < minX) minX = dx;
      if (dx > maxX) maxX = dx;
      if (dy < minY) minY = dy;
      if (dy > maxY) maxY = dy;
    }
    if (pts.length < 6) return null; // fewer than three vertices is not an area
    return _Ring(Float64List.fromList(pts), minX, minY, maxX, maxY);
  }

  /// True when [lat]/[lon] is inside (holes are outside).
  bool contains(double lat, double lon) {
    for (final p in _polys) {
      if (p.contains(lon, lat)) return true;
    }
    return false;
  }

  /// Planar area in square kilometres (equirectangular, outer rings minus holes). For ordering regions by size,
  /// not for surveying.
  late final double areaKm2 = () {
    const kmPerDeg = 111.32;
    var a = 0.0;
    for (final p in _polys) {
      for (var i = 0; i < p.rings.length; i++) {
        final r = p.rings[i].areaDeg2() * kmPerDeg * kmPerDeg;
        a += i == 0 ? r : -r;
      }
    }
    return a;
  }();

  /// Metres from the fix to the nearest edge of any ring (holes count). Local equirectangular projection around
  /// the fix: well under a metre off at region scale. Infinity when there is no edge.
  double distanceM(double lat, double lon) {
    final cosLat = math.cos(lat * math.pi / 180);
    const mPerDeg = 111320.0;
    var best = double.infinity;
    for (final p in _polys) {
      for (final r in p.rings) {
        // A ring whose box is farther away than the best edge so far cannot improve it.
        final dxBox = lon < r.minX ? r.minX - lon : (lon > r.maxX ? lon - r.maxX : 0.0);
        final dyBox = lat < r.minY ? r.minY - lat : (lat > r.maxY ? lat - r.maxY : 0.0);
        final boxM = math.sqrt(math.pow(dxBox * mPerDeg * cosLat, 2) + math.pow(dyBox * mPerDeg, 2));
        if (boxM >= best) continue;
        final xy = r.xy;
        var ax = (xy[0] - lon) * mPerDeg * cosLat, ay = (xy[1] - lat) * mPerDeg;
        for (var i = 1; i < r.count; i++) {
          final bx = (xy[i * 2] - lon) * mPerDeg * cosLat, by = (xy[i * 2 + 1] - lat) * mPerDeg;
          final dx = bx - ax, dy = by - ay;
          final len2 = dx * dx + dy * dy;
          var t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2);
          t = t < 0 ? 0 : (t > 1 ? 1 : t);
          final px = ax + t * dx, py = ay + t * dy;
          final d2 = px * px + py * py;
          if (d2 < best * best) best = math.sqrt(d2);
          ax = bx;
          ay = by;
        }
      }
    }
    return best;
  }
}

/// Metres from a point to the nearest edge of a GeoJSON Polygon/MultiPolygon [boundary] (any ring, so holes count).
/// Infinity for a malformed boundary.
double distanceToBoundaryM(Map<String, dynamic> boundary, double lat, double lon) =>
    PreparedBoundary.of(boundary)?.distanceM(lat, lon) ?? double.infinity;
