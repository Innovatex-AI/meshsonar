import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/model.dart';

import 'helpers.dart';

http.Response jsonRes(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  test('endpoint URLs: base with and without trailing slash or sub-path', () {
    expect(HttpCmatClient(Uri.parse('https://x.org')).endpoint('drive-upload').toString(),
        'https://x.org/api/cmh/drive-upload');
    expect(HttpCmatClient(Uri.parse('https://x.org/')).endpoint('driver-status').toString(),
        'https://x.org/api/cmh/driver-status');
    expect(HttpCmatClient(Uri.parse('http://localhost:8080/cmat/')).endpoint('driver-request').toString(),
        'http://localhost:8080/cmat/api/cmh/driver-request');
  });

  test('requestKey posts name/callsign/email (omits nulls) and parses 201', () async {
    late http.Request seen;
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
      seen = req;
      return jsonRes({'driverId': 'd1', 'key': 'ms_secret', 'status': 'pending', 'display': 'Driver 3'}, 201);
    }));
    final r = await c.requestKey(name: 'Andy', callsign: 'KE4BFI');
    expect(seen.method, 'POST');
    expect(seen.url.path, '/api/cmh/driver-request');
    expect(seen.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(seen.body), {'name': 'Andy', 'callsign': 'KE4BFI'});
    expect(seen.headers.containsKey('x-driver-key'), isFalse);
    expect(r.key, 'ms_secret');
    expect(r.driverId, 'd1');
    expect(r.status, DriverKeyStatus.pending);
    expect(r.display, 'Driver 3');
  });

  test('requestKey 429 → CmatException with server error and status', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'),
        client: MockClient((_) async => jsonRes({'error': 'too many requests are waiting'}, 429)));
    await expectLater(
        c.requestKey(name: 'Andy'),
        throwsA(isA<CmatException>()
            .having((e) => e.status, 'status', 429)
            .having((e) => e.message, 'message', 'too many requests are waiting')));
  });

  test('status sends x-driver-key with GET and parses every status string', () async {
    for (final (wire, want) in [
      ('pending', DriverKeyStatus.pending),
      ('approved', DriverKeyStatus.approved),
      ('rejected', DriverKeyStatus.rejected),
      ('revoked', DriverKeyStatus.revoked),
      ('weird', DriverKeyStatus.unknown),
    ]) {
      final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
        expect(req.method, 'GET');
        expect(req.url.path, '/api/cmh/driver-status');
        expect(req.headers['x-driver-key'], 'ms_k');
        return jsonRes({'status': wire, 'display': 'KE4BFI'});
      }));
      final r = await c.status('ms_k');
      expect(r.status, want);
      expect(r.display, 'KE4BFI');
    }
  });

  test('status 401 maps to CmatException(401)', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'),
        client: MockClient((_) async => jsonRes({'error': 'x-driver-key required'}, 401)));
    await expectLater(c.status('bad'), throwsA(isA<CmatException>().having((e) => e.status, 'status', 401)));
  });

  test('upload posts the batch JSON and parses counts and rejections', () async {
    final s = makeSession();
    final pings = [makePing(0), makePing(1)];
    late Map body;
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
      expect(req.url.path, '/api/cmh/drive-upload');
      expect(req.headers['x-driver-key'], 'ms_k');
      body = jsonDecode(req.body) as Map;
      return jsonRes({
        'sessionId': s.id, 'stored': 1, 'duplicate': 0, 'rejected': 1,
        'rejections': [{'index': 1, 'id': pings[1].id, 'reason': 'lat/lon missing or out of range'}],
      });
    }));
    final r = await c.upload('ms_k', DriveBatch(app: const AppInfo(name: 'MeshSonar'), session: s, pings: pings));
    expect(body['format'], 'meshsonar.drive.v1');
    expect(shapeProblems(body), isEmpty);
    expect(r.stored, 1);
    expect(r.rejected, 1);
    expect(r.rejectionReasons, ['lat/lon missing or out of range']);
    expect(r, isA<DetailedUploadResult>());
    expect((r as DetailedUploadResult).rejections.single.index, 1);
    expect(r.sessionId, s.id);
  });

  test('upload 403 carries server message and status', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'),
        client: MockClient((_) async => jsonRes({'error': 'driver key is pending', 'status': 'pending'}, 403)));
    await expectLater(
        c.upload('k', DriveBatch(app: const AppInfo(), session: makeSession(), pings: const [])),
        throwsA(isA<CmatException>().having((e) => e.status, 's', 403).having((e) => e.message, 'm', 'driver key is pending')));
  });

  test('non-JSON error page → generic message with status', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => http.Response('<html>oops', 502)));
    await expectLater(c.status('k'),
        throwsA(isA<CmatException>().having((e) => e.status, 's', 502).having((e) => e.message, 'm', contains('502'))));
  });

  test('200 with unreadable body → CmatException', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => http.Response('not json', 200)));
    await expectLater(c.status('k'), throwsA(isA<CmatException>()));
  });

  test('network errors → CmatException with null status', () async {
    final c1 = HttpCmatClient(Uri.parse('https://x.org'),
        client: MockClient((_) async => throw const SocketException('no route')));
    await expectLater(c1.status('k'), throwsA(isA<CmatException>().having((e) => e.status, 's', isNull)));
    final c2 = HttpCmatClient(Uri.parse('https://x.org'),
        client: MockClient((_) async => throw http.ClientException('reset')));
    await expectLater(c2.status('k'), throwsA(isA<CmatException>().having((e) => e.status, 's', isNull)));
  });

  test('timeouts → CmatException', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'),
        timeout: const Duration(milliseconds: 50),
        client: MockClient((_) => Completer<http.Response>().future));
    await expectLater(c.status('k'), throwsA(isA<CmatException>().having((e) => e.message, 'm', contains('timed out'))));
  });

  test('repeaters parses list, lower-cases keys, skips malformed entries', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
      expect(req.url.path, '/api/cmh/drive-repeaters');
      expect(req.headers['x-driver-key'], 'k');
      return jsonRes({
        'repeaters': [
          {'key': 'DF0136AA', 'name': 'Tower', 'lat': 40.1, 'lon': -82.9},
          {'key': 'bb', 'name': 'Bad'},
        ],
        'at': '2026-10-15T00:00:00Z',
      });
    }));
    final r = await c.repeaters('k');
    expect(r, hasLength(1));
    expect(r.single.key, 'df0136aa');
    expect(r.single.name, 'Tower');
  });

  test('parseDriverKeyStatus handles null', () {
    expect(parseDriverKeyStatus(null), DriverKeyStatus.unknown);
  });
}
