// M3-2 data rules (core/m3_data.dart), the same as the website's src/lib/map/m3-data.ts and estimated.ts: Redundancy cells, Links by
// SNR lines and the server's estimated positions.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/m3_data.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/region_m3_api.dart';
import 'package:meshsonar/core/region_repeaters_api.dart' show RegionRepeatersException;

final _def = MapDefinition.parse(File('assets/map/map-definition.json').readAsStringSync());

String _k(String c) => c * 64;

/// nodes: 0 located repeater, 1 located room, 2 located repeater, 3 UNlocated repeater, 4 located companion.
List<Object?> get _nodes => [
  [_k('a'), 'Alpha', 'repeater', 39.96, -83.0],
  [_k('b'), 'Bravo', 'room', 40.0, -83.1],
  [_k('c'), null, 'repeater', 40.1, -82.9],
  [_k('d'), 'Delta', 'repeater', null, null],
  [_k('e'), 'Echo', 'companion', 39.9, -83.3],
];

void main() {
  group('Redundancy', () {
    test('distinct located repeaters per cell; unlocated nodes and companions are not counted; steps cap at 4', () {
      final g = LinkGraph.fromJson({
        'nodes': _nodes,
        'drive': [
          [0, 'abcdef012345678', 5, -3.0],
          [0, 'abcdef012345678', 2, 1.0], // the same repeater again: still one
          [1, 'abcdef012345678', 4, 2.0],
          [2, 'abcdef012345679', 3, 0.0],
          [3, 'abcdef012345679', 3, 0.0], // unlocated repeater: not counted
          [4, 'abcdef012345679', 3, 0.0], // a companion: not counted
          [9, 'abcdef01234567a', 1, 0.0], // index outside the graph
          [0, 'NOT-A-CELL', 1, 0.0],
        ],
        'driveUnresolved': 3,
      })!;
      final r = redundancyCells(g);
      expect([for (final c in r.cells) (c.h3, c.n)], [('abcdef012345678', 2), ('abcdef012345679', 1)]);
      expect(r.single, 1);
      expect(r.unresolved, 3, reason: 'the layer says how many ids it could not count');
      expect(redundancyStep(1), 1);
      expect(redundancyStep(3), 3);
      expect(redundancyStep(9), 4, reason: '4 or more');
      expect(redundancyCells(null).cells, isEmpty);
    });
  });

  group('Links by SNR', () {
    List<Object?> link(int a, int b, String src, num? snr, num? n, [num? km]) => [a, b, src, null, snr, null, null, n, null, null, null, km];

    test('one line per located pair; measured wins over reported; relaying only has no SNR (band 0, neutral); lines are by packets', () {
      final g = LinkGraph.fromJson({
        'nodes': _nodes,
        'links': [
          link(0, 1, 'reported', -2.0, 40, 8.2),
          link(1, 0, 'measured', 6.0, 12), // same pair, other direction: ONE line, the measured SNR
          link(0, 2, 'observed', null, 480),
          link(0, 2, 'observed', null, 20),
          link(0, 3, 'reported', 5.0, 9), // an end without a position: no line
          link(0, 4, 'reported', 5.0, 9), // a companion: no line
          link(0, 0, 'reported', 5.0, 9), // a loop: no line
        ],
      })!;
      final l = snrLinks(g, _def);
      expect(l, hasLength(2));
      expect(l.first.packets, 500, reason: 'sorted by packets: observed 480 + 20');
      expect(l.first.band, 0);
      expect(l.first.snr, isNull);
      expect(l.first.source, 'observed');
      final m = l[1];
      expect(m.source, 'measured');
      expect(m.snr, 6.0);
      expect(m.band, 4, reason: 'SF7 floor -7.5: margin 13.5 dB is Good');
      expect(m.km, 8.2);
      expect(m.packets, 40, reason: 'the larger report count of the pair');
      expect(m.aLabel, 'Alpha');
      expect(l.first.bLabel, _k('c').substring(0, 8), reason: 'no name: the key prefix');
      expect(snrLinkText(m), 'Alpha to Bravo: 6.0 dB SNR, 40 packets');
      expect(snrLinkText(l.first), contains('SNR not measured'));
    });

    test('the band follows the spreading factor of the default preset', () {
      final g = LinkGraph.fromJson({'nodes': _nodes, 'links': [link(0, 1, 'measured', -5.0, 3)]})!;
      expect(snrLinks(g, _def, sf: 7).single.band, 2, reason: '2.5 dB over the SF7 floor: Weak');
      expect(snrLinks(g, _def, sf: 10).single.band, 4, reason: 'SF10 floor is -15: 10 dB margin: Good');
    });

    test('width is a log scale from the definition: 1 packet = min, 500 = max, clamped', () {
      expect(linkWidth(1, _def), 1.2);
      expect(linkWidth(500, _def), 5);
      expect(linkWidth(100000, _def), 5);
      expect(linkWidth(0, _def), 1.2);
      final mid = linkWidth(22, _def);
      expect(mid, greaterThan(1.2));
      expect(mid, lessThan(5));
    });
  });

  group('estimated positions (server-computed, drawn as given)', () {
    final answer = {
      'builtAt': '2026-11-12T10:00:00Z',
      'estimates': [
        {'key': _k('D'), 'name': 'Delta', 'role': 'repeater', 'lat': 40.01, 'lon': -83.02, 'confidence': 'high', 'anchors': 3, 'spreadKm': 4.5},
        {'key': _k('e'), 'name': null, 'role': 'room', 'lat': 40.2, 'lon': -83.2, 'confidence': 'low', 'anchors': 1, 'spreadKm': null},
        {'key': _k('f'), 'role': 'repeater', 'lat': 40.3, 'lon': -83.3, 'confidence': 'medium', 'anchors': 2, 'spreadKm': 20},
        {'key': _k('1'), 'role': 'repeater', 'lat': 0, 'lon': 0, 'confidence': 'high', 'anchors': 3}, // 0/0: never drawn
        {'key': _k('2'), 'role': 'repeater', 'lat': 40.3, 'lon': -83.3, 'confidence': 'sure', 'anchors': 3}, // unknown confidence
        {'key': _k('3'), 'role': 'repeater', 'lat': null, 'lon': -83.3, 'confidence': 'low', 'anchors': 1},
      ],
    };

    test('parses; a row with no usable position or confidence is skipped, never guessed', () {
      final a = EstimatesAnswer.fromJson(answer)!;
      expect(a.estimates.map((e) => e.key), [_k('d'), _k('e'), _k('f')], reason: 'keys are lower-case');
      expect(a.estimates.first.lat, 40.01);
      expect(a.estimates.first.lon, -83.02, reason: 'positions are used exactly as given');
      expect(a.estimates[1].spreadKm, isNull);
      expect(a.builtAt, DateTime.utc(2026, 11, 12, 10));
      expect(EstimatesAnswer.fromJson({'nope': 1}), isNull);
      expect(EstimatesAnswer.fromJson('x'), isNull);
    });

    test('paler for low confidence: the definition\'s opacity per confidence (.8 / .6 / .4)', () {
      final a = EstimatesAnswer.fromJson(answer)!.estimates;
      expect(a.map((e) => e.opacity(_def)), [0.8, 0.4, 0.6]);
      expect(a[0].opacity(_def), greaterThan(a[1].opacity(_def)));
      expect(a[0].confidenceText(_def), contains('3 or more located neighbours'));
      expect(a[1].confidenceText(_def), contains('1 located neighbour'));
    });

    test('only estimates whose repeater still has no position in the roster are drawn', () {
      final a = EstimatesAnswer.fromJson(answer)!;
      expect(estimatesToDraw(a, {_k('d')}).map((e) => e.key), [_k('e'), _k('f')]);
      expect(estimatesToDraw(a, const {}), hasLength(3));
      expect(estimatesToDraw(const EstimatesAnswer(null, []), {_k('d')}), isEmpty, reason: 'when the server omits them none is shown');
    });
  });

  group('the website fixture answers (the same bytes the web test reads)', () {
    test('the symbols the layers draw with are in the definition', () {
      expect(_def.symbol('estimated')['opacity'], {'high': 0.8, 'medium': 0.6, 'low': 0.4});
      expect(((_def.symbol('redundancy')['colours'] as Map)['light'] as List), hasLength(4));
      expect(_def.symbol('snrLink')['widthPx'], [1.2, 5]);
    });
  });

  group('the two region answers over HTTP', () {
    test('URLs: estimates; link graph for Links by SNR (all sources) and for Redundancy alone (measured + drive rows)', () {
      expect(regionEstimatesUri('https://cmh.meshsonar.com', 'cmh').toString(), 'https://cmh.meshsonar.com/api/cmh/region-repeater-estimates');
      expect(regionEstimatesUri('https://meshsonar.com', 'day').toString(), 'https://day.meshsonar.com/api/cmh/region-repeater-estimates', reason: 'the hub address plus a slug is the region host');
      expect(regionLinkGraphUri('https://cmh.meshsonar.com', 'cmh', allSources: true, drive: false).toString(), 'https://cmh.meshsonar.com/api/cmh/region-link-graph?drive=0');
      expect(regionLinkGraphUri('https://cmh.meshsonar.com', 'cmh', allSources: true, drive: true).toString(), 'https://cmh.meshsonar.com/api/cmh/region-link-graph?drive=1');
      expect(regionLinkGraphUri('https://cmh.meshsonar.com', 'cmh', allSources: false, drive: true).toString(), 'https://cmh.meshsonar.com/api/cmh/region-link-graph?sources=measured&drive=1');
    });

    test('fetch parses; sends no identifier; a 404 / 500 / bad body is one RegionRepeatersException', () async {
      final seen = <http.Request>[];
      final ok = MockClient((r) async {
        seen.add(r);
        return http.Response(jsonEncode(r.url.path.endsWith('estimates') ? {'estimates': <Object>[], 'builtAt': null} : {'nodes': _nodes, 'links': <Object>[], 'drive': <Object>[]}), 200);
      });
      final e = await fetchRegionEstimates('https://cmh.meshsonar.com', 'cmh', client: ok);
      expect(e.estimates, isEmpty);
      final g = await fetchRegionLinkGraph('https://cmh.meshsonar.com', 'cmh', allSources: true, drive: false, client: ok);
      expect(g.nodes, hasLength(5));
      for (final r in seen) {
        expect(r.headers.keys.map((k) => k.toLowerCase()), isNot(contains('x-driver-key')), reason: 'public data: no identifier');
      }
      for (final code in [404, 500]) {
        await expectLater(fetchRegionEstimates('https://cmh.meshsonar.com', 'cmh', client: MockClient((_) async => http.Response('x', code))), throwsA(isA<RegionRepeatersException>()));
      }
      await expectLater(fetchRegionLinkGraph('https://cmh.meshsonar.com', 'cmh', allSources: true, drive: false, client: MockClient((_) async => http.Response('not json', 200))), throwsA(isA<RegionRepeatersException>()));
      await expectLater(fetchRegionEstimates('https://cmh.meshsonar.com', 'cmh', client: MockClient((_) async => http.Response('[]', 200))), throwsA(isA<RegionRepeatersException>()));
    });
  });
}
