// `plan-native?view=scenario`: the scenario lab. Pick original plan sites (or a preset), a mount height, a link tier and a people
// radius, and read what the mesh would become: live repeaters in the main mesh, pieces, people within reach, single points of
// failure, and what each site is worth. Computed on the server with the website's computeScenario. Pure Dart.
import '../region_dataset_fetch.dart' show jDbl, jInt, jMap, jMaps, jStr;

class ScenarioFigures {
  final int mainMesh, people;
  final int? spof;
  final List<int> pieces;
  const ScenarioFigures(this.mainMesh, this.pieces, this.people, this.spof);
  static ScenarioFigures parse(Object? o) {
    final m = jMap(o);
    return ScenarioFigures(jInt(m['mainMesh']) ?? 0, [if (m['pieces'] is List) for (final x in m['pieces'] as List) if (x is num) x.toInt()], jInt(m['people']) ?? 0, jInt(m['spof']));
  }
}

class ScenarioSpof {
  final String id, name;
  final int stranded;
  final bool isSite;
  const ScenarioSpof(this.id, this.name, this.stranded, this.isSite);
}

class ScenarioMarginal {
  final String id;
  final bool on;
  final int dMain, dPeople;
  const ScenarioMarginal(this.id, this.on, this.dMain, this.dPeople);
}

class ScenarioLink {
  final String a, b, tier;
  final double km, odds;
  final double? aLat, aLon, bLat, bLon;
  const ScenarioLink(this.a, this.b, this.km, this.tier, this.odds, this.aLat, this.aLon, this.bLat, this.bLon);
}

class ScenarioRepeater {
  final String key, name;
  final double lat, lon;
  final bool inMain, isNew;
  const ScenarioRepeater(this.key, this.name, this.lat, this.lon, this.inMain, this.isNew);
}

class ScenarioPreset {
  final String id, label, detail;
  final List<String> sites;
  const ScenarioPreset(this.id, this.label, this.detail, this.sites);
}

class ScenarioSite {
  final String id, name;
  final int wave;
  final bool poleTop;
  final double lat, lon;
  const ScenarioSite(this.id, this.name, this.wave, this.poleTop, this.lat, this.lon);
}

class ScenarioWave {
  final int wave;
  final String name;
  final List<String> sites;
  const ScenarioWave(this.wave, this.name, this.sites);
}

class ScenarioResult {
  final bool available;
  final String? reason, asOf, network, liveTakenAt;
  final bool liveAvailable;
  final int h, repeaterCount;
  final String tier;
  final double r;
  final List<String> sites;
  final ScenarioFigures result, today;
  final ScenarioFigures? baseline;
  final List<ScenarioSpof> spofTop;
  final List<ScenarioMarginal> marginals;
  final List<ScenarioLink> addedLinks;
  final List<(String, int)> outside;
  final List<ScenarioRepeater> repeaters;
  final List<ScenarioPreset> presets;
  final List<ScenarioSite> sitesList;
  final List<ScenarioWave> waves;
  final List<String> liveAdded, liveRemoved;
  const ScenarioResult({
    required this.available,
    this.reason,
    this.asOf,
    this.network = 'baseline',
    this.liveTakenAt,
    this.liveAvailable = false,
    this.h = 33,
    this.tier = 'likely',
    this.r = 3,
    this.sites = const [],
    this.repeaterCount = 0,
    this.result = const ScenarioFigures(0, [], 0, null),
    this.today = const ScenarioFigures(0, [], 0, null),
    this.baseline,
    this.spofTop = const [],
    this.marginals = const [],
    this.addedLinks = const [],
    this.outside = const [],
    this.repeaters = const [],
    this.presets = const [],
    this.sitesList = const [],
    this.waves = const [],
    this.liveAdded = const [],
    this.liveRemoved = const [],
  });

  ScenarioMarginal? marginal(String id) {
    for (final m in marginals) {
      if (m.id == id) return m;
    }
    return null;
  }

  static ScenarioResult parse(Map<String, dynamic> j) {
    if (j['available'] == false) return ScenarioResult(available: false, reason: jStr(j['reason']));
    List<String> strs(Object? o) => [if (o is List) for (final x in o) if (x is String) x];
    final live = jMap(j['liveChanges']);
    return ScenarioResult(
      available: true,
      asOf: jStr(j['asOf']),
      network: jStr(j['network']) ?? 'baseline',
      liveTakenAt: jStr(j['liveTakenAt']),
      liveAvailable: j['liveAvailable'] == true,
      h: jInt(j['h']) ?? 33,
      tier: jStr(j['tier']) ?? 'likely',
      r: jDbl(j['r']) ?? 3,
      sites: strs(j['sites']),
      repeaterCount: jInt(j['repeaterCount']) ?? 0,
      result: ScenarioFigures.parse(j['result']),
      today: ScenarioFigures.parse(j['today']),
      baseline: j['baseline'] == null ? null : ScenarioFigures.parse(j['baseline']),
      spofTop: [for (final s in jMaps(j['spofTop'])) ScenarioSpof(jStr(s['id']) ?? '', jStr(s['name']) ?? '', jInt(s['stranded']) ?? 0, s['isSite'] == true)],
      marginals: [for (final m in jMaps(j['marginals'])) ScenarioMarginal(jStr(m['id']) ?? '', m['on'] == true, jInt(m['dMain']) ?? 0, jInt(m['dPeople']) ?? 0)],
      addedLinks: [
        for (final l in jMaps(j['addedLinks']))
          ScenarioLink(jStr(l['a']) ?? '', jStr(l['b']) ?? '', jDbl(l['km']) ?? 0, jStr(l['tier']) ?? 'Stretch', jDbl(l['odds']) ?? 0, jDbl(l['aLat']), jDbl(l['aLon']), jDbl(l['bLat']), jDbl(l['bLon'])),
      ],
      outside: [for (final o in jMaps(j['outside'])) (jStr(o['piece']) ?? 'other', jInt(o['n']) ?? 0)],
      repeaters: [
        for (final r in jMaps(j['repeaters']))
          if (jDbl(r['lat']) != null && jDbl(r['lon']) != null) ScenarioRepeater(jStr(r['key']) ?? '', jStr(r['name']) ?? '', jDbl(r['lat'])!, jDbl(r['lon'])!, r['inMain'] == true, r['isNew'] == true),
      ],
      presets: [for (final p in jMaps(j['presets'])) ScenarioPreset(jStr(p['id']) ?? '', jStr(p['label']) ?? '', jStr(p['detail']) ?? '', strs(p['sites']))],
      sitesList: [
        for (final s in jMaps(j['sitesList']))
          ScenarioSite(jStr(s['id']) ?? '', jStr(s['name']) ?? '', jInt(s['wave']) ?? 4, s['poleTop'] == true, jDbl(s['lat']) ?? 0, jDbl(s['lon']) ?? 0),
      ],
      waves: [for (final w in jMaps(j['waves'])) ScenarioWave(jInt(w['wave']) ?? 0, jStr(w['name']) ?? 'Wave ${w['wave']}', strs(w['sites']))],
      liveAdded: strs(live['added']),
      liveRemoved: strs(live['removed']),
    );
  }
}
