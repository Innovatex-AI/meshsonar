// Network-wide measured coverage (GET /api/cmh/public-coverage), turned into drawable cells: the website's own
// coverage squares/hexagons, not just this phone's pings — "where hasn't this been driven", the gap-visibility
// background layer on the live map (see docs/CHANGELOG.md). An uncovered area draws nothing; a cell only appears
// where the network actually measured something, so absence of a drawn cell is the gap indicator.
//
// Pure logic over an injected [H3] (same convention as hex_cells.dart), so this is unit-testable without the
// native plugin, and so the UI layer never has to know square vs. hexagon geometry.
import 'package:h3_flutter/h3_flutter.dart';

import 'api.dart';
import 'hex_cells.dart' show HexPoint;

/// Which dimension buckets a cell's colour (the layer's colour-by picker: best SNR / share heard / noise floor).
enum CoverageColorBy { snr, heard, noise }

/// A cell's bucket on its [CoverageColorBy] legend, weakest to strongest. [none] means "nothing to show" (no
/// pings yet, heard nothing, or no reading for the chosen dimension) and is drawn as neutral, not a colour step.
enum CoverageLevel { none, weak, fair, good, strong }

/// One drawable network-coverage cell: a boundary (square or hexagon corners) and the bucket it falls in.
class NetworkCell {
  /// H3 hex id, or a synthetic `lat,lon` id for a square cell.
  final String id;

  /// The outline, not closed (first point is not repeated) — same convention as [HexCell].
  final List<HexPoint> boundary;
  final CoverageLevel level;

  /// The measured numbers behind the cell (tap-cell sheet).
  final CoverageCell? cell;
  const NetworkCell({required this.id, required this.boundary, required this.level, this.cell});
}

/// Buckets one [CoverageCell] by [by], using the website's own `/coverage` thresholds (meshcore-insights
/// `src/components/coverage/cells.ts`) so the app's gap layer reads the same as the site's map.
CoverageLevel levelFor(CoverageCell c, CoverageColorBy by) {
  switch (by) {
    case CoverageColorBy.snr:
      if (c.heard <= 0) return CoverageLevel.none;
      final s = c.bestSnr;
      if (s == null) return CoverageLevel.none;
      if (s >= 5) return CoverageLevel.strong;
      if (s >= 0) return CoverageLevel.good;
      if (s >= -5) return CoverageLevel.fair;
      return CoverageLevel.weak;
    case CoverageColorBy.heard:
      if (c.pings <= 0) return CoverageLevel.none;
      final pct = 100 * c.heard / c.pings;
      if (pct >= 75) return CoverageLevel.strong;
      if (pct >= 50) return CoverageLevel.good;
      if (pct >= 25) return CoverageLevel.fair;
      return CoverageLevel.weak;
    case CoverageColorBy.noise:
      final n = c.noiseFloor;
      if (n == null) return CoverageLevel.none;
      if (n < -125) return CoverageLevel.strong;
      if (n < -115) return CoverageLevel.good;
      if (n < -105) return CoverageLevel.fair;
      return CoverageLevel.weak;
  }
}

/// Half-side of a square cell's bbox, in degrees of latitude/longitude (the server's `lat`/`lon` is the square's
/// centre — meshcore-insights `cmh_public_coverage_src`'s `(ci + 0.5) * cellDeg`).
List<HexPoint> _squareBoundary(double lat, double lon, double cellDeg) {
  final half = cellDeg / 2;
  return [
    HexPoint(lat - half, lon - half),
    HexPoint(lat - half, lon + half),
    HexPoint(lat + half, lon + half),
    HexPoint(lat + half, lon - half),
  ];
}

/// Turns a [PublicCoverage] answer into drawable [NetworkCell]s, bucketed by [by]. Hexagon cells need [h3] (null
/// on a platform/test run where the native library didn't load — those cells are skipped rather than guessed at,
/// same philosophy as [buildHexCells] skipping a ping with an unusable position); square cells need no engine.
List<NetworkCell> buildNetworkCells(PublicCoverage coverage, H3? h3, CoverageColorBy by) {
  final hex = coverage.grid.kind == CoverageGridKind.h3;
  final out = <NetworkCell>[];
  for (final c in coverage.cells) {
    if (!c.lat.isFinite || !c.lon.isFinite || c.lat.abs() > 90 || c.lon.abs() > 180) continue;
    List<HexPoint> boundary;
    String id;
    if (hex) {
      final raw = c.h3;
      if (raw == null || h3 == null) continue;
      BigInt idx;
      try {
        idx = BigInt.parse(raw, radix: 16);
        boundary = [for (final g in h3.cellToBoundary(idx)) HexPoint(g.lat, g.lon)];
      } catch (_) {
        continue;
      }
      id = raw;
    } else {
      boundary = _squareBoundary(c.lat, c.lon, coverage.grid.cellDeg);
      id = '${c.lat},${c.lon}';
    }
    out.add(NetworkCell(id: id, boundary: boundary, level: levelFor(c, by), cell: c));
  }
  return out;
}
