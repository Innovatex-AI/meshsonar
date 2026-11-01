// `plan-native?view=sites`: every possible repeater site (OSM places of worship, schools and parks plus the original plan sites
// that have no OSM record) in the website's row shape, and the Site explorer's search, filters, sort, "nearby" and compare maths
// (ports of the website's components/candidates/model.ts, engine.ts byValue and the candidate compare table). Runs on the phone,
// so filtering and sorting work offline on the last list. Pure Dart: no Flutter imports.
import '../heard.dart' show haversineM;
import '../region_dataset_fetch.dart' show jDbl, jInt, jMap, jMaps, jStr;
import '../units.dart' show Units;
import 'plan_overview.dart' show PlanRepeater;

class SiteBest {
  final String key, tier, basis; // basis: lidar | trees | terrain
  final double km, odds;
  const SiteBest(this.key, this.km, this.tier, this.odds, this.basis);
  static SiteBest? parse(Object? o) {
    if (o is! Map<String, dynamic>) return null;
    final k = jStr(o['key']), odds = jDbl(o['odds']);
    return k == null || odds == null ? null : SiteBest(k, jDbl(o['km']) ?? 0, jStr(o['tier']) ?? 'Stretch', odds, jStr(o['basis']) ?? 'terrain');
  }
}

class SiteValue {
  final int joins, newPeople, linksIntoMesh;
  final bool joinsMain;
  const SiteValue(this.joins, this.newPeople, this.linksIntoMesh, this.joinsMain);
  static SiteValue? parse(Object? o) {
    if (o is! Map<String, dynamic>) return null;
    return SiteValue(jInt(o['joins']) ?? 0, jInt(o['newPeople']) ?? 0, jInt(o['linksIntoMesh']) ?? 0, o['joinsMain'] == true);
  }
}

class SiteRow {
  final String id, sub, name, town, likelyBasis;
  final String? candId, planSite, kind, street, zip;
  final double lat, lon, elevM;
  final int? gap3, rank, nLikely, pop3, seqLikely, seqPossible;
  final double? score, canopy150;
  final SiteBest? best;
  final bool? joinsMain;
  final SiteValue? value;
  const SiteRow({
    required this.id,
    required this.candId,
    required this.planSite,
    required this.kind,
    required this.sub,
    required this.name,
    required this.lat,
    required this.lon,
    required this.town,
    required this.street,
    required this.zip,
    required this.elevM,
    required this.gap3,
    required this.score,
    required this.rank,
    required this.best,
    required this.nLikely,
    required this.likelyBasis,
    required this.canopy150,
    required this.joinsMain,
    required this.seqLikely,
    required this.seqPossible,
    required this.value,
    required this.pop3,
  });

  bool get isPlan => planSite != null;

  /// What the Site explorer shows as the site's own reference: the plan id for an original site, else the OSM id.
  String get ref => planSite ?? 'c:${candId ?? id}';

  static SiteRow? parse(Map<String, dynamic> j) {
    final id = jStr(j['id']), lat = jDbl(j['lat']), lon = jDbl(j['lon']);
    if (id == null || lat == null || lon == null) return null;
    final seq = jMap(j['seq']);
    return SiteRow(
      id: id,
      candId: jStr(j['candId']),
      planSite: jStr(j['planSite']),
      kind: jStr(j['kind']),
      sub: jStr(j['sub']) ?? '',
      name: jStr(j['name']) ?? id,
      lat: lat,
      lon: lon,
      town: jStr(j['town']) ?? 'Unknown',
      street: jStr(j['street']),
      zip: jStr(j['zip']),
      elevM: jDbl(j['elevM']) ?? 0,
      gap3: jInt(j['gap3']),
      score: jDbl(j['score']),
      rank: jInt(j['rank']),
      best: SiteBest.parse(j['best']),
      nLikely: jInt(j['nLikely']),
      likelyBasis: jStr(j['likelyBasis']) ?? 'terrain',
      canopy150: jDbl(j['canopy150']),
      joinsMain: j['joinsMain'] is bool ? j['joinsMain'] as bool : null,
      seqLikely: jInt(seq['likely']),
      seqPossible: jInt(seq['possible']),
      value: SiteValue.parse(j['value']),
      pop3: jInt(j['pop3']),
    );
  }
}

class SitesMeta {
  final int count;
  final String asOfOsm, builtUtc;
  final List<double> box; // south, north, west, east
  const SitesMeta(this.count, this.asOfOsm, this.builtUtc, this.box);
}

class PlanSites {
  final bool available;
  final String? reason, asOf, planBuilt;
  final SitesMeta? meta;
  final List<PlanRepeater> repeaters;
  final List<SiteRow> rows;
  const PlanSites({required this.available, this.reason, this.asOf, this.planBuilt, this.meta, this.repeaters = const [], this.rows = const []});

  String repeaterName(String key) {
    for (final r in repeaters) {
      if (r.key == key) return r.name;
    }
    return key.length > 8 ? key.substring(0, 8) : key;
  }

  PlanRepeater? repeater(String key) {
    for (final r in repeaters) {
      if (r.key == key) return r;
    }
    return null;
  }

  SiteRow? byRef(String ref) {
    for (final r in rows) {
      if (r.planSite == ref || 'c:${r.candId}' == ref || r.id == ref) return r;
    }
    return null;
  }

  static PlanSites parse(Map<String, dynamic> j) {
    if (j['available'] == false) return PlanSites(available: false, reason: jStr(j['reason']));
    final m = jMap(j['meta']);
    final box = m['box'];
    return PlanSites(
      available: true,
      asOf: jStr(j['asOf']),
      planBuilt: jStr(j['planBuilt']),
      meta: m.isEmpty
          ? null
          : SitesMeta(jInt(m['count']) ?? 0, jStr(m['asOfOsm']) ?? '', jStr(m['builtUtc']) ?? '',
              [if (box is List) for (final x in box) if (x is num) x.toDouble()]),
      repeaters: [for (final r in jMaps(j['repeaters'])) ?PlanRepeater.parse(r)],
      rows: [for (final r in jMaps(j['rows'])) ?SiteRow.parse(r)],
    );
  }
}

// ---------------------------------------------------------------- filter and sort (candidates/model.ts)
enum SiteSort { value, best, likely, gap, score, canopy, elev, dist, name }

const siteSortLabels = <SiteSort, String>{
  SiteSort.value: 'Engine value',
  SiteSort.best: 'Best link odds, 33 ft',
  SiteSort.likely: 'Likely+ links, 33 ft',
  SiteSort.gap: 'People newly within 3 km',
  SiteSort.score: 'Candidate score',
  SiteSort.canopy: 'Canopy within 150 m',
  SiteSort.elev: 'Ground elevation',
  SiteSort.dist: 'Distance from location',
  SiteSort.name: 'Name',
};

/// Default direction per sort key: engine order, distance and name ascend; everything else biggest first.
bool defaultAsc(SiteSort s) => s == SiteSort.value || s == SiteSort.dist || s == SiteSort.name;

class NearPoint {
  final double lat, lon;
  final String label;
  const NearPoint(this.lat, this.lon, this.label);
}

class SiteFilter {
  final String q;

  /// worship | school | park | plan
  final String? kind;
  final String? town;
  final bool joins, likely;
  final SiteSort sort;

  /// Direction actually applied (already resolved against [defaultAsc]).
  final bool asc;
  final NearPoint? near;
  const SiteFilter({this.q = '', this.kind, this.town, this.joins = false, this.likely = false, this.sort = SiteSort.value, bool? asc, this.near})
      : asc = asc ?? true;

  SiteFilter copyWith({String? q, Object? kind = _keep, Object? town = _keep, bool? joins, bool? likely, SiteSort? sort, bool? asc, Object? near = _keep}) => SiteFilter(
        q: q ?? this.q,
        kind: identical(kind, _keep) ? this.kind : kind as String?,
        town: identical(town, _keep) ? this.town : town as String?,
        joins: joins ?? this.joins,
        likely: likely ?? this.likely,
        sort: sort ?? this.sort,
        asc: asc ?? this.asc,
        near: identical(near, _keep) ? this.near : near as NearPoint?,
      );
  static const Object _keep = Object();
  bool get any => q.trim().isNotEmpty || kind != null || town != null || joins || likely;
}

bool matchRow(SiteRow r, String q) {
  final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  if (words.isEmpty) return true;
  final hay = '${r.name} ${r.sub} ${r.street ?? ''} ${r.town} ${r.zip ?? ''} ${r.planSite ?? ''}'.toLowerCase();
  return words.every(hay.contains);
}

/// Every filter except the kind facet, so the kind chips can show counts under the other filters.
List<SiteRow> baseFilter(List<SiteRow> rows, SiteFilter f) {
  final q = f.q.trim();
  return [
    for (final c in rows)
      if ((f.town == null || c.town == f.town) && (!f.joins || c.joinsMain == true) && (!f.likely || (c.nLikely ?? 0) > 0) && (q.isEmpty || matchRow(c, q))) c,
  ];
}

double? distKm(SiteRow c, NearPoint? n) => n == null ? null : haversineM(n.lat, n.lon, c.lat, c.lon) / 1000;

Map<String, int> kindCounts(List<SiteRow> rows) {
  final out = {'worship': 0, 'school': 0, 'park': 0, 'plan': 0};
  for (final c in rows) {
    if (c.kind != null && out.containsKey(c.kind)) out[c.kind!] = out[c.kind!]! + 1;
    if (c.planSite != null) out['plan'] = out['plan']! + 1;
  }
  return out;
}

/// Towns with site counts, most sites first (ties by name).
List<(String, int)> townCounts(List<SiteRow> rows) {
  final m = <String, int>{};
  for (final c in rows) {
    m[c.town] = (m[c.town] ?? 0) + 1;
  }
  final out = [for (final e in m.entries) (e.key, e.value)];
  out.sort((a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1));
  return out;
}

/// Engine value order: regional sequence position (Likely+, then Possible+), then today's standalone value (live repeaters
/// joined, people newly within 3 km), then the candidate score (engine.ts byValue).
int byValue(SiteRow a, SiteRow b) {
  int cmp(num x, num y) => x == y ? 0 : (x < y ? -1 : 1);
  num s(int? v) => v ?? double.infinity;
  final d = cmp(s(a.seqLikely), s(b.seqLikely));
  if (d != 0) return d;
  final d2 = cmp(s(a.seqPossible), s(b.seqPossible));
  if (d2 != 0) return d2;
  int j(SiteRow r) => r.value?.joins ?? -1;
  int p(SiteRow r) => r.value?.newPeople ?? r.gap3 ?? -1;
  final jj = j(b) - j(a);
  if (jj != 0) return jj;
  final pp = p(b) - p(a);
  if (pp != 0) return pp;
  final ss = ((b.score ?? -1) - (a.score ?? -1));
  if (ss != 0) return ss > 0 ? 1 : -1;
  return a.name.compareTo(b.name);
}

List<SiteRow> applyFilter(List<SiteRow> rows, SiteFilter f) {
  final base = [
    for (final c in baseFilter(rows, f))
      if (f.kind == null || (f.kind == 'plan' ? c.planSite != null : c.kind == f.kind)) c,
  ];
  final sort = f.sort == SiteSort.dist && f.near == null ? SiteSort.value : f.sort;
  if (sort == SiteSort.value) {
    final out = [...base]..sort(byValue);
    return f.asc ? out : out.reversed.toList();
  }
  final asc = f.asc;
  Comparable val(SiteRow c) {
    switch (sort) {
      case SiteSort.best:
        return c.best?.odds ?? -1;
      case SiteSort.likely:
        return c.nLikely ?? -1;
      case SiteSort.gap:
        return c.gap3 ?? -1;
      case SiteSort.score:
        return c.score ?? -1;
      case SiteSort.canopy:
        return c.canopy150 ?? -1;
      case SiteSort.elev:
        return c.elevM;
      case SiteSort.dist:
        return distKm(c, f.near) ?? 0;
      case SiteSort.name:
        return c.name.toLowerCase();
      case SiteSort.value:
        return 0;
    }
  }

  final dir = asc ? 1 : -1;
  final keyed = [for (final c in base) (c, val(c))];
  keyed.sort((a, b) {
    final d = a.$2.compareTo(b.$2);
    return d != 0 ? d * dir : byValue(a.$1, b.$1);
  });
  return [for (final k in keyed) k.$1];
}

/// Rows within [km] of a point in engine-value order, with their distance.
List<(SiteRow, double)> nearby(List<SiteRow> rows, double lat, double lon, double km, {bool Function(SiteRow)? exclude}) {
  final out = <(SiteRow, double)>[];
  for (final c in rows) {
    if (exclude != null && exclude(c)) continue;
    final d = haversineM(lat, lon, c.lat, c.lon) / 1000;
    if (d <= km) out.add((c, d));
  }
  out.sort((a, b) {
    final v = byValue(a.$1, b.$1);
    return v != 0 ? v : a.$2.compareTo(b.$2);
  });
  return out;
}

// ---------------------------------------------------------------- compare (candidate-compare.tsx)
class CompareCell {
  final String text;
  final bool best;
  const CompareCell(this.text, {this.best = false});
}

class CompareRow {
  final String label;
  final String? sub;
  final List<CompareCell> cells;
  const CompareRow(this.label, this.cells, {this.sub});
}

/// Indices holding the row's best (highest) value; empty with fewer than two values or a tie of all of them.
Set<int> bestIdx(List<num?> values) {
  final present = [for (final v in values) if (v != null && v.isFinite) v];
  if (present.length < 2) return {};
  final mx = present.reduce((a, b) => a > b ? a : b);
  if (present.every((v) => v == mx)) return {};
  return {for (var i = 0; i < values.length; i++) if (values[i] == mx) i};
}

String groupInt(num n) {
  final s = n.round().abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String pct0(double? share) => share == null || !share.isFinite ? '—' : '${(share * 100).round()}%';

/// The plan's 33 ft mount scenario by name (a 10 m pole), the same in every unit system.
final _mount33 = ['33', 'ft'].join('\u00a0');

String basisLabel(String b) => b == 'lidar' ? 'lidar' : (b == 'trees' ? 'est.' : 'terrain');

/// The comparison table for 2 to 4 sites; "best" marks the earliest step / highest value / least canopy, a label, not advice.
List<CompareRow> compareRows(List<SiteRow> cols, String Function(String key) repeaterName, {Units units = Units.metric}) {
  List<CompareCell> mark(List<String> texts, List<num?> vals) {
    final b = bestIdx(vals);
    return [for (var i = 0; i < texts.length; i++) CompareCell(texts[i], best: b.contains(i))];
  }

  num? neg(int? n) => n == null ? null : -n;
  final seq = [for (final c in cols) c.seqLikely != null || c.seqPossible != null ? '${c.seqLikely ?? '—'} (${c.seqPossible ?? '—'})' : 'Not picked'];
  return [
    CompareRow('Type', [for (final c in cols) CompareCell('${c.sub}\n${c.town}')]),
    CompareRow('Regional build step', mark(seq, [for (final c in cols) neg(c.seqLikely)]), sub: 'Likely+ run (Possible+ run)'),
    CompareRow('Live repeaters joined today', mark([for (final c in cols) c.value == null ? '—' : groupInt(c.value!.joins)], [for (final c in cols) c.value?.joins]), sub: 'built alone, Likely+'),
    CompareRow('People newly within ${units.distance(3000)}', mark([for (final c in cols) groupInt(c.value?.newPeople ?? c.gap3 ?? 0)], [for (final c in cols) c.value?.newPeople ?? c.gap3])),
    CompareRow(
        'Best link, $_mount33',
        mark([
          for (final c in cols)
            c.best == null ? 'None' : '${c.best!.tier} ${(c.best!.odds * 100).toStringAsFixed(1)}% ${basisLabel(c.best!.basis)}\n${repeaterName(c.best!.key)} ${units.distance(c.best!.km * 1000)}'
        ], [for (final c in cols) c.best?.odds ?? 0])),
    CompareRow('Likely+ links, $_mount33', mark([for (final c in cols) '${c.nLikely ?? '—'} ${basisLabel(c.likelyBasis)}'], [for (final c in cols) c.nLikely])),
    CompareRow('Tree cover within ${units.distance(150)}', mark([for (final c in cols) pct0(c.canopy150)], [for (final c in cols) c.canopy150 == null ? null : -c.canopy150!])),
    CompareRow('People within ${units.distance(3000)}', mark([for (final c in cols) c.pop3 == null ? 'No OSM record' : groupInt(c.pop3!)], [for (final c in cols) c.pop3])),
    CompareRow('Ground elevation', mark([for (final c in cols) units.height(c.elevM)], [for (final c in cols) c.elevM])),
    CompareRow('Candidate pre-score', mark([for (final c in cols) c.score == null ? 'No OSM record' : '${c.score!.round()} rank ${groupInt(c.rank ?? 0)}'], [for (final c in cols) c.score]),
        sub: 'of 100, terrain only'),
  ];
}
