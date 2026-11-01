// The regions next to the one being viewed, for the map's "Regions" layer (the website's region switching, meshcore-insights
// src/lib/region/neighbours.ts and `regions-index?near=<slug>`): outlines and names of the nearest regions, so the next
// region over is visible and one tap away. Computed on the phone from the regions-index it already keeps for offline use
// (outlines thinned to about 300 m), so the layer works with no signal and costs no request. The order is the server's: the
// smallest gap between bounding boxes first, then the nearest centre. Pure Dart: no Flutter imports.
import 'dart:math' as math;

import 'region_lookup.dart';
import 'region_pick.dart' show pointInBoundary;
import 'region_search.dart' show shortNameOf;

/// How many neighbours the map shows (the website's `near` read returns the region itself plus 15).
const int kRegionNeighbourMax = 15;

/// Beyond this map zoom the layer is hidden (street level while driving: the neighbours are not what you are looking at).
const double kRegionLayerMaxZoom = 12.5;

class RegionNeighbour {
  final RegionIndexEntry region;

  /// The outer ring of each part of the outline as (lat, lon) pairs; holes are left out.
  final List<List<({double lat, double lon})>> rings;

  /// Where the name sits: the middle of the region's largest part.
  final ({double lat, double lon}) label;

  /// Metres between this region's box and the viewed region's box (0 = they touch or overlap).
  final double gapM;
  const RegionNeighbour({required this.region, required this.rings, required this.label, required this.gapM});

  String get name => shortNameOf(region);

  /// True when ([lat], [lon]) is inside this region's outline (its box when the server sent no outline).
  bool contains(double lat, double lon) {
    final b = region.bbox;
    if (b != null && (lon < b[0] || lon > b[2] || lat < b[1] || lat > b[3])) return false;
    final bd = region.boundary;
    return bd == null ? b != null : pointInBoundary(bd, lat, lon);
  }
}

/// The neighbours of [viewing] and the viewed region itself (so a tap inside it never offers a switch).
class RegionNeighbourSet {
  final RegionIndexEntry viewing;
  final List<RegionNeighbour> neighbours;
  const RegionNeighbourSet({required this.viewing, required this.neighbours});

  bool get isEmpty => neighbours.isEmpty;

  /// The neighbour at ([lat], [lon]), or null when the point is inside the viewed region itself, or in no neighbour.
  RegionNeighbour? hit(double lat, double lon) {
    final own = viewing.boundary == null ? null : pointInBoundary(viewing.boundary!, lat, lon);
    if (own == true) return null;
    final inBox = viewing.bbox != null &&
        lon >= viewing.bbox![0] && lon <= viewing.bbox![2] && lat >= viewing.bbox![1] && lat <= viewing.bbox![3];
    if (own == null && inBox) return null;
    RegionNeighbour? best;
    var bestArea = double.infinity;
    for (final n in neighbours) {
      if (!n.contains(lat, lon)) continue;
      final b = n.region.bbox;
      final area = b == null ? double.infinity : (b[2] - b[0]) * (b[3] - b[1]);
      if (area < bestArea) {
        best = n;
        bestArea = area;
      }
    }
    return best;
  }
}

/// The [limit] regions nearest to [viewing] in [index], nearest first (smallest box gap, then nearest centre). Regions
/// without a box are skipped; so is [viewing] itself.
RegionNeighbourSet neighboursOf(List<RegionIndexEntry> index, RegionIndexEntry viewing, {int limit = kRegionNeighbourMax}) {
  final vb = viewing.bbox;
  if (vb == null) return RegionNeighbourSet(viewing: viewing, neighbours: const []);
  final vLat = (vb[1] + vb[3]) / 2, vLon = (vb[0] + vb[2]) / 2;
  final keyed = <(RegionIndexEntry, double, double)>[];
  for (final r in index) {
    final b = r.bbox;
    if (b == null || r.code == viewing.code) continue;
    final gap = _boxGapM(vb, b);
    final centre = _haversineM(vLat, vLon, (b[1] + b[3]) / 2, (b[0] + b[2]) / 2);
    keyed.add((r, gap, centre));
  }
  keyed.sort((a, b) {
    final g = a.$2.compareTo(b.$2);
    if (g != 0) return g;
    final c = a.$3.compareTo(b.$3);
    return c != 0 ? c : a.$1.slug.compareTo(b.$1.slug);
  });
  return RegionNeighbourSet(viewing: viewing, neighbours: [
    for (final k in keyed.take(limit)) _neighbour(k.$1, k.$2),
  ]);
}

RegionNeighbour _neighbour(RegionIndexEntry r, double gapM) {
  final rings = _outerRings(r.boundary);
  final b = r.bbox!;
  var label = (lat: (b[1] + b[3]) / 2, lon: (b[0] + b[2]) / 2);
  if (rings.isNotEmpty) {
    // The middle of the largest part, so a region with an island or an exclave is named on its main body.
    var best = rings.first;
    var bestArea = -1.0;
    for (final ring in rings) {
      final a = _ringBoxArea(ring);
      if (a > bestArea) {
        best = ring;
        bestArea = a;
      }
    }
    final mid = _ringMid(best);
    final bd = r.boundary;
    label = bd != null && pointInBoundary(bd, mid.lat, mid.lon) ? mid : label;
  }
  return RegionNeighbour(region: r, rings: rings, label: label, gapM: gapM);
}

List<List<({double lat, double lon})>> _outerRings(Map<String, dynamic>? boundary) {
  if (boundary == null) return const [];
  final coords = boundary['coordinates'];
  final out = <List<({double lat, double lon})>>[];
  void add(Object? ring) {
    if (ring is! List) return;
    final pts = <({double lat, double lon})>[];
    for (final p in ring) {
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num) pts.add((lat: (p[1] as num).toDouble(), lon: (p[0] as num).toDouble()));
    }
    if (pts.length >= 3) out.add(pts);
  }

  if (coords is! List) return const [];
  if (boundary['type'] == 'Polygon') {
    if (coords.isNotEmpty) add(coords.first);
  } else if (boundary['type'] == 'MultiPolygon') {
    for (final poly in coords) {
      if (poly is List && poly.isNotEmpty) add(poly.first);
    }
  }
  return out;
}

double _ringBoxArea(List<({double lat, double lon})> ring) {
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (final p in ring) {
    minLat = math.min(minLat, p.lat);
    maxLat = math.max(maxLat, p.lat);
    minLon = math.min(minLon, p.lon);
    maxLon = math.max(maxLon, p.lon);
  }
  return (maxLat - minLat) * (maxLon - minLon);
}

({double lat, double lon}) _ringMid(List<({double lat, double lon})> ring) {
  var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
  for (final p in ring) {
    minLat = math.min(minLat, p.lat);
    maxLat = math.max(maxLat, p.lat);
    minLon = math.min(minLon, p.lon);
    maxLon = math.max(maxLon, p.lon);
  }
  return (lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2);
}

/// Metres between two boxes ([west, south, east, north]); 0 when they touch or overlap. The website's formula
/// (`bboxGapKm`, src/lib/region/neighbours.ts), so the app and the server agree on who is nearest.
double _boxGapM(List<double> a, List<double> b) {
  const kmPerDeg = 111.195;
  final dLat = math.max(0.0, math.max(a[1] - b[3], b[1] - a[3]));
  final dLon = math.max(0.0, math.max(a[0] - b[2], b[0] - a[2]));
  final midLat = ((math.max(a[1], b[1]) + math.min(a[3], b[3])) / 2) * (math.pi / 180);
  final lat = midLat.isFinite ? math.cos(midLat) : 1.0;
  final x = dLon * kmPerDeg * math.max(0.05, lat.abs());
  final y = dLat * kmPerDeg;
  return math.sqrt(x * x + y * y) * 1000;
}

double _haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
  return 2 * r * math.asin(math.min(1.0, math.sqrt(a)));
}
