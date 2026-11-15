import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan/plan_repository.dart';
import 'package:meshsonar/core/plan/saved_plans.dart';

import 'plan_test_kit.dart';

void main() {
  var now = DateTime.utc(2026, 11, 15, 14);
  DateTime clock() => now;

  test('save, list newest first, load, delete', () async {
    final s = SavedPlans(MemoryPlanRepository(), clock: clock);
    final a = await s.save(Plan(id: 'p_a', name: 'A', createdAt: DateTime.utc(2026)));
    expect(a.updatedAt, now);
    now = now.add(const Duration(minutes: 1));
    await s.save(thirtyNodePlan());
    final list = await s.list();
    expect(list.map((x) => x.id), ['p_golden30', 'p_a']);
    expect(list.first.nodeCount, 30);
    expect(list.first.name, 'Columbus backbone');
    expect((await s.load('p_golden30'))!.nodes, thirtyNodePlan().nodes);
    await s.delete('p_a');
    expect((await s.list()).map((x) => x.id), ['p_golden30']);
    expect(await s.load('p_a'), isNull);
  });

  test('a damaged document costs only that plan', () async {
    final repo = MemoryPlanRepository();
    final s = SavedPlans(repo, clock: clock);
    await s.save(Plan(id: 'p_ok', createdAt: DateTime.utc(2026)));
    await repo.write('p_bad', '{not json');
    await repo.write('p_v9', jsonEncode({'v': 9, 'nodes': []}));
    expect((await s.list()).map((x) => x.id), ['p_ok']);
    expect(await s.load('p_bad'), isNull);
  });

  test('the file name is the id; works on the real file repository', () async {
    final dir = await Directory.systemTemp.createTemp('plans');
    addTearDown(() => dir.delete(recursive: true));
    final repo = FilePlanRepository(dir);
    final s = SavedPlans(repo, clock: clock);
    await s.save(thirtyNodePlan());
    await repo.write('p_copy', (await repo.read('p_golden30'))!);
    expect((await s.load('p_copy'))!.id, 'p_copy');
    expect(File('${dir.path}/p_golden30.plan.json').existsSync(), isTrue);
  });

  test('importing a shared plan gives it a new id and never overwrites', () async {
    final s = SavedPlans(MemoryPlanRepository(), clock: clock);
    final original = await s.save(thirtyNodePlan());
    final shared = thirtyNodePlan();
    final kept = await s.import(shared);
    expect(kept.id, isNot(original.id));
    expect(kept.nodes.any((n) => n.mine), isFalse);
    expect((await s.list()).length, 2);
    expect(isValidPlanId(kept.id), isTrue);
  });
}
