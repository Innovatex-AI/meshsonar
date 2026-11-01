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

/// Which dimension buckets a cell's colour (the layer's colour-by picker: best SNR / share heard / noise floor / ping age /
/// noise against the area's typical level).
///
/// Colour contract: grey ([CoverageLevel.none]) = mapped, nothing heard (or no reading for the dimension); purple
/// ([CoverageLevel.unknown]) = heard, signal unknown; the strength colours (green/blue/amber/red) mean measured SNR and the
/// share heard. [age] and [noiseDelta] are NOT strength, so they draw in their own ramps (lib/ui/map/coverage_ramps.dart).
enum CoverageColorBy {
  snr,
  heard,
  noise,

  /// How long ago the cell was last measured: 24 h, 7 d, 30 d, older.
  age,

  /// The cell's mean noise floor against the median of the cells loaded: quieter, typical, noisier, much noisier.
  noiseDelta;

  /// True for the two modes that are about strength (SNR, share heard, absolute noise) and use the strength colours.
  bool get isStrength => this == snr || this == heard || this == noise;
}

/// Edges of the [CoverageColorBy.age] buckets, days: up to 1, up to 7, up to 30, older.
const List<int> kAgeBucketDays = [1, 7, 30];

/// Edges of the [CoverageColorBy.noiseDelta] buckets, dB against the median: -3 or quieter, within 3, up to +8, above.
const double kNoiseQuieterDb = -3, kNoiseTypicalDb = 3, kNoiseMuchDb = 8;

/// The median noise floor of the cells that report one; null with fewer than 3 readings (no meaningful "typical").
double? medianNoiseFloor(Iterable<CoverageCell> cells) {
  final v = [for (final c in cells) if (c.noiseFloor != null && c.noiseFloor!.isFinite) c.noiseFloor!]..sort();
  if (v.length < 3) return null;
  final m = v.length ~/ 2;
  return v.length.isOdd ? v[m] : (v[m - 1] + v[m]) / 2;
}

/// A cell's bucket on its [CoverageColorBy] legend, weakest to strongest. [none] means the cell was mapped but nothing
/// was heard there (or there is no reading for the noise dimension): drawn GREY, never a coverage colour. [unknown]
/// means something WAS heard but no signal strength was measured: its own colour, never green.
enum CoverageLevel { none, unknown, weak, fair, good, strong }

/// A cell with fewer pings than this is a thin sample and is drawn fainter than a properly measured one.
const int kMinCellPings = 3;

/// How strongly a network cell is drawn: (fill alpha, outline alpha). Nothing heard is the faintest of all, then a thin
/// sample ([pings] below [kMinCellPings]), then a measured cell. The map and the legend both use this.
(double, double) cellAlphas(CoverageLevel level, int pings) =>
    level == CoverageLevel.none ? (0.16, 0.45) : (pings < kMinCellPings ? (0.17, 0.5) : (0.34, 0.8));

/// One drawable network-coverage cell: a boundary (square or hexagon corners) and the bucket it falls in.
class NetworkCell {
  /// The mode [level] was bucketed by, so the map draws it with that mode's colours.
  final CoverageColorBy mode;

  /// H3 hex id, or a synthetic `lat,lon` id for a square cell.
  final String id;

  /// The outline, not closed (first point is not repeated) — same convention as [HexCell].
  final List<HexPoint> boundary;
  final CoverageLevel level;

  /// The measured numbers behind the cell (tap-cell sheet).
  final CoverageCell? cell;
  const NetworkCell({required this.id, required this.boundary, required this.level, this.cell, this.mode = CoverageColorBy.snr});
}

/// Buckets one [CoverageCell] by [by], using the website's own `/coverage` thresholds (meshcore-insights
/// `src/components/coverage/cells.ts`) so the app's gap layer reads the same as the site's map.
///
/// [now] dates the age mode and [noiseBaseline] (see [medianNoiseFloor]) anchors the noise-delta mode; a cell without a
/// date or reading, or no baseline, is [CoverageLevel.none]. In both new modes a cell where nothing was heard stays grey.
CoverageLevel levelFor(CoverageCell c, CoverageColorBy by, {DateTime? now, double? noiseBaseline}) {
  switch (by) {
    case CoverageColorBy.age:
      if (c.heard <= 0) return CoverageLevel.none;
      final at = DateTime.tryParse(c.lastAt);
      if (at == null) return CoverageLevel.none;
      final days = (now ?? DateTime.now()).difference(at).inHours / 24;
      if (days <= kAgeBucketDays[0]) return CoverageLevel.strong;
      if (days <= kAgeBucketDays[1]) return CoverageLevel.good;
      if (days <= kAgeBucketDays[2]) return CoverageLevel.fair;
      return CoverageLevel.weak;
    case CoverageColorBy.noiseDelta:
      final n = c.noiseFloor;
      if (c.heard <= 0 || n == null || noiseBaseline == null) return CoverageLevel.none;
      final d = n - noiseBaseline;
      if (d <= kNoiseQuieterDb) return CoverageLevel.strong;
      if (d < kNoiseTypicalDb) return CoverageLevel.good;
      if (d < kNoiseMuchDb) return CoverageLevel.fair;
      return CoverageLevel.weak;
    case CoverageColorBy.snr:
      if (c.heard <= 0) return CoverageLevel.none;
      final s = c.bestSnr;
      if (s == null) return CoverageLevel.unknown;
      if (s >= 5) return CoverageLevel.strong;
      if (s >= 0) return CoverageLevel.good;
      if (s >= -5) return CoverageLevel.fair;
      return CoverageLevel.weak;
    case CoverageColorBy.heard:
      if (c.pings <= 0 || c.heard <= 0) return CoverageLevel.none; // nothing heard is grey, not the 'weak' colour
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
List<NetworkCell> buildNetworkCells(PublicCoverage coverage, H3? h3, CoverageColorBy by, {DateTime? now}) {
  final baseline = by == CoverageColorBy.noiseDelta ? medianNoiseFloor(coverage.cells) : null;
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
    out.add(NetworkCell(id: id, boundary: boundary, level: levelFor(c, by, now: now, noiseBaseline: baseline), cell: c, mode: by));
  }
  return out;
}
