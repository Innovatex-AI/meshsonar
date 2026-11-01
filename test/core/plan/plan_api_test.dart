import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/plan/plan_api.dart';
import 'package:meshsonar/core/plan/plan_store.dart';

// Wire shapes: meshcore-insights src/server/cmh.server.ts scoreLink, src/lib/tools/coverage-run.ts CoverageResult,
// src/lib/tools/airtime-load.ts LoadAnalysis (+ airtime.server.ts fetch/region fields).
Map<String, dynamic> scoreBody() => {
      'km': 3.0,
      'heightsM': {'a': 6, 'b': 6},
      'bullingtonDb': 4.2,
      'terrainModel': {'odds': 0.31, 'tier': 'Strong', 'note': 'n'},
      'profile': {
        'distanceKm': [0, 1.5, 3.0],
        'groundM': [250.1, 262.0, 255.5],
      },
      'source': 'AWS Terrain Tiles (Terrarium), zoom 14, 100 samples',
    };

Map<String, dynamic> paintBody() => {
      'mode': 'coverage',
      'params': {'mode': 'coverage', 'lat': 39.96, 'lon': -82.99, 'antennaFt': 33, 'txDbm': 22, 'gainDbi': 3, 'receiver': 'handheld', 'radiusKm': 10, 'searchKm': 1.5, 'clutter': {'endpointDb': 0, 'dbPerKm': 13.3, 'canopyM': 15}},
      'model': {'sensitivityDbm': -127.5, 'note': 'Estimate'},
      'terrain': {'source': 'AWS Terrain Tiles', 'zoom': 12, 'pixelM': 30, 'tiles': 4, 'fetched': 4},
      'sweep': {'radials': 90, 'stepM': 100, 'samples': 9000, 'groundM': 240.5},
      'bands': [
        {'id': 'below', 'label': 'Below 0 dB', 'areaKm2': 100.0},
        {'id': 'fringe', 'label': '0–6 dB', 'areaKm2': 20.5},
        {'id': 'usable', 'label': '6–12 dB', 'areaKm2': 10.0},
        {'id': 'solid', 'label': 'Over 12 dB', 'areaKm2': 4.25},
      ],
      'coveredKm2': 34.75,
      'population': {'inRadius': 12000, 'covered': 5000, 'newlyCovered': 1800, 'liveRepeaters': 3},
      'links': [
        {'publicKey': 'aa' * 32, 'keyShort': 'aaaaaaaa', 'name': 'Hilltop', 'piece': 'p', 'km': 4.2, 'marginDb': 7.5, 'downDb': 7.5, 'upDb': 9.0}
      ],
      'footprint': {
        'type': 'FeatureCollection',
        'features': [
          {
            'type': 'Feature',
            'properties': {'band': 'solid', 'label': 'Over 12 dB'},
            'geometry': {
              'type': 'MultiPolygon',
              'coordinates': [
                [
                  [
                    [-82.99, 39.96],
                    [-82.98, 39.97],
                    [-82.97, 39.96],
                    [-82.99, 39.96]
                  ]
                ]
              ]
            }
          }
        ]
      },
      'cached': true,
      'computedAt': '2026-11-01T10:00:00.000Z',
    };

Map<String, dynamic> loadBody() => {
      'windowStart': '2026-10-31T00:00:00Z',
      'windowEnd': '2026-11-01T00:00:00Z',
      'hours': 24,
      'flagPct': 10,
      'radio': {'sf': 7, 'bwKHz': 62.5, 'cr': 5, 'preamble': 32},
      'counts': {'packets': 10, 'observations': 30, 'transmissions': 20, 'skipped': 0, 'outOfWindow': 0},
      'observers': [
        {'id': 'o1', 'name': 'INNO-OB-1', 'observations': 30, 'airtimeS': 120.5, 'meanPct': 0.14, 'peakPct': 2.5, 'peakHour': '2026-10-31T17:00:00Z', 'hoursOver': 0, 'hourly': [], 'mix': {'fixedS': 10.0, 'floodByHopS': [1.0, 2.0], 'advertByHopS': [0.5]}, 'lastHourObs': 1}
      ],
      'byType': [
        {'type': 'ADVERT', 'transmissions': 10, 'airtimeS': 50.0, 'heardS': 90.0}
      ],
      'talkers': [
        {'key': 'h:ab', 'fullKey': false, 'name': null, 'transmissions': 4, 'airtimeS': 9.0, 'originatedS': 3.0, 'relayedS': 6.0}
      ],
      'floodHops': [
        {'hops': 0, 'airtimeS': 1.0, 'transmissions': 2}
      ],
      'lastHourTransmissions': 5,
      'region': 'CMH',
      'generatedAt': '2026-11-01T00:00:00Z',
      'cached': false,
      'fetch': {'pages': 1, 'pageSize': 2000, 'maxPages': 8, 'fetched': 10, 'total': 10, 'truncated': false, 'ms': 800},
    };

http.Response _json(Object b, [int status = 200]) => http.Response(jsonEncode(b), status, headers: {'content-type': 'application/json'});

void main() {
  test('score-link: the profile is parsed, requested with rounded coordinates and stored', () async {
    late http.Request seen;
    final store = PlanStore();
    final api = ScoreLinkApi('https://day.meshsonar.com/', store, client: () => MockClient((r) async {
          seen = r;
          return _json(scoreBody());
        }));
    final r = await api.profile(39.960001234, -82.99, 39.97, -82.95);
    expect(r.ok, isTrue);
    expect(seen.url.toString(), 'https://day.meshsonar.com/api/cmh/score-link');
    expect(seen.method, 'POST');
    final sent = jsonDecode(seen.body) as Map;
    expect(sent['a'], {'lat': 39.96, 'lon': -82.99});
    expect(sent.keys.toSet(), {'a', 'b', 'haM', 'hbM'}, reason: 'nothing but the two points and default heights leaves the phone');
    expect(r.data!.groundM, [250.1, 262.0, 255.5]);
    expect(r.data!.km, 3.0);
    expect(r.data!.serverOdds, 0.31);
    expect(r.offlineAsOf, isNull);
  });

  test('offline: a network failure serves the stored answer for the same request, labelled with when it was fetched', () async {
    final store = PlanStore(clock: () => DateTime.utc(2026, 11, 1, 8));
    var online = true;
    final api = ScoreLinkApi('https://x.test', store, client: () => MockClient((r) async {
          if (!online) throw http.ClientException('offline');
          return _json(scoreBody());
        }));
    expect((await api.profile(1, 2, 1.01, 2.01)).ok, isTrue);
    online = false;
    final again = await api.profile(1, 2, 1.01, 2.01);
    expect(again.ok, isTrue);
    expect(again.offlineAsOf, DateTime.utc(2026, 11, 1, 8));
    final other = await api.profile(5, 6, 5.01, 6.01);
    expect(other.ok, isFalse);
    expect(other.error, 'No connection to the server.');
  });

  test('a 4xx is the server sentence and never falls back to a stored copy; 5xx falls back', () async {
    final store = PlanStore();
    var status = 200;
    final api = ScoreLinkApi('https://x.test', store, client: () => MockClient((r) async => status == 200 ? _json(scoreBody()) : _json({'error': 'points more than 40 km apart'}, status)));
    await api.profile(1, 2, 1.01, 2.01);
    status = 400;
    final bad = await api.profile(1, 2, 1.01, 2.01);
    expect(bad.error, 'points more than 40 km apart');
    status = 502;
    final down = await api.profile(1, 2, 1.01, 2.01);
    expect(down.ok, isTrue);
    expect(down.offlineAsOf, isNotNull);
    status = 429;
    expect((await api.profile(1, 2, 1.01, 2.01)).error, contains('Too many requests'));
  });

  test('a profile with fewer than 3 samples is refused as unreadable', () async {
    final b = scoreBody();
    (b['profile'] as Map)['groundM'] = [1.0];
    (b['profile'] as Map)['distanceKm'] = [0.0];
    final api = ScoreLinkApi('https://x.test', PlanStore(), client: () => MockClient((r) async => _json(b)));
    expect((await api.profile(1, 2, 1.01, 2.01)).error, 'The server sent something unreadable.');
  });

  test('coverage painter: footprint rings, bands, people and links parse; the request carries only the point and the model settings', () async {
    late http.Request seen;
    final api = CoveragePainterApi('https://cmh.meshsonar.com', PlanStore(), client: () => MockClient((r) async {
          seen = r;
          return _json(paintBody());
        }));
    final r = await api.paint(const PainterParams(lat: 39.960004, lon: -82.99, antennaFt: 40));
    expect(seen.url.path, '/api/cmh/coverage');
    final sent = jsonDecode(seen.body) as Map;
    expect(sent['lat'], 39.96);
    expect(sent.keys.toSet(), {'mode', 'lat', 'lon', 'antennaFt', 'txDbm', 'gainDbi', 'receiver', 'radiusKm'});
    final d = r.data!;
    expect(d.coveredKm2, 34.75);
    expect(d.bands.map((b) => b.id), ['below', 'fringe', 'usable', 'solid']);
    expect(d.footprint.single.id, 'solid');
    expect(d.footprint.single.rings.single.first, (39.96, -82.99), reason: 'GeoJSON lon/lat becomes lat/lon');
    expect((d.peopleInRadius, d.peopleCovered, d.peopleNew), (12000, 5000, 1800));
    expect(d.links.single.name, 'Hilltop');
    expect(d.serverCached, isTrue);
    expect(d.computedAt, DateTime.utc(2026, 11, 1, 10));
  });

  test('best-pole answers are not accepted by the painter parser', () {
    expect(() => PainterResult.parse({'mode': 'best-pole'}), throwsFormatException);
  });

  test('airtime load: observers, types, talkers and hop rows parse; a region without it gets the server sentence', () async {
    final api = AirtimeLoadApi('https://cmh.meshsonar.com', PlanStore(), client: () => MockClient((r) async {
          expect(r.url.queryParameters['hours'], '24');
          return _json(loadBody());
        }));
    final d = (await api.load()).data!;
    expect((d.sf, d.bwKHz, d.cr), (7, 62.5, 5));
    expect(d.observers.single.name, 'INNO-OB-1');
    expect(d.observers.single.peakPct, 2.5);
    expect(d.observers.single.mix!.floodByHopS, [1.0, 2.0]);
    expect(d.byType.single.type, 'ADVERT');
    expect(d.talkers.single.relayedS, 6.0);
    expect(d.floodHops.single.transmissions, 2);
    expect(d.lastHourTransmissions, 5);
    expect(d.truncated, isFalse);

    final none = AirtimeLoadApi('https://x.test', PlanStore(), client: () => MockClient((r) async => _json({'error': 'Live channel load is not available in this region yet', 'unavailable': true}, 404)));
    expect((await none.load()).error, 'Live channel load is not available in this region yet');
  });

  test('PlanStore round-trips through disk and evicts the oldest beyond its cap', () async {
    final dir = await Directory.systemTemp.createTemp('planstore');
    addTearDown(() async { if (await dir.exists()) await dir.delete(recursive: true); });
    final s = PlanStore(dir: dir, maxEntries: 2);
    await s.write('a', '{"x":1}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await s.write('b', '{"x":2}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await s.write('c', '{"x":3}');
    final fresh = PlanStore(dir: dir, maxEntries: 2);
    expect(await fresh.read('a'), isNull);
    expect((await fresh.read('c'))!.body, '{"x":3}');
    await fresh.clear();
    expect(await PlanStore(dir: dir).read('c'), isNull);
  });
}
