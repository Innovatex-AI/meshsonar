// Hex coverage: the drive's own pings rolled up onto the same H3 hexagons the website draws.
//
// Same rule as the server (meshcore-insights docs/specs/m1-h3-grid.md): a ping's cell at display resolution 9 is the PARENT of
// its resolution-11 cell, never latLngToCell(lat, lon, 9) (for about 6% of points the two differ). Only tx pings count, like the
// site ("did the mesh hear what I sent here"); rx pings are listening, not coverage. The id is the lower-case hex string, the
// same string h3-js and the site's API use.
//
// Pure logic over an injected [H3] so tests can load libh3 by path; the app loads it with [loadHexEngine].
import 'package:h3_flutter/h3_flutter.dart';

import 'coverage_v2.dart' show coverageBandOf, kCoverageV2Res;
import 'model.dart';

/// Display resolution, the same as the site's default (about 350 m across).
const int hexDisplayRes = 9;

/// Resolution the server stores per ping; the roll-up goes through it.
const int hexStoreRes = 11;

class HexPoint {
  final double lat;
  final double lon;
  const HexPoint(this.lat, this.lon);
}

/// One hexagon of the drive: how many tx pings landed in it and what the mesh heard.
class HexCell {
  /// Lower-case hex, same as the website.
  final String id;

  /// The outline, not closed (first point is not repeated).
  final List<HexPoint> boundary;

  /// tx pings sent from inside the hexagon.
  final int sent;

  /// Of those, how many were heard by at least one repeater.
  final int heard;

  /// Strongest SNR heard from inside it (dB), null when nothing was heard or no SNR was reported.
  final double? bestSnrDb;

  /// Coverage v2 ("This drive", [buildDriveCells]): the MEAN of the ping results that carry an SNR (dB), how many do, and the
  /// cell's band (lib/core/coverage_v2.dart, the server's rule). Null / 0 on cells from [buildHexCells].
  final double? snrMeanDb;
  final int nSnr;
  final int? band;

  /// The cell's centre (v2 cells only; used for the zoomed-out dots and the inspector).
  final HexPoint? center;
  const HexCell({
    required this.id,
    required this.boundary,
    required this.sent,
    required this.heard,
    this.bestSnrDb,
    this.snrMeanDb,
    this.nSnr = 0,
    this.band,
    this.center,
  });

  bool get wasHeard => heard > 0;
}

/// Loads the H3 library the way the platform wants it (iOS and macOS link it into the app). Null when it is not there, so the
/// map simply draws no hexagons instead of failing.
H3? loadHexEngine() {
  try {
    return const H3Factory().load();
  } catch (_) {
    return null;
  }
}

/// The cell of one position at [res] (parent of its resolution-11 cell), as the website computes it.
BigInt hexCellOf(H3 h3, double lat, double lon, {int res = hexDisplayRes}) => h3
    .cellToParent(h3.geoToCell(GeoCoord(lon: lon, lat: lat), hexStoreRes), res);

/// Lower-case hex for a cell index.
String hexId(BigInt cell) => cell.toRadixString(16);

/// Rolls the tx pings up onto hexagons. Pings without a usable position are skipped; the order of the result is stable
/// (by id) so redraws do not shuffle.
List<HexCell> buildHexCells(
  Iterable<DrivePing> pings,
  H3 h3, {
  int res = hexDisplayRes,
}) {
  final sent = <BigInt, int>{};
  final heard = <BigInt, int>{};
  final best = <BigInt, double>{};
  for (final p in pings) {
    if (p.kind != PingKind.tx) {
      continue;
    }
    if (!p.lat.isFinite || !p.lon.isFinite || p.lat.abs() > 90 || p.lon.abs() > 180) {
      continue;
    }
    final c = hexCellOf(h3, p.lat, p.lon, res: res);
    sent[c] = (sent[c] ?? 0) + 1;
    if (!p.heardNothing) {
      heard[c] = (heard[c] ?? 0) + 1;
      for (final e in p.echoes) {
        final s = e.snrDb;
        if (s != null && (best[c] == null || s > best[c]!)) best[c] = s;
      }
    }
  }
  final out = <HexCell>[
    for (final e in sent.entries)
      HexCell(
        id: hexId(e.key),
        boundary: [
          for (final g in h3.cellToBoundary(e.key)) HexPoint(g.lat, g.lon),
        ],
        sent: e.value,
        heard: heard[e.key] ?? 0,
        bestSnrDb: best[e.key],
      ),
  ]..sort((a, b) => a.id.compareTo(b.id));
  return out;
}

/// "12 of 31 hexagons heard" style summary numbers for a list of cells.
({int cells, int heardCells}) hexTotals(List<HexCell> cells) =>
    (cells: cells.length, heardCells: cells.where((c) => c.wasHeard).length);

/// The result of one tx ping for coverage v2 (plan D2): heard or not, and its SNR. The SNR is the best DIRECT echo (hops 1, or
/// unknown hops as the server counts them), else the local SNR of the discover answer folded into the same attempt; null when
/// it was heard only through a relay or without a reading. Null for rx pings and unusable positions.
({bool ok, double? snr})? pingResult(DrivePing p) {
  if (p.kind != PingKind.tx) return null;
  if (!p.lat.isFinite || !p.lon.isFinite || p.lat.abs() > 90 || p.lon.abs() > 180) return null;
  if (p.heardNothing) return (ok: false, snr: null);
  double? best;
  for (final e in p.echoes) {
    final s = e.snrDb;
    if (s == null || !s.isFinite || (e.hops != null && e.hops != 1)) continue;
    if (best == null || s > best) best = s;
  }
  best ??= p.neighbor?.localSnrDb;
  return (ok: true, snr: best != null && best.isFinite ? best : null);
}

/// "This drive" (coverage v2, plan 5): this session's pings as res-11 cells, each with the MEAN SNR of its results and the
/// same band the server gives a measured cell ([sf] picks the floor). Failed pings count in [HexCell.sent] but never in the
/// mean (D4). Stable order (by id).
List<HexCell> buildDriveCells(Iterable<DrivePing> pings, H3 h3, {int sf = 7}) {
  final sent = <BigInt, int>{};
  final ok = <BigInt, int>{};
  final nSnr = <BigInt, int>{};
  final sum = <BigInt, double>{};
  final best = <BigInt, double>{};
  for (final p in pings) {
    final r = pingResult(p);
    if (r == null) continue;
    final c = h3.geoToCell(GeoCoord(lon: p.lon, lat: p.lat), kCoverageV2Res);
    sent[c] = (sent[c] ?? 0) + 1;
    if (!r.ok) continue;
    ok[c] = (ok[c] ?? 0) + 1;
    final s = r.snr;
    if (s == null) continue;
    nSnr[c] = (nSnr[c] ?? 0) + 1;
    sum[c] = (sum[c] ?? 0) + s;
    if (best[c] == null || s > best[c]!) best[c] = s;
  }
  final out = <HexCell>[
    for (final e in sent.entries)
      () {
        final n = nSnr[e.key] ?? 0;
        final mean = n == 0 ? null : sum[e.key]! / n;
        final ctr = h3.cellToGeo(e.key);
        return HexCell(
          id: hexId(e.key),
          boundary: [for (final g in h3.cellToBoundary(e.key)) HexPoint(g.lat, g.lon)],
          sent: e.value,
          heard: ok[e.key] ?? 0,
          bestSnrDb: best[e.key],
          snrMeanDb: mean,
          nSnr: n,
          band: coverageBandOf(snrMean: mean, nOk: ok[e.key] ?? 0, nSnr: n, sf: sf),
          center: HexPoint(ctr.lat, ctr.lon),
        );
      }(),
  ]..sort((a, b) => a.id.compareTo(b.id));
  return out;
}
