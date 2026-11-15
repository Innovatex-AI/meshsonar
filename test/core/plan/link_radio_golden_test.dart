// The on-device link model with the radio as a parameter, against the website's own plan-link maths
// (test/fixtures/plan_native/link_radio_golden.json, generated from meshcore-insights src/lib/plan/link.ts by
// gen_link_radio_golden.ts) at 910.525, 869.618 and 869.525 MHz, and against the server's contract fixtures
// (test/fixtures/plan_native/server/, copied from meshcore-insights src/test/fixtures/plan/).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/link_model.dart';
import 'package:meshsonar/core/plan_contract.dart';

import 'plan_golden.dart';

double _d(Object? v) => (v as num).toDouble();
Map<String, dynamic> _fx(String name) => jsonDecode(File('test/fixtures/plan_native/$name').readAsStringSync()) as Map<String, dynamic>;
PlanRadio _radio(Map r) => PlanRadio(freqMHz: _d(r['freqMHz']), bwKHz: _d(r['bwKHz']), sf: r['sf'] as int, cr: r['cr'] as int);

void main() {
  final g = _fx('link_radio_golden.json');
  final profiles = {
    for (final p in ((loadPlanGolden()['link'] as Map)['profiles'] as List).cast<Map<String, dynamic>>()) p['name'] as String: p,
  };
  final cases = (g['cases'] as List).cast<Map<String, dynamic>>();
  final ends = g['ends'] as Map<String, dynamic>;
  const a = PlanPoint(37.1, -80.2), b = PlanPoint(37.12, -80.14);

  test('the radio constants follow the radio: wavelength, noise floor and sensitivity at each preset', () {
    for (final r in (g['radios'] as List).cast<Map<String, dynamic>>()) {
      final radio = _radio(r['radio'] as Map);
      expect(lambdaFor(radio), closeTo(_d(r['lambdaM']), 1e-15), reason: '${radio.freqMHz}');
      expect(radioNoiseFloorDbm(radio), closeTo(_d(r['noiseFloorDbm']), 1e-12));
      expect(radioSensitivityDbm(radio), closeTo(_d(r['sensitivityDbm']), 1e-12));
    }
    expect(snrFloorForSf(7), -7.5);
    expect(snrFloorForSf(12), -20);
    expect(snrFloorForSf(20), -20, reason: 'clamped to SF12');
  });

  test('every radio x profile x height x clutter x direction: the budget and the plan-link answer match the website', () {
    expect(cases.length, 162);
    for (final c in cases) {
      final radio = _radio(c['radio'] as Map);
      final p = profiles[c['profile']]!;
      final ground = [for (final v in p['ground'] as List) _d(v)];
      final km = _d(p['km']);
      final cl = c['clutter'] as Map;
      final clutter = PlanClutter(canopyM: _d(cl['canopyM']), dbPerKm: _d(cl['dbPerKm']));
      final dir = PlanDirection.parse(c['direction']);
      final ha = _d(c['haM']), hb = _d(c['hbM']);
      final tag = '${radio.freqMHz} ${c['profile']} $ha/$hb ${cl['dbPerKm']} ${dir.wire}';
      final aTx = _d((ends['a'] as Map)['txDbm']), aG = _d((ends['a'] as Map)['gainDbi']);
      final bTx = _d((ends['b'] as Map)['txDbm']), bG = _d((ends['b'] as Map)['gainDbi']);

      final an = analyseLink(ground, km, ha, hb, radio: radio, clutter: clutter, txDbm: aTx, gainDbi: aG, bTxDbm: bTx, bGainDbi: bG);
      final raw = c['raw'] as Map;
      expect(an.fspl, closeTo(_d(raw['fsplDb']), 1e-9), reason: tag);
      expect(an.diffractionDb, closeTo(_d(raw['diffractionDb']), 1e-9), reason: tag);
      expect(an.clutterDb, closeTo(_d(raw['clutterDb']), 1e-9), reason: tag);
      expect(an.pathLossDb, closeTo(_d(raw['pathLossDb']), 1e-9), reason: tag);
      expect(an.abDb, closeTo(_d(raw['abDb']), 1e-9), reason: tag);
      expect(an.baDb, closeTo(_d(raw['baDb']), 1e-9), reason: tag);
      expect(an.los, raw['los'], reason: tag);

      final req = PlanLinkRequest(a: a, b: b, haM: ha, hbM: hb, radio: radio, clutter: clutter, direction: dir);
      final r = localPlanLink(req, ground, km: km, aTxDbm: aTx, bTxDbm: bTx, aGainDbi: aG, bGainDbi: bG);
      final w = c['answer'] as Map;
      expect(r.km, _d(w['km']), reason: tag);
      expect(r.fresnelClearancePct, _d(w['fresnelClearancePct']), reason: tag);
      expect(r.odds, _d(w['odds']), reason: tag);
      expect(r.verdict?.wire, w['verdict'], reason: tag);
      expect(r.marginDb, _d(w['marginDb']), reason: tag);
      expect(an.verdict(dir).wire, w['verdict'], reason: tag);
      final t = w['tightest'] as Map?;
      expect(r.tightest?.km, t == null ? null : _d(t['km']), reason: tag);
      expect(r.tightest?.raiseM, t == null ? null : _d(t['raiseM']), reason: tag);
      final rg = w['ridge'] as Map?;
      expect(r.ridge?.km, rg == null ? null : _d(rg['km']), reason: tag);
      expect(r.ridge?.at?.lat, rg == null ? null : _d(rg['lat']), reason: tag);
      expect(r.ridge?.at?.lon, rg == null ? null : _d(rg['lon']), reason: tag);
      expect(r.ridge?.groundM, rg == null ? null : _d(rg['groundM']), reason: tag);
      // The lower-level geometry agrees with the trimmed contract fields.
      final geo = linkGeometry(a, b, ha, hb, km, ground, lambda: lambdaFor(radio));
      if (t != null) {
        expect(geo.tightest!.end, t['end'], reason: tag);
        expect(geo.tightest!.clearanceM, _d(t['clearanceM']), reason: tag);
        expect(geo.tightest!.zoneM, _d(t['zoneM']), reason: tag);
      }
      if (rg != null) expect(geo.ridge!.aboveRayM, _d(rg['aboveRayM']), reason: tag);
    }
  });

  test('the goldens exercise all three verdicts at each frequency, and the frequency really changes the answer', () {
    for (final f in [910.525, 869.618, 869.525]) {
      final at = cases.where((c) => (c['radio'] as Map)['freqMHz'] == f).map((c) => (c['answer'] as Map)['verdict']).toSet();
      expect(at, containsAll(['likely', 'marginal', 'unlikely']), reason: '$f');
    }
    final short = [for (final v in profiles['short']!['ground'] as List) _d(v)];
    final us = analyseLink(short, _d(profiles['short']!['km']), 10, 10);
    final eu = analyseLink(short, _d(profiles['short']!['km']), 10, 10, radio: const PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8));
    expect(eu.fspl, lessThan(us.fspl));
    expect(eu.sensitivityDbm, -130.04119982655925);
    expect(eu.marginDb - us.marginDb, greaterThan(2.5), reason: 'SF8 gains 2.5 dB of sensitivity plus less free-space loss');
  });

  test('verdictOf: the 10 dB fade margin splits likely / marginal / unlikely', () {
    expect(fadeMarginDb, 10);
    expect(verdictOf(0), PlanVerdict.likely);
    expect(verdictOf(-0.1), PlanVerdict.marginal);
    expect(verdictOf(-10), PlanVerdict.marginal);
    expect(verdictOf(-10.1), PlanVerdict.unlikely);
    expect(fadeMarginWords, contains('10 dB'));
  });

  group('server contract fixtures', () {
    test('every fixture parses with the app contract', () {
      for (final n in ['plan-link.estimate', 'plan-link.measured']) {
        final r = PlanLinkResult.parse(_fx('server/$n.response.json'));
        expect(r.profile.groundM.length, greaterThan(2), reason: n);
        expect(r.verdict, isNotNull, reason: n);
      }
      expect(PlanLinkResult.parse(_fx('server/plan-link.measured.response.json')).measured!.echoes, 41);
      final one = PlanVerifyResult.parse(_fx('server/plan-verify.site.response.json'));
      expect(one.coveredKm2, greaterThan(0));
      expect(one.newAreaKm2, isNotNull);
      // The server's batch form ({sites:[...]} -> {results:[...]}) carries one single-site answer per site.
      final many = (_fx('server/plan-verify.sites.response.json')['results'] as List).cast<Map<String, dynamic>>();
      expect([for (final r in many) PlanVerifyResult.parse(r).coveredKm2 > 0], [true, true]);
      expect(PlanSuggestResult.parse(_fx('server/plan-suggest.response.json')).sites, isNotEmpty);
      expect(PlanSuggestResult.parse(_fx('server/plan-suggest.preparing.json')).preparing, isTrue);
    });

    test('the phone and the server judge the same link the same way (869.618 MHz SF8 fixture)', () {
      final req = _fx('server/plan-link.estimate.request.json');
      final res = _fx('server/plan-link.estimate.response.json');
      final server = PlanLinkResult.parse(res);
      final request = PlanLinkRequest(
        a: PlanPoint.tryParse(req['a'])!,
        b: PlanPoint.tryParse(req['b'])!,
        haM: _d(req['haM']),
        hbM: _d(req['hbM']),
        radio: PlanRadio.tryParse(req['radio'])!,
        clutter: PlanClutter.tryParse(req['clutter'])!,
        direction: PlanDirection.parse(req['direction']),
      );
      expect(request.radio.freqMHz, 869.618);
      // The server rounds the profile it sends to 0.1 m; recomputing from it lands within rounding of its own answer.
      final local = localPlanLink(request, server.profile.groundM, km: server.km);
      expect(local.verdict, server.verdict);
      expect(local.marginDb!, closeTo(server.marginDb!, 0.3));
      expect(local.odds!, closeTo(server.odds!, 0.005));
      expect(local.fresnelClearancePct!, closeTo(server.fresnelClearancePct!, 2));
      expect(local.ridge!.km, closeTo(server.ridge!.km, 0.06));
      expect(local.tightest!.raiseM, closeTo(server.tightest!.raiseM, 1.5));
      expect(local.provenance.model, onDeviceModelName);
      expect(local.provenance.confidence, PlanConfidenceLevel.estimate);
    });
  });
}
