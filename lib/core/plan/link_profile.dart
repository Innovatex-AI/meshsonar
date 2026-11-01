// `plan-native?view=link&a=..&b=..`: the stored terrain profile of a candidate link (ground, surface with trees and buildings,
// earth bulge included) and the line-of-sight / 60% first-Fresnel / Bullington maths over it. The maths is a port of the website's
// lib/profile.ts (clearance, clearanceStored, storedFt, linkBudget) so the height sliders work on the phone, offline, with the
// same numbers; test/core/plan/link_profile_test.dart checks the port against the server's own figures for the stored 20 and 33 ft
// scenarios. Wavelength is the website's (the US preset, 910.525 MHz). Pure Dart: no Flutter imports.
import 'dart:math' as math;

import '../region_dataset_fetch.dart' show jDbl, jInt, jMap, jMaps, jStr;

const double _freqMhz = 910.525;
final double _lambdaM = 299792458 / (_freqMhz * 1e6);
const double fresnelShare = 0.6;
const double sensitivityDbm = -127.5;

double _knifeEdge(double v) => v <= -0.78 ? 0 : 6.9 + 20 * (math.log(math.sqrt(math.pow(v - 0.1, 2) + 1) + v - 0.1) / math.ln10);

/// ITU-R P.526 single-equivalent-edge (Bullington) loss over heights that already include earth bulge.
double bullingtonBulged(List<double> d, List<double> h, double hA, double hB) {
  final n = d.length;
  final dd = n == 0 ? 0.0 : d.last;
  if (n < 3 || dd < 100) return 0;
  var s1 = double.negativeInfinity, s2 = double.negativeInfinity, vmax = double.negativeInfinity;
  for (var i = 1; i < n - 1; i++) {
    final di = d[i], hi = h[i];
    if (di <= 0 || di >= dd) continue;
    s1 = math.max(s1, (hi - hA) / di);
    s2 = math.max(s2, (hi - hB) / (dd - di));
    final los = hA + ((hB - hA) * di) / dd;
    vmax = math.max(vmax, (hi - los) * math.sqrt((2 * dd) / (_lambdaM * di * (dd - di))));
  }
  if (!s1.isFinite) return 0;
  final slr = (hB - hA) / dd;
  if (s1 < slr) return _knifeEdge(vmax);
  final db = (hB - hA + s2 * dd) / (s1 + s2);
  if (!(db > 0 && db < dd)) return _knifeEdge(vmax);
  final hb = hA + s1 * db;
  final v = (hb - (hA + ((hB - hA) * db) / dd)) * math.sqrt((2 * dd) / (_lambdaM * db * (dd - db)));
  return _knifeEdge(v);
}

double fsplDb(double km) => 20 * (math.log(math.max(km, 0.001)) / math.ln10) + 20 * (math.log(_freqMhz) / math.ln10) + 32.44;

class ClearRow {
  final double km, ground, surface, line, fresnelLo, fresnelHi;
  final bool tree;
  final double? ratio;
  const ClearRow(this.km, this.ground, this.surface, this.tree, this.line, this.fresnelLo, this.fresnelHi, this.ratio);
  bool get blocked => surface > line;
}

class Obstruction {
  final double km, above, ratio;
  final String what; // canopy | building | ground
  const Obstruction(this.km, this.above, this.what, this.ratio);
}

class Clearance {
  final List<ClearRow> rows;
  final double floor, top, hAm, hBm, worstRatio, worstKm, worstClearM, clearShare, bullDb, bullGroundDb, fspl;
  final String worstWhat;
  final int blockedM, canopyM;
  final List<Obstruction> obstructions;
  const Clearance({
    required this.rows,
    required this.floor,
    required this.top,
    required this.hAm,
    required this.hBm,
    required this.worstRatio,
    required this.worstKm,
    required this.worstClearM,
    required this.worstWhat,
    required this.clearShare,
    required this.blockedM,
    required this.canopyM,
    required this.bullDb,
    required this.bullGroundDb,
    required this.fspl,
    required this.obstructions,
  });
}

class LinkBudget {
  final double txDbm, gainsDbi, cableDb, fspl, diffraction, rxDbm, sensitivity, marginDb;
  const LinkBudget(this.txDbm, this.gainsDbi, this.cableDb, this.fspl, this.diffraction, this.rxDbm, this.sensitivity, this.marginDb);
}

/// Tx + both antenna gains - cable loss - free-space loss - Bullington. An estimate, not the fitted odds model.
LinkBudget linkBudget(Clearance c, double txDbm, double gainsDbi, double cableDb) {
  final rx = txDbm + gainsDbi - cableDb - c.fspl - c.bullDb;
  return LinkBudget(txDbm, gainsDbi, cableDb, c.fspl, c.bullDb, rx, sensitivityDbm, rx - sensitivityDbm);
}

class LinkEnd {
  final String id, name, kind; // kind: site | repeater
  final int? wave;
  final double? lat, lon;
  final String? key;
  const LinkEnd(this.id, this.name, this.kind, this.wave, this.lat, this.lon, this.key);
}

class StoredClearance {
  final int h, blockedM, canopyM;
  final double worstRatio, worstKm, worstClearM, clearShare, bullDb, fspl;
  const StoredClearance(this.h, this.worstRatio, this.worstKm, this.worstClearM, this.clearShare, this.blockedM, this.canopyM, this.bullDb, this.fspl);
}

class LinkOdds {
  final String tier20, tier33;
  final double odds20, odds33, treeM20, treeM33;
  const LinkOdds(this.tier20, this.tier33, this.odds20, this.odds33, this.treeM20, this.treeM33);
}

class LinkProfile {
  final bool found;
  final String a, b;
  final double km;
  final int profileCount;
  final List<LinkEnd> ends;
  final List<double> d, ground, surface;
  final List<bool> tree;
  final double ant20A, ant20B, ant33A, ant33B;
  final bool existingA, existingB;
  final List<StoredClearance> stored;
  final LinkOdds? odds;
  const LinkProfile({
    required this.found,
    required this.a,
    required this.b,
    this.km = 0,
    this.profileCount = 0,
    this.ends = const [],
    this.d = const [],
    this.ground = const [],
    this.surface = const [],
    this.tree = const [],
    this.ant20A = 0,
    this.ant20B = 0,
    this.ant33A = 0,
    this.ant33B = 0,
    this.existingA = false,
    this.existingB = false,
    this.stored = const [],
    this.odds,
  });

  /// Ground under each antenna: for a proposed site recovered from the stored 20 ft antenna (minus 6 m), for a live repeater
  /// the profile's own end sample.
  double get baseA => existingA ? ground.first : ant20A - 6;
  double get baseB => existingB ? ground.last : ant20B - 6;

  /// Antenna height above ground at each end for a stored scenario (20 ft or 33 ft poles in the plan's own naming), metres.
  (double, double) storedHeights(int h) => ((h == 33 ? ant33A : ant20A) - baseA, (h == 33 ? ant33B : ant20B) - baseB);

  /// Line of sight, 60% Fresnel and diffraction for antennas [hAm] / [hBm] metres above the ground at each end.
  Clearance clearance(double hAm, double hBm) => _clearanceAbs(baseA + hAm, baseB + hBm, hAm, hBm);

  Clearance clearanceStored(int h) {
    final m = storedHeights(h);
    return _clearanceAbs(h == 33 ? ant33A : ant20A, h == 33 ? ant33B : ant20B, m.$1, m.$2);
  }

  Clearance _clearanceAbs(double hA, double hB, double hAm, double hBm) {
    final n = d.length;
    final dd = n == 0 || d.last == 0 ? 1.0 : d.last;
    final floor = (ground.reduce(math.min) - 10).floorToDouble();
    final step = n > 1 ? dd / (n - 1) : 0.0;
    var worst = double.infinity, worstKm = 0.0, clearN = 0, interior = 0;
    var blockedM = 0.0, canopyM = 0.0;
    final surf = <double>[];
    final rows = <ClearRow>[];
    for (var i = 0; i < n; i++) {
      final di = d[i];
      final t = di / dd;
      final line = hA + (hB - hA) * t;
      final g = ground[i], s = math.max(surface[i], g), tr = tree[i];
      surf.add(s);
      final r1 = di > 0 && di < dd ? math.sqrt((_lambdaM * di * (dd - di)) / dd) : 0.0;
      final z = fresnelShare * r1;
      final double? ratio = r1 > 0 ? (line - s) / r1 : null;
      if (ratio != null) {
        interior++;
        if (ratio >= fresnelShare) clearN++;
        if (ratio < worst) {
          worst = ratio;
          worstKm = di / 1000;
        }
      }
      if (s > line) {
        blockedM += step;
        if (tr) canopyM += step;
      }
      rows.add(ClearRow((di.roundToDouble()) / 1000, g, s, tr, line, line - z, line + z, ratio));
    }
    // Worst obstructions: local maxima of the intrusion into the 60% zone, at least 300 m apart.
    final cand = <(int, double)>[
      for (var i = 0; i < rows.length; i++)
        if (rows[i].ratio != null && fresnelShare - rows[i].ratio! > 0) (i, fresnelShare - rows[i].ratio!),
    ]..sort((x, y) => y.$2.compareTo(x.$2));
    final picked = <(int, double)>[];
    for (final c in cand) {
      if (picked.every((q) => (rows[q.$1].km - rows[c.$1].km).abs() >= 0.3)) picked.add(c);
      if (picked.length >= 3) break;
    }
    String what(ClearRow r) => r.tree ? 'canopy' : (r.surface - r.ground > 2 ? 'building' : 'ground');
    final obstructions = [
      for (final p in picked) Obstruction(rows[p.$1].km, (((rows[p.$1].surface - rows[p.$1].line) * 10).round()) / 10, what(rows[p.$1]), rows[p.$1].ratio ?? 0),
    ];
    final top = (rows.map((r) => math.max(r.surface, r.fresnelHi)).reduce(math.max) + 4).ceilToDouble();
    ClearRow? wr;
    for (final r in rows) {
      if (r.ratio == worst) {
        wr = r;
        break;
      }
    }
    ClearRow? deepest;
    for (final r in rows) {
      if (r.ratio == null) continue;
      if (deepest == null || r.surface - r.line > deepest.surface - deepest.line) deepest = r;
    }
    if (deepest != null && deepest.surface > deepest.line) {
      wr = deepest;
      worstKm = deepest.km;
    }
    return Clearance(
      rows: rows,
      floor: floor,
      top: top,
      hAm: hAm,
      hBm: hBm,
      worstRatio: worst.isFinite ? worst : 1,
      worstKm: worstKm,
      worstClearM: wr == null ? 0 : (((wr.line - wr.surface) * 10).round()) / 10,
      worstWhat: wr == null ? 'ground' : what(wr),
      clearShare: interior > 0 ? clearN / interior : 1,
      blockedM: blockedM.round(),
      canopyM: canopyM.round(),
      bullDb: bullingtonBulged(d, surf, hA, hB),
      bullGroundDb: bullingtonBulged(d, ground, hA, hB),
      fspl: fsplDb(km),
      obstructions: obstructions,
    );
  }

  static LinkProfile parse(Map<String, dynamic> j) {
    final a = jStr(j['a']) ?? '', b = jStr(j['b']) ?? '';
    if (j['found'] != true) return LinkProfile(found: false, a: a, b: b, profileCount: jInt(j['profileCount']) ?? 0);
    final p = jMap(j['profile']);
    final ant = jMap(p['ant']);
    final ex = jMap(p['existing']);
    List<double> nums(Object? o) => [if (o is List) for (final x in o) if (x is num) x.toDouble()];
    final c = jMap(j['candidate']);
    return LinkProfile(
      found: true,
      a: a,
      b: b,
      km: jDbl(j['km']) ?? 0,
      ends: [
        for (final e in jMaps(j['ends']))
          LinkEnd(jStr(e['id']) ?? '', jStr(e['name']) ?? jStr(e['id']) ?? '', jStr(e['kind']) ?? 'site', jInt(e['wave']), jDbl(e['lat']), jDbl(e['lon']), jStr(e['key'])),
      ],
      d: nums(p['d']),
      ground: nums(p['ground']),
      surface: nums(p['surface']),
      tree: [if (p['tree'] is List) for (final x in p['tree'] as List) x == 1 || x == true],
      ant20A: jDbl(ant['a20']) ?? 0,
      ant20B: jDbl(ant['b20']) ?? 0,
      ant33A: jDbl(ant['a33']) ?? 0,
      ant33B: jDbl(ant['b33']) ?? 0,
      existingA: ex['a'] == true,
      existingB: ex['b'] == true,
      stored: [
        for (final s in jMaps(j['stored']))
          StoredClearance(jInt(s['h']) ?? 33, jDbl(s['worstRatio']) ?? 0, jDbl(s['worstKm']) ?? 0, jDbl(s['worstClearM']) ?? 0, jDbl(s['clearShare']) ?? 0, jInt(s['blockedM']) ?? 0, jInt(s['canopyM']) ?? 0,
              jDbl(s['bullDb']) ?? 0, jDbl(s['fspl']) ?? 0),
      ],
      odds: c.isEmpty ? null : LinkOdds(jStr(c['tier20']) ?? 'Stretch', jStr(c['tier33']) ?? 'Stretch', jDbl(c['odds20']) ?? 0, jDbl(c['odds33']) ?? 0, jDbl(c['treeM20']) ?? 0, jDbl(c['treeM33']) ?? 0),
    );
  }
}
