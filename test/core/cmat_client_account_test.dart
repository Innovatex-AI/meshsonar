// HttpCmatClient against the driver-key account endpoints: methods, paths, headers, bodies, and answers.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';

http.Response jres(Object b, [int code = 200]) => http.Response(jsonEncode(b), code, headers: {'content-type': 'application/json'});

void main() {
  late List<http.Request> seen;
  HttpCmatClient make(http.Response Function(http.Request) f) {
    seen = [];
    return HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((r) async {
      seen.add(r);
      return f(r);
    }));
  }

  test('driver-devices: GET with the key', () async {
    final c = make((_) => jres({'v': 1, 'linked': false, 'driver': {'id': 'd1', 'display': 'x', 'status': 'approved'}, 'devices': [], 'mm': {'linked': false, 'keys': []}}));
    final d = await c.driverDevices('ms_key');
    expect(d.driver.id, 'd1');
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/api/cmh/driver-devices');
    expect(seen.single.headers['x-driver-key'], 'ms_key');
  });

  test('driver-key-reveal: body kind and id; revealable false gives no key; mm gives the link', () async {
    var n = 0;
    final c = make((r) {
      n++;
      return n == 1 ? jres({'revealable': false}) : jres({'revealable': true, 'key': 'mmf_k', 'configLink': 'meshmapper://custom-api?url=u&key=k'});
    });
    expect((await c.revealKey('ms_key', kind: 'driver', id: 'i1')).revealable, isFalse);
    final r = await c.revealKey('ms_key', kind: 'mm', id: 'i2');
    expect(r.key, 'mmf_k');
    expect(r.configLink, startsWith('meshmapper://'));
    expect(jsonDecode(seen.last.body), {'kind': 'mm', 'id': 'i2'});
    expect(seen.last.method, 'POST');
  });

  test('driver-key-rotate sends the new key; a 409 or 429 is a CmatException with the status', () async {
    final c = make((_) => jres({'ok': true, 'keyHint': 'wxyz'}));
    expect(await c.rotateKey('ms_old', 'ms_new'), 'wxyz');
    expect(jsonDecode(seen.single.body), {'newKey': 'ms_new'});
    expect(seen.single.headers['x-driver-key'], 'ms_old');
    final bad = make((_) => jres({'error': 'busy'}, 429));
    await expectLater(bad.rotateKey('a', 'b'), throwsA(isA<CmatException>().having((e) => e.status, 'status', 429)));
  });

  test('driver-drive / update / delete / reports / delete-driver', () async {
    final c = make((r) {
      switch (r.url.path) {
        case '/api/cmh/driver-drive':
          return jres({'drive': {'id': 's1', 'startedAt': '2026-10-30T10:00:00Z'}, 'pings': []});
        case '/api/cmh/driver-reports':
          return jres({'reports': [{'id': 'r1', 'createdAt': '2026-10-31T00:00:00Z'}]});
        case '/api/cmh/driver-delete':
          return jres({'deleted': {'sessions': 2}});
        default:
          return jres({'ok': true});
      }
    });
    expect((await c.driverDrive('k', 's1')).drive.id, 's1');
    expect(seen.last.url.queryParameters, {'id': 's1'});
    await c.updateServerDrive('k', 's1', label: 'Run', hidden: true);
    expect(jsonDecode(seen.last.body), {'id': 's1', 'label': 'Run', 'hidden': true});
    await c.updateServerDrive('k', 's1', clearLabel: true);
    expect(jsonDecode(seen.last.body), {'id': 's1', 'label': null});
    await c.deleteServerDrive('k', 's1');
    expect(seen.last.url.path, '/api/cmh/driver-drive-delete');
    expect((await c.driverReports('k')).single.id, 'r1');
    final cnt = await c.deleteDriver('k');
    expect(cnt.sessions, 2);
    expect(seen.last.method, 'DELETE');
  });

  test('driver-export returns the raw bytes; an error answer throws with the status', () async {
    final c = make((_) => http.Response('{"format":"x"}', 200));
    expect(utf8.decode(await c.exportAccount('k')), '{"format":"x"}');
    final bad = make((_) => jres({'error': 'slow down'}, 429));
    await expectLater(bad.exportAccount('k'), throwsA(isA<CmatException>().having((e) => e.status, 'status', 429)));
  });
}
