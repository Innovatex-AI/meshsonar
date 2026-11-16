// Point-to-point link maths on the phone: a port of the website's terrain link model so the app can score any elevation
// profile with no server maths, for ANY radio (release 0.38: the frequency, bandwidth and spreading factor are a parameter,
// never a constant; the default is the region's preset, PlanRadio.usDefault only when the region has none). Sources (each
// function named below exists in meshcore-insights):
//   src/lib/mesh.ts           bullingtonDb, terrainOdds, tierOf, TERRAIN_MODEL, haversineKm  (what `score-link` returns)
//   src/lib/profile.ts        clearance(): line of sight, 60 % first Fresnel zone, tightest point
//   src/lib/tools/coverage.ts radioModel, snrFloorForSf, bullington, fsplDb, clutterDb, belowCanopyFraction, linkBudget,
//                             profileLink (the painter's link budget)
//   src/lib/plan/link.ts      linkGeometry, verdictOf, FADE_MARGIN_DB, linkAnswer (the `plan-link` answer)
// Golden tests: test/fixtures/plan_tools_golden.json (website, US preset) and test/fixtures/plan_native/link_radio_golden.json
// (generated from src/lib/plan/link.ts at 910.525, 869.618 and 869.525 MHz by test/fixtures/plan_native/gen_link_radio_golden.ts).
// The terrain itself (the elevation profile) is NOT computed here: the server sends it (`score-link` / `plan-link`), the
// phone does everything else, so changing a height or the radio needs no second request. Pure Dart.
import 'dart:math' as math;

import '../plan_contract.dart';
import '../units.dart' show metresPerFoot;

const double _rad = math.pi / 180;
const double _ln10 = 2.302585092994046;
double _log10(double x) => math.log(x) / _ln10;

/// JavaScript `Math.round` (half rounds towards +infinity), so rounded numbers match the website's to the last digit.
double jsRound(double x) => (x + 0.5).floorToDouble();
double _r1(double x) => jsRound(x * 10) / 10;

const double lightMs = 299792458;
const double kFactor = 4 / 3;
const double earthRadiusM = 6371000;
const double keM = kFactor * earthRadiusM;
const double ftM = metresPerFoot;

/// Wavelength (m) of a radio's centre frequency.
double lambdaFor(PlanRadio radio) => lightMs / (radio.freqMHz * 1e6);

/// The US default radio's wavelength. Every Planner mode takes the plan's own radio instead: [lambdaFor].
final double lambdaM = lambdaFor(PlanRadio.usDefault);

/// The 60 % first-Fresnel rule of thumb (website `FRESNEL_SHARE` / `FRESNEL_CLEAR`).
const double fresnelShare = 0.6;

/// dB the budget must clear on top of the sensitivity before a link is called likely (fading, body loss, a wet antenna):
/// website `FADE_MARGIN_DB`. Plain words for the glossary: [fadeMarginWords].
const double fadeMarginDb = 10;
const String fadeMarginWords = 'A 10 dB safety margin on top of what the radio can just decode, for fading, rain, '
    'a hand on the antenna and the model being an estimate. A link that clears it is likely; one that only reaches the '
    'radio\'s limit is marginal.';

/// The most an answer suggests raising an end by; beyond it the path needs a relay (website `RAISE_MAX_M`).
const double raiseMaxM = 999;

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
double bullingtonDb(List<double> elev, double distM, double ha, double hb, {required double lambda}) {
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

// ---------------------------------------------------------------- the radio (coverage.ts radioModel)
const double radioNoiseFigureDb = 6;

/// LoRa demodulation SNR floor (dB) per spreading factor (Semtech SX126x table): SF7 -7.5, 2.5 dB lower per SF step.
double snrFloorForSf(int sf) => -7.5 - 2.5 * (sf.clamp(5, 12) - 7);

/// Thermal noise floor (dBm) for a bandwidth (Hz) and receiver noise figure: -174 dBm/Hz + 10 log10(BW) + NF.
double noiseFloorDbm(double bwHz, [double nf = radioNoiseFigureDb]) => -174 + 10 * _log10(bwHz) + nf;

double radioNoiseFloorDbm(PlanRadio radio) => noiseFloorDbm(radio.bwKHz * 1000);

/// Receiver sensitivity (dBm) of a radio: noise floor + the SF's SNR floor (about -127.5 dBm at 62.5 kHz SF7).
double radioSensitivityDbm(PlanRadio radio) => radioNoiseFloorDbm(radio) + snrFloorForSf(radio.sf);

/// Free-space path loss (dB) for a distance in km at a frequency in MHz.
double fsplDb(double dKm, double fMhz) {
  final d = math.max(dKm, 1e-3);
  return 20 * _log10(d) + 20 * _log10(fMhz) + 20 * _log10(4 * math.pi * 1e9 / lightMs);
}

double _knifeEdge(double v) => !(v > -0.78) ? 0 : 6.9 + 20 * _log10(math.sqrt(math.pow(v - 0.1, 2) + 1) + v - 0.1);
double _nu(double h, double d1, double d2, double lambda) => h * math.sqrt(2 * (d1 + d2) / (lambda * d1 * d2));

class BullingtonResult {
  final double lossDb, nu;
  final bool los;
  const BullingtonResult(this.lossDb, this.nu, this.los);
}

/// coverage.ts `bullington`: distM[0] = 0 ... distM[n-1] = D, bare-earth [groundM], antenna heights AGL; earth bulge at k = 4/3.
BullingtonResult bullington(List<double> distM, List<double> groundM, double hTx, double hRx, {required double lambda}) {
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
    vmax = math.max(vmax, _nu(hi - (h1 + slr * di), di, d - di, lambda));
  }
  if (s1 < slr) return BullingtonResult(_knifeEdge(vmax), vmax, true);
  final db = (h2 - h1 + s2 * d) / (s1 + s2);
  final hb = h1 + s1 * db;
  final v = _nu(hb - (h1 + slr * db), db, d - db, lambda);
  return BullingtonResult(_knifeEdge(v), v, false);
}

/// The painter's calibrated clutter default (coverage.ts `CLUTTER_DEFAULT`); the per-plan value is a [PlanClutter].
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
/// elevations, evenly spaced over [km]; antenna heights [haM]/[hbM] above ground; [lambda] the radio's wavelength.
Fresnel clearance(List<double> groundM, double km, double haM, double hbM, {required double lambda}) {
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
    final r1 = d[i] > 0 && d[i] < dTot ? math.sqrt(lambda * d[i] * (dTot - d[i]) / dTot) : 0.0;
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
  final bullDb = _bullingtonBulged(d, bulged, hA, hB, lambda);
  return Fresnel(
    worstRatio: worst.isFinite ? worst : 1,
    worstKm: worstKm,
    worstClearM: wr == null ? 0 : ((lines[wr] - bulged[wr]) * 10).round() / 10,
    clearShare: interior > 0 ? clearN / interior : 1,
    blockedM: blockedM.round(),
    bullDb: bullDb,
  );
}

double _bullingtonBulged(List<double> d, List<double> h, double hA, double hB, double lambda) {
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
    vmax = math.max(vmax, (hi - los) * math.sqrt(2 * dTot / (lambda * di * (dTot - di))));
  }
  if (!s1.isFinite) return 0;
  final slr = (hB - hA) / dTot;
  if (s1 < slr) return _knifeEdge(vmax);
  final db = (hB - hA + s2 * dTot) / (s1 + s2);
  if (!(db > 0 && db < dTot)) return _knifeEdge(vmax);
  final hb = hA + s1 * db;
  final v = (hb - (hA + (hB - hA) * db / dTot)) * math.sqrt(2 * dTot / (lambda * db * (dTot - db)));
  return _knifeEdge(v);
}

/// The three-state verdict of a margin that already has the fade margin taken off (website `verdictOf`): at or above 0
/// likely, within the fade margin marginal, below that unlikely.
PlanVerdict verdictOf(double marginAfterFadeDb) => marginAfterFadeDb >= 0
    ? PlanVerdict.likely
    : marginAfterFadeDb >= -fadeMarginDb
        ? PlanVerdict.marginal
        : PlanVerdict.unlikely;

/// What the link tool shows for one pair of points, antenna heights and radio.
class LinkAnalysis {
  final double km, haM, hbM;
  final PlanRadio radio;

  /// Terrain obstruction (Bullington dB, mesh.ts `bullingtonDb`) and the website's terrain-only odds and tier.
  final double bullDb, odds;
  final LinkTier tier;
  final Fresnel clear;

  /// The painter's budget (coverage.ts `profileLink`). [marginDb] is the weaker direction above the sensitivity with NO
  /// fade margin taken off (the website's painter number); [abDb] is A transmitting to B, [baDb] B to A.
  final double fspl, diffractionDb, clutterDb, pathLossDb, marginDb, prxDbm, abDb, baDb, sensitivityDbm;
  final bool los;

  /// Ground samples (m above sea level) and their distances from A (km), as the server sent them.
  final List<double> groundM, distKm;
  const LinkAnalysis({
    required this.km,
    required this.haM,
    required this.hbM,
    this.radio = PlanRadio.usDefault,
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
    required this.abDb,
    required this.baDb,
    required this.sensitivityDbm,
    required this.los,
    required this.groundM,
    required this.distKm,
  });

  /// The margin for [direction] (down = A to B, up = B to A, both = the weaker) with the 10 dB fade margin taken off,
  /// rounded to 0.1 dB like the server's `marginDb`.
  double marginAfterFade([PlanDirection direction = PlanDirection.both]) {
    final raw = switch (direction) {
      PlanDirection.down => abDb,
      PlanDirection.up => baDb,
      PlanDirection.both => math.min(abDb, baDb),
    };
    return _r1(raw - fadeMarginDb);
  }

  PlanVerdict verdict([PlanDirection direction = PlanDirection.both]) => verdictOf(marginAfterFade(direction));
}

const double existingTxDbm = 22, existingGainDbi = 3;

/// One link over an evenly sampled bare-earth profile, for any radio. [txDbm]/[gainDbi] are A's (and B's unless
/// [bTxDbm]/[bGainDbi] say otherwise); [cableLossDb] at either end comes off that end's gain.
LinkAnalysis analyseLink(
  List<double> groundM,
  double km,
  double haM,
  double hbM, {
  PlanRadio radio = PlanRadio.usDefault,
  PlanClutter clutter = const PlanClutter(),
  double txDbm = existingTxDbm,
  double gainDbi = existingGainDbi,
  double? bTxDbm,
  double? bGainDbi,
}) {
  final n = groundM.length;
  final lambda = lambdaFor(radio);
  final d = [for (var i = 0; i < n; i++) i / (n - 1) * km * 1000];
  final bull = bullingtonDb(groundM, km * 1000, haM, hbM, lambda: lambda);
  final odds = terrainOdds(km, bull);
  final b = bullington(d, groundM, haM, hbM, lambda: lambda);
  final canopy = belowCanopyFraction(d, groundM, haM, hbM, clutter.canopyM);
  final fs = fsplDb(km, radio.freqMHz);
  final cl = clutterEndpointDb + clutter.dbPerKm * km * canopy;
  final pl = fs + b.lossDb + cl;
  final sens = radioSensitivityDbm(radio);
  final aTx = txDbm, aG = gainDbi, bTx = bTxDbm ?? txDbm, bG = bGainDbi ?? gainDbi;
  final ab = aTx + aG + bG - pl - sens, ba = bTx + bG + aG - pl - sens;
  final weaker = math.min(ab, ba);
  return LinkAnalysis(
    km: km,
    haM: haM,
    hbM: hbM,
    radio: radio,
    bullDb: bull,
    odds: odds,
    tier: tierOf(odds),
    clear: clearance(groundM, km, haM, hbM, lambda: lambda),
    fspl: fs,
    diffractionDb: b.lossDb,
    clutterDb: cl,
    pathLossDb: pl,
    marginDb: weaker,
    prxDbm: weaker + sens,
    abDb: ab,
    baDb: ba,
    sensitivityDbm: sens,
    los: b.los,
    groundM: groundM,
    distKm: [for (final x in d) x / 1000],
  );
}

// ---------------------------------------------------------------- plan-link geometry (website src/lib/plan/link.ts)
/// The most obstructed point of a path and how much the lower end must rise for 60 % clearance over the whole path.
class LinkTightest {
  final double km, raiseM, clearanceM, zoneM;

  /// Which end the answer raises: the one whose antenna (ground + mast) is lower.
  final String end;
  const LinkTightest({required this.km, required this.raiseM, required this.end, required this.clearanceM, required this.zoneM});
}

/// The terrain that blocks the straight line (the highest point above the ray).
class LinkRidge {
  final double km, lat, lon, groundM, aboveRayM;
  const LinkRidge({required this.km, required this.lat, required this.lon, required this.groundM, required this.aboveRayM});
}

class LinkGeometry {
  /// Smallest first-Fresnel-zone clearance along the path, percent of the zone radius (capped at 100, negative = blocked).
  final double fresnelClearancePct;
  final LinkTightest? tightest;
  final LinkRidge? ridge;
  const LinkGeometry({required this.fresnelClearancePct, this.tightest, this.ridge});
}

/// Website `linkGeometry`: Fresnel clearance, the tightest point, metres to raise and the blocking ridge over a profile
/// sampled evenly from [a] to [b] (k = 4/3 bulge).
LinkGeometry linkGeometry(PlanPoint a, PlanPoint b, double haM, double hbM, double km, List<double> elev, {required double lambda}) {
  final n = elev.length;
  final dTot = km * 1000;
  final dist = [for (var i = 0; i < n; i++) i / (n - 1) * dTot];
  final h1 = elev[0] + haM, h2 = elev[n - 1] + hbM;
  final end = h1 <= h2 ? 'a' : 'b';
  var minRatio = double.infinity, tight = -1, need = 0.0, worstAbove = 0.0, ridgeAt = -1;
  for (var i = 1; i < n - 1; i++) {
    final d1 = dist[i], d2 = dTot - d1;
    final g = elev[i] + d1 * d2 / (2 * keM);
    final ray = h1 + (h2 - h1) * d1 / dTot;
    final clear = ray - g, zone = math.sqrt(lambda * d1 * d2 / dTot);
    final ratio = clear / zone;
    if (ratio < minRatio) {
      minRatio = ratio;
      tight = i;
    }
    final w = end == 'a' ? d2 / dTot : d1 / dTot;
    if (w > 1e-6) need = math.max(need, (fresnelShare * zone - clear) / w);
    if (-clear > worstAbove) {
      worstAbove = -clear;
      ridgeAt = i;
    }
  }
  if (tight < 0) return const LinkGeometry(fresnelClearancePct: 100);
  final d1 = dist[tight], zoneT = math.sqrt(lambda * d1 * (dTot - d1) / dTot);
  final clearT = minRatio * zoneT;
  double t(int i) => i / (n - 1);
  return LinkGeometry(
    fresnelClearancePct: jsRound(math.min(100, minRatio * 100)),
    tightest: LinkTightest(
      km: jsRound(d1) / 1000,
      raiseM: math.min(raiseMaxM, (math.max(0, need) * 2).ceilToDouble() / 2),
      end: end,
      clearanceM: _r1(clearT),
      zoneM: _r1(zoneT),
    ),
    ridge: ridgeAt < 0
        ? null
        : LinkRidge(
            km: jsRound(dist[ridgeAt]) / 1000,
            lat: jsRound((a.lat + (b.lat - a.lat) * t(ridgeAt)) * 1e5) / 1e5,
            lon: jsRound((a.lon + (b.lon - a.lon) * t(ridgeAt)) * 1e5) / 1e5,
            groundM: _r1(elev[ridgeAt]),
            aboveRayM: _r1(worstAbove),
          ),
  );
}

/// The model name the on-device answer carries (the server's is `profile+bullington+clutter v1`, the same maths).
const String onDeviceModelName = 'profile+bullington+clutter v1 (on this phone)';

/// The `plan-link` answer computed on the phone from an elevation profile [elev] sampled evenly from A to B (score-link's
/// profile, a stored plan-link profile, or any other): the same maths as the server's `linkAnswer`, so a link can be
/// judged offline or before the server has `plan-link`. Per-end power and gain default to a MeshCore repeater.
PlanLinkResult localPlanLink(
  PlanLinkRequest req,
  List<double> elev, {
  double? km,
  double aTxDbm = existingTxDbm,
  double bTxDbm = existingTxDbm,
  double aGainDbi = existingGainDbi,
  double bGainDbi = existingGainDbi,
  String terrain = 'terrain profile',
  DateTime? asOf,
  PlanMeasured? measured,
}) {
  if (elev.length < 3) throw ArgumentError.value(elev.length, 'elev', 'needs at least 3 samples');
  final dKm = km ?? haversineKm(req.a.lat, req.a.lon, req.b.lat, req.b.lon);
  final lambda = lambdaFor(req.radio);
  final geo = linkGeometry(req.a, req.b, req.haM, req.hbM, dKm, elev, lambda: lambda);
  final an = analyseLink(elev, dKm, req.haM, req.hbM,
      radio: req.radio, clutter: req.clutter, txDbm: aTxDbm, gainDbi: aGainDbi, bTxDbm: bTxDbm, bGainDbi: bGainDbi);
  final margin = an.marginAfterFade(req.direction);
  final n = elev.length;
  final odds = terrainOdds(dKm, an.diffractionDb);
  return PlanLinkResult(
    km: jsRound(dKm * 1000) / 1000,
    profile: PlanProfile(
      distanceKm: [for (var i = 0; i < n; i++) jsRound(i / (n - 1) * dKm * 1000) / 1000],
      groundM: [for (final e in elev) _r1(e)],
    ),
    fresnelClearancePct: geo.fresnelClearancePct,
    tightest: geo.tightest == null ? null : PlanTightestPoint(km: geo.tightest!.km, raiseM: geo.tightest!.raiseM),
    ridge: geo.ridge == null ? null : PlanRidge(km: geo.ridge!.km, at: PlanPoint(geo.ridge!.lat, geo.ridge!.lon), groundM: geo.ridge!.groundM),
    odds: jsRound(odds * 1000) / 1000,
    verdict: verdictOf(margin),
    marginDb: margin,
    measured: measured,
    provenance: PlanProvenance(
      model: onDeviceModelName,
      terrain: terrain,
      asOf: asOf,
      confidence: PlanConfidenceLevel.estimate,
      confidenceNote: 'unobserved, estimate',
    ),
  );
}
