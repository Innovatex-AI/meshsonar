// HttpCmatClient.reportProblem (spec m1-app-0.4.0 §3 "Sending"; CMAT m1-problem-reports.md §5). AC-4, AC-7, AC-8.
// Kept apart from cmat_client_test.dart so the 0.3.x client tests keep compiling while this API doesn't exist yet.
//
// API under test: Future<ProblemReportResult> HttpCmatClient.reportProblem(String driverKey, String body)
//   POST <base>/api/cmh/problem-report, x-driver-key, content-type application/json, body bytes = utf8(body) exactly;
//   201 → ProblemReportResult(id, status, …); errors → CmatException(server error text, status: http code);
//   network failure / timeout → CmatException(status: null); a body over 5,000,000 bytes is never sent.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';

http.Response jsonRes(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const created = {
  'id': '3f2a9c1e-7b6d-4e21-9a0c-1d2e3f4a5b6c',
  'status': 'new',
  'receivedAt': '2026-10-17T14:02:11.000Z',
  'redacted': {'driverKey': 0, 'jwt': 0, 'bearer': 0, 'secret': 0, 'mqtt': 0, 'coords': 3},
};

const body = '{\n  "category": "upload",\n  "description": "Upload failed 😬",\n'
    '  "app": {"name": "MeshSonar", "version": "0.4.0", "build": "5", "platform": "iOS"}\n}';

void main() {
  test('POSTs the exact body bytes to /api/cmh/problem-report with the driver key; 201 → id', () async {
    late http.Request seen;
    final c = HttpCmatClient(Uri.parse('https://x.org/cmat/'), client: MockClient((req) async {
      seen = req;
      return jsonRes(created, 201);
    }));
    final r = await c.reportProblem('ms_k', body);
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'https://x.org/cmat/api/cmh/problem-report');
    expect(seen.headers['x-driver-key'], 'ms_k');
    expect(seen.headers['content-type'], startsWith('application/json'));
    expect(seen.bodyBytes, utf8.encode(body), reason: 'byte-for-byte what the preview showed (no re-encoding)');
    expect(r.id, '3f2a9c1e-7b6d-4e21-9a0c-1d2e3f4a5b6c');
    expect(r.status, 'new');
  });

  group('server errors keep their HTTP status (the app maps them to messages, AC-8)', () {
    for (final (code, err) in [
      (400, 'description: required'),
      (401, 'x-driver-key required'),
      (403, 'driver key is revoked'),
      (404, 'not found'),
      (413, 'Report is larger than 5 MB.'),
      (429, 'Too many requests. Try again later.'),
      (500, 'boom'),
      (503, 'Problem reports are turned off on this server.'),
    ]) {
      test('$code', () async {
        final c = HttpCmatClient(Uri.parse('https://x.org'),
            client: MockClient((_) async => jsonRes({'error': err, if (code == 403) 'status': 'revoked'}, code)));
        await expectLater(
            c.reportProblem('k', body),
            throwsA(isA<CmatException>()
                .having((e) => e.status, 'status', code)
                .having((e) => e.message, 'message', err)));
      });
    }
  });

  test('network errors and timeouts → CmatException with null status; default timeout is 30 s', () async {
    expect(HttpCmatClient(Uri.parse('https://x.org')).timeout, const Duration(seconds: 30));
    final c1 = HttpCmatClient(Uri.parse('https://x.org'),
        client: MockClient((_) async => throw const SocketException('no route')));
    await expectLater(c1.reportProblem('k', body), throwsA(isA<CmatException>().having((e) => e.status, 's', isNull)));
    final c2 = HttpCmatClient(Uri.parse('https://x.org'),
        timeout: const Duration(milliseconds: 50), client: MockClient((_) => Completer<http.Response>().future));
    await expectLater(c2.reportProblem('k', body),
        throwsA(isA<CmatException>().having((e) => e.status, 's', isNull).having((e) => e.message, 'm', contains('timed out'))));
  });

  test('AC-7: a body over 5,000,000 UTF-8 bytes is never sent', () async {
    var calls = 0;
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async {
      calls++;
      return jsonRes(created, 201);
    }));
    final big = '{"description": "${'é' * 2500000}"}'; // 5,000,000+ bytes, ~2.5 M characters
    expect(utf8.encode(big).length, greaterThan(5000000));
    await expectLater(c.reportProblem('k', big), throwsA(isA<CmatException>()));
    expect(calls, 0);
    final ok = '{"d": "${'a' * (5000000 - 9)}"}';
    expect(utf8.encode(ok).length, 5000000);
    await c.reportProblem('k', ok);
    expect(calls, 1, reason: 'exactly 5,000,000 bytes is allowed');
  });
}
