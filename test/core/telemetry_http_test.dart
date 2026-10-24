import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';

void main() {
  test('POST/DELETE /api/cmh/telemetry carry x-driver-key and the exact body; statuses are returned, not thrown', () async {
    final seen = <http.Request>[];
    final c = HttpCmatClient(Uri.parse('https://meshsonar.com'), client: MockClient((r) async {
      seen.add(r);
      if (r.method == 'DELETE') return http.Response('{"deleted":4}', 200);
      return http.Response('{"error":"slow down"}', 429, headers: {'retry-after': '42'});
    }));
    final p = await c.postTelemetry('key-123', [123, 125]);
    expect(p.status, 429);
    expect(p.retryAfterSec, 42);
    expect(seen.single.url.toString(), 'https://meshsonar.com/api/cmh/telemetry');
    expect(seen.single.headers['x-driver-key'], 'key-123');
    expect(seen.single.headers['content-type'], 'application/json');
    expect(seen.single.body, '{}');
    final d = await c.deleteTelemetry('key-123');
    expect(d.status, 200);
    expect(d.body!['deleted'], 4);
    expect(seen.last.method, 'DELETE');
    expect(seen.last.bodyBytes, isEmpty);
  });

  test('a network failure throws', () async {
    final c = HttpCmatClient(Uri.parse('https://meshsonar.com'), client: MockClient((r) async => throw http.ClientException('down')));
    expect(c.postTelemetry('k', [1]), throwsA(isA<CmatException>()));
  });
}
