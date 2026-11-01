// `plan-native?view=overview`: the planning engine's recommended build (both runs, Likely+ and Possible+), the engine against the
// original 20-site plan, the budget inputs, the risk register and the 20 original sites. The server runs the website's own
// functions (regionalView, buildRisks), so these are the same numbers the website's Plan > Recommended page prints.
// The budget maths (cost = sites x (hardware + mounting) + pole-top sites x pole-top install) runs here, on the phone, so the
// unit costs can be edited offline; it is a port of the website's budget.ts waveCosts and has a golden test.
// Pure Dart: no Flutter imports.
import '../region_dataset_fetch.dart' show jDbl, jInt, jMap, jMaps, jStr;

class PlanRepeater {
  final String key, name, short, piece;
  final double lat, lon;
  const PlanRepeater(this.key, this.name, this.short, this.lat, this.lon, this.piece);
  static PlanRepeater? parse(Map<String, dynamic> j) {
    final k = jStr(j['key']), lat = jDbl(j['lat']), lon = jDbl(j['lon']);
    if (k == null || lat == null || lon == null) return null;
    return PlanRepeater(k, jStr(j['name']) ?? k.substring(0, k.length < 8 ? k.length : 8), jStr(j['short']) ?? k.substring(0, k.length < 8 ? k.length : 8), lat, lon, jStr(j['piece']) ?? '');
  }
}

/// A link from a planned site to a live repeater (`kind` repeater) or another planned site.
class PlanLinkTo {
  final String to, name, kind, tier;
  final String? short;
  final double p;
  final bool lidar;
  const PlanLinkTo(this.to, this.name, this.short, this.kind, this.p, this.tier, this.lidar);
  bool get isRepeater => kind == 'repeater';
  static PlanLinkTo? parse(Map<String, dynamic> j) {
    final to = jStr(j['to']), p = jDbl(j['p']);
    if (to == null || p == null) return null;
    return PlanLinkTo(to, jStr(j['name']) ?? to, jStr(j['short']), jStr(j['kind']) ?? 'site', p, jStr(j['tier']) ?? 'Stretch', j['lidar'] == true);
  }
}

class PlanStepSite {
  final String id, name;
  final String? kind, sub, planSite;
  final double? lat, lon;
  final List<String> pairedWith;
  final List<PlanLinkTo> links;
  const PlanStepSite(this.id, this.name, this.kind, this.sub, this.planSite, this.lat, this.lon, this.pairedWith, this.links);
  bool get hasPoint => lat != null && lon != null;
  static PlanStepSite? parse(Map<String, dynamic> j) {
    final id = jStr(j['id']);
    if (id == null) return null;
    return PlanStepSite(
      id,
      jStr(j['name']) ?? id,
      jStr(j['kind']),
      jStr(j['sub']),
      jStr(j['planSite']),
      jDbl(j['lat']),
      jDbl(j['lon']),
      [for (final x in (j['pairedWith'] is List ? j['pairedWith'] as List : const []) ) if (x is String) x],
      [for (final l in jMaps(j['links'])) ?PlanLinkTo.parse(l)],
    );
  }
}

class PlanBridged {
  final String label;
  final int size;
  final bool direct;
  const PlanBridged(this.label, this.size, this.direct);
}

/// One build step: a single site, or a linked pair that only joins anything together.
class PlanGroup {
  final int stepNo, ordFrom, ordTo, joins, newPeople, mainMesh, people;
  final String gate;
  final bool verified;
  final List<PlanBridged> bridged;
  final List<PlanStepSite> sites;
  const PlanGroup(this.stepNo, this.ordFrom, this.ordTo, this.joins, this.newPeople, this.mainMesh, this.people, this.gate, this.verified, this.bridged, this.sites);
  bool get isPair => sites.length > 1;
  static PlanGroup parse(Map<String, dynamic> j) => PlanGroup(
        jInt(j['stepNo']) ?? 0,
        jInt(j['ordFrom']) ?? 0,
        jInt(j['ordTo']) ?? 0,
        jInt(j['joins']) ?? 0,
        jInt(j['newPeople']) ?? 0,
        jInt(j['mainMesh']) ?? 0,
        jInt(j['people']) ?? 0,
        jStr(j['gate']) ?? '',
        j['verified'] == true,
        [for (final b in jMaps(j['bridged'])) PlanBridged(jStr(b['label']) ?? '', jInt(b['size']) ?? 0, b['direct'] == true)],
        [for (final s in jMaps(j['sites'])) ?PlanStepSite.parse(s)],
      );
}

class PlanPhase {
  final int id, sites, joins, newPeople, endSites, endMainMesh, endPeople;
  final String name, rule;
  final List<int> endPieces;
  final List<PlanGroup> groups;
  const PlanPhase(this.id, this.name, this.rule, this.sites, this.joins, this.newPeople, this.endSites, this.endMainMesh, this.endPeople, this.endPieces, this.groups);
  static PlanPhase parse(Map<String, dynamic> j) {
    final end = jMap(j['end']);
    return PlanPhase(
      jInt(j['id']) ?? 0,
      jStr(j['name']) ?? '',
      jStr(j['rule']) ?? '',
      jInt(j['sites']) ?? 0,
      jInt(j['joins']) ?? 0,
      jInt(j['newPeople']) ?? 0,
      jInt(end['sites']) ?? 0,
      jInt(end['mainMesh']) ?? 0,
      jInt(end['people']) ?? 0,
      [for (final x in (end['pieces'] is List ? end['pieces'] as List : const [])) if (x is num) x.toInt()],
      [for (final g in jMaps(j['groups'])) PlanGroup.parse(g)],
    );
  }
}

class PlanEval {
  final List<String> siteIds;
  final int sites, mainMesh, people;
  const PlanEval(this.siteIds, this.sites, this.mainMesh, this.people);
  static PlanEval? parse(Object? o) {
    if (o is! Map<String, dynamic>) return null;
    return PlanEval([for (final x in (o['siteIds'] is List ? o['siteIds'] as List : const [])) if (x is String) x], jInt(o['sites']) ?? 0, jInt(o['mainMesh']) ?? 0, jInt(o['people']) ?? 0);
  }
}

class SeriesPoint {
  final int x, mainMesh, people;
  const SeriesPoint(this.x, this.mainMesh, this.people);
}

class BudgetInput {
  final int wave, joined, people;
  final List<String> sites;
  const BudgetInput(this.wave, this.joined, this.people, this.sites);
}

class PlanRisk {
  final String id, title, exposureValue, exposureUnit, what, mitigation, source;
  const PlanRisk(this.id, this.title, this.exposureValue, this.exposureUnit, this.what, this.mitigation, this.source);
}

class PlanRun {
  /// `likely` or `possible`.
  final String run, label, tier, builtUtc, method;
  final int poolTotal, todayMainMesh, todayPeople, liveRepeaters, linksTotal, linksLidar;
  final List<int> todayPieces;
  final List<PlanPhase> phases;
  final PlanEval? waves12, all20;
  final List<SeriesPoint> series;
  final List<BudgetInput> budgetInputs;
  final List<PlanRisk> risks;
  const PlanRun({
    required this.run,
    required this.label,
    required this.tier,
    required this.builtUtc,
    required this.method,
    required this.poolTotal,
    required this.todayMainMesh,
    required this.todayPeople,
    required this.todayPieces,
    required this.liveRepeaters,
    required this.linksTotal,
    required this.linksLidar,
    required this.phases,
    required this.waves12,
    required this.all20,
    required this.series,
    required this.budgetInputs,
    required this.risks,
  });

  List<PlanGroup> get groups => [for (final p in phases) ...p.groups];
  int get totalSites => groups.fold(0, (a, g) => a + g.sites.length);

  /// Engine value after [x] sites built (a pair only counts once both are built); the website's valueAt.
  int valueAt(int x, {required bool people}) {
    var v = people ? todayPeople : todayMainMesh;
    for (final g in groups) {
      if (g.stepNo <= x) {
        v = people ? g.people : g.mainMesh;
      } else {
        break;
      }
    }
    return v;
  }

  static PlanRun parse(Map<String, dynamic> j) {
    final today = jMap(j['today']);
    final links = jMap(j['links']);
    final pool = jMap(j['pool']);
    final orig = jMap(j['original']);
    return PlanRun(
      run: jStr(j['run']) ?? 'likely',
      label: jStr(j['label']) ?? 'Likely+',
      tier: jStr(j['tier']) ?? 'Likely',
      builtUtc: jStr(j['builtUtc']) ?? '',
      method: jStr(j['method']) ?? '',
      poolTotal: jInt(pool['total']) ?? 0,
      todayMainMesh: jInt(today['mainMesh']) ?? 0,
      todayPeople: jInt(today['people']) ?? 0,
      todayPieces: [for (final x in (today['pieces'] is List ? today['pieces'] as List : const [])) if (x is num) x.toInt()],
      liveRepeaters: jInt(j['liveRepeaters']) ?? 0,
      linksTotal: jInt(links['total']) ?? 0,
      linksLidar: jInt(links['lidar']) ?? 0,
      phases: [for (final p in jMaps(j['phases'])) PlanPhase.parse(p)],
      waves12: PlanEval.parse(orig['waves12']),
      all20: PlanEval.parse(orig['all20']),
      series: [for (final s in jMaps(j['series'])) SeriesPoint(jInt(s['x']) ?? 0, jInt(s['mainMesh']) ?? 0, jInt(s['people']) ?? 0)],
      budgetInputs: [
        for (final b in jMaps(j['budgetInputs']))
          BudgetInput(jInt(b['wave']) ?? 0, jInt(b['joined']) ?? 0, jInt(b['people']) ?? 0, [for (final x in (b['sites'] is List ? b['sites'] as List : const [])) if (x is String) x]),
      ],
      risks: [
        for (final r in jMaps(j['risks']))
          PlanRisk(jStr(r['id']) ?? '', jStr(r['title']) ?? '', jStr(jMap(r['exposure'])['value']) ?? '', jStr(jMap(r['exposure'])['unit']) ?? '', jStr(r['what']) ?? '', jStr(r['mitigation']) ?? '',
              jStr(r['source']) ?? ''),
      ],
    );
  }
}

// ---------------------------------------------------------------- budget (port of budget.ts)
class PlanUnitCost {
  final double hw, mount, pole;
  const PlanUnitCost(this.hw, this.mount, this.pole);
  PlanUnitCost copyWith({double? hw, double? mount, double? pole}) => PlanUnitCost(hw ?? this.hw, mount ?? this.mount, pole ?? this.pole);
  Map<String, dynamic> toJson() => {'hw': hw, 'mount': mount, 'pole': pole};
  static PlanUnitCost? parse(Object? o) {
    if (o is! Map<String, dynamic>) return null;
    final hw = jDbl(o['hw']), m = jDbl(o['mount']), p = jDbl(o['pole']);
    return hw == null || m == null || p == null ? null : PlanUnitCost(hw, m, p);
  }
}

class PlanCostInput {
  final double value;
  final String basis;
  final String? source;
  const PlanCostInput(this.value, this.basis, this.source);
  static PlanCostInput parse(Object? o) {
    final m = jMap(o);
    return PlanCostInput(jDbl(m['default']) ?? 0, jStr(m['basis']) ?? '', jStr(m['source']));
  }
}

enum PlanCase { low, expected, high }

class PlanBudget {
  final String note;
  final PlanCostInput hardware, mounting, pole;
  final Set<String> poleTop;
  final Map<PlanCase, PlanUnitCost> cases;
  const PlanBudget(this.note, this.hardware, this.mounting, this.pole, this.poleTop, this.cases);

  static PlanBudget? parse(Object? o) {
    if (o is! Map<String, dynamic>) return null;
    final c = jMap(o['cases']);
    final low = PlanUnitCost.parse(c['low']), exp = PlanUnitCost.parse(c['expected']), high = PlanUnitCost.parse(c['high']);
    if (exp == null) return null;
    return PlanBudget(
      jStr(o['note']) ?? '',
      PlanCostInput.parse(o['hardware']),
      PlanCostInput.parse(o['mounting']),
      PlanCostInput.parse(o['pole']),
      {for (final x in (o['poleTop'] is List ? o['poleTop'] as List : const [])) if (x is String) x},
      {PlanCase.low: low ?? exp, PlanCase.expected: exp, PlanCase.high: high ?? exp},
    );
  }
}

/// "$89.90-$99.90" (en dash, hyphen, em dash or "to") -> [89.9, 99.9]; null when the text has no dollar range (budget.ts listRange).
List<double>? listRange(String? text) {
  final m = RegExp(r'\$\s?(\d+(?:\.\d+)?)\s*(?:–|-|—|to)\s*\$?\s?(\d+(?:\.\d+)?)').firstMatch(text ?? '');
  if (m == null) return null;
  final a = double.tryParse(m.group(1)!), b = double.tryParse(m.group(2)!);
  if (a == null || b == null) return null;
  return a <= b ? [a, b] : [b, a];
}

class WaveCost {
  final int wave, n, nPole, joined, cumJoined, people, cumPeople;
  final double cost, cumCost;
  const WaveCost(this.wave, this.n, this.nPole, this.cost, this.cumCost, this.joined, this.cumJoined, this.people, this.cumPeople);
}

List<WaveCost> waveCosts(List<BudgetInput> waves, Set<String> poleTop, PlanUnitCost u) {
  var cumCost = 0.0;
  var cumJoined = 0, cumPeople = 0;
  return [
    for (final w in waves)
      () {
        final n = w.sites.length;
        final nPole = w.sites.where(poleTop.contains).length;
        final cost = n * (u.hw + u.mount) + nPole * u.pole;
        cumCost += cost;
        cumJoined += w.joined;
        cumPeople += w.people;
        return WaveCost(w.wave, n, nPole, cost, cumCost, w.joined, cumJoined, w.people, cumPeople);
      }(),
  ];
}

double? costPer(double cost, int units) => units > 0 ? cost / units : null;
double? costPerThousand(double cost, int people) => people > 0 ? cost / (people / 1000) : null;

/// Whole dollars; cents only under $10 (the website's formatUsd).
String usd(num n) {
  final neg = n < 0;
  final a = n.abs();
  final String body;
  if (a < 10) {
    body = a.toStringAsFixed(2);
  } else {
    final s = a.round().toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    body = b.toString();
  }
  return '${neg ? '-' : ''}\$$body';
}

// ---------------------------------------------------------------- original plan sites
class PlanSiteLink {
  final String to, toName;
  final String? toKey;
  final double km, odds20, odds33, treeM20, treeM33;
  final String tier20, tier33;
  const PlanSiteLink(this.to, this.toName, this.toKey, this.km, this.tier20, this.tier33, this.odds20, this.odds33, this.treeM20, this.treeM33);
  static PlanSiteLink? parse(Map<String, dynamic> j) {
    final to = jStr(j['to']);
    if (to == null) return null;
    return PlanSiteLink(to, jStr(j['toName']) ?? to, jStr(j['toKey']), jDbl(j['km']) ?? 0, jStr(j['tier20']) ?? 'Stretch', jStr(j['tier33']) ?? 'Stretch', jDbl(j['odds20']) ?? 0,
        jDbl(j['odds33']) ?? 0, jDbl(j['treeM20']) ?? 0, jDbl(j['treeM33']) ?? 0);
  }
}

/// One of the original plan sites (the website's `sites[]`).
class PlanOriginalSite {
  final String id, name, phaseName, area, hostType, address, role, rationale, verifyNote;
  final int wave, phase, linksLikelyPlus33, linksPossiblePlus33, linksPossiblePlus20, newPeople2, newPeople3, newPeople5;
  final double lat, lon, groundElevM, groundElevFt;
  final double? usgsElevM;
  final bool poleTop;
  final List<PlanSiteLink> links;
  const PlanOriginalSite({
    required this.id,
    required this.name,
    required this.phaseName,
    required this.area,
    required this.hostType,
    required this.address,
    required this.role,
    required this.rationale,
    required this.verifyNote,
    required this.wave,
    required this.phase,
    required this.linksLikelyPlus33,
    required this.linksPossiblePlus33,
    required this.linksPossiblePlus20,
    required this.newPeople2,
    required this.newPeople3,
    required this.newPeople5,
    required this.lat,
    required this.lon,
    required this.groundElevM,
    required this.groundElevFt,
    required this.usgsElevM,
    required this.poleTop,
    required this.links,
  });

  int newPeopleAt(int radiusKm) => radiusKm <= 2 ? newPeople2 : (radiusKm == 3 ? newPeople3 : newPeople5);

  /// Highest-tier link to anything at [h] feet, ties by odds (the website's bestLinkAt).
  PlanSiteLink? bestLinkAt(int h) {
    const order = ['Strong', 'Likely', 'Possible', 'Stretch'];
    int t(PlanSiteLink l) => order.indexOf(h == 33 ? l.tier33 : l.tier20);
    double o(PlanSiteLink l) => h == 33 ? l.odds33 : l.odds20;
    final sorted = [...links]..sort((a, b) {
        final d = t(a) - t(b);
        return d != 0 ? d : o(b).compareTo(o(a));
      });
    return sorted.isEmpty ? null : sorted.first;
  }

  static PlanOriginalSite? parse(Map<String, dynamic> j) {
    final id = jStr(j['id']), lat = jDbl(j['lat']), lon = jDbl(j['lon']);
    if (id == null || lat == null || lon == null) return null;
    return PlanOriginalSite(
      id: id,
      name: jStr(j['name']) ?? id,
      phaseName: jStr(j['phaseName']) ?? '',
      area: jStr(j['area']) ?? '',
      hostType: jStr(j['hostType']) ?? '',
      address: jStr(j['address']) ?? '',
      role: jStr(j['role']) ?? '',
      rationale: jStr(j['rationale']) ?? '',
      verifyNote: jStr(j['verifyNote']) ?? '',
      wave: jInt(j['wave']) ?? 4,
      phase: jInt(j['phase']) ?? 0,
      linksLikelyPlus33: jInt(j['linksLikelyPlus33']) ?? 0,
      linksPossiblePlus33: jInt(j['linksPossiblePlus33']) ?? 0,
      linksPossiblePlus20: jInt(j['linksPossiblePlus20']) ?? 0,
      newPeople2: jInt(j['newPeopleWithin2km']) ?? 0,
      newPeople3: jInt(j['newPeopleWithin3km']) ?? 0,
      newPeople5: jInt(j['newPeopleWithin5km']) ?? 0,
      lat: lat,
      lon: lon,
      groundElevM: jDbl(j['groundElevM']) ?? 0,
      groundElevFt: jDbl(j['groundElevFt']) ?? 0,
      usgsElevM: jDbl(j['usgsElevM']),
      poleTop: j['poleTopPriority'] == true,
      links: [for (final l in jMaps(j['links'])) ?PlanSiteLink.parse(l)],
    );
  }
}

class PlanCandidateLink {
  final String a, b, tier20, tier33;
  final double km, odds20, odds33;
  const PlanCandidateLink(this.a, this.b, this.km, this.tier20, this.tier33, this.odds20, this.odds33);
}

class PlanOverview {
  final bool available;
  final String? reason, asOf;
  final List<PlanRepeater> repeaters;
  final Map<String, PlanRun> runs;
  final PlanBudget? budget;
  final List<PlanOriginalSite> sites;
  final List<PlanCandidateLink> candidateLinks;
  final List<Map<String, dynamic>> waves, waveCriticality;
  const PlanOverview({
    required this.available,
    this.reason,
    this.asOf,
    this.repeaters = const [],
    this.runs = const {},
    this.budget,
    this.sites = const [],
    this.candidateLinks = const [],
    this.waves = const [],
    this.waveCriticality = const [],
  });

  PlanOriginalSite? site(String id) {
    for (final s in sites) {
      if (s.id == id) return s;
    }
    return null;
  }

  PlanRepeater? repeater(String key) {
    for (final r in repeaters) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// Nodes stranded if [siteId] is lost: 33 ft Likely+, right after its own wave (analysis.waveCriticality).
  int? strandedAfterWave(PlanOriginalSite s) {
    for (final w in waveCriticality) {
      if (jInt(w['wave']) == s.wave) return jInt(jMap(w['critical33Likely'])[s.id]) ?? 0;
    }
    return null;
  }

  static PlanOverview parse(Map<String, dynamic> j) {
    if (j['available'] == false) return PlanOverview(available: false, reason: jStr(j['reason']));
    final runs = jMap(j['runs']);
    return PlanOverview(
      available: j['available'] != false && runs.isNotEmpty,
      reason: runs.isEmpty ? 'The planning engine has not produced a plan for this region yet.' : null,
      asOf: jStr(j['asOf']),
      repeaters: [for (final r in jMaps(j['repeaters'])) ?PlanRepeater.parse(r)],
      runs: {for (final e in runs.entries) if (e.value is Map<String, dynamic>) e.key: PlanRun.parse(e.value as Map<String, dynamic>)},
      budget: PlanBudget.parse(j['budget']),
      sites: [for (final s in jMaps(j['sites'])) ?PlanOriginalSite.parse(s)],
      candidateLinks: [
        for (final c in jMaps(j['candidateLinks']))
          if (jStr(c['a']) != null && jStr(c['b']) != null)
            PlanCandidateLink(jStr(c['a'])!, jStr(c['b'])!, jDbl(c['km']) ?? 0, jStr(c['tier20']) ?? 'Stretch', jStr(c['tier33']) ?? 'Stretch', jDbl(c['odds20']) ?? 0, jDbl(c['odds33']) ?? 0),
      ],
      waves: jMaps(j['waves']),
      waveCriticality: jMaps(j['waveCriticality']),
    );
  }
}
