// Region geometry for the switcher and the "which region am I in" rule: point-in-polygon against the server's
// `boundary` (Polygon/MultiPolygon, holes honoured), distance to a region, and the switcher's order.
// Spec: app-website-parity-and-region-spec C.2/C.3 and Andy's Oct 21 decision (the switcher lists ALL regions,
// GPS region first, then by distance; outside every region the nearest region is the one shown).
// Pure Dart: no Flutter imports.
import 'dart:math' as math;

import 'region_lookup.dart';

/// Ray-cast test of [lat]/[lon] against one linear ring of `[lon, lat]` pairs.
bool _inRing(List<dynamic> ring, double lat, double lon) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if (a is! List || b is! List || a.length < 2 || b.length < 2) continue;
    final xi = (a[0] as num).toDouble(), yi = (a[1] as num).toDouble();
    final xj = (b[0] as num).toDouble(), yj = (b[1] as num).toDouble();
    if ((yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

/// Polygon = [outer, hole, hole, ...].
bool _inPolygon(List<dynamic> rings, double lat, double lon) {
  if (rings.isEmpty || rings.first is! List) return false;
  if (!_inRing(rings.first as List, lat, lon)) return false;
  for (var i = 1; i < rings.length; i++) {
    if (rings[i] is List && _inRing(rings[i] as List, lat, lon)) return false;
  }
  return true;
}

/// True when [lat]/[lon] is inside [boundary] (GeoJSON Polygon or MultiPolygon). A malformed boundary is "not inside".
bool pointInBoundary(Map<String, dynamic> boundary, double lat, double lon) {
  try {
    final c = boundary['coordinates'];
    if (c is! List) return false;
    if (boundary['type'] == 'Polygon') return _inPolygon(c, lat, lon);
    if (boundary['type'] == 'MultiPolygon') {
      for (final poly in c) {
        if (poly is List && _inPolygon(poly, lat, lon)) return true;
      }
    }
  } catch (_) {}
  return false;
}

double _bboxArea(List<double> b) => (b[2] - b[0]).abs() * (b[3] - b[1]).abs();

/// The region that contains [lat]/[lon]: bbox first, then the real boundary when the region has one. Where several
/// match (a shared border), the smallest bbox wins (a more specific region beats a wide one), ties by code.
RegionIndexEntry? regionContaining(List<RegionIndexEntry> index, double lat, double lon) {
  if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) return null;
  final hits = <RegionIndexEntry>[];
  for (final r in index) {
    final b = r.bbox;
    if (b == null) continue;
    if (lon < b[0] || lon > b[2] || lat < b[1] || lat > b[3]) continue;
    final boundary = r.boundary;
    if (boundary != null && !pointInBoundary(boundary, lat, lon)) continue;
    hits.add(r);
  }
  if (hits.isEmpty) return null;
  hits.sort((a, b) {
    final c = _bboxArea(a.bbox!).compareTo(_bboxArea(b.bbox!));
    return c != 0 ? c : a.code.compareTo(b.code);
  });
  return hits.first;
}

/// Centre of a region's bbox, or null without one.
({double lat, double lon})? regionCenter(RegionIndexEntry r) {
  final b = r.bbox;
  if (b == null) return null;
  return (lat: (b[1] + b[3]) / 2, lon: (b[0] + b[2]) / 2);
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

/// Metres from [lat]/[lon] to the region's bbox (0 inside it); null when the region has no bbox.
double? distanceToRegionM(RegionIndexEntry r, double lat, double lon) {
  final b = r.bbox;
  if (b == null) return null;
  final cLat = lat.clamp(b[1], b[3]).toDouble();
  final cLon = lon.clamp(b[0], b[2]).toDouble();
  return _haversineM(lat, lon, cLat, cLon);
}

/// The switcher's order: [gpsRegion] first, then nearest first by distance from the fix, then (no fix or no bbox)
/// by name. Every region in [index] is listed: there is no "bordering only" filter.
List<RegionIndexEntry> regionsForSwitcher(List<RegionIndexEntry> index, {RegionIndexEntry? gpsRegion, double? lat, double? lon}) {
  final out = List<RegionIndexEntry>.of(index);
  double d(RegionIndexEntry r) {
    if (lat == null || lon == null) return double.infinity;
    return distanceToRegionM(r, lat, lon) ?? double.infinity;
  }

  out.sort((a, b) {
    if (a.code == gpsRegion?.code) return -1;
    if (b.code == gpsRegion?.code) return 1;
    final c = d(a).compareTo(d(b));
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  return out;
}

/// The region nearest to a fix (used when the phone is outside every region); null without a fix or any bbox.
RegionIndexEntry? nearestRegion(List<RegionIndexEntry> index, double lat, double lon) {
  RegionIndexEntry? best;
  var bestD = double.infinity;
  for (final r in index) {
    final dist = distanceToRegionM(r, lat, lon);
    if (dist != null && dist < bestD) {
      bestD = dist;
      best = r;
    }
  }
  return best;
}
