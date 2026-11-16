// The profile chart's maths (profile_chart.dart): the point under the crosshair and its plain-words readout.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/link_model.dart' show keM, lambdaFor;
import 'package:meshsonar/core/plan_contract.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/plan/modes/profile_chart.dart';

void main() {
  const flat = PlanProfile(distanceKm: [0, 5, 10], groundM: [100, 100, 100]);
  final lambda = lambdaFor(PlanRadio.usDefault);

  test('at the ends the line sits on the masts and the zone is closed', () {
    final a = profilePointAt(flat, 10, 4, lambda, 0);
    expect(a.km, 0);
    expect(a.clearM, closeTo(10, 1e-9));
    expect(a.zoneM, 0);
    expect(a.fresnelPct, 100);
    final b = profilePointAt(flat, 10, 4, lambda, 1);
    expect(b.km, 10);
    expect(b.clearM, closeTo(4, 1e-9));
  });

  test('mid-path: the earth curve and the first Fresnel radius', () {
    final m = profilePointAt(flat, 10, 10, lambda, 0.5);
    expect(m.km, 5);
    expect(m.bulgedM - m.groundM, closeTo(5000 * 5000 / (2 * keM), 1e-9));
    expect(m.zoneM, closeTo(28.7, 0.1), reason: 'sqrt(lambda * 5 km * 5 km / 10 km) at 910.525 MHz');
    expect(m.clearM, lessThan(10));
  });

  test('ground interpolates between samples; the readout says blocked when the ground is above the line', () {
    const hill = PlanProfile(distanceKm: [0, 1, 2], groundM: [100, 200, 100]);
    final p = profilePointAt(hill, 5, 5, lambda, 0.25);
    expect(p.groundM, closeTo(150, 1e-9));
    expect(p.clearM, lessThan(0));
    expect(profileReadout(p, Units.metric, aName: 'Hill'), allOf(startsWith('500 m from Hill: ground 150'), endsWith('(blocked)')));
    final clear = profilePointAt(flat, 30, 30, lambda, 0.5);
    expect(profileReadout(clear, Units.metric), contains('% of the Fresnel zone open'));
  });
}
