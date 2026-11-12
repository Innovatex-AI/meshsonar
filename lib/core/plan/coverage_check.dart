// "Is there measured coverage here?" answered from the measured coverage cells the app already holds (the same
// `public-coverage` data the website's /coverage map draws: real drives, MeshSonar and forwarded MeshMapper). Nothing is
// modelled: a place is Covered when a driven cell near it heard a repeater, Dead when cells near it were driven and
// nothing answered, Unmeasured when nobody has driven there. Pure Dart; offline whenever the cells are cached.
//
// DEF-3 (V1-PLAN AN-2): the verdict is the MEAN SNR BAND of the drives around the place, the same rule as the map's cells (SQL
// ms_coverage_band, `coverageBandOf` in coverage_v2.dart): the mean SNR of every successful result in range, as a margin over the
// LoRa floor of the region's spreading factor. It is NOT the share of pings that were answered (heard share): a place where
// half the pings were answered but every answer was strong, or one answered ping in a hundred failures, say different things.
import '../api.dart';
import '../coverage_v2.dart';
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

  /// The pooled mean SNR (dB) of the successful results in those cells (null when none carried an SNR), the band that mean
  /// falls in (CoverageBand: 0 No reply .. 5 Excellent, 6 heard without an SNR; null when unmeasured) and the floor it was
  /// judged against.
  final double? meanSnr;
  final int? band;
  final double floorDb;

  /// Successful and failed results in those cells (the v2 n_ok / n_fail; an older answer's heard / unheard pings).
  final int nOk, nFail;

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
    required this.meanSnr,
    required this.band,
    required this.floorDb,
    required this.nOk,
    required this.nFail,
    required this.bestSnr,
    required this.maxRepeaters,
    required this.lastAt,
    required this.nearestM,
    required this.cellsLoaded,
  });
}

/// The verdict for a band (the map's rule, grouped): Dead = band 0 (no successful result), Weak = Edge or Weak (the mean sits
/// under 5 dB above the floor: on the edge), Covered = Fair, Good, Excellent, or heard without an SNR (a repeater answered but
/// there is no signal figure to grade; the screen says so).
CoverageVerdict verdictForBand(int band) => switch (band) {
  CoverageBand.noReply => CoverageVerdict.dead,
  CoverageBand.edge || CoverageBand.weak => CoverageVerdict.weak,
  _ => CoverageVerdict.covered,
};

/// Roughly how far a cell's centre can be from a point inside it, metres: the cell edge for the grid [g] (H3 edge lengths
/// per resolution; a square grid's side). Added to the search radius so a point inside a big cell still finds that cell.
double cellReachM(CoverageGrid g) {
  if (g.kind == CoverageGridKind.h3 && g.res != null) {
    const edge = {7: 1220.0, 8: 461.0, 9: 174.0, 10: 66.0, 11: 25.0};
    return edge[g.res!] ?? 0;
  }
  return g.cellDeg * 111320 / 2;
}

/// [sf] is the viewed region's spreading factor (the floor the bands are measured from; SF7 when unknown, as the map does).
///
/// A v2 cell (`metric=mean`) carries `snrMean`, `nOk` and `nFail`. A cell from an older server has only pings, heard and the
/// median SNR: its heard pings stand in for n_ok, the unheard for n_fail, and the median SNR for the mean (the best figure that
/// answer has; an older server never sends the mean).
CoverageCheck checkCoverage(List<CoverageCell> all, double lat, double lon, {double radiusM = 500, double reachM = 0, int sf = 7}) {
  var cells = 0, heardCells = 0, pings = 0, heardPings = 0, maxRep = 0, nOk = 0, nFail = 0, nSnr = 0;
  var snrSum = 0.0; // sum of mean x n over cells that carry an SNR, so snrSum / nSnr is the mean of every result
  double? best;
  DateTime? last;
  double? nearest;
  for (final c in all) {
    if (c.pings <= 0 && c.attempts <= 0) continue;
    final dM = haversineKm(lat, lon, c.lat, c.lon) * 1000;
    if (dM > radiusM + reachM) {
      if (nearest == null || dM < nearest) nearest = dM;
      continue;
    }
    cells++;
    pings += c.attempts;
    final ok = c.nOk ?? c.heard;
    heardPings += ok;
    nOk += ok;
    nFail += c.nFail ?? (c.pings - c.heard).clamp(0, c.pings);
    final mean = c.snrMean ?? c.medianSnr;
    if (ok > 0 && mean != null && mean.isFinite) {
      nSnr += ok;
      snrSum += mean * ok;
    }
    if (ok > 0) heardCells++;
    if (c.repeaters > maxRep) maxRep = c.repeaters;
    final s = c.bestSnr;
    if (s != null && (best == null || s > best)) best = s;
    final t = DateTime.tryParse(c.lastAt)?.toUtc();
    if (t != null && (last == null || t.isAfter(last))) last = t;
  }
  final mean = nSnr > 0 ? snrSum / nSnr : null;
  final int? band = cells == 0 ? null : coverageBandOf(snrMean: mean, nOk: nOk, nSnr: nSnr, sf: sf);
  return CoverageCheck(
    verdict: band == null ? CoverageVerdict.unmeasured : verdictForBand(band),
    radiusM: radiusM,
    cells: cells,
    heardCells: heardCells,
    pings: pings,
    heardPings: heardPings,
    meanSnr: mean,
    band: band,
    floorDb: snrFloorDb(sf),
    nOk: nOk,
    nFail: nFail,
    bestSnr: best,
    maxRepeaters: maxRep,
    lastAt: last,
    nearestM: cells == 0 ? nearest : null,
    cellsLoaded: all.length,
  );
}
