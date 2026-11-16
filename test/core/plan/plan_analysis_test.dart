import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_analysis.dart';
import 'package:meshsonar/core/plan/plan_api.dart' show ScoredProfile;
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan_contract.dart';

import 'plan_test_kit.dart';

const origin = PlanPoint(40.0, -83.0);
PlanPoint east(double km, [PlanPoint from = origin]) => offsetM(from, 0, km * 1000);
PlanPoint north(double km, [PlanPoint from = origin]) => offsetM(from, km * 1000, 0);
PlanNode node(String id, PlanPoint p, {String? key, double? h}) => PlanNode(id: id, name: id, lat: p.lat, lon: p.lon, existingKey: key, heightM: h);
Plan planOf(List<PlanNode> nodes, {PlanRadio radio = PlanRadio.usDefault}) => Plan(id: 'p', radio: radio, nodes: nodes, createdAt: DateTime.utc(2026));

void main() {
  test('on flat ground the plan radio and distance decide: 2 km likely, 4 km unlikely at 10 m with the calibrated clutter', () async {
    final t = FakeTerrain();
    final p = planOf([node('a', origin), node('b', east(2)), node('c', east(4))]);
    final m = await buildLinkMatrix(p, t.source);
    expect(m.between('a', 'b')!.verdict, PlanVerdict.likely);
    expect(m.between('b', 'c')!.verdict, PlanVerdict.likely);
    expect(m.between('a', 'c')!.verdict, PlanVerdict.unlikely);
    expect(m.between('c', 'a'), same(m.between('a', 'c')), reason: 'symmetric lookup');
    expect(m.peersOf('b'), {'a', 'c'});
    expect(m.truncated, isFalse);
    // The EU narrow preset (SF8) gains sensitivity: the matrix follows the plan's radio.
    final eu = await buildLinkMatrix(planOf(p.nodes, radio: const PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8)), t.source);
    expect(eu.between('a', 'c')!.result!.marginDb!, greaterThan(m.between('a', 'c')!.result!.marginDb!));
  });

  test('the matrix covers at most 10 nodes (45 pairs) and says when it is truncated; `only` picks them', () async {
    final t = FakeTerrain();
    final p = planOf([for (var i = 0; i < 12; i++) node('n$i', east(i * 0.5))]);
    final m = await buildLinkMatrix(p, t.source);
    expect(m.nodeIds.length, linkMatrixMaxNodes);
    expect(m.links.length, 45);
    expect(t.calls, 45);
    expect(m.truncated, isTrue);
    final some = await buildLinkMatrix(p, t.source, only: ['n11', 'n0', 'n5']);
    expect(some.nodeIds, ['n0', 'n5', 'n11']);
    expect(some.links.length, 3);
  });

  test('a pair without terrain carries the reason instead of a verdict', () async {
    final a = origin, b = east(2);
    final t = FakeTerrain(failPairs: {'${a.lat},${a.lon}|${b.lat},${b.lon}'});
    final m = await buildLinkMatrix(planOf([node('a', a), node('b', b)]), t.source);
    expect(m.between('a', 'b')!.verdict, isNull);
    expect(m.between('a', 'b')!.error, 'No connection to the server.');
  });

  test('a ridge between the ends blocks the link and is reported', () async {
    final t = FakeTerrain(hill: ridgeAt(east(4).lon, 180, widthM: 1500));
    final p = planOf([node('a', origin), node('b', east(8))]);
    final m = await buildLinkMatrix(p, t.source);
    final r = m.between('a', 'b')!.result!;
    expect(r.verdict, PlanVerdict.unlikely);
    expect(hasLineOfSight(r), isFalse);
    expect(r.ridge!.km, closeTo(4, 0.25));
    expect(r.tightest!.raiseM, greaterThan(100));
  });

  test('relay finder: puts the relay on the ridge top with dual line of sight, best first', () async {
    final t = FakeTerrain(hill: ridgeAt(east(4).lon, 180, widthM: 1500));
    final a = node('a', origin), b = node('b', east(8));
    final p = planOf([a, b]);
    final ab = (await t(a.point, b.point)).data!;
    final relays = await findRelays(p, a, b, t.source, abProfile: ab);
    expect(relays, isNotEmpty);
    expect(relays.length, lessThanOrEqualTo(3));
    final best = relays.first;
    expect(best.dualLineOfSight, isTrue);
    expect(best.verdict, PlanVerdict.likely);
    expect(best.at.lon, closeTo(east(4).lon, 0.01));
    expect(best.groundM, greaterThan(400));
    for (var i = 1; i < relays.length; i++) {
      final x = relays[i - 1], y = relays[i];
      expect(x.dualLineOfSight || !y.dualLineOfSight, isTrue);
      if (x.dualLineOfSight == y.dualLineOfSight) expect(x.worstMarginDb, greaterThanOrEqualTo(y.worstMarginDb));
    }
  });

  test('snap to high ground: finds the hill top within the radius, says how much higher it is', () async {
    final peak = east(0.3);
    final t = FakeTerrain(hill: (p) => 60 * (1 - (distanceM(p, peak) / 400).clamp(0, 1)));
    final r = (await snapToHighGround(origin, 500, t.source))!;
    expect(distanceM(r.at, peak), lessThan(20));
    expect(r.groundM, closeTo(310, 3));
    expect(r.gainM!, closeTo(310 - t.groundAt(origin), 3));
    expect(r.distanceM, closeTo(300, 20));
    expect(t.calls, 8);
    // Out of reach: the peak is not chosen when the radius stops short of it.
    final near = (await snapToHighGround(origin, 100, FakeTerrain(hill: (p) => 60 * (1 - (distanceM(p, peak) / 400).clamp(0, 1))).source))!;
    expect(near.distanceM, lessThanOrEqualTo(100.5));
    expect(highestSample(origin, 50, const []), isNull);
  });

  test('profileSamples puts each sample on the map along A-B', () {
    final a = origin, b = east(1);
    final s = profileSamples(a, b, const ScoredProfile(km: 1, groundM: [1, 2, 3], distKm: [0, 0.5, 1], source: 't'));
    expect(s[1].$1.lon, closeTo((a.lon + b.lon) / 2, 1e-12));
    expect(s.map((x) => x.$2), [1, 2, 3]);
  });

  test('how many repeaters see this spot', () async {
    final t = FakeTerrain();
    final p = planOf([node('a', origin), node('b', east(9)), PlanNode(id: 'h', name: 'h', lat: origin.lat, lon: origin.lon, role: PlanNodeRole.handheld)]);
    expect(await nodesSeeing(p, east(1.5), t.source), 1);
    expect(await nodesSeeing(p, east(30), t.source), 0);
    expect(await nodesSeeing(p, origin, t.source), 1, reason: 'standing at the node counts');
  });

  group('node classes', () {
    test('a node that alone joins two parts of the plan is critical; the ends are marginal', () async {
      final p = planOf([node('a', origin), node('b', east(2)), node('c', east(4))]);
      final m = await buildLinkMatrix(p, FakeTerrain().source);
      final c = classifyNodes(p, matrix: m);
      expect(c['b']!.cls, PlanNodeClass.critical);
      expect(c['b']!.reason, 'The only link between parts of this plan');
      expect(c['a']!.cls, PlanNodeClass.marginal);
      expect(c['a']!.reason, 'Reaches only 1 node');
    });

    test('E8 critical nodes, E5 peers: critical / backbone / redundant / marginal', () {
      final k = {for (final x in ['a', 'b', 'c', 'd']) x: x * 64};
      final p = planOf([for (final x in ['a', 'b', 'c', 'd']) node(x, origin, key: k[x])]);
      final c = classifyNodes(p,
          facts: NetworkFacts(criticalStranded: {k['a']!: 5}, peers: {
            k['a']!: {'x' * 64},
            k['b']!: {'x' * 64, 'y' * 64, 'z' * 64},
            k['c']!: {'x' * 64, 'y' * 64},
            k['d']!: {},
          }));
      expect(c['a']!.cls, PlanNodeClass.critical);
      expect(c['a']!.reason, 'Strands 5 repeaters if it goes down');
      expect(c['b']!.cls, PlanNodeClass.backbone);
      expect(c['b']!.reason, 'Links to 3 nodes');
      expect(c['c']!.cls, PlanNodeClass.redundant);
      expect(c['d']!.cls, PlanNodeClass.marginal);
      expect(c['d']!.reason, 'Reaches no other node');
      expect(PlanNodeClass.values.map((x) => x.label), ['Critical', 'Backbone', 'Redundant', 'Marginal']);
    });

    test('a plan link and the same network link count once', () async {
      final ka = 'a' * 64, kb = 'b' * 64;
      final p = planOf([node('a', origin, key: ka), node('b', east(2), key: kb)]);
      final m = await buildLinkMatrix(p, FakeTerrain().source);
      final c = classifyNodes(p, matrix: m, facts: NetworkFacts(peers: {ka: {kb}}));
      expect(c['a']!.peers, 1);
    });

    test('only marginal links', () async {
      // 3.6 km at 10 m with the calibrated clutter is within the fade margin.
      final p = planOf([node('a', origin), node('b', east(3.6))]);
      final m = await buildLinkMatrix(p, FakeTerrain().source);
      expect(m.between('a', 'b')!.verdict, PlanVerdict.marginal);
      expect(classifyNodes(p, matrix: m)['a']!.reason, 'Only marginal links');
    });
  });

  test('calibration confidence: "412 drive cells within 2 km" or "unobserved, estimate"', () {
    final cells = [
      for (var i = 0; i < 412; i++) offsetM(origin, (i % 20) * 50.0, (i ~/ 20) * 50.0),
      east(5),
      north(-3),
    ];
    final c = calibrationConfidence(origin, cells);
    expect(c.driveCells, 412);
    expect(c.text, '412 drive cells within 2 km');
    expect(c.observed, isTrue);
    expect(calibrationConfidence(east(50), cells).text, 'unobserved, estimate');
    expect(calibrationConfidence(east(5), cells).text, '1 drive cell within 2 km');
    expect(calibrationConfidence(origin, cells, radiusKm: 0.5).text, endsWith('within 0.5 km'));
  });
}
