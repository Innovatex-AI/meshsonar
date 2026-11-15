// Shared test data for the Plan core tests.
import 'dart:math' as math;

import 'package:meshsonar/core/plan/link_model.dart' show haversineKm;
import 'package:meshsonar/core/plan/plan_analysis.dart';
import 'package:meshsonar/core/plan/plan_api.dart';
import 'package:meshsonar/core/plan/plan_model.dart';
import 'package:meshsonar/core/plan_contract.dart';

/// A full plan: 30 nodes of every status, role, mount and optional field (the Plan JSON v1 and codec goldens).
Plan thirtyNodePlan() {
  final nodes = <PlanNode>[];
  for (var i = 0; i < 30; i++) {
    final status = PlanNodeStatus.values[i % 3];
    nodes.add(PlanNode(
      id: 'n${i.toString().padLeft(2, '0')}',
      name: 'Site ${i + 1}${i == 7 ? ' (Mount Olive)' : ''}',
      lat: double.parse((39.9 + i * 0.01234).toStringAsFixed(5)),
      lon: double.parse((-83.1 + (i % 6) * 0.0217).toStringAsFixed(5)),
      status: status,
      mine: i % 5 == 0,
      existingKey: status == PlanNodeStatus.existing ? i.toRadixString(16).padLeft(2, '0') * 32 : null,
      heightM: i % 4 == 0 ? 6.0 + i : null,
      txDbm: i % 7 == 0 ? 20 : null,
      gainDbi: i % 6 == 0 ? 5.8 : null,
      cableLossDb: i % 9 == 0 ? 1.2 : null,
      mount: i % 4 == 1 ? PlanMount.values[i % 3] : null,
      role: i == 29 ? PlanNodeRole.handheld : PlanNodeRole.repeater,
    ));
  }
  return Plan(
    id: 'p_golden30',
    name: 'Columbus backbone',
    region: 'cmh',
    radio: PlanRadio.usDefault,
    goal: PlanGoal.links,
    receiverM: 1.8,
    nodes: nodes,
    createdAt: DateTime.utc(2026, 11, 15, 12),
    updatedAt: DateTime.utc(2026, 11, 15, 13, 30),
  );
}

/// A synthetic terrain: a profile of [samples] points between any two points, ground rising with a smooth hill whose
/// height is given by [hill] (metres above a 250 m plain) at each location. Counts calls.
class FakeTerrain {
  final double Function(PlanPoint p) hill;
  final int samples;
  int calls = 0;
  final Set<String> failPairs;
  FakeTerrain({double Function(PlanPoint p)? hill, this.samples = 41, this.failPairs = const {}}) : hill = hill ?? ((_) => 0);

  double groundAt(PlanPoint p) => 250 + hill(p);

  Future<PlanResult<ScoredProfile>> call(PlanPoint a, PlanPoint b) async {
    calls++;
    if (failPairs.contains('${a.lat},${a.lon}|${b.lat},${b.lon}')) return const PlanResult.fail('No connection to the server.', unavailable: true);
    final km = haversineKm(a.lat, a.lon, b.lat, b.lon);
    final g = <double>[], d = <double>[];
    for (var i = 0; i < samples; i++) {
      final t = i / (samples - 1);
      g.add(groundAt(PlanPoint(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t)));
      d.add(km * t);
    }
    return PlanResult.ok(ScoredProfile(km: km, groundM: g, distKm: d, source: 'fake terrain'), at: DateTime.utc(2026, 11, 15));
  }

  ProfileSource get source => call;
}

/// A ridge of [heightM] metres along the meridian [lon] (gaussian, ~[widthM] wide).
double Function(PlanPoint) ridgeAt(double lon, double heightM, {double widthM = 300}) =>
    (p) => heightM * math.exp(-math.pow((p.lon - lon) * 85000 / widthM, 2));
