// Region geometry for the switcher and the "which region am I in" rule: point-in-polygon against the server's
// `boundary` (Polygon/MultiPolygon, holes honoured), distance to a region, and the switcher's order.
// Spec: app-website-parity-and-region-spec C.2/C.3 and Andy's Oct 21 decision (the switcher lists ALL regions,
// GPS region first, then by distance; outside every region the nearest region is the one shown).
// Pure Dart: no Flutter imports.
import 'dart:math' as math;

import 'region_geometry.dart';
import 'region_lookup.dart';

/// True when [lat]/[lon] is inside [boundary] (GeoJSON Polygon or MultiPolygon, holes honoured). A malformed boundary
/// is "not inside". Runs on the typed-array form of the boundary (lib/core/region_geometry.dart), built once.
bool pointInBoundary(Map<String, dynamic> boundary, double lat, double lon) => PreparedBoundary.of(boundary)?.contains(lat, lon) ?? false;

/// Whether [r] holds the fix: inside its bbox and, when it has a boundary, inside that. No bbox = never.
bool regionHolds(RegionIndexEntry r, double lat, double lon) {
  final b = r.bbox;
  if (b == null || lon < b[0] || lon > b[2] || lat < b[1] || lat > b[3]) return false;
  final boundary = r.boundary;
  return boundary == null || pointInBoundary(boundary, lat, lon);
}

double _bboxArea(List<double> b) => (b[2] - b[0]).abs() * (b[3] - b[1]).abs();

/// Size used to rank overlapping regions: the real boundary area when there is one, else the bbox area (km2-ish).
double _size(RegionIndexEntry r) {
  final bd = r.boundary;
  final p = bd == null ? null : PreparedBoundary.of(bd);
  if (p != null) return p.areaKm2;
  final b = r.bbox!;
  return _bboxArea(b) * 111.32 * 111.32 * math.cos((b[1] + b[3]) / 2 * math.pi / 180).abs();
}

int _bySizeThenCode(RegionIndexEntry a, RegionIndexEntry b) {
  final c = _size(a).compareTo(_size(b));
  return c != 0 ? c : a.code.compareTo(b.code);
}

/// EVERY region that contains [lat]/[lon], most specific first (smallest real area, ties by code). More than one is
/// normal near a shared border and for nested zones: the server lists a positioned node in each of them
/// (docs/REGION_BORDERS.md N1) and gives a ping to exactly one (rule 4 of the Oct 21 overlap rules), which the phone
/// cannot reproduce (it needs the observers). The phone shows the first and can say "also in ...".
List<RegionIndexEntry> regionsContaining(List<RegionIndexEntry> index, double lat, double lon) {
  if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) return const [];
  final hits = <RegionIndexEntry>[];
  for (final r in index) {
    if (regionHolds(r, lat, lon)) hits.add(r);
  }
  if (hits.length > 1) hits.sort(_bySizeThenCode);
  return hits;
}

/// The region that contains [lat]/[lon]: bbox first, then the real boundary when the region has one. Where several
/// match (a shared border), the smallest one wins (a more specific region beats a wide one), ties by code.
///
/// [seamM] > 0 adds a seam rule for outlines that were thinned for the wire (the hub index is simplified to about
/// 300 m, so two neighbours no longer share an exact edge and a fix on the seam can fall in neither): with no real
/// hit, the region whose edge is nearest within [seamM] metres is returned. The default 0 is the exact rule.
RegionIndexEntry? regionContaining(List<RegionIndexEntry> index, double lat, double lon, {double seamM = 0}) {
  if (!lat.isFinite || !lon.isFinite || lat.abs() > 90 || lon.abs() > 180) return null;
  final hits = regionsContaining(index, lat, lon);
  if (hits.isNotEmpty) return hits.first;
  if (seamM <= 0) return null;
  return _nearestEdge(index, lat, lon, seamM)?.$1;
}

/// The region with the nearest boundary edge within [maxM] metres of a fix that is inside none, with that distance.
(RegionIndexEntry, double)? _nearestEdge(List<RegionIndexEntry> index, double lat, double lon, double maxM) {
  final padLat = maxM / 111320.0;
  final padLon = maxM / (111320.0 * math.max(0.01, math.cos(lat * math.pi / 180)));
  (RegionIndexEntry, double)? best;
  for (final r in index) {
    final b = r.bbox, bd = r.boundary;
    if (b == null || bd == null) continue;
    if (lon < b[0] - padLon || lon > b[2] + padLon || lat < b[1] - padLat || lat > b[3] + padLat) continue;
    final d = distanceToBoundaryM(bd, lat, lon);
    if (d <= maxM && (best == null || d < best.$2 || (d == best.$2 && r.code.compareTo(best.$1.code) < 0))) best = (r, d);
  }
  return best;
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

/// Metres from the fix to the region's bbox centre (the tie-break among regions whose bbox all hold the fix).
double? _distanceToCentreM(RegionIndexEntry r, double lat, double lon) {
  final c = regionCenter(r);
  return c == null ? null : _haversineM(lat, lon, c.lat, c.lon);
}

/// The switcher's order: [gpsRegion] first, then nearest first by distance from the fix (to the bbox; regions whose
/// bbox holds the fix by distance to their centre, so a fix inside a big region's box still ranks the small town next
/// to you before a far one), then (no fix or no bbox) by name. Every region in [index] is listed: no "bordering only"
/// filter. The sort keys are computed once per region, not once per comparison.
List<RegionIndexEntry> regionsForSwitcher(List<RegionIndexEntry> index, {RegionIndexEntry? gpsRegion, double? lat, double? lon}) {
  final hasFix = lat != null && lon != null;
  final keyed = [
    for (final r in index)
      (
        r,
        hasFix ? (distanceToRegionM(r, lat, lon) ?? double.infinity) : double.infinity,
        hasFix ? (_distanceToCentreM(r, lat, lon) ?? double.infinity) : double.infinity,
      ),
  ];
  keyed.sort((a, b) {
    if (a.$1.code == gpsRegion?.code) return -1;
    if (b.$1.code == gpsRegion?.code) return 1;
    var c = a.$2.compareTo(b.$2);
    if (c == 0) c = a.$3.compareTo(b.$3);
    return c != 0 ? c : a.$1.name.compareTo(b.$1.name);
  });
  return [for (final k in keyed) k.$1];
}

/// The region nearest to a fix (used when the phone is outside every region); null without a fix or any bbox.
/// Judged by the real boundary where there is one: a fix inside the BOX of several regions but inside none of them
/// gets the one whose edge is nearest, not whichever box is listed first.
RegionIndexEntry? nearestRegion(List<RegionIndexEntry> index, double lat, double lon) {
  final cand = <(RegionIndexEntry, double)>[];
  for (final r in index) {
    final d = distanceToRegionM(r, lat, lon);
    if (d != null) cand.add((r, d));
  }
  if (cand.isEmpty) return null;
  cand.sort((a, b) => a.$2.compareTo(b.$2));
  // The boxes are lower bounds of the real distances: refine only the ones that could still win.
  RegionIndexEntry? best;
  var bestD = double.infinity;
  for (final c in cand) {
    if (c.$2 > bestD) break;
    final bd = c.$1.boundary;
    var d = c.$2;
    if (bd != null) {
      final inside = pointInBoundary(bd, lat, lon);
      d = inside ? 0 : distanceToBoundaryM(bd, lat, lon);
      if (!d.isFinite) d = c.$2;
    }
    if (d < bestD || (d == bestD && best != null && c.$1.code.compareTo(best.code) < 0)) {
      bestD = d;
      best = c.$1;
    }
  }
  return best;
}
