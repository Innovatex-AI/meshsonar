// The coverage footprint maths (release 0.38 A9): grid decode, the received-power field, re-styling without a new request,
// the union and "how many sites see this spot", the band rebuild for answers without a grid, the verify loop.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan/link_model.dart' show radioNoiseFloorDbm, snrFloorForSf;
import 'package:meshsonar/core/plan/plan_analysis.dart' show offsetM;
import 'package:meshsonar/core/plan_contract.dart';
import 'package:meshsonar/ui/plan/modes/footprint_field.dart';

import 'coverage_kit.dart';

const _site = PlanPoint(40.0, -83.0);

SiteFootprint _fp(String id, PlanPoint at, {double Function(int r, int j)? m}) =>
    SiteFootprint.fromVerify(id, verifyAt(at.lat, at.lon, marginDb: m).raw, site: at, radio: PlanRadio.usDefault)!;

void main() {
  group('SiteFootprint', () {
    test('decodes the 0.5 dB grid into received power (margin + the run\'s sensitivity)', () {
      final f = _fp('a', _site);
      expect(f.fromBands, isFalse);
      expect(f.radials, 36);
      expect(f.samples, 30);
      expect(f.radiusM, 3000);
      // 500 m north: sample 5, margin 20 - 5 = 15 dB.
      expect(f.dbmAt(offsetM(_site, 500, 0)), closeTo(15 + kSensitivityDbm, 1e-3));
      // 1 km east: sample 10 on the 90 degree radial.
      expect(f.dbmAt(offsetM(_site, 0, 1000)), closeTo(10 + kSensitivityDbm, 1e-3));
      expect(f.dbmAt(offsetM(_site, 5000, 0)), isNull, reason: 'outside the sweep');
    });

    test('a radial-dependent grid lands on the right bearing', () {
      final f = _fp('a', _site, m: (r, j) => r == 9 ? 30 : -10); // radial 9 = 90 degrees (east)
      expect(f.dbmAt(offsetM(_site, 0, 800))! - kSensitivityDbm, closeTo(30, 0.01));
      expect(f.dbmAt(offsetM(_site, 800, 0))! - kSensitivityDbm, closeTo(-10, 0.01));
    });

    test('a grid that does not add up falls back to the band polygons', () {
      final j = jsonDecode(File('test/fixtures/plan_server/plan-verify.site.response.json').readAsStringSync()) as Map<String, dynamic>;
      // The committed server fixture carries a shortened grid (48 bytes for 360 x 83): the bands rebuild it.
      final f = SiteFootprint.fromVerify('a', j, site: const PlanPoint(37.27, -79.94), radio: PlanRadio.usDefault)!;
      expect(f.fromBands, isTrue);
      expect(f.radiusM, greaterThan(4000));
      final sens = (j['model'] as Map)['sensitivityDbm'] as num;
      // Every swept sample is one of the band middles.
      final margins = {for (final v in f.rxDbm) if (!v.isNaN) (v - sens).round()};
      expect(margins.difference({-6, 3, 9, 15}), isEmpty);
      // The fixture keeps two radials (north): the rebuilt sectors give each distance its band, nothing to the south.
      const site = PlanPoint(37.27, -79.94);
      double? m(double northM) {
        final v = f.dbmAt(offsetM(site, northM, 0));
        return v == null ? null : (v - sens).toDouble();
      }

      expect(m(1500), closeTo(15, 0.01), reason: 'solid out to about 3.15 km');
      expect(m(3215), closeTo(9, 0.01), reason: 'usable');
      expect(m(3335), closeTo(3, 0.01), reason: 'fringe');
      expect(m(4500), closeTo(-6, 0.01), reason: 'below');
      expect(f.dbmAt(offsetM(site, -1000, 0)), isNull, reason: 'no polygon to the south');
    });

    test('an answer with numbers only has no footprint', () {
      expect(SiteFootprint.fromVerify('a', const {'coveredKm2': 3}, site: _site, radio: PlanRadio.usDefault), isNull);
    });
  });

  group('FootprintField', () {
    test('one site: area at the decode limit, then re-styled for SF12 and a stricter minimum with no new data', () {
      final f = FootprintField.build([_fp('a', _site)])!;
      final noise = radioNoiseFloorDbm(PlanRadio.usDefault);
      final sf7 = f.classify(noiseDbm: noise, minSnrDb: snrFloorForSf(7));
      // Decodes while margin >= 0: 20 samples x 100 m = a 2 km disc, about 12.6 km².
      expect(sf7.areaKm2, closeTo(12.57, 1.2));
      expect(sf7.overlapKm2, 0);
      // SF12 decodes 12.5 dB lower: the same received power reaches farther (margin + 12.5 >= 0 out to 3 km, the sweep's end).
      final sf12 = f.classify(noiseDbm: noise, minSnrDb: snrFloorForSf(12));
      expect(sf12.areaKm2, greaterThan(sf7.areaKm2 * 1.8));
      final strict = f.classify(noiseDbm: noise, minSnrDb: snrFloorForSf(7) + 10);
      expect(strict.areaKm2, closeTo(3.14, 0.6), reason: '10 dB to spare: a 1 km disc');
    });

    test('two sites: overlap, the count per cell, what the planned site adds to the existing one', () {
      final b = offsetM(_site, 0, 3000);
      final f = FootprintField.build([_fp('a', _site), _fp('b', b)])!;
      final v = f.classify(noiseDbm: kNoiseDbm, minSnrDb: -7.5, existing: {0});
      final mid = f.cellAt(offsetM(_site, 0, 1500))!;
      expect(v.count[mid], 2, reason: 'half way: both 2 km discs reach');
      expect(v.count[f.cellAt(offsetM(_site, 0, -1500))!], 1);
      expect(v.overlapKm2, greaterThan(0.5));
      expect(v.areaKm2, closeTo(v.siteKm2[0] + v.siteKm2[1] - v.overlapKm2, 0.01));
      expect(v.existingKm2, closeTo(v.siteKm2[0], 0.01));
      expect(v.addedKm2, closeTo(v.siteKm2[1] - v.overlapKm2, 0.01));
    });

    test('spotReport: strongest first, sites out of reach left out', () {
      final b = offsetM(_site, 0, 3000);
      final sites = [_fp('a', _site), _fp('b', b)];
      final r = spotReport(sites, offsetM(_site, 0, 1000), noiseDbm: kNoiseDbm);
      expect([for (final x in r) x.$1], [0, 1]);
      expect(r.first.$2, closeTo(10 + kSensitivityDbm - kNoiseDbm, 0.01));
      expect(spotReport(sites, offsetM(_site, 0, -2500), noiseDbm: kNoiseDbm).map((x) => x.$1), [0]);
    });

    test('a wide plan keeps the cell count bounded', () {
      final sites = [for (var i = 0; i < 10; i++) _fp('n$i', offsetM(_site, 0, i * 4000.0))];
      final f = FootprintField.build(sites, maxCells: 20000)!;
      expect(f.rows * f.cols, lessThanOrEqualTo(21000));
    });
  });
}
