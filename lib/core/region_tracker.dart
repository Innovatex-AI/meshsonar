// Which region the phone is in, with hysteresis so a border crossing (or GPS jitter on the border) never flaps.
// Pure Dart. Spec: app-website-parity-and-region-spec WP-R1 / E.5.
//
// Rules, in order, for each fix:
//  1. First fix commits immediately (nothing to flap from).
//  2. Same region as committed: all good, reset any pending switch.
//  3. The committed region still contains the fix (overlap zone, shared border): stay. Overlap never switches.
//  4. Outside every region: keep the committed region for [outsideGrace]; after that the committed region becomes
//     null ("outside coverage"). Brief gaps (tunnels, boundary simplification) never drop it.
//  5. Inside another region B but outside the committed one: hold while the fix is within [edgeMarginM] of the
//     committed region's boundary (near-edge: GPS error can put you on the wrong side), otherwise B must win
//     [confirmFixes] consecutive fixes before it is committed.
import 'dart:math' as math;

import 'region_lookup.dart';
import 'region_pick.dart';

/// Metres from a point to the nearest edge of a GeoJSON Polygon/MultiPolygon [boundary] (any ring, so holes count).
/// Infinity for a malformed boundary. Local equirectangular projection: accurate to well under a metre at region
/// scale, which is far finer than GPS.
double distanceToBoundaryM(Map<String, dynamic> boundary, double lat, double lon) {
  final cosLat = math.cos(lat * math.pi / 180);
  const mPerDeg = 111320.0;
  var best = double.infinity;
  double segDist(double ax, double ay, double bx, double by) {
    // Coordinates in metres relative to the query point (which is the origin).
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : (-(ax * dx + ay * dy) / len2);
    t = t.clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    return math.sqrt(px * px + py * py);
  }

  void ring(List<dynamic> pts) {
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      if (a is! List || b is! List || a.length < 2 || b.length < 2) continue;
      final d = segDist(((a[0] as num) - lon) * mPerDeg * cosLat, ((a[1] as num) - lat) * mPerDeg,
          ((b[0] as num) - lon) * mPerDeg * cosLat, ((b[1] as num) - lat) * mPerDeg);
      if (d < best) best = d;
    }
  }

  try {
    final c = boundary['coordinates'];
    if (c is! List) return double.infinity;
    void poly(List<dynamic> rings) {
      for (final r in rings) {
        if (r is List) ring(r);
      }
    }

    if (boundary['type'] == 'Polygon') {
      poly(c);
    } else if (boundary['type'] == 'MultiPolygon') {
      for (final p in c) {
        if (p is List) poly(p);
      }
    }
  } catch (_) {}
  return best;
}

/// What one fix did to the tracker.
class RegionTrackUpdate {
  final RegionIndexEntry? current;
  final RegionIndexEntry? previous;

  /// True when [current] differs from the region committed before this fix.
  final bool changed;

  /// The fix is within [RegionTracker.nearEdgeM] of the committed region's boundary.
  final bool nearEdge;
  const RegionTrackUpdate({required this.current, required this.previous, required this.changed, required this.nearEdge});
}

class RegionTracker {
  final int confirmFixes;
  final double edgeMarginM;
  final double nearEdgeM;
  final Duration outsideGrace;
  RegionTracker({
    this.confirmFixes = 3,
    this.edgeMarginM = 100,
    this.nearEdgeM = 300,
    this.outsideGrace = const Duration(seconds: 60),
  });

  RegionIndexEntry? _current;
  String? _pendingCode;
  int _pendingCount = 0;
  DateTime? _outsideSince;

  RegionIndexEntry? get current => _current;

  /// Forget everything (index replaced, server changed).
  void reset() {
    _current = null;
    _pendingCode = null;
    _pendingCount = 0;
    _outsideSince = null;
  }

  RegionTrackUpdate update(List<RegionIndexEntry> index, double lat, double lon, DateTime at) {
    final prev = _current;
    // Re-resolve the committed region against the latest index (boundaries may have been refreshed).
    RegionIndexEntry? cur;
    if (prev != null) {
      for (final r in index) {
        if (r.code == prev.code) cur = r;
      }
      _current = cur; // dropped from the index -> treated as outside
    }
    final raw = regionContaining(index, lat, lon);

    void commit(RegionIndexEntry? to) {
      _current = to;
      _pendingCode = null;
      _pendingCount = 0;
      _outsideSince = null;
    }

    if (raw == null) {
      if (_current != null) {
        _outsideSince ??= at;
        if (at.difference(_outsideSince!) >= outsideGrace) commit(null);
      }
    } else {
      _outsideSince = null;
      if (_current == null) {
        commit(raw);
      } else if (raw.code == _current!.code) {
        _pendingCode = null;
        _pendingCount = 0;
      } else if (_stillInside(_current!, lat, lon)) {
        _pendingCode = null; // overlap zone: never switch
        _pendingCount = 0;
      } else {
        final edge = _current!.boundary == null ? double.infinity : distanceToBoundaryM(_current!.boundary!, lat, lon);
        if (edge >= edgeMarginM) {
          if (_pendingCode == raw.code) {
            _pendingCount++;
          } else {
            _pendingCode = raw.code;
            _pendingCount = 1;
          }
          if (_pendingCount >= confirmFixes) commit(raw);
        }
        // else: near-edge hold; keep any pending count as is (do not advance it).
      }
    }

    final now = _current;
    var near = false;
    if (now?.boundary != null) near = distanceToBoundaryM(now!.boundary!, lat, lon) <= nearEdgeM;
    return RegionTrackUpdate(current: now, previous: prev, changed: now?.code != prev?.code, nearEdge: near);
  }

  bool _stillInside(RegionIndexEntry r, double lat, double lon) {
    final b = r.bbox;
    if (b == null) return false;
    if (lon < b[0] || lon > b[2] || lat < b[1] || lat > b[3]) return false;
    final bd = r.boundary;
    return bd == null || pointInBoundary(bd, lat, lon);
  }
}
