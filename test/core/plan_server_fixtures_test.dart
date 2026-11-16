// The app parses the server's real plan-link / plan-verify answers (fixtures copied from meshcore-insights src/test/fixtures/plan).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';

Map<String, dynamic> _f(String n) => jsonDecode(File('test/fixtures/plan_server/$n').readAsStringSync()) as Map<String, dynamic>;

void main() {
  for (final n in ['plan-link.estimate', 'plan-link.measured']) {
    test('$n response parses', () {
      final r = PlanLinkResult.parse(_f('$n.response.json'));
      expect(r.profile.distanceKm.length, greaterThan(1));
      expect(r.verdict, isNotNull);
      expect(r.provenance.model, isNotEmpty);
    });
  }
  test('measured link carries measured evidence', () {
    expect(PlanLinkResult.parse(_f('plan-link.measured.response.json')).measured, isNotNull);
  });
  test('plan-verify single site response parses', () {
    final r = PlanVerifyResult.parse(_f('plan-verify.site.response.json'));
    expect(r.provenance.model, isNotEmpty);
  });
  test('plan-verify sites form is a results list of parseable site answers', () {
    final j = _f('plan-verify.sites.response.json');
    final list = j['results'] as List;
    expect(list, isNotEmpty);
    for (final e in list) {
      PlanVerifyResult.parse((e as Map).cast<String, dynamic>());
    }
  });
}
