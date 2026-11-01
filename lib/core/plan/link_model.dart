// Point-to-point link maths: a port of the website's terrain-only link model so the phone can score any elevation
// profile with no server maths. Sources (each function named below exists in meshcore-insights; golden tests read
// numbers generated from them by `scripts/plan-tools-golden.ts`):
//   src/lib/mesh.ts           bullingtonDb, terrainOdds, tierOf, TERRAIN_MODEL, haversineKm  (what `score-link` returns)
//   src/lib/profile.ts        clearance(): line of sight, 60 % first Fresnel zone, tightest point
//   src/lib/tools/coverage.ts bullington, fsplDb, clutterDb, belowCanopyFraction, linkBudget  (the painter's link budget)
// The terrain itself (the elevation profile) is NOT computed here: the app asks the website's `score-link` endpoint for
// it (AWS Terrain Tiles / USGS 3DEP 1/3 arc-second, server side), then does everything else on the phone, so changing an
// antenna height needs no second request. Pure Dart.
import 'dart:math' as math;

import '../units.dart' show metresPerFoot;

const double _rad = math.pi / 180;
const double _ln10 = 2.302585092994046;
double _log10(double x) => math.log(x) / _ln10;

/// Free-space frequency used by the painter and the link tool (MeshCore US default, website `US_PRESET.freqMHz`).
const double linkFreqMhz = 910.525;
const double lightMs = 299792458;
const double lambdaM = lightMs / (linkFreqMhz * 1e6);
const double kFactor = 4 / 3;
const double earthRadiusM = 6371000;
const double keM = kFactor * earthRadiusM;
const double ftM = metresPerFoot;

/// The 60 % first-Fresnel rule of thumb (website `FRESNEL_SHARE`).
const double fresnelShare = 0.6;

double haversineKm(double aLat, double aLon, double bLat, double bLon) {
  final dLat = (bLat - aLat) * _rad, dLon = (bLon - aLon) * _rad;
  final s = math.pow(math.sin(dLat / 2), 2) + math.cos(aLat * _rad) * math.cos(bLat * _rad) * math.pow(math.sin(dLon / 2), 2);
  return 2 * 6371.0088 * math.asin(math.min(1.0, math.sqrt(s)));
}

// ---------------------------------------------------------------- the website's fitted terrain model
class TierCuts {
  final double strong, likely, possible;
  const TierCuts(this.strong, this.likely, this.possible);
}

const List<double> terrainW = [1.203817, -3.015752, -0.138551];
const TierCuts terrainTiers = TierCuts(0.279, 0.164, 0.097);

enum LinkTier {
  stretch('Stretch'),
  possible('Possible'),
  likely('Likely'),
  strong('Strong');

  final String label;
  const LinkTier(this.label);
}

LinkTier tierOf(double p, [TierCuts t = terrainTiers]) => p >= t.strong
    ? LinkTier.strong
    : p >= t.likely
        ? LinkTier.likely
        : p >= t.possible
            ? LinkTier.possible
            : LinkTier.stretch;

double terrainOdds(double km, double bullDb) =>
    1 / (1 + math.exp(-(terrainW[0] + terrainW[1] * _log10(math.max(km, 0.3)) + terrainW[2] * bullDb)));

double _j(double v) => v <= -0.78 ? 0 : 6.9 + 20 * _log10(math.sqrt(math.pow(v - 0.1, 2) + 1) + v - 0.1);

/// Bullington single-edge diffraction loss (dB) over a ground profile sampled evenly from A to B (mesh.ts `bullingtonDb`).
double bullingtonDb(List<double> elev, double distM, double ha, double hb, {double lambda = lambdaM}) {
  final n = elev.length;
  if (n < 3 || distM < 100) return 0;
  final ds = [for (var i = 0; i < n; i++) i / (n - 1) * distM];
  final hh = [for (var i = 0; i < n; i++) elev[i] + ds[i] * (distM - ds[i]) / (2 * keM)];
  final h1 = elev[0] + ha, h2 = elev[n - 1] + hb;
  var s1 = double.negativeInfinity, s2 = double.negativeInfinity, vmax = double.negativeInfinity;
  for (var i = 1; i < n - 1; i++) {
    s1 = math.max(s1, (hh[i] - h1) / ds[i]);
    s2 = math.max(s2, (hh[i] - h2) / (distM - ds[i]));
    final los = h1 + (h2 - h1) * ds[i] / distM;
    vmax = math.max(vmax, (hh[i] - los) * math.sqrt(2 * distM / (lambda * ds[i] * (distM - ds[i]))));
  }
  final slr = (h2 - h1) / distM;
  if (s1 < slr) return _j(vmax);
  final db = (h2 - h1 + s2 * distM) / (s1 + s2);
  final hb_ = h1 + s1 * db;
  final v = (hb_ - (h1 + (h2 - h1) * db / distM)) * math.sqrt(2 * distM / (lambda * db * (distM - db)));
  return _j(v);
}

// ---------------------------------------------------------------- the painter's link budget (coverage.ts)
const double radioBwHz = 62500;
const double radioNoiseFigureDb = 6;
const double radioSnrFloorDb = -7.5;
double noiseFloorDbm([double bwHz = radioBwHz, double nf = radioNoiseFigureDb]) => -174 + 10 * _log10(bwHz) + nf;
double sensitivityDbmLink() => noiseFloorDbm() + radioSnrFloorDb;

double fsplDb(double dKm, [double fMhz = linkFreqMhz]) {
  final d = math.max(dKm, 1e-3);
  return 20 * _log10(d) + 20 * _log10(fMhz) + 20 * _log10(4 * math.pi * 1e9 / lightMs);
}

double _knifeEdge(double v) => !(v > -0.78) ? 0 : 6.9 + 20 * _log10(math.sqrt(math.pow(v - 0.1, 2) + 1) + v - 0.1);
double _nu(double h, double d1, double d2) => h * math.sqrt(2 * (d1 + d2) / (lambdaM * d1 * d2));

class BullingtonResult {
  final double lossDb, nu;
  final bool los;
  const BullingtonResult(this.lossDb, this.nu, this.los);
}

/// coverage.ts `bullington`: distM[0] = 0 ... distM[n-1] = D, bare-earth [groundM], antenna heights AGL; earth bulge at k = 4/3.
BullingtonResult bullington(List<double> distM, List<double> groundM, double hTx, double hRx) {
  final n = distM.length;
  final d = n > 0 ? distM[n - 1] : 0.0;
  if (n < 3 || !(d > 0)) return const BullingtonResult(0, double.negativeInfinity, true);
  final h1 = groundM[0] + hTx, h2 = groundM[n - 1] + hRx;
  final slr = (h2 - h1) / d;
  var s1 = double.negativeInfinity, s2 = double.negativeInfinity, vmax = double.negativeInfinity;
  for (var i = 1; i < n - 1; i++) {
    final di = distM[i];
    final hi = groundM[i] + di * (d - di) / (2 * keM);
    s1 = math.max(s1, (hi - h1) / di);
    s2 = math.max(s2, (hi - h2) / (d - di));
    vmax = math.max(vmax, _nu(hi - (h1 + slr * di), di, d - di));
  }
  if (s1 < slr) return BullingtonResult(_knifeEdge(vmax), vmax, true);
  final db = (h2 - h1 + s2 * d) / (s1 + s2);
  final hb = h1 + s1 * db;
  final v = _nu(hb - (h1 + slr * db), db, d - db);
  return BullingtonResult(_knifeEdge(v), v, false);
}

/// The painter's calibrated clutter default (coverage.ts `CLUTTER_DEFAULT`).
const double clutterEndpointDb = 0, clutterDbPerKm = 13.3, clutterCanopyM = 15;

double belowCanopyFraction(List<double> distM, List<double> groundM, double hTx, double hRx, double canopyM) {
  final n = distM.length;
  final d = n > 0 ? distM[n - 1] : 0.0;
  if (!canopyM.isFinite) return 1;
  if (n < 2 || !(d > 0)) return hTx < canopyM ? 1 : 0;
  final h1 = groundM[0] + hTx, h2 = groundM[n - 1] + hRx;
  var low = 0;
  for (var i = 0; i < n; i++) {
    final di = distM[i];
    final ray = h1 + (h2 - h1) * di / d, hi = groundM[i] + di * (d - di) / (2 * keM);
    if (ray - hi < canopyM) low++;
  }
  return low / n;
}

// ---------------------------------------------------------------- one link, analysed
class Fresnel {
  /// Worst clearance of the path above the surface as a share of the first Fresnel radius (min over interior samples);
  /// below 0.6 fails the 60 % rule, below 0 the line of sight is blocked.
  final double worstRatio;
  final double worstKm;

  /// Metres between the antenna line and the ground at the tightest point (negative = ground above the line).
  final double worstClearM;

  /// Share of interior samples with at least 60 % of the first zone clear.
  final double clearShare;

  /// Metres of the path where the ground is above the straight antenna line.
  final int blockedM;

  /// Bullington loss over the earth-bulged ground (profile.ts `bullingtonBulged`).
  final double bullDb;
  const Fresnel({required this.worstRatio, required this.worstKm, required this.worstClearM, required this.clearShare, required this.blockedM, required this.bullDb});

  bool get lineOfSight => worstClearM >= 0 && blockedM == 0;
  bool get fresnelClear => worstRatio >= fresnelShare;
}

/// profile.ts `clearanceAbs` for a path with no tree layer (the app only has the bare-earth profile): [groundM] are raw
/// elevations, evenly spaced over [km]; antenna heights [haM]/[hbM] above ground.
Fresnel clearance(List<double> groundM, double km, double haM, double hbM) {
  final n = groundM.length;
  final dTot = km * 1000;
  final d = [for (var i = 0; i < n; i++) i / (n - 1) * dTot];
  final bulged = [for (var i = 0; i < n; i++) groundM[i] + d[i] * (dTot - d[i]) / (2 * keM)];
  final hA = bulged[0] + haM, hB = bulged[n - 1] + hbM;
  final step = n > 1 ? dTot / (n - 1) : 0.0;
  var worst = double.infinity, worstKm = 0.0, clearN = 0, interior = 0, blockedM = 0.0;
  final lines = <double>[];
  final ratios = <double?>[];
  for (var i = 0; i < n; i++) {
    final t = d[i] / dTot;
    final line = hA + (hB - hA) * t;
    final s = bulged[i];
    lines.add(line);
    final r1 = d[i] > 0 && d[i] < dTot ? math.sqrt(lambdaM * d[i] * (dTot - d[i]) / dTot) : 0.0;
    final ratio = r1 > 0 ? (line - s) / r1 : null;
    ratios.add(ratio);
    if (ratio != null) {
      interior++;
      if (ratio >= fresnelShare) clearN++;
      if (ratio < worst) {
        worst = ratio;
        worstKm = d[i] / 1000;
      }
    }
    if (s > line) blockedM += step;
  }
  // Tightest point: where the ground rises highest above the line when the line is blocked, else the lowest ratio.
  int? wr;
  for (var i = 0; i < n; i++) {
    if (ratios[i] == worst) {
      wr = i;
      break;
    }
  }
  int? deepest;
  for (var i = 0; i < n; i++) {
    if (ratios[i] == null) continue;
    if (deepest == null || bulged[i] - lines[i] > bulged[deepest] - lines[deepest]) deepest = i;
  }
  if (deepest != null && bulged[deepest] > lines[deepest]) {
    wr = deepest;
    worstKm = d[deepest].roundToDouble() / 1000; // the website's row km: Math.round(d) / 1000
  }
  final bullDb = _bullingtonBulged(d, bulged, hA, hB);
  return Fresnel(
    worstRatio: worst.isFinite ? worst : 1,
    worstKm: worstKm,
    worstClearM: wr == null ? 0 : ((lines[wr] - bulged[wr]) * 10).round() / 10,
    clearShare: interior > 0 ? clearN / interior : 1,
    blockedM: blockedM.round(),
    bullDb: bullDb,
  );
}

double _bullingtonBulged(List<double> d, List<double> h, double hA, double hB) {
  final n = d.length;
  final dTot = n > 0 ? d[n - 1] : 0.0;
  if (n < 3 || dTot < 100) return 0;
  var s1 = double.negativeInfinity, s2 = double.negativeInfinity, vmax = double.negativeInfinity;
  for (var i = 1; i < n - 1; i++) {
    final di = d[i], hi = h[i];
    if (di <= 0 || di >= dTot) continue;
    s1 = math.max(s1, (hi - hA) / di);
    s2 = math.max(s2, (hi - hB) / (dTot - di));
    final los = hA + (hB - hA) * di / dTot;
    vmax = math.max(vmax, (hi - los) * math.sqrt(2 * dTot / (lambdaM * di * (dTot - di))));
  }
  if (!s1.isFinite) return 0;
  final slr = (hB - hA) / dTot;
  if (s1 < slr) return _knifeEdge(vmax);
  final db = (hB - hA + s2 * dTot) / (s1 + s2);
  if (!(db > 0 && db < dTot)) return _knifeEdge(vmax);
  final hb = hA + s1 * db;
  final v = (hb - (hA + (hB - hA) * db / dTot)) * math.sqrt(2 * dTot / (lambdaM * db * (dTot - db)));
  return _knifeEdge(v);
}

/// What the link screen shows for one pair of points and antenna heights.
class LinkAnalysis {
  final double km, haM, hbM;

  /// Terrain obstruction (Bullington dB, mesh.ts `bullingtonDb`) and the website's terrain-only odds and tier.
  final double bullDb, odds;
  final LinkTier tier;
  final Fresnel clear;

  /// The painter's budget at 22 dBm and 3 dBi both ends (website EXISTING radio), both directions are equal here.
  final double fspl, diffractionDb, clutterDb, pathLossDb, marginDb, prxDbm;
  final bool los;

  /// Ground samples (m above sea level) and their distances from A (km), as the server sent them.
  final List<double> groundM, distKm;
  const LinkAnalysis({
    required this.km,
    required this.haM,
    required this.hbM,
    required this.bullDb,
    required this.odds,
    required this.tier,
    required this.clear,
    required this.fspl,
    required this.diffractionDb,
    required this.clutterDb,
    required this.pathLossDb,
    required this.marginDb,
    required this.prxDbm,
    required this.los,
    required this.groundM,
    required this.distKm,
  });
}

const double existingTxDbm = 22, existingGainDbi = 3;

LinkAnalysis analyseLink(List<double> groundM, double km, double haM, double hbM, {double txDbm = existingTxDbm, double gainDbi = existingGainDbi}) {
  final n = groundM.length;
  final d = [for (var i = 0; i < n; i++) i / (n - 1) * km * 1000];
  final bull = bullingtonDb(groundM, km * 1000, haM, hbM);
  final odds = terrainOdds(km, bull);
  final b = bullington(d, groundM, haM, hbM);
  final canopy = belowCanopyFraction(d, groundM, haM, hbM, clutterCanopyM);
  final fs = fsplDb(km);
  final cl = clutterEndpointDb + clutterDbPerKm * km * canopy;
  final pl = fs + b.lossDb + cl;
  final prx = txDbm + gainDbi + gainDbi - pl;
  return LinkAnalysis(
    km: km,
    haM: haM,
    hbM: hbM,
    bullDb: bull,
    odds: odds,
    tier: tierOf(odds),
    clear: clearance(groundM, km, haM, hbM),
    fspl: fs,
    diffractionDb: b.lossDb,
    clutterDb: cl,
    pathLossDb: pl,
    marginDb: prx - sensitivityDbmLink(),
    prxDbm: prx,
    los: b.los,
    groundM: groundM,
    distKm: [for (final x in d) x / 1000],
  );
}
