// The person's saved plans on this phone: Plan JSON v1 documents (plan_model.dart) kept through the PlanRepository seam
// (AppServices.planRepository: one atomic file per plan under <data>/plans/). A damaged document costs only that plan: it
// is skipped in the list and [load] returns null. Nothing here leaves the phone. Pure Dart.
import 'dart:convert';

import 'plan_model.dart';
import 'plan_repository.dart';

/// One row of the saved-plans list.
class SavedPlanSummary {
  final String id, name;
  final int nodeCount;
  final DateTime updatedAt;
  const SavedPlanSummary({required this.id, required this.name, required this.nodeCount, required this.updatedAt});
}

class SavedPlans {
  final PlanRepository repository;
  final DateTime Function() clock;
  SavedPlans(this.repository, {DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  /// Every readable saved plan, most recently saved first.
  Future<List<SavedPlanSummary>> list() async {
    final out = <SavedPlanSummary>[];
    for (final id in await repository.ids()) {
      final p = await load(id);
      if (p != null) out.add(SavedPlanSummary(id: p.id, name: p.name, nodeCount: p.nodes.length, updatedAt: p.updatedAt));
    }
    return out;
  }

  /// The plan saved under [id]; null when there is none or it cannot be read.
  Future<Plan?> load(String id) async {
    final s = await repository.read(id);
    if (s == null) return null;
    try {
      final p = Plan.fromJson(jsonDecode(s));
      // The file name is the truth for the id (a copied file keeps working).
      return p.id == id ? p : p.copyWith(id: id);
    } catch (_) {
      return null;
    }
  }

  /// Saves [plan] stamped with the current time; returns what was written.
  Future<Plan> save(Plan plan) async {
    final p = plan.copyWith(updatedAt: clock().toUtc());
    await repository.write(p.id, jsonEncode(p.toJson()));
    return p;
  }

  Future<void> delete(String id) => repository.delete(id);

  /// Keeps a plan that arrived in a share link: a fresh id (never overwrites a plan of the same id already here).
  Future<Plan> import(Plan shared) async {
    final now = clock().toUtc();
    return save(Plan(
      id: newPlanId(now: now),
      name: shared.name,
      region: shared.region,
      radio: shared.radio,
      clutter: shared.clutter,
      goal: shared.goal,
      receiverM: shared.receiverM,
      nodes: [for (final n in shared.nodes) n.copyWith(mine: false)],
      createdAt: now,
    ));
  }
}
