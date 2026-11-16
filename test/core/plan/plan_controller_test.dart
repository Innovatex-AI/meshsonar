import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/node_claim.dart';
import 'package:meshsonar/core/plan/plan_analysis.dart';
import 'package:meshsonar/core/plan/plan_controller.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan/plan_repository.dart';
import 'package:meshsonar/core/plan/saved_plans.dart';
import 'package:meshsonar/core/plan_contract.dart';

import 'plan_test_kit.dart';

const origin = PlanPoint(40.0, -83.0);
PlanPoint east(double km) => offsetM(origin, 0, km * 1000);
Plan empty() => Plan(id: 'p_test', createdAt: DateTime.utc(2026));

void main() {
  test('add, move, edit, delete, with notifications', () {
    final c = PlanController(empty(), random: math.Random(3));
    var calls = 0;
    void l() => calls++;
    c.addListener(l);
    final a = c.addNode(name: 'Hill', lat: 40, lon: -83);
    final b = c.addNode(name: '  ', lat: 40.01, lon: -83);
    expect(c.nodes.map((n) => n.name), ['Hill', 'Node 2']);
    expect(a.id, isNot(b.id));
    expect(c.moveNode(a.id, 40.5, -83.5), isTrue);
    expect(c.plan.node(a.id)!.lat, 40.5);
    expect(c.moveNode('nope', 1, 1), isFalse);
    expect(c.moveNode(a.id, 91, 0), isFalse);
    expect(c.updateNode(a.id, (n) => n.copyWith(heightM: 20, mount: PlanMount.building)), isTrue);
    expect(c.plan.node(a.id)!.antennaM, 20);
    expect(() => c.updateNode(a.id, (n) => PlanNode(id: 'other', name: 'x', lat: 0, lon: 0)), throwsArgumentError);
    expect(c.deleteNode(b.id), isTrue);
    expect(c.deleteNode(b.id), isFalse);
    expect(c.nodes.length, 1);
    expect(calls, 5);
    c.removeListener(l);
    c.rename('Ridge plan');
    expect(calls, 5);
    expect(c.plan.name, 'Ridge plan');
  });

  test('30 nodes at most; the same network node is not added twice', () {
    final c = PlanController(empty());
    final k = 'ab' * 32;
    final first = c.addNode(name: 'R', lat: 1, lon: 1, existingKey: k, status: PlanNodeStatus.existing);
    expect(c.addNode(name: 'R again', lat: 1, lon: 1, existingKey: k), same(first));
    for (var i = 1; i < Plan.maxNodes; i++) {
      c.addNode(name: '$i', lat: 0, lon: i / 100);
    }
    expect(c.plan.isFull, isTrue);
    expect(() => c.addNode(name: 'one too many', lat: 0, lon: 0), throwsA(isA<PlanFullException>()));
    expect(const PlanFullException().toString(), contains('30'));
  });

  test('undo and redo every kind of change; a drag is one undo step', () {
    final c = PlanController(empty());
    expect(c.canUndo, isFalse);
    final a = c.addNode(name: 'A', lat: 40, lon: -83);
    c.moveNode(a.id, 40.001, -83);
    for (var i = 2; i <= 20; i++) {
      c.moveNode(a.id, 40 + i / 1000, -83, continuing: true);
    }
    c.setRadio(const PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8));
    c.setClutter(const PlanClutter(canopyM: 10, dbPerKm: 5));
    c.setGoal(PlanGoal.redundancy);
    c.setReceiverM(1.8);
    expect(c.plan.node(a.id)!.lat, 40.02);
    expect(c.undo(), isTrue); // receiver
    expect(c.plan.receiverM, isNull);
    c.undo(); // goal
    c.undo(); // clutter
    c.undo(); // radio
    expect(c.plan.radio, PlanRadio.usDefault);
    expect(c.plan.goal, PlanGoal.overall);
    c.undo(); // the whole drag
    expect(c.plan.node(a.id)!.lat, 40);
    expect(c.canRedo, isTrue);
    c.redo();
    expect(c.plan.node(a.id)!.lat, 40.02);
    c.undo();
    c.undo(); // the add
    expect(c.nodes, isEmpty);
    expect(c.undo(), isFalse);
    c.redo();
    expect(c.nodes.length, 1);
    c.addNode(name: 'B', lat: 0, lon: 0);
    expect(c.canRedo, isFalse, reason: 'a new change drops the redo history');
  });

  test('undo history is bounded', () {
    final c = PlanController(empty(), maxUndo: 3);
    for (var i = 0; i < 6; i++) {
      c.addNode(name: '$i', lat: 0, lon: i / 10);
    }
    var n = 0;
    while (c.undo()) {
      n++;
    }
    expect(n, 3);
    expect(c.nodes.length, 3);
  });

  test('autosave writes the plan after the quiet period, and on dispose', () {
    fakeAsync((async) {
      final repo = MemoryPlanRepository();
      final saved = SavedPlans(repo, clock: () => DateTime.utc(2026, 11, 15, 9));
      final c = PlanController(empty(), saved: saved);
      c.addNode(name: 'A', lat: 1, lon: 1);
      expect(c.dirty, isTrue);
      async.elapse(const Duration(milliseconds: 300));
      c.addNode(name: 'B', lat: 1, lon: 2);
      async.elapse(const Duration(milliseconds: 300));
      expect(repo.ids(), completion(isEmpty), reason: 'still inside the quiet period after the last change');
      async.elapse(const Duration(milliseconds: 400));
      async.flushMicrotasks();
      expect(c.dirty, isFalse);
      Plan? back;
      saved.load('p_test').then((p) => back = p);
      async.flushMicrotasks();
      expect(back!.nodes.map((n) => n.name), ['A', 'B']);
      expect(back!.updatedAt, DateTime.utc(2026, 11, 15, 9));
      c.rename('Renamed');
      c.dispose();
      async.flushMicrotasks();
      saved.load('p_test').then((p) => back = p);
      async.flushMicrotasks();
      expect(back!.name, 'Renamed');
    });
  });

  test('changes stream; replace opens another plan with a fresh history', () async {
    final c = PlanController(empty());
    final seen = <int>[];
    final sub = c.changes.listen((p) => seen.add(p.nodes.length));
    c.addNode(name: 'A', lat: 0, lon: 0);
    c.replace(thirtyNodePlan());
    await Future<void>.delayed(Duration.zero);
    expect(seen, [1, 30]);
    expect(c.canUndo, isFalse);
    await sub.cancel();
    await c.dispose();
  });

  test('mine follows the claims without an undo step', () {
    final k = 'cd' * 32;
    final c = PlanController(empty());
    c.addNode(name: 'Mine?', lat: 0, lon: 0, existingKey: k, status: PlanNodeStatus.existing);
    c.resolveMineFrom([NodeClaim(pubkey: k)]);
    expect(c.nodes.single.mine, isTrue);
    c.undo();
    expect(c.nodes, isEmpty, reason: 'undo skips the derived change and removes the add');
  });

  test('link matrix is reused until something that changes it changes; node classes come from it', () async {
    final t = FakeTerrain();
    final c = PlanController(empty());
    final a = c.addNode(name: 'A', lat: origin.lat, lon: origin.lon);
    c.addNode(name: 'B', lat: east(2).lat, lon: east(2).lon);
    c.addNode(name: 'C', lat: east(4).lat, lon: east(4).lon);
    final m1 = await c.linkMatrix(t.source);
    expect(t.calls, 3);
    expect(await c.linkMatrix(t.source), same(m1));
    expect(t.calls, 3);
    c.rename('Only the name');
    expect(await c.linkMatrix(t.source), same(m1));
    final cls = c.nodeClasses();
    expect(cls.values.where((x) => x.cls == PlanNodeClass.critical).length, 1);
    c.moveNode(a.id, origin.lat, origin.lon + 0.001);
    await c.linkMatrix(t.source);
    expect(t.calls, 6);
    c.setRadio(const PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8));
    expect(c.nodeClasses().values.every((x) => x.peers == 0), isTrue, reason: 'a stale matrix is not used');
  });

  test('relay finder and snap act on the plan as one undo step each', () async {
    final t = FakeTerrain(hill: ridgeAt(east(4).lon, 180, widthM: 1500));
    final c = PlanController(empty());
    final a = c.addNode(name: 'A', lat: origin.lat, lon: origin.lon);
    final b = c.addNode(name: 'B', lat: east(8).lat, lon: east(8).lon);
    final relays = await c.relaysFor(a.id, b.id, t.source);
    expect(relays.first.verdict, PlanVerdict.likely);
    final relay = c.addRelay(relays.first);
    expect(c.nodes.length, 3);
    expect(relay.heightM, plannedHeightM);
    c.undo();
    expect(c.nodes.length, 2);
    expect(await c.relaysFor('x', b.id, t.source), isEmpty);

    final s = await c.snapNode(a.id, 5000, t.source);
    expect(s, isNotNull);
    expect(c.plan.node(a.id)!.lon, closeTo(east(4).lon, 0.01), reason: 'moved onto the ridge');
    c.undo();
    expect(c.plan.node(a.id)!.lon, origin.lon);
    expect(await c.snapNode('nope', 100, t.source), isNull);
  });
}
