// HttpCmatClient's Master Planner and MQTT preset calls (release 0.38): the dispatcher paths under /api/cmh, POST JSON
// without a region (the server's Host is the region), no driver key, server errors as CmatException, ETag on presets.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';

http.Response _json(Object body, [int status = 200, Map<String, String> headers = const {}]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json', ...headers});

void main() {
  test('plan-link: POST /api/cmh/plan-link with the request body, no key, no region; the answer is parsed', () async {
    late http.Request seen;
    final c = HttpCmatClient(Uri.parse('https://cmh.meshsonar.com'), client: MockClient((req) async {
      seen = req;
      return _json({
        'km': 2,
        'profile': {'distanceKm': [0, 1, 2], 'groundM': [200, 230, 210]},
        'verdict': 'likely',
        'terrain': 'AWS Terrain Tiles',
      });
    }));
    final r = await c.planLink(const PlanLinkRequest(a: PlanPoint(40, -83), b: PlanPoint(40.01, -83.01)));
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://cmh.meshsonar.com/api/cmh/plan-link');
    expect(seen.headers.containsKey('x-driver-key'), isFalse);
    final body = jsonDecode(seen.body) as Map;
    expect(body.containsKey('region'), isFalse);
    expect(body['a'], {'lat': 40.0, 'lon': -83.0});
    expect(r.verdict, PlanVerdict.likely);
    expect(r.provenance.terrain, 'AWS Terrain Tiles');
  });

  test('plan-verify and plan-suggest go to their own endpoints', () async {
    final paths = <String>[];
    final c = HttpCmatClient(Uri.parse('https://x.org/'), client: MockClient((req) async {
      paths.add(req.url.path);
      return req.url.path.endsWith('plan-verify') ? _json({'coveredKm2': 5}) : _json({'pool': 0, 'sites': []});
    }));
    expect((await c.planVerify(const PlanVerifyRequest(site: PlanPoint(40, -83)))).coveredKm2, 5);
    expect((await c.planSuggest(const PlanSuggestRequest(bounds: PlanBounds(south: 39, north: 40, west: -84, east: -83)))).sites, isEmpty);
    expect(paths, ['/api/cmh/plan-verify', '/api/cmh/plan-suggest']);
  });

  test('a server without the planner (501 not built), a bad request (400) and an unreadable answer throw CmatException', () async {
    Future<void> expectStatus(http.Response res, int status, {String? message}) async {
      final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => res));
      try {
        await c.planLink(const PlanLinkRequest(a: PlanPoint(1, 1), b: PlanPoint(1, 2)));
        fail('no exception');
      } on CmatException catch (e) {
        expect(e.status, status);
        if (message != null) expect(e.message, message);
      }
    }

    await expectStatus(_json({'error': 'not_built', 'built': false}, 501), 501);
    await expectStatus(_json({'error': 'The two ends are more than 40 km apart.'}, 400), 400, message: 'The two ends are more than 40 km apart.');
    await expectStatus(_json({'km': 3}), 200, message: 'server sent an unreadable answer');
  });

  test('mqtt-presets: GET with If-None-Match; 304 = not modified; 200 = the list and its ETag', () async {
    final asks = <String?>[];
    final c = HttpCmatClient(Uri.parse('https://meshsonar.com'), client: MockClient((req) async {
      asks.add(req.headers['if-none-match']);
      expect(req.method, 'GET');
      expect(req.url.path, '/api/cmh/mqtt-presets');
      if (req.headers['if-none-match'] == '"v7"') return http.Response('', 304, headers: {'etag': '"v7"'});
      return _json({
        'v': 1,
        'presets': [
          {'id': 'corecomms', 'name': 'CoreComms', 'host': 'mqtt.corecomms.net', 'path': '/mqtt'},
        ],
      }, 200, {'etag': '"v7"'});
    }));
    final fresh = await c.mqttPresets();
    expect(fresh.notModified, isFalse);
    expect(fresh.etag, '"v7"');
    expect(fresh.list!.presets.single.id, 'corecomms');
    final same = await c.mqttPresets(ifNoneMatch: '"v7"');
    expect(same.notModified, isTrue);
    expect(asks, [null, '"v7"']);
    final failing = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => _json({'error': 'x'}, 404)));
    expect(failing.mqttPresets(), throwsA(isA<CmatException>().having((e) => e.status, 'status', 404)));
  });
}
