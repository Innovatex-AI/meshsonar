// `candidates?ids=<osm id>` (the website's own public endpoint): the full row of one candidate site, with its modelled links to the
// live repeaters. Tree-adjusted (lidar where verified) links are primary, terrain-only links secondary (engine.ts mergedLinks).
// Pure Dart: no Flutter imports.
import '../region_dataset_fetch.dart' show jDbl, jInt, jMap, jMaps, jStr;

class MergedLink {
  final String key, piece;
  final double km;

  /// Tree-adjusted odds at 33 ft, tier and basis (lidar | trees); null when the engine has none for this link.
  final double? treeOdds, treeM;
  final String? treeTier, treeBasis;

  /// Terrain-only odds at 33 ft and tier.
  final double? terrainOdds;
  final String? terrainTier;
  const MergedLink(this.key, this.km, this.piece, this.treeOdds, this.treeTier, this.treeM, this.treeBasis, this.terrainOdds, this.terrainTier);

  double get sortOdds => treeOdds ?? -1;
}

class ScoreParts {
  final double connect, reach, height, bridge;
  const ScoreParts(this.connect, this.reach, this.height, this.bridge);
}

class CandidateDetail {
  final String id, kind, sub, name;
  final String? street, city, near, zip, county, osm, website, denomination, operator, planSite;
  final double lat, lon, elevM, promM, score;
  final int pop3, gap3, rank;
  final double? canopy150, canopy1k, expN33;
  final ScoreParts? parts;
  final List<MergedLink> links;
  final List<(String, double, String)> siteLinks; // (site id, km, tier)
  const CandidateDetail({
    required this.id,
    required this.kind,
    required this.sub,
    required this.name,
    required this.street,
    required this.city,
    required this.near,
    required this.zip,
    required this.county,
    required this.osm,
    required this.website,
    required this.denomination,
    required this.operator,
    required this.planSite,
    required this.lat,
    required this.lon,
    required this.elevM,
    required this.promM,
    required this.score,
    required this.pop3,
    required this.gap3,
    required this.rank,
    required this.canopy150,
    required this.canopy1k,
    required this.expN33,
    required this.parts,
    required this.links,
    required this.siteLinks,
  });

  String get place => [street, city ?? (near == null ? null : 'near $near')].whereType<String>().join(', ');

  static CandidateDetail? parse(Map<String, dynamic> j) {
    final id = jStr(j['id']), lat = jDbl(j['lat']), lon = jDbl(j['lon']);
    if (id == null || lat == null || lon == null) return null;
    final m = <String, MergedLink>{};
    for (final l in jMaps(j['links'])) {
      final k = jStr(l['key']);
      if (k == null) continue;
      m[k] = MergedLink(k, jDbl(l['km']) ?? 0, jStr(l['piece']) ?? '', null, null, null, null, jDbl(l['o33']), jStr(l['t33']));
    }
    for (final l in jMaps(j['linksTree'])) {
      final k = jStr(l['key']);
      if (k == null) continue;
      final prev = m[k];
      m[k] = MergedLink(k, prev?.km ?? jDbl(l['km']) ?? 0, prev?.piece ?? jStr(l['piece']) ?? '', jDbl(l['o33t']), jStr(l['t33t']), jDbl(l['treeM']), l['lidar'] == true ? 'lidar' : 'trees',
          prev?.terrainOdds, prev?.terrainTier);
    }
    final links = m.values.toList()
      ..sort((a, b) {
        final d = b.sortOdds.compareTo(a.sortOdds);
        return d != 0 ? d : (b.terrainOdds ?? 0).compareTo(a.terrainOdds ?? 0);
      });
    final sp = jMap(j['scoreParts']);
    return CandidateDetail(
      id: id,
      kind: jStr(j['kind']) ?? 'park',
      sub: jStr(j['sub']) ?? '',
      name: jStr(j['name']) ?? id,
      street: jStr(j['street']),
      city: jStr(j['city']),
      near: jStr(j['near']),
      zip: jStr(j['zip']),
      county: jStr(j['county']),
      osm: jStr(j['osm']),
      website: jStr(j['website']),
      denomination: jStr(j['denomination']),
      operator: jStr(j['operator']),
      planSite: jStr(j['planSite']),
      lat: lat,
      lon: lon,
      elevM: jDbl(j['elevM']) ?? 0,
      promM: jDbl(j['promM']) ?? 0,
      score: jDbl(j['score']) ?? 0,
      pop3: jInt(j['pop3']) ?? 0,
      gap3: jInt(j['gap3']) ?? 0,
      rank: jInt(j['rank']) ?? 0,
      canopy150: jDbl(j['canopy150']),
      canopy1k: jDbl(j['canopy1k']),
      expN33: jDbl(j['expN33']),
      parts: sp.isEmpty ? null : ScoreParts(jDbl(sp['connect']) ?? 0, jDbl(sp['reach']) ?? 0, jDbl(sp['height']) ?? 0, jDbl(sp['bridge']) ?? 0),
      links: links,
      siteLinks: [for (final s in jMaps(j['siteLinks'])) if (jStr(s['site']) != null) (jStr(s['site'])!, jDbl(s['km']) ?? 0, jStr(s['t33']) ?? 'Stretch')],
    );
  }
}
