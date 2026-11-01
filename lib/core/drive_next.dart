// "Where to drive next": gaps in the network's measured coverage near the phone, from the cells the app already has
// (GET /api/cmh/public-coverage, the website's /coverage data). Two honest kinds:
//   silent   - a cell somebody drove and the mesh heard nothing (the map draws it grey). A real hole.
//   unmapped - a hexagon near you with no measurement at all. Nobody has driven it; it may still be water or a field.
// Pure Dart over an injected [H3] (null: only silent cells are found, unmapped needs hexagon ids).
import 'dart:math' as math;

import 'package:h3_flutter/h3_flutter.dart';

import 'api.dart';

enum DriveTargetKind { silent, unmapped }

class DriveTarget {
  final DriveTargetKind kind;
  final double lat;
  final double lon;
  final double distanceM;

  /// Pings measured in it (silent cells), 0 for unmapped.
  final int pings;
  const DriveTarget({
    required this.kind,
    required this.lat,
    required this.lon,
    required this.distanceM,
    this.pings = 0,
  });
}

/// Great-circle distance in metres.
double distanceMetres(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(lat1)) *
          math.cos(rad(lat2)) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Apple Maps driving directions to a point (opens the Maps app on an iPhone/iPad; the web page elsewhere).
Uri appleMapsDirections(double lat, double lon, {String? label}) =>
    Uri.https('maps.apple.com', '/', {
      'daddr': '${lat.toStringAsFixed(6)},${lon.toStringAsFixed(6)}',
      'dirflg': 'd',
      'q': ?label,
    });

/// Up to [limit] targets of each kind within [radiusM] of the phone, nearest first, no two closer than [spacingM].
List<DriveTarget> driveNextTargets({
  required PublicCoverage? coverage,
  required double lat,
  required double lon,
  H3? h3,
  double radiusM = 15000,
  int limit = 4,
  double spacingM = 1200,
}) {
  if (coverage == null) return const [];
  final silent = <DriveTarget>[];
  for (final c in coverage.cells) {
    if (!c.lat.isFinite || !c.lon.isFinite || c.heard > 0 || c.pings <= 0) {
      continue;
    }
    final d = distanceMetres(lat, lon, c.lat, c.lon);
    if (d <= radiusM) {
      silent.add(
        DriveTarget(
          kind: DriveTargetKind.silent,
          lat: c.lat,
          lon: c.lon,
          distanceM: d,
          pings: c.pings,
        ),
      );
    }
  }
  final out = [..._spaced(silent, limit, spacingM)];

  final gridRes = coverage.grid.res;
  if (h3 != null &&
      coverage.grid.kind == CoverageGridKind.h3 &&
      gridRes != null) {
    final res = math.min(gridRes, 8);
    final mapped = <BigInt>{};
    for (final c in coverage.cells) {
      final raw = c.h3;
      if (raw == null) continue;
      try {
        var idx = BigInt.parse(raw, radix: 16);
        if (gridRes > res) idx = h3.cellToParent(idx, res);
        mapped.add(idx);
      } catch (_) {}
    }
    // Rings of about 0.9 km (res 8): enough to reach radiusM.
    final k = (radiusM / 900).ceil().clamp(1, 20);
    final unmapped = <DriveTarget>[];
    try {
      final centre = h3.geoToCell(GeoCoord(lon: lon, lat: lat), res);
      for (final cell in h3.gridDisk(centre, k)) {
        if (mapped.contains(cell)) continue;
        final g = h3.cellToGeo(cell);
        final d = distanceMetres(lat, lon, g.lat, g.lon);
        if (d <= radiusM) {
          unmapped.add(
            DriveTarget(
              kind: DriveTargetKind.unmapped,
              lat: g.lat,
              lon: g.lon,
              distanceM: d,
            ),
          );
        }
      }
    } catch (_) {}
    out.addAll(_spaced(unmapped, limit, spacingM));
  }
  return out;
}

List<DriveTarget> _spaced(List<DriveTarget> all, int limit, double spacingM) {
  all.sort((a, b) => a.distanceM.compareTo(b.distanceM));
  final picked = <DriveTarget>[];
  for (final t in all) {
    if (picked.length >= limit) break;
    if (picked.any(
      (p) => distanceMetres(p.lat, p.lon, t.lat, t.lon) < spacingM,
    )) {
      continue;
    }
    picked.add(t);
  }
  return picked;
}

/// Initial compass bearing from the first point to the second, degrees clockwise from north.
double bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final y = math.sin(rad(lon2 - lon1)) * math.cos(rad(lat2));
  final x =
      math.cos(rad(lat1)) * math.sin(rad(lat2)) -
      math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(rad(lon2 - lon1));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}
