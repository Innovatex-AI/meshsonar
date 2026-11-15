// The Master Planner wire contract (lib/core/plan_contract.dart; plan-tab-master-planner-2026-11-15.md section 4.4 as
// corrected by build-0.38-final-plan section 5.4): requests never carry a region, the wizard point is rounded to ~1 km,
// and every response reads model / terrain / asOf / confidence.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/plan_contract.dart';

void main() {
  group('requests', () {
    test('plan-link: ends to 5 places, heights, radio, clutter, direction; no region, keys only when known', () {
      final j = const PlanLinkRequest(
        a: PlanPoint(39.9612345678, -82.9987654321),
        b: PlanPoint(40.1, -83.2),
        haM: 12,
        hbM: 2,
        radio: PlanRadio(freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 8),
        direction: PlanDirection.up,
        bKey: 'ab12',
      ).toJson();
      expect(j['a'], {'lat': 39.96123, 'lon': -82.99877});
      expect(j['haM'], 12);
      expect(j['hbM'], 2);
      expect(j['radio'], {'freqMHz': 869.618, 'bwKHz': 62.5, 'sf': 8, 'cr': 8});
      expect(j['clutter'], {'canopyM': 15, 'dbPerKm': 13.3});
      expect(j['direction'], 'up');
      expect(j['bKey'], 'ab12');
      expect(j.containsKey('aKey'), isFalse);
      expect(j.containsKey('region'), isFalse);
    });

    test('plan-verify: site, antenna, receiver and mount; no region', () {
      final j = const PlanVerifyRequest(site: PlanPoint(39.9, -83), antennaM: 18, receiverM: 1.5, mount: PlanMount.tree).toJson();
      expect(j['site'], {'lat': 39.9, 'lon': -83.0});
      expect(j['antennaM'], 18);
      expect(j['receiver'], 'handheld');
      expect(j['receiverM'], 1.5);
      expect(j['mount'], 'tree');
      expect(j['direction'], 'both');
      expect(j['radio'], PlanRadio.usDefault.toJson());
      expect(j.containsKey('region'), isFalse);
    });

    test('plan-suggest: the wizard point goes rounded to about 1 km, the limit is capped at 20', () {
      final j = const PlanSuggestRequest(
        bounds: PlanBounds(south: 39.81234, north: 40.21234, west: -83.21234, east: -82.81234),
        goal: PlanGoal.links,
        limit: 99,
        near: PlanPoint(39.987654, -83.012345),
      ).toJson();
      expect(j['near'], {'lat': 39.99, 'lon': -83.01}, reason: 'never more precise than ~1 km');
      expect(j['limit'], PlanSuggestRequest.maxLimit);
      expect(j['goal'], 'links');
      expect(j['bounds'], {'south': 39.8123, 'north': 40.2123, 'west': -83.2123, 'east': -82.8123});
      expect(j.containsKey('region'), isFalse);
      expect(jsonEncode(j).contains('39.987654'), isFalse);
      expect(const PlanSuggestRequest(bounds: PlanBounds(south: 0, north: 1, west: 0, east: 1)).toJson().containsKey('near'), isFalse);
    });
  });

  group('responses', () {
    test('plan-link: profile, clearance, tightest point, ridge, odds, verdict, measured evidence, provenance', () {
      final r = PlanLinkResult.parse({
        'km': 12.4,
        'profile': {'distanceKm': [0, 6.2, 12.4], 'groundM': [250, 310, 240]},
        'fresnelClearancePct': -12.5,
        'tightest': {'km': 6.2, 'raiseM': 14.0},
        'ridge': {'km': 6.2, 'lat': 40.0, 'lon': -83.1, 'groundM': 310},
        'odds': 0.31,
        'verdict': 'marginal',
        'marginDb': 2.5,
        'measured': {'echoes': 41, 'meanSnr': -6.5, 'lastAt': '2026-11-14T10:00:00Z', 'source': 'neighbor reports'},
        'model': 'profile+bullington+clutter v1',
        'terrain': {'source': 'AWS Terrain Tiles'},
        'asOf': '2026-11-15T00:00:00Z',
        'confidence': {'level': 'calibrated', 'note': 'calibrated on Columbus'},
        'cached': true,
      });
      expect(r.km, 12.4);
      expect(r.profile.groundM, [250, 310, 240]);
      expect(r.fresnelClearancePct, -12.5);
      expect(r.tightest!.raiseM, 14);
      expect(r.ridge!.at, const PlanPoint(40.0, -83.1));
      expect(r.verdict, PlanVerdict.marginal);
      expect(r.measured!.echoes, 41);
      expect(r.measured!.lastAt, DateTime.utc(2026, 11, 14, 10));
      expect(r.provenance.model, 'profile+bullington+clutter v1');
      expect(r.provenance.terrain, 'AWS Terrain Tiles');
      expect(r.provenance.asOf, DateTime.utc(2026, 11, 15));
      expect(r.provenance.confidence, PlanConfidenceLevel.calibrated);
      expect(r.provenance.confidenceNote, 'calibrated on Columbus');
      expect(r.cached, isTrue);
    });

    test('plan-link: missing extras take defaults; no profile is unreadable', () {
      final r = PlanLinkResult.parse({
        'profile': {'distanceKm': [0, 1], 'groundM': [1, 2]},
      });
      expect(r.km, 1);
      expect(r.measured, isNull);
      expect(r.ridge, isNull);
      expect(r.provenance.confidence, PlanConfidenceLevel.estimate);
      expect(() => PlanLinkResult.parse({'km': 3}), throwsFormatException);
    });

    test('plan-verify: the coverage run plus what it adds; the whole body is kept for the footprint layer', () {
      final body = {
        'coveredKm2': 88.5,
        'bands': [
          {'id': 'b5', 'label': 'Strong', 'areaKm2': 20},
        ],
        'links': [
          {'publicKey': 'aa', 'name': 'Hilltop', 'km': 9, 'marginDb': 11},
        ],
        'newAreaKm2': 31.2,
        'newPeople': 4200,
        'footprint': {'type': 'FeatureCollection', 'features': []},
        'confidence': 'estimate',
      };
      final r = PlanVerifyResult.parse(body);
      expect(r.coveredKm2, 88.5);
      expect(r.bands.single.label, 'Strong');
      expect(r.links.single.name, 'Hilltop');
      expect(r.newAreaKm2, 31.2);
      expect(r.newPeople, 4200);
      expect(r.raw['footprint'], isA<Map>());
      expect(() => PlanVerifyResult.parse({'nothing': 1}), throwsFormatException);
    });

    test('plan-suggest: sites with reasons and gains; bad sites are skipped; preparing is honest', () {
      final r = PlanSuggestResult.parse({
        'pool': 1873,
        'sites': [
          {
            'id': 's1',
            'lat': 40.01,
            'lon': -83.02,
            'groundM': 290,
            'heightAboveM': 24,
            'kind': 'tree',
            'mount': 'tree',
            'osm': {'id': 123, 'operator': 'City'},
            'score': 140,
            'reason': 'Tree at 24 m sees 3 repeaters',
            'gain': {
              'newAreaKm2': 12.5,
              'newPeople': 2215,
              'newLinks': [
                {'key': 'bb', 'name': 'Ridge', 'km': 6.1, 'odds': 0.8, 'tier': 'likely'},
              ],
              'redundancy': 'removes_spof',
              'spofName': 'Downtown',
            },
            'evidence': {'deadZoneDrives': 7},
          },
          {'id': 'no-position'},
        ],
        'notes': ['terrain: bare earth', 3],
        'asOf': '2026-11-15T01:00:00Z',
      });
      expect(r.pool, 1873);
      expect(r.sites, hasLength(1));
      final s = r.sites.single;
      expect(s.score, 100, reason: 'clamped to 0-100');
      expect(s.mount, PlanMount.tree);
      expect(s.osmId, '123');
      expect(s.gain.newLinks.single.tier, 'likely');
      expect(s.gain.redundancy, PlanRedundancyGain.removesSpof);
      expect(s.gain.spofName, 'Downtown');
      expect(s.deadZoneDrives, 7);
      expect(r.notes, ['terrain: bare earth']);
      expect(PlanSuggestResult.parse({'preparing': true}).preparing, isTrue);
      expect(() => PlanSuggestResult.parse({'pool': 3}), throwsFormatException);
    });
  });
}
