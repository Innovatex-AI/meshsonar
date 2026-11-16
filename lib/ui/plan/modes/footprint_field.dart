// Coverage footprints of the plan's sites as fields of RECEIVED POWER (release 0.38 A9, improvements 8 and 9). A plan-verify
// answer (the website's coverage run, meshcore-insights src/lib/tools/coverage.ts) carries the sweep as `grid`: per radial
// and per range sample the link margin over the radio's sensitivity, 0.5 dB steps, base64 Int8. [SiteFootprint] turns it
// back into dBm at the receiver (margin + the run's sensitivity), so the SNR of any cell for ANY spreading factor or
// bandwidth is `dBm - noise floor` and a change of the plan's sensitivity or of the minimum-SNR slider re-renders with no
// new request (only the frequency, heights, power, clutter or the receiver change the dBm themselves). An answer without a
// usable grid (an older server, the coverage painter fallback) is rebuilt from its band polygons at each band's middle.
//
// [FootprintField] puts every current site on one grid of square cells (the union): per cell and per site the dBm, from
// which [FootprintField.classify] gives the best SNR, how many sites reach the cell at the minimum SNR ("how many
// repeaters see this spot") and the plan's area numbers. Pure Dart (no Flutter), so it is unit-tested directly.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../../core/plan/link_model.dart' show radioSensitivityDbm;
import '../../../core/plan_contract.dart';

const double _mPerDegLat = 111320;
double _mPerDegLon(double lat) => _mPerDegLat * math.cos(lat * math.pi / 180);

/// Margin (dB over sensitivity) a band polygon stands for when the grid itself is not there: each band's middle, and 6 dB
/// under the decode limit for "below".
const Map<String, double> bandMidMarginDb = {'below': -6, 'fringe': 3, 'usable': 9, 'solid': 15};

/// One site's modelled footprint: received power per cell of its radial sweep.
class SiteFootprint {
  /// The plan node it belongs to.
  final String nodeId;
  final PlanPoint site;
  final int radials, samples;

  /// Distance between range samples; sample j (1-based) sits j x [stepM] from the site.
  final double stepM;

  /// Received power at the receiver, dBm, at `[r * samples + (j - 1)]`; NaN where the sweep did not reach.
  final Float32List rxDbm;

  /// The radio the run was made for (its frequency fixes the path loss; SF and bandwidth only move the sensitivity).
  final PlanRadio radio;

  /// Rebuilt from the band polygons (each band at its middle), not the 0.5 dB grid.
  final bool fromBands;

  SiteFootprint({
    required this.nodeId,
    required this.site,
    required this.radials,
    required this.samples,
    required this.stepM,
    required this.rxDbm,
    required this.radio,
    this.fromBands = false,
  }) : assert(rxDbm.length == radials * samples);

  double get radiusM => samples * stepM;

  /// Received power at [p] (dBm), or null outside the swept area.
  double? dbmAt(PlanPoint p) {
    final dy = (p.lat - site.lat) * _mPerDegLat, dx = (p.lon - site.lon) * _mPerDegLon(site.lat);
    return _at(math.sqrt(dx * dx + dy * dy), dx, dy);
  }

  double? _at(double d, double dx, double dy) {
    if (d > radiusM + stepM / 2) return null;
    var j = (d / stepM).round();
    if (j < 1) j = 1;
    if (j > samples) j = samples;
    var brg = math.atan2(dx, dy) * 180 / math.pi;
    if (brg < 0) brg += 360;
    final r = (brg / 360 * radials).round() % radials;
    final v = rxDbm[r * samples + j - 1];
    return v.isNaN ? null : v;
  }

  /// The footprint of a plan-verify answer ([raw] is `PlanVerifyResult.raw`, the coverage run). Null when the answer has
  /// neither a grid nor band polygons (an answer with numbers only).
  static SiteFootprint? fromVerify(String nodeId, Map<String, dynamic> raw, {required PlanPoint site, required PlanRadio radio}) {
    final model = _m(raw['model']);
    final params = _m(raw['params']);
    final at = PlanPoint(_n(params['lat']) ?? site.lat, _n(params['lon']) ?? site.lon);
    final ran = PlanRadio(
      freqMHz: _n(model['freqMHz']) ?? radio.freqMHz,
      bwKHz: _n(model['bwKHz']) ?? radio.bwKHz,
      sf: _n(model['sf'])?.round() ?? radio.sf,
      cr: _n(model['cr'])?.round() ?? radio.cr,
    );
    final sens = _n(model['sensitivityDbm']) ?? radioSensitivityDbm(ran);
    final g = fromGrid(nodeId, _m(raw['grid']), site: at, radio: ran, sensitivityDbm: sens);
    if (g != null) return g;
    return ofBands(nodeId, bandsOfGeoJson(_m(raw['footprint'])), site: at, radio: ran, sensitivityDbm: sens);
  }

  /// The 0.5 dB margin grid (`{radials, n, stepM, margin, scale}`), or null when it is missing or does not add up.
  static SiteFootprint? fromGrid(String nodeId, Map<String, dynamic> grid, {required PlanPoint site, required PlanRadio radio, required double sensitivityDbm}) {
    final radials = _n(grid['radials'])?.round(), n = _n(grid['n'])?.round(), step = _n(grid['stepM']);
    final b64 = grid['margin'];
    if (radials == null || n == null || step == null || b64 is! String || radials < 8 || n < 1 || step <= 0) return null;
    final Uint8List bytes;
    try {
      bytes = base64.decode(b64);
    } on FormatException {
      return null;
    }
    if (bytes.length != radials * n) return null;
    final scale = _n(grid['scale']) ?? 0.5;
    final margin = Int8List.sublistView(bytes);
    final out = Float32List(radials * n);
    for (var i = 0; i < out.length; i++) {
      out[i] = margin[i] * scale + sensitivityDbm;
    }
    return SiteFootprint(nodeId: nodeId, site: site, radials: radials, samples: n, stepM: step, rxDbm: out, radio: radio);
  }

  /// A footprint rebuilt from band polygons (annular sectors around [site], as coverage.ts `footprint` draws them), each
  /// band at its middle margin ([bandMidMarginDb]). Null when there is nothing to rebuild.
  static SiteFootprint? ofBands(
    String nodeId,
    List<(String band, List<List<(double lat, double lon)>> rings)> bands, {
    required PlanPoint site,
    required PlanRadio radio,
    required double sensitivityDbm,
    int radials = 720,
    double stepM = 50,
  }) {
    final sectors = <(double b0, double b1, double r1, double r2, double margin)>[];
    var maxR = 0.0;
    final mLon = _mPerDegLon(site.lat);
    for (final (band, rings) in bands) {
      final margin = bandMidMarginDb[band];
      if (margin == null) continue;
      for (final ring in rings) {
        final brgs = <double>[];
        var r1 = double.infinity, r2 = 0.0;
        for (final (la, lo) in ring) {
          final dy = (la - site.lat) * _mPerDegLat, dx = (lo - site.lon) * mLon;
          final d = math.sqrt(dx * dx + dy * dy);
          if (d < 1) {
            r1 = 0;
            continue;
          }
          r1 = math.min(r1, d);
          r2 = math.max(r2, d);
          var b = math.atan2(dx, dy) * 180 / math.pi;
          if (b < 0) b += 360;
          brgs.add(b);
        }
        if (brgs.length < 2 || r2 <= 0) continue;
        brgs.sort();
        var b0 = brgs.first, b1 = brgs.last;
        if (b1 - b0 > 180) {
          // The sector straddles north: its bearings sit near 0 and near 360.
          final shifted = [for (final b in brgs) b > 180 ? b - 360 : b]..sort();
          b0 = shifted.first;
          b1 = shifted.last;
        }
        if (r1.isInfinite) r1 = 0;
        sectors.add((b0, b1, r1, r2, margin));
        maxR = math.max(maxR, r2);
      }
    }
    if (sectors.isEmpty) return null;
    final n = math.max(1, (maxR / stepM).ceil());
    final out = Float32List(radials * n)..fillRange(0, radials * n, double.nan);
    final w = 360 / radials;
    for (final (b0, b1, r1, r2, margin) in sectors) {
      final kFrom = (b0 / w).ceil(), kTo = (b1 / w).ceil();
      final jFrom = math.max(1, (r1 / stepM).ceil());
      final jTo = math.max(jFrom, math.min(n, (r2 / stepM).floor()));
      for (var k = kFrom; k < math.max(kTo, kFrom + 1); k++) {
        final r = k % radials; // Dart's % is never negative for a positive divisor
        for (var j = jFrom; j <= jTo; j++) {
          final i = r * n + j - 1;
          // Where two bands meet on one sample, the stronger wins (the sector edges are shared).
          final v = margin + sensitivityDbm;
          if (out[i].isNaN || v > out[i]) out[i] = v;
        }
      }
    }
    return SiteFootprint(nodeId: nodeId, site: site, radials: radials, samples: n, stepM: stepM, rxDbm: out, radio: radio, fromBands: true);
  }
}

/// Band polygons of a coverage run's `footprint` GeoJSON (MultiPolygon per band, lon/lat order) as lat/lon rings.
List<(String, List<List<(double, double)>>)> bandsOfGeoJson(Map<String, dynamic> fc) {
  final out = <(String, List<List<(double, double)>>)>[];
  final feats = fc['features'];
  if (feats is! List) return out;
  for (final f in feats) {
    if (f is! Map) continue;
    final band = _m(f['properties'])['band'];
    final geom = _m(f['geometry']);
    final rings = <List<(double, double)>>[];
    if (geom['type'] == 'MultiPolygon' && geom['coordinates'] is List) {
      for (final poly in geom['coordinates'] as List) {
        if (poly is! List) continue;
        for (final ring in poly) {
          if (ring is! List) continue;
          final pts = <(double, double)>[];
          for (final c in ring) {
            if (c is List && c.length >= 2 && c[0] is num && c[1] is num) pts.add(((c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
          if (pts.length >= 3) rings.add(pts);
        }
      }
    }
    if (band is String) out.add((band, rings));
  }
  return out;
}

/// What the union of the footprints shows at one minimum SNR.
class FootprintView {
  /// Best SNR of any site per cell (NaN = no site swept it).
  final Float32List bestSnr;

  /// Sites reaching each cell at the minimum SNR.
  final Uint8List count;
  final double minSnrDb;

  /// Area reached by at least one site, by two or more, by an existing network node of the plan, and reached only by the
  /// plan's planned or installed sites (what they add to the plan's existing nodes), km².
  final double areaKm2, overlapKm2, existingKm2, addedKm2;

  /// Area each site reaches on its own, km², by site index.
  final List<double> siteKm2;
  const FootprintView({
    required this.bestSnr,
    required this.count,
    required this.minSnrDb,
    required this.areaKm2,
    required this.overlapKm2,
    required this.existingKm2,
    required this.addedKm2,
    required this.siteKm2,
  });
}

/// Every current footprint on one grid of square cells.
class FootprintField {
  final List<SiteFootprint> sites;
  final double south, west, dLat, dLon, cellM;
  final int rows, cols;

  /// dBm per cell and site: `[(row * cols + col) * sites.length + s]`, NaN where the site's sweep does not reach.
  final Float32List dbm;
  FootprintField._(this.sites, this.south, this.west, this.dLat, this.dLon, this.cellM, this.rows, this.cols, this.dbm);

  /// Cells of at most [maxCells] (the cell size grows with the area so a phone stays quick).
  static FootprintField? build(List<SiteFootprint> sites, {int maxCells = 62500}) {
    if (sites.isEmpty) return null;
    var s = 90.0, n = -90.0, w = 180.0, e = -180.0;
    var minStep = double.infinity;
    for (final f in sites) {
      final r = f.radiusM + f.stepM;
      final dLa = r / _mPerDegLat, dLo = r / _mPerDegLon(f.site.lat);
      s = math.min(s, f.site.lat - dLa);
      n = math.max(n, f.site.lat + dLa);
      w = math.min(w, f.site.lon - dLo);
      e = math.max(e, f.site.lon + dLo);
      minStep = math.min(minStep, f.stepM);
    }
    final midLat = (s + n) / 2;
    final hM = (n - s) * _mPerDegLat, wM = (e - w) * _mPerDegLon(midLat);
    var cell = math.max(minStep, math.sqrt(hM * wM / maxCells));
    final rows = math.max(1, (hM / cell).ceil()), cols = math.max(1, (wM / cell).ceil());
    final dLat = cell / _mPerDegLat, dLon = cell / _mPerDegLon(midLat);
    final k = sites.length;
    final out = Float32List(rows * cols * k)..fillRange(0, rows * cols * k, double.nan);
    for (var si = 0; si < k; si++) {
      final f = sites[si];
      final mLon = _mPerDegLon(f.site.lat);
      final reach = f.radiusM + f.stepM / 2;
      final r0 = math.max(0, ((f.site.lat - reach / _mPerDegLat - s) / dLat).floor());
      final r1 = math.min(rows - 1, ((f.site.lat + reach / _mPerDegLat - s) / dLat).ceil());
      final c0 = math.max(0, ((f.site.lon - reach / mLon - w) / dLon).floor());
      final c1 = math.min(cols - 1, ((f.site.lon + reach / mLon - w) / dLon).ceil());
      for (var r = r0; r <= r1; r++) {
        final dy = (s + (r + 0.5) * dLat - f.site.lat) * _mPerDegLat;
        for (var c = c0; c <= c1; c++) {
          final dx = (w + (c + 0.5) * dLon - f.site.lon) * mLon;
          final d = math.sqrt(dx * dx + dy * dy);
          if (d > reach) continue;
          final v = f._at(d, dx, dy);
          if (v != null) out[(r * cols + c) * k + si] = v;
        }
      }
    }
    return FootprintField._(List.unmodifiable(sites), s, w, dLat, dLon, cell, rows, cols, out);
  }

  double get cellKm2 => cellM * cellM / 1e6;

  /// The cell's south-west corner.
  (double lat, double lon) corner(int row, int col) => (south + row * dLat, west + col * dLon);

  /// The cell under [p], or null outside the field.
  int? cellAt(PlanPoint p) {
    final r = ((p.lat - south) / dLat).floor(), c = ((p.lon - west) / dLon).floor();
    if (r < 0 || c < 0 || r >= rows || c >= cols) return null;
    return r * cols + c;
  }

  /// The union at [minSnrDb], with SNR = dBm - [noiseDbm] (the plan radio's noise floor). [existing] are the site indexes
  /// that are existing network nodes of the plan.
  FootprintView classify({required double noiseDbm, required double minSnrDb, Set<int> existing = const {}}) {
    final cells = rows * cols, k = sites.length;
    final best = Float32List(cells);
    final count = Uint8List(cells);
    final siteCells = List<int>.filled(k, 0);
    var any = 0, overlap = 0, ex = 0, added = 0;
    for (var i = 0; i < cells; i++) {
      var b = double.nan;
      var n = 0;
      var byExisting = false, byNew = false;
      for (var si = 0; si < k; si++) {
        final v = dbm[i * k + si];
        if (v.isNaN) continue;
        final snr = v - noiseDbm;
        if (b.isNaN || snr > b) b = snr;
        if (snr >= minSnrDb) {
          n++;
          siteCells[si]++;
          if (existing.contains(si)) {
            byExisting = true;
          } else {
            byNew = true;
          }
        }
      }
      best[i] = b;
      count[i] = math.min(n, 255);
      if (n > 0) any++;
      if (n > 1) overlap++;
      if (byExisting) ex++;
      if (byNew && !byExisting) added++;
    }
    final a = cellKm2;
    return FootprintView(
      bestSnr: best,
      count: count,
      minSnrDb: minSnrDb,
      areaKm2: any * a,
      overlapKm2: overlap * a,
      existingKm2: ex * a,
      addedKm2: added * a,
      siteKm2: [for (final c in siteCells) c * a],
    );
  }
}

/// What every footprint says about one spot: (site index, SNR dB), strongest first. Sites whose sweep does not reach it are
/// left out.
List<(int site, double snrDb)> spotReport(List<SiteFootprint> sites, PlanPoint p, {required double noiseDbm}) {
  final out = <(int, double)>[];
  for (var i = 0; i < sites.length; i++) {
    final v = sites[i].dbmAt(p);
    if (v != null) out.add((i, v - noiseDbm));
  }
  out.sort((a, b) => b.$2.compareTo(a.$2));
  return out;
}

/// Measured cells near an installed site against its footprint (the verify loop, improvement 20).
class VerifyLoop {
  /// Measured cells inside the footprint's reach.
  final int cells;

  /// Cells where the estimate and the measurement agree (both heard, or both nothing).
  final int agree;

  /// The estimate said a radio decodes there, but drives heard nothing.
  final int predictedNotHeard;

  /// Drives heard something where the estimate said nothing decodes.
  final int heardNotPredicted;

  /// Mean measured SNR and mean predicted SNR over the cells that heard something with a reading, dB.
  final double? measuredSnr, predictedSnr;
  const VerifyLoop({required this.cells, required this.agree, required this.predictedNotHeard, required this.heardNotPredicted, this.measuredSnr, this.predictedSnr});

  double get agreePct => cells == 0 ? 0 : 100 * agree / cells;

  /// Predicted minus measured SNR (positive = the estimate is optimistic).
  double? get biasDb => measuredSnr == null || predictedSnr == null ? null : predictedSnr! - measuredSnr!;
}

/// One measured cell for [verifyLoop]: centre, whether anything was heard, and its SNR (mean, else median) when read.
typedef MeasuredCell = ({PlanPoint at, bool heard, double? snr});

/// Compares [measured] cells inside [f]'s reach with the footprint: a cell "decodes" when its predicted SNR is at least
/// [decodeSnrDb] (the radio's floor).
VerifyLoop verifyLoop(SiteFootprint f, Iterable<MeasuredCell> measured, {required double noiseDbm, required double decodeSnrDb}) {
  var cells = 0, agree = 0, pnh = 0, hnp = 0, nSnr = 0;
  var sumM = 0.0, sumP = 0.0;
  final dLa = (f.radiusM + f.stepM) / _mPerDegLat, dLo = (f.radiusM + f.stepM) / _mPerDegLon(f.site.lat);
  for (final m in measured) {
    if ((m.at.lat - f.site.lat).abs() > dLa || (m.at.lon - f.site.lon).abs() > dLo) continue;
    final v = f.dbmAt(m.at);
    if (v == null) continue;
    cells++;
    final snr = v - noiseDbm;
    final predicted = snr >= decodeSnrDb;
    if (predicted == m.heard) {
      agree++;
    } else if (predicted) {
      pnh++;
    } else {
      hnp++;
    }
    if (m.heard && m.snr != null && m.snr!.isFinite) {
      nSnr++;
      sumM += m.snr!;
      sumP += snr;
    }
  }
  return VerifyLoop(
    cells: cells,
    agree: agree,
    predictedNotHeard: pnh,
    heardNotPredicted: hnp,
    measuredSnr: nSnr == 0 ? null : sumM / nSnr,
    predictedSnr: nSnr == 0 ? null : sumP / nSnr,
  );
}

double? _n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
Map<String, dynamic> _m(Object? v) => v is Map<String, dynamic> ? v : const {};
