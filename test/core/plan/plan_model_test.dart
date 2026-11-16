import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart' show RadioPreset;
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan_contract.dart';

import 'plan_test_kit.dart';

void main() {
  test('Plan JSON v1 golden: a 30-node plan encodes to the committed document and decodes back equal', () {
    final plan = thirtyNodePlan();
    final golden = File('test/fixtures/plan_native/plan_v1_30_nodes.json').readAsStringSync();
    expect(const JsonEncoder.withIndent(' ').convert(plan.toJson()), golden.trimRight());
    final back = Plan.fromJson(jsonDecode(golden));
    expect(back.nodes, plan.nodes);
    expect(back.radio, plan.radio);
    expect(back.goal, PlanGoal.links);
    expect(back.receiverM, 1.8);
    expect(back.createdAt, plan.createdAt);
    expect(jsonEncode(back.toJson()), jsonEncode(plan.toJson()));
  });

  test('optional node fields are left out when unset, kept when set', () {
    const n = PlanNode(id: 'a', name: 'A', lat: 1.123456789, lon: 2, status: PlanNodeStatus.existing);
    expect(n.toJson(), {'id': 'a', 'name': 'A', 'lat': 1.12346, 'lon': 2.0, 'status': 'existing', 'role': 'repeater'});
    final full = n.copyWith(heightM: 12, txDbm: 20, gainDbi: 6, cableLossDb: 1.5, mount: PlanMount.tree, mine: true, existingKey: 'ab' * 32);
    expect(full.toJson(), containsPair('mount', 'tree'));
    expect(full.toJson(), containsPair('mine', true));
    expect(PlanNode.tryParse(full.toJson()), full.copyWith(lat: 1.12346), reason: 'positions travel at 5 places (about a metre)');
  });

  test('antenna height, power and gain defaults by mount, status and role', () {
    const p = PlanNode(id: 'p', name: 'P', lat: 0, lon: 0);
    expect(p.antennaM, plannedHeightM);
    expect(p.copyWith(status: PlanNodeStatus.existing).antennaM, existingHeightM);
    expect(p.copyWith(role: PlanNodeRole.handheld).antennaM, handheldHeightM);
    expect(p.copyWith(mount: PlanMount.tree).antennaM, 15);
    expect(p.copyWith(mount: PlanMount.building, heightM: 22).antennaM, 22, reason: 'own height wins over the mount');
    expect(p.effectiveTxDbm, 22);
    expect(p.copyWith(gainDbi: 6, cableLossDb: 1.5).effectiveGainDbi, 4.5);
    expect(p.copyWith(role: PlanNodeRole.handheld).effectiveGainDbi, 0);
  });

  test('decoding is tolerant: bad nodes dropped, odd fields defaulted, out-of-range values clamped, ids made unique', () {
    final p = Plan.fromJson({
      'v': 1,
      'id': 'bad id with spaces',
      'nodes': [
        {'id': 'x', 'name': 'ok', 'lat': 10, 'lon': 20, 'heightM': 9999, 'status': 'weird', 'role': 'robot'},
        {'id': 'x', 'name': 'dup', 'lat': 11, 'lon': 21},
        {'id': 'y', 'lat': 'north', 'lon': 0},
        {'id': 'z', 'lat': 95, 'lon': 0},
        {'name': 'no id', 'lat': 1, 'lon': 1, 'existingKey': 'NOT A KEY'},
        'junk',
      ],
    });
    expect(p.id, 'p_imported');
    expect(p.name, 'Shared plan');
    expect(p.radio, PlanRadio.usDefault);
    expect(p.nodes.map((n) => n.name), ['ok', 'dup', 'no id']);
    expect(p.nodes.map((n) => n.id).toSet().length, 3);
    expect(p.nodes[0].heightM, 300);
    expect(p.nodes[0].status, PlanNodeStatus.planned);
    expect(p.nodes[0].role, PlanNodeRole.repeater);
    expect(p.nodes[2].existingKey, isNull);
  });

  test('the spec draft field `source: existing|mine|planned` is still read', () {
    final p = Plan.fromJson({
      'v': 1,
      'nodes': [
        {'id': 'a', 'lat': 1, 'lon': 1, 'source': 'existing'},
        {'id': 'b', 'lat': 1, 'lon': 1, 'source': 'mine'},
        {'id': 'c', 'lat': 1, 'lon': 1, 'source': 'planned'},
      ],
    });
    expect([for (final n in p.nodes) (n.status, n.mine)], [(PlanNodeStatus.existing, false), (PlanNodeStatus.planned, true), (PlanNodeStatus.planned, false)]);
  });

  test('not a v1 plan throws', () {
    expect(() => Plan.fromJson('x'), throwsFormatException);
    expect(() => Plan.fromJson({'v': 2, 'nodes': []}), throwsFormatException);
    expect(() => Plan.fromJson({'v': 1}), throwsFormatException);
  });

  test('at most 30 nodes, both built and decoded', () {
    final many = [for (var i = 0; i < 40; i++) PlanNode(id: 'n$i', name: '$i', lat: 0, lon: i / 100)];
    expect(Plan(id: 'p', nodes: many, createdAt: DateTime.utc(2026)).nodes.length, Plan.maxNodes);
    final j = {'v': 1, 'nodes': [for (final n in many) n.toJson()]};
    expect(Plan.fromJson(j).nodes.length, 30);
    expect(Plan.fromJson(j).isFull, isTrue);
  });

  test('a new plan takes the region preset as its radio; the US default only when there is none', () {
    final eu = Plan.create(preset: const RadioPreset(name: 'EU', freqMhz: 869.618, bwKhz: 62.5, sf: 8, cr: 8), now: DateTime.utc(2026, 11, 15), random: math.Random(1));
    expect(eu.radio, const PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8));
    expect(Plan.create(now: DateTime.utc(2026)).radio, PlanRadio.usDefault);
    expect(RegExp(r'^p_[a-z0-9]+$').hasMatch(eu.id), isTrue);
    expect(eu.id.length, lessThanOrEqualTo(64));
  });

  group('mine from claimed radios (my-radios)', () {
    final k1 = 'a1' * 32, k2 = 'b2' * 32, k3 = 'c3' * 32;
    NodeClaim claim(String k, {ClaimNodeType t = ClaimNodeType.repeater, bool ended = false, String? name}) =>
        NodeClaim(pubkey: k, nodeType: t, ended: ended, displayName: name);

    test('keyed nodes follow the active claims; planned sites without a key keep what the person set', () {
      final p = Plan(id: 'p', createdAt: DateTime.utc(2026), nodes: [
        PlanNode(id: 'a', name: 'A', lat: 0, lon: 0, status: PlanNodeStatus.existing, existingKey: k1),
        PlanNode(id: 'b', name: 'B', lat: 0, lon: 0, status: PlanNodeStatus.existing, existingKey: k2, mine: true),
        const PlanNode(id: 'c', name: 'C', lat: 0, lon: 0, mine: true),
      ]);
      final r = resolveMine(p, [claim(k1), claim(k2, ended: true)]);
      expect([for (final n in r.nodes) n.mine], [true, false, true]);
      expect(identical(resolveMine(r, [claim(k1)]), r), isTrue, reason: 'no change, same plan');
    });

    test('mineNodes adds the claimed radios with a known position, once, and skips observers', () {
      final p = Plan(id: 'p', createdAt: DateTime.utc(2026), nodes: [
        PlanNode(id: 'a', name: 'A', lat: 0, lon: 0, existingKey: k1),
      ]);
      final out = mineNodes(
        p,
        [claim(k1), claim(k2, name: 'Roof'), claim(k3, t: ClaimNodeType.observer), claim('d4' * 32, t: ClaimNodeType.companion)],
        {k1: const PlanPoint(1, 1), k2: const PlanPoint(2, 2), k3: const PlanPoint(3, 3), 'd4' * 32: const PlanPoint(4, 4)},
        random: math.Random(2),
      );
      expect(out.map((n) => n.name), ['Roof', 'Radio d4d4d4d4']);
      expect(out.every((n) => n.mine && n.status == PlanNodeStatus.existing), isTrue);
      expect(out.last.role, PlanNodeRole.handheld);
      expect(out.map((n) => n.id).toSet().length, 2);
    });
  });
}
