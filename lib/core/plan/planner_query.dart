// The Planner: a question to the planning engine ("where should the next N sites go?") and its answer.
// The query is the website's `pq` string (src/lib/planner/query.ts: `s:today;o:connect;n:6;h:33;t:likely;k:worship.school;...`), so a
// query written on the phone means the same on the website and the other way round; the server (plan-native?view=planner) runs
// the website's own engine. Pure Dart: no Flutter imports.
import '../region_dataset_fetch.dart' show jDbl, jInt, jMap, jMaps, jStr;

enum PlannerObjective { connect, people, redundancy, reach, density }

const plannerObjectiveLabel = <PlannerObjective, String>{
  PlannerObjective.connect: 'Connect first',
  PlannerObjective.people: 'People first',
  PlannerObjective.redundancy: 'Redundancy',
  PlannerObjective.reach: 'Flood reach',
  PlannerObjective.density: 'Avoid observed redundancy',
};
const plannerObjectiveRule = <PlannerObjective, String>{
  PlannerObjective.connect: 'Joins the most live repeaters to the main mesh first, then people newly within 3 km.',
  PlannerObjective.people: 'Adds the most people newly within 3 km first, then repeaters joined.',
  PlannerObjective.redundancy: 'Removes the most single points of failure first, then repeaters joined and people.',
  PlannerObjective.reach: 'Best mean simulated flood reach across live repeaters (30 floods from each of 5 origins).',
  PlannerObjective.density: 'Like connect, but worth less where drives already show heavy duplicate reception nearby.',
};
const plannerKinds = ['worship', 'school', 'park', 'plan'];
const plannerKindLabel = {'worship': 'Worship', 'school': 'Schools', 'park': 'Parks', 'plan': 'Original plan sites'};
const plannerMaxSites = 25;

class PlannerNear {
  final double lat, lon, km;
  final String label;
  const PlannerNear(this.lat, this.lon, this.km, this.label);
}

class PlannerQuery {
  /// today | live | scenario
  final String start;
  final PlannerObjective objective;
  final int maxSites, height;

  /// likely | possible
  final String tier;
  final List<String> kinds, towns, include, exclude;
  final PlannerNear? near;

  /// Scenario start: plan sites and OSM candidates already built.
  final List<String> prebuiltSites, prebuiltCand;
  const PlannerQuery({
    this.start = 'today',
    this.objective = PlannerObjective.connect,
    this.maxSites = 6,
    this.height = 33,
    this.tier = 'likely',
    this.kinds = plannerKinds,
    this.towns = const [],
    this.include = const [],
    this.exclude = const [],
    this.near,
    this.prebuiltSites = const [],
    this.prebuiltCand = const [],
  });

  PlannerQuery copyWith({
    String? start,
    PlannerObjective? objective,
    int? maxSites,
    int? height,
    String? tier,
    List<String>? kinds,
    List<String>? towns,
    List<String>? include,
    List<String>? exclude,
    Object? near = _keep,
    List<String>? prebuiltSites,
    List<String>? prebuiltCand,
  }) =>
      PlannerQuery(
        start: start ?? this.start,
        objective: objective ?? this.objective,
        maxSites: maxSites ?? this.maxSites,
        height: height ?? this.height,
        tier: tier ?? this.tier,
        kinds: kinds ?? this.kinds,
        towns: towns ?? this.towns,
        include: include ?? this.include,
        exclude: exclude ?? this.exclude,
        near: identical(near, _keep) ? this.near : near as PlannerNear?,
        prebuiltSites: prebuiltSites ?? this.prebuiltSites,
        prebuiltCand: prebuiltCand ?? this.prebuiltCand,
      );
  static const Object _keep = Object();

  /// The website's `pq` string. Absent fields take the website's defaults (25 sites, connect, 33 ft, Likely+, every kind).
  String encode() {
    final out = <String>['s:$start'];
    if (objective != PlannerObjective.connect) out.add('o:${objective.name}');
    if (maxSites != plannerMaxSites) out.add('n:$maxSites');
    if (height != 33) out.add('h:$height');
    if (tier != 'likely') out.add('t:$tier');
    if (kinds.length != plannerKinds.length) out.add('k:${kinds.join('.')}');
    if (towns.isNotEmpty) out.add('town:${towns.map((t) => Uri.encodeComponent(_clean(t)).replaceAll('.', '%2E')).join('.')}');
    final n = near;
    if (n != null) out.add('near:${n.lat.toStringAsFixed(5)},${n.lon.toStringAsFixed(5)},${_num(n.km)},${Uri.encodeComponent(_clean(n.label))}');
    if (include.isNotEmpty) out.add('inc:${include.join('.')}');
    if (exclude.isNotEmpty) out.add('exc:${exclude.join('.')}');
    return out.join(';');
  }

  static String _clean(String s) => s.replaceAll(RegExp(r'[;:|]'), ' ').trim();
  static String _num(double v) => v == v.roundToDouble() ? '${v.round()}' : '$v';

  /// Query-string parameters for `plan-native?view=planner`.
  Map<String, String> toParams() => {
        'view': 'planner',
        'pq': encode(),
        if (start == 'scenario' && prebuiltSites.isNotEmpty) 'sites': prebuiltSites.join(','),
        if (start == 'scenario' && prebuiltCand.isNotEmpty) 'cand': prebuiltCand.join(','),
      };

  String get cacheId => '${encode()}|${prebuiltSites.join(',')}|${prebuiltCand.join(',')}';

  /// Parses a `pq` string (the inverse of [encode]); unknown or bad fields keep the defaults.
  static PlannerQuery decode(String raw) {
    var q = const PlannerQuery(maxSites: plannerMaxSites);
    for (final part in raw.split(';')) {
      final i = part.indexOf(':');
      if (i < 0) continue;
      final k = part.substring(0, i).trim(), v = part.substring(i + 1).trim();
      switch (k) {
        case 's':
          if (v == 'today' || v == 'live' || v == 'scenario') q = q.copyWith(start: v);
        case 'o':
          for (final o in PlannerObjective.values) {
            if (o.name == v) q = q.copyWith(objective: o);
          }
        case 'n':
          final n = int.tryParse(v);
          if (n != null) q = q.copyWith(maxSites: n.clamp(1, plannerMaxSites));
        case 'h':
          q = q.copyWith(height: v == '20' ? 20 : 33);
        case 't':
          if (v == 'likely' || v == 'possible') q = q.copyWith(tier: v);
        case 'k':
          final ks = [for (final x in v.split('.')) if (plannerKinds.contains(x)) x];
          if (ks.isNotEmpty) q = q.copyWith(kinds: ks);
        case 'town':
          q = q.copyWith(towns: [for (final t in v.split('.')) if (Uri.decodeComponent(t).trim().isNotEmpty) Uri.decodeComponent(t).trim()].take(12).toList());
        case 'near':
          final p = v.split(',');
          if (p.length >= 3) {
            final a = double.tryParse(p[0]), b = double.tryParse(p[1]), r = double.tryParse(p[2]);
            if (a != null && b != null && r != null && r > 0) {
              final label = Uri.decodeComponent(p.skip(3).join(','));
              q = q.copyWith(near: PlannerNear(a, b, r > 60 ? 60 : r, label.isEmpty ? '${a.toStringAsFixed(4)}, ${b.toStringAsFixed(4)}' : label));
            }
          }
        case 'inc':
          q = q.copyWith(include: _ids(v));
        case 'exc':
          q = q.copyWith(exclude: _ids(v));
      }
    }
    return q;
  }

  static List<String> _ids(String v) {
    final re = RegExp(r'^(?:[nwr]\d{1,12}|site:[A-Z]\d)$');
    return {for (final s in v.split('.')) if (re.hasMatch(s.trim())) s.trim()}.take(plannerMaxSites).toList();
  }
}

// ---------------------------------------------------------------- the answer
class PlannerLink {
  final String to, toKind, tier, model;
  final double p;
  final double? km;
  const PlannerLink(this.to, this.toKind, this.p, this.tier, this.model, this.km);
  bool get isRepeater => toKind == 'repeater';
}

class PlannerSiteOut {
  final int order;
  final String id, name;
  final String? kind, sub, town, planSite;
  final double lat, lon;
  final List<PlannerLink> links;
  const PlannerSiteOut(this.order, this.id, this.name, this.kind, this.sub, this.town, this.planSite, this.lat, this.lon, this.links);
}

class PlannerStepOut {
  final int step, joins, newPeople, mainMesh, people, phase;
  final int? linksIntoMesh, spofDelta, spof;
  final bool pair;
  final String reason, why;
  final List<PlannerSiteOut> sites;
  final List<String> joinedNames;
  const PlannerStepOut({
    required this.step,
    required this.pair,
    required this.reason,
    required this.why,
    required this.joins,
    required this.newPeople,
    required this.linksIntoMesh,
    required this.spofDelta,
    required this.mainMesh,
    required this.people,
    required this.spof,
    required this.phase,
    required this.sites,
    required this.joinedNames,
  });
}

class PlannerPoint {
  final double lat, lon;
  final String name;
  const PlannerPoint(this.lat, this.lon, this.name);
}

class PlannerResult {
  final bool ok;
  final String? error, asOf, network, stop;
  final bool liveRequestedButMissing;
  final PlannerQuery? query;
  final int startMainMesh, startPeople, evaluated, pool, matched, repeaterCount;
  final int? startSpof;
  final List<PlannerStepOut> steps;
  final Map<String, PlannerPoint> targets;
  final List<PlannerPoint> repeaters;
  const PlannerResult({
    required this.ok,
    this.error,
    this.asOf,
    this.network,
    this.stop,
    this.liveRequestedButMissing = false,
    this.query,
    this.startMainMesh = 0,
    this.startPeople = 0,
    this.startSpof,
    this.evaluated = 0,
    this.pool = 0,
    this.matched = 0,
    this.repeaterCount = 0,
    this.steps = const [],
    this.targets = const {},
    this.repeaters = const [],
  });

  int get siteCount => steps.fold(0, (a, s) => a + s.sites.length);
  int get endMainMesh => steps.isEmpty ? startMainMesh : steps.last.mainMesh;
  int get endPeople => steps.isEmpty ? startPeople : steps.last.people;

  String get stopText {
    switch (stop) {
      case 'max':
        return 'Stopped at the number of sites asked for.';
      case 'no-gain':
        return 'Stopped: the next site would add almost nothing.';
      case 'complete':
        return 'Stopped: every live repeater is in the main mesh.';
      case 'pool':
        return 'Stopped: no more sites in the pool.';
      default:
        return '';
    }
  }

  static PlannerResult parse(Map<String, dynamic> j) {
    final q = jMap(j['query']);
    final start = jMap(j['start']);
    final graph = jMap(j['graph']);
    final targets = <String, PlannerPoint>{};
    jMap(j['targets']).forEach((k, v) {
      if (v is Map<String, dynamic>) {
        final lat = jDbl(v['lat']), lon = jDbl(v['lon']);
        if (lat != null && lon != null) targets[k] = PlannerPoint(lat, lon, jStr(v['name']) ?? k);
      }
    });
    List<String> strs(Object? o) => [if (o is List) for (final x in o) if (x is String) x];
    return PlannerResult(
      ok: true,
      asOf: jStr(j['asOf']),
      network: jStr(j['network']),
      stop: jStr(j['stop']),
      liveRequestedButMissing: j['liveRequestedButMissing'] == true,
      query: PlannerQuery(
        start: jStr(q['start']) ?? 'today',
        objective: PlannerObjective.values.firstWhere((o) => o.name == q['objective'], orElse: () => PlannerObjective.connect),
        maxSites: jInt(q['maxSites']) ?? plannerMaxSites,
        height: jInt(q['height']) ?? 33,
        tier: jStr(q['tier']) ?? 'likely',
        kinds: strs(q['kinds']).isEmpty ? plannerKinds : strs(q['kinds']),
        towns: strs(q['towns']),
        include: strs(q['include']),
        exclude: strs(q['exclude']),
      ),
      startMainMesh: jInt(start['mainMesh']) ?? 0,
      startPeople: jInt(start['people']) ?? 0,
      startSpof: jInt(start['spof']),
      evaluated: jInt(j['evaluated']) ?? 0,
      pool: jInt(j['pool']) ?? jInt(graph['pool']) ?? 0,
      matched: jInt(j['matched']) ?? 0,
      repeaterCount: jInt(j['repeaterCount']) ?? 0,
      targets: targets,
      repeaters: [
        for (final r in jMaps(j['repeaters']))
          if (jDbl(r['lat']) != null && jDbl(r['lon']) != null) PlannerPoint(jDbl(r['lat'])!, jDbl(r['lon'])!, jStr(r['name']) ?? ''),
      ],
      steps: [
        for (final s in jMaps(j['steps']))
          PlannerStepOut(
            step: jInt(s['step']) ?? 0,
            pair: s['pair'] == true,
            reason: jStr(s['reason']) ?? 'engine',
            why: jStr(s['why']) ?? '',
            joins: jInt(s['joins']) ?? 0,
            newPeople: jInt(s['newPeople']) ?? 0,
            linksIntoMesh: jInt(s['linksIntoMesh']),
            spofDelta: jInt(s['spofDelta']),
            mainMesh: jInt(s['mainMesh']) ?? 0,
            people: jInt(s['people']) ?? 0,
            spof: jInt(s['spof']),
            phase: jInt(s['phase']) ?? 3,
            joinedNames: strs(s['joinedNames']),
            sites: [
              for (final x in jMaps(s['sites']))
                PlannerSiteOut(
                  jInt(x['order']) ?? 0,
                  jStr(x['id']) ?? '',
                  jStr(x['name']) ?? jStr(x['id']) ?? '',
                  jStr(x['kind']),
                  jStr(x['sub']),
                  jStr(x['town']),
                  jStr(x['planSite']),
                  jDbl(x['lat']) ?? 0,
                  jDbl(x['lon']) ?? 0,
                  [
                    for (final l in jMaps(x['links']))
                      if (jStr(l['to']) != null) PlannerLink(jStr(l['to'])!, jStr(l['toKind']) ?? 'site', jDbl(l['p']) ?? 0, jStr(l['tier']) ?? 'Stretch', jStr(l['model']) ?? 'tree', jDbl(l['km'])),
                  ],
                ),
            ],
          ),
      ],
    );
  }
}
