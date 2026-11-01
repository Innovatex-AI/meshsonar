// "Is there measured coverage here?" answered from the measured coverage cells the app already holds (the same
// `public-coverage` data the website's /coverage map draws: real drives, MeshSonar and forwarded MeshMapper). Nothing is
// modelled: a place is Covered when a driven cell near it heard a repeater, Dead when cells near it were driven and
// nothing answered, Unmeasured when nobody has driven there. Pure Dart; offline whenever the cells are cached.
import '../api.dart';
import 'link_model.dart' show haversineKm;

enum CoverageVerdict { covered, weak, dead, unmeasured }

class CoverageCheck {
  final CoverageVerdict verdict;

  /// Radius searched around the point, metres.
  final double radiusM;

  /// Cells inside the radius, and how many of them heard a repeater at least once.
  final int cells, heardCells;

  /// Pings in those cells, and how many were answered.
  final int pings, heardPings;

  /// Best SNR (dB) seen in the cells, and the most repeaters any one cell reached.
  final double? bestSnr;
  final int maxRepeaters;

  /// Newest measurement in the cells.
  final DateTime? lastAt;

  /// Distance to the nearest measured cell when none is inside the radius, metres.
  final double? nearestM;

  /// Cells held in total (the whole loaded area), so "unmeasured" can say how much data it compared against.
  final int cellsLoaded;
  const CoverageCheck({
    required this.verdict,
    required this.radiusM,
    required this.cells,
    required this.heardCells,
    required this.pings,
    required this.heardPings,
    required this.bestSnr,
    required this.maxRepeaters,
    required this.lastAt,
    required this.nearestM,
    required this.cellsLoaded,
  });

  double get heardShare => pings == 0 ? 0 : heardPings / pings;
}

/// A cell counts as Covered when at least half of the driven pings around the place were answered; Weak when some were
/// but under half (the place is on the edge); Dead when none were.
const double coveredShare = 0.5;

/// Roughly how far a cell's centre can be from a point inside it, metres: the cell edge for the grid [g] (H3 edge lengths
/// per resolution; a square grid's side). Added to the search radius so a point inside a big cell still finds that cell.
double cellReachM(CoverageGrid g) {
  if (g.kind == CoverageGridKind.h3 && g.res != null) {
    const edge = {7: 1220.0, 8: 461.0, 9: 174.0, 10: 66.0, 11: 25.0};
    return edge[g.res!] ?? 0;
  }
  return g.cellDeg * 111320 / 2;
}

CoverageCheck checkCoverage(List<CoverageCell> all, double lat, double lon, {double radiusM = 500, double reachM = 0}) {
  var cells = 0, heardCells = 0, pings = 0, heardPings = 0, maxRep = 0;
  double? best;
  DateTime? last;
  double? nearest;
  for (final c in all) {
    if (c.pings <= 0) continue;
    final dM = haversineKm(lat, lon, c.lat, c.lon) * 1000;
    if (dM > radiusM + reachM) {
      if (nearest == null || dM < nearest) nearest = dM;
      continue;
    }
    cells++;
    pings += c.pings;
    heardPings += c.heard;
    if (c.heard > 0) heardCells++;
    if (c.repeaters > maxRep) maxRep = c.repeaters;
    final s = c.bestSnr;
    if (s != null && (best == null || s > best)) best = s;
    final t = DateTime.tryParse(c.lastAt)?.toUtc();
    if (t != null && (last == null || t.isAfter(last))) last = t;
  }
  final CoverageVerdict v;
  if (cells == 0) {
    v = CoverageVerdict.unmeasured;
  } else if (heardPings == 0) {
    v = CoverageVerdict.dead;
  } else if (heardPings / pings >= coveredShare) {
    v = CoverageVerdict.covered;
  } else {
    v = CoverageVerdict.weak;
  }
  return CoverageCheck(
    verdict: v,
    radiusM: radiusM,
    cells: cells,
    heardCells: heardCells,
    pings: pings,
    heardPings: heardPings,
    bestSnr: best,
    maxRepeaters: maxRep,
    lastAt: last,
    nearestM: cells == 0 ? nearest : null,
    cellsLoaded: all.length,
  );
}
