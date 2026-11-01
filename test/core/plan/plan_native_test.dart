// The planning engine's data layer in the app (lib/core/plan/*): parsing of the real plan-native answers (fixtures written by the
// website's plan-native.test.ts from its own functions), and the on-phone ports checked against the website's numbers in
// golden.json (budget maths, site filter/sort, pq strings) and link.json (clearance).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/plan/link_profile.dart';
import 'package:meshsonar/core/plan/plan_native_api.dart';
import 'package:meshsonar/core/plan/plan_overview.dart';
import 'package:meshsonar/core/plan/plan_scenario.dart';
import 'package:meshsonar/core/plan/plan_sites.dart';
import 'package:meshsonar/core/plan/plan_tracker.dart';
import 'package:meshsonar/core/plan/planner_query.dart';

Map<String, dynamic> fx(String name) => jsonDecode(File('test/fixtures/plan_native/$name.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final golden = fx('golden');

  group('overview (Recommended build)', () {
    final o = PlanOverview.parse(fx('overview'));
    test('parses both runs with phases, steps, links and the engine-vs-original series', () {
      expect(o.available, isTrue);
      expect(o.runs.keys, containsAll(['likely', 'possible']));
      final r = o.runs['likely']!;
      expect(r.phases, isNotEmpty);
      expect(r.groups.length, 3);
      expect(r.groups.first.sites.first.links.first.isRepeater, isTrue);
      expect(r.todayMainMesh, 40);
      expect(r.series.last.x, 20);
      expect(r.valueAt(3, people: true), 41000);
      expect(r.valueAt(0, people: false), 40);
      expect(r.waves12?.sites, 2);
      expect(r.risks, isNotEmpty);
      expect(r.risks.first.exposureValue, isNotEmpty);
      expect(o.sites, hasLength(20));
      expect(o.repeaters, isNotEmpty);
    });
    test('wave costs equal the website\'s waveCosts for low, expected and high', () {
      final r = o.runs['likely']!;
      final b = o.budget!;
      for (final c in PlanCase.values) {
        final got = waveCosts(r.budgetInputs, b.poleTop, b.cases[c]!);
        final want = (golden['costs'] as Map<String, dynamic>)[c.name] as List;
        expect(got.length, want.length);
        for (var i = 0; i < want.length; i++) {
          final w = want[i] as Map<String, dynamic>;
          expect(got[i].cost, (w['cost'] as num).toDouble(), reason: '${c.name} wave ${w['wave']}');
          expect(got[i].cumCost, (w['cumCost'] as num).toDouble());
          expect(got[i].n, w['n']);
          expect(got[i].nPole, w['nPole']);
          expect(got[i].cumJoined, w['cumJoined']);
          expect(got[i].cumPeople, w['cumPeople']);
        }
      }
    });
    test('pole-top sites add the pole-top install cost', () {
      const u = PlanUnitCost(100, 50, 200);
      final w = waveCosts(const [BudgetInput(1, 2, 100, ['D2', 'X9'])], {'D2'}, u);
      expect(w.single.cost, 2 * 150 + 200);
      expect(costPer(w.single.cost, 0), isNull);
      expect(costPer(500, 2), 250);
      expect(costPerThousand(500, 2000), 250);
    });
    test('list price range and dollar formatting follow the website', () {
      expect(listRange('RAK list \$89.90–\$99.90 (solar)'), [89.9, 99.9]);
      expect(listRange('no range'), isNull);
      expect(usd(100), '\$100');
      expect(usd(1234567.4), '\$1,234,567');
      expect(usd(7.5), '\$7.50');
    });
    test('a region with no plan says so', () {
      final n = PlanOverview.parse({'available': false, 'reason': 'No planning data for this region yet'});
      expect(n.available, isFalse);
      expect(n.reason, contains('No planning data'));
      expect(PlanOverview.parse({'available': true, 'runs': <String, dynamic>{}, 'sites': <dynamic>[]}).available, isFalse);
    });
    test('an original site knows its best link, people at a radius and the nodes stranded after its wave', () {
      final s = o.sites.first;
      expect(s.bestLinkAt(33), isNotNull);
      expect(s.newPeopleAt(3), s.newPeople3);
      expect(o.strandedAfterWave(o.site('D2')!), isNotNull);
    });
  });

  group('site explorer', () {
    final s = PlanSites.parse(fx('sites'));
    test('parses candidates and the original plan sites without an OSM record', () {
      expect(s.rows.where((r) => r.candId != null), hasLength(3));
      expect(s.rows.where((r) => r.candId == null && r.isPlan), hasLength(20));
      expect(s.byRef('w1')?.seqLikely, 1);
      expect(s.byRef('c:w1')?.pop3, 5000);
      expect(s.byRef('D2')?.name, isNotEmpty);
      expect(s.meta?.count, 3);
    });
    test('every sort and direction orders the rows exactly as the website does', () {
      for (final w in golden['sorts'] as List) {
        final sort = SiteSort.values.firstWhere((e) => e.name == w['sort']);
        final asc = w['asc'] as bool;
        final near = w['near'] == true ? const NearPoint(40.12, -82.99, 'x') : null;
        final got = applyFilter(s.rows, SiteFilter(sort: sort, asc: asc, near: near)).map((r) => r.id).toList();
        expect(got, (w['ids'] as List).cast<String>(), reason: '${sort.name} asc=$asc');
      }
    });
    test('search, kind, likely and joins filters match the website', () {
      final cases = <SiteFilter>[
        const SiteFilter(q: 'park'),
        const SiteFilter(kind: 'plan'),
        const SiteFilter(kind: 'park', likely: true),
        const SiteFilter(joins: true),
      ];
      final want = (golden['filters'] as List).map((f) => (f['ids'] as List).cast<String>()).toList();
      for (var i = 0; i < cases.length; i++) {
        expect(applyFilter(s.rows, cases[i]).map((r) => r.id).toList(), want[i], reason: 'filter $i');
      }
    });
    test('kind and town counts match the website', () {
      expect(kindCounts(s.rows), {for (final e in (golden['kinds'] as Map<String, dynamic>).entries) e.key: e.value});
      expect(townCounts(s.rows).map((t) => (t.$1, t.$2)).toList(), [for (final t in golden['towns'] as List) (t['town'] as String, t['n'] as int)]);
    });
    test('nearby lists rows within a radius in engine order', () {
      final w1 = s.byRef('w1')!;
      final n = nearby(s.rows, w1.lat, w1.lon, 5, exclude: (r) => r.id == w1.id);
      expect(n.map((e) => e.$1.id), isNot(contains(w1.id)));
      expect(n.every((e) => e.$2 <= 5), isTrue);
    });
    test('compare marks the best value per row and never ties', () {
      final cols = [s.byRef('w1')!, s.byRef('w2')!];
      final rows = compareRows(cols, s.repeaterName);
      final step = rows.firstWhere((r) => r.label == 'Regional build step');
      expect(step.cells[0].best, isTrue);
      expect(step.cells[1].best, isFalse);
      expect(bestIdx([3, 3]), isEmpty);
      expect(bestIdx([1, null]), isEmpty);
      expect(bestIdx([1, 5, 5]), {1, 2});
    });
  });

  group('planner query', () {
    test('encodes exactly the website\'s pq string and decodes it back', () {
      for (final p in golden['pq'] as List) {
        final enc = p['enc'] as String;
        final d = PlannerQuery.decode(enc);
        expect(d.encode(), enc);
      }
      final q = PlannerQuery.decode((golden['pq'] as List)[1]['enc'] as String);
      expect(q.start, 'live');
      expect(q.objective, PlannerObjective.redundancy);
      expect(q.maxSites, 7);
      expect(q.height, 20);
      expect(q.tier, 'possible');
      expect(q.kinds, ['school', 'plan']);
      expect(q.towns, ['Delaware', 'St. Louisville']);
      expect(q.near?.km, 8);
      expect(q.near?.label, 'Westerville, OH');
      expect(q.include, ['w123', 'site:X1']);
      expect(q.exclude, ['n9']);
    });
    test('bad fields keep the defaults and ids are validated', () {
      final q = PlannerQuery.decode('s:today;n:99;h:12;k:bogus;inc:DROP TABLE.w5');
      expect(q.maxSites, 25);
      expect(q.height, 33);
      expect(q.kinds, plannerKinds);
      expect(q.include, ['w5']);
    });
    test('scenario start sends the built sites as parameters', () {
      const q = PlannerQuery(start: 'scenario', prebuiltSites: ['D2'], prebuiltCand: ['w1']);
      expect(q.toParams(), {'view': 'planner', 'pq': 's:scenario;n:6', 'sites': 'D2', 'cand': 'w1'});
      expect(const PlannerQuery().toParams().containsKey('sites'), isFalse);
    });
    test('parses a planner answer with steps, links, coordinates and the why line', () {
      final r = PlannerResult.parse(fx('planner'));
      expect(r.ok, isTrue);
      expect(r.steps, isNotEmpty);
      expect(r.siteCount, greaterThan(0));
      expect(r.steps.first.sites.first.links, isNotEmpty);
      expect(r.targets, isNotEmpty);
      expect(r.endMainMesh, r.steps.last.mainMesh);
      expect(r.query?.maxSites, 3);
      expect(r.stopText, isNotEmpty);
      expect(r.repeaters, isNotEmpty);
    });
  });

  group('link profile', () {
    final j = fx('link');
    final p = LinkProfile.parse(j);
    test('the on-phone clearance equals the server\'s for both stored scenarios', () {
      expect(p.found, isTrue);
      expect(p.stored, hasLength(2));
      for (final s in p.stored) {
        final c = p.clearanceStored(s.h);
        expect(c.blockedM, s.blockedM, reason: '${s.h} ft blockedM');
        expect(c.canopyM, s.canopyM, reason: '${s.h} ft canopyM');
        expect(double.parse(c.clearShare.toStringAsFixed(3)), s.clearShare);
        expect(double.parse(c.worstRatio.toStringAsFixed(3)), s.worstRatio);
        expect(double.parse(c.worstKm.toStringAsFixed(3)), s.worstKm);
        expect(c.worstClearM, s.worstClearM);
        expect(double.parse(c.bullDb.toStringAsFixed(1)), s.bullDb);
        expect(double.parse(c.fspl.toStringAsFixed(1)), s.fspl);
      }
    });
    test('free heights at the stored heights reproduce the stored scenario', () {
      final m = p.storedHeights(33);
      final a = p.clearance(m.$1, m.$2), b = p.clearanceStored(33);
      expect(a.blockedM, b.blockedM);
      expect(a.bullDb, closeTo(b.bullDb, 1e-9));
    });
    test('a taller mast never makes the line more blocked, and the budget margin follows the diffraction loss', () {
      final low = p.clearance(3, 3), high = p.clearance(18, 18);
      expect(high.blockedM, lessThanOrEqualTo(low.blockedM));
      final bl = linkBudget(low, 22, 6, 1), bh = linkBudget(high, 22, 6, 1);
      expect(bh.marginDb, greaterThanOrEqualTo(bl.marginDb));
      expect(bl.rxDbm, closeTo(22 + 6 - 1 - low.fspl - low.bullDb, 1e-9));
    });
    test('a pair with no stored profile parses as not found', () {
      final n = LinkProfile.parse({'found': false, 'a': 'ZZ', 'b': 'YY', 'profileCount': 127});
      expect(n.found, isFalse);
      expect(n.profileCount, 127);
    });
    test('the ends and the lidar odds are kept', () {
      expect(p.ends, hasLength(2));
      expect(p.ends.any((e) => e.kind == 'site'), isTrue);
      expect(p.odds?.odds33, greaterThan(0));
    });
  });

  group('scenario and tracker', () {
    test('parses the scenario answer', () {
      final s = ScenarioResult.parse(fx('scenario'));
      expect(s.available, isTrue);
      expect(s.sites.toSet(), {'D2', 'P2'});
      expect(s.result.mainMesh, greaterThan(s.today.mainMesh));
      expect(s.result.pieces, isNotEmpty);
      expect(s.spofTop, isNotEmpty);
      expect(s.marginals, hasLength(20));
      expect(s.marginal('D2')?.on, isTrue);
      expect(s.presets.map((p) => p.id), contains('w12'));
      expect(s.waves, isNotEmpty);
      expect(s.addedLinks.first.aLat, isNotNull);
      expect(s.network, 'baseline');
    });
    test('parses the tracker board', () {
      final t = PlanTracker.parse(fx('tracker'));
      expect(t.available, isTrue);
      expect(t.sites, hasLength(3));
      expect(t.statuses.first, 'Proposed');
      expect(t.counts['Proposed'], 3);
      expect(t.sites.first.nextAction, isNotEmpty);
      expect(t.siteName('w1'), 'Cand w1');
    });
    test('unavailable answers keep the reason', () {
      expect(ScenarioResult.parse({'available': false, 'reason': 'none'}).reason, 'none');
      expect(PlanTracker.parse({'available': false, 'reason': 'none'}).available, isFalse);
      expect(PlanSites.parse({'available': false, 'reason': 'none'}).available, isFalse);
    });
  });

  group('api', () {
    http.Response ok(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

    test('asks the region host for each view and parses the answer', () async {
      final seen = <Uri>[];
      final api = PlanNativeApi('https://cmh.meshsonar.com/', client: MockClient((req) async {
        seen.add(req.url);
        final v = req.url.queryParameters['view'];
        return ok(fx(v == 'sites' ? 'sites' : v == 'link' ? 'link' : v == 'scenario' ? 'scenario' : v == 'tracker' ? 'tracker' : v == 'planner' ? 'planner' : 'overview'));
      }));
      expect((await api.overview()).data?.available, isTrue);
      expect((await api.sites()).data?.rows, isNotEmpty);
      expect((await api.tracker()).data?.sites, isNotEmpty);
      expect((await api.link('A', 'B')).data?.found, isTrue);
      expect((await api.planner(const PlannerQuery(objective: PlannerObjective.people, maxSites: 3))).data?.steps, isNotEmpty);
      expect((await api.scenario(sites: ['D2'], h: 33, tier: 'likely', r: 3)).data?.available, isTrue);
      expect(seen.every((u) => u.host == 'cmh.meshsonar.com' && u.path == '/api/cmh/plan-native'), isTrue);
      expect(seen[3].queryParameters, {'view': 'link', 'a': 'A', 'b': 'B'});
      expect(seen[4].queryParameters['pq'], 's:today;o:people;n:3');
      expect(seen[5].queryParameters, {'view': 'scenario', 'sites': 'D2', 'h': '33', 'tier': 'likely', 'r': '3'});
    });
    test('scenario with no sites asks for "none" and with live asks for the living plan', () async {
      late Uri u;
      final api = PlanNativeApi('https://x.org', client: MockClient((req) async {
        u = req.url;
        return ok(fx('scenario'));
      }));
      await api.scenario(sites: const [], h: 20, tier: 'possible', r: 4.5, live: true);
      expect(u.queryParameters, {'view': 'scenario', 'sites': 'none', 'h': '20', 'tier': 'possible', 'r': '4.5', 'net': 'live'});
      await api.scenario(sites: null, h: 33, tier: 'likely', r: 3);
      expect(u.queryParameters.containsKey('sites'), isFalse);
    });
    test('a refused or too-slow query shows the server\'s own sentence; no network is an honest failure', () async {
      final busy = PlanNativeApi('https://x.org', client: MockClient((_) async => http.Response(jsonEncode({'error': 'The planner is busy; try again in a moment'}), 503)));
      final r = await busy.planner(const PlannerQuery());
      expect(r.ok, isFalse);
      expect(r.error, 'The planner is busy; try again in a moment');
      expect(r.status, 503);
      final down = PlanNativeApi('https://x.org', client: MockClient((_) async => throw const SocketException('no route')));
      expect((await down.overview()).error, 'No connection to the server.');
    });
    test('a candidate\'s full row merges tree-adjusted and terrain links', () async {
      final api = PlanNativeApi('https://x.org', client: MockClient((req) async {
        expect(req.url.path, '/api/cmh/candidates');
        expect(req.url.queryParameters['ids'], 'w1');
        return ok({
          'items': [
            {
              'id': 'w1', 'kind': 'park', 'sub': 'Park', 'name': 'Cand', 'lat': 40.1, 'lon': -83.0, 'elevM': 300, 'promM': 5, 'pop3': 100, 'gap3': 50, 'score': 55, 'rank': 3,
              'links': [
                {'key': 'aa', 'km': 3, 'o33': 0.2, 't33': 'Likely', 'piece': 'core'},
                {'key': 'bb', 'km': 4, 'o33': 0.1, 't33': 'Possible', 'piece': 'core'},
              ],
              'linksTree': [
                {'key': 'bb', 'km': 4, 'o33t': 0.3, 't33t': 'Likely', 'treeM': 12, 'piece': 'core', 'lidar': true},
              ],
              'siteLinks': [],
            }
          ]
        });
      }));
      final c = (await api.candidate('w1')).data!;
      expect(c.links.first.key, 'bb');
      expect(c.links.first.treeBasis, 'lidar');
      expect(c.links.first.terrainOdds, 0.1);
      expect(c.links.last.treeOdds, isNull);
      final none = PlanNativeApi('https://x.org', client: MockClient((_) async => ok({'items': <dynamic>[]})));
      expect((await none.candidate('zz')).data, isNull);
    });
  });
}
