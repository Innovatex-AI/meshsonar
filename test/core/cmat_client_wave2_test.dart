// Wave 2 client surface: site-config capabilities (flags + format lists), DELETE drive-context, GET drive-env.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/region_cache.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const _liveCaps = {
  'driveContextErase': true,
  'driveEnv': true,
  'driveFormats': ['meshsonar.drive.v1', 'meshsonar.drive.v1.1', 'meshsonar.drive.v1.2'],
  'driverSummary': true,
  'networkRepeatersDelta': true,
  'reachDriverKey': true,
  'rfWindow': true,
  'snrDaily': true,
  'telemetryFormats': ['meshsonar-telemetry/1'],
};

Map<String, dynamic> _site(Object? caps) => {
      'region': {'slug': 'cmh', 'url': 'https://cmh.meshsonar.com'},
      'radioPreset': null,
      'capabilities': ?caps,
    };

void main() {
  test('siteConfig parses the live capabilities: flags and format lists', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => _json(_site(_liveCaps))));
    final s = await c.siteConfig();
    expect(s.acceptsDriveV12, isTrue);
    expect(s.driveFormats, hasLength(3));
    expect(s.telemetryFormats, ['meshsonar-telemetry/1']);
    expect(s.driveEnv && s.driveContextErase && s.networkRepeatersDelta && s.driverSummary, isTrue);
    expect(s.reachDriverKey && s.rfWindow && s.snrDaily, isTrue);
  });

  test('an older server (no capabilities, or only v1.1) reads as no features, never as errors', () async {
    final none = await HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => _json(_site(null)))).siteConfig();
    expect(none.acceptsDriveV12, isFalse);
    expect(none.driveContextErase || none.driveEnv || none.networkRepeatersDelta, isFalse);
    final old = await HttpCmatClient(Uri.parse('https://x.org'),
            client: MockClient((_) async => _json(_site({'driveFormats': ['meshsonar.drive.v1', 'meshsonar.drive.v1.1'], 'driveEnv': 'yes', 'rfWindow': 1}))))
        .siteConfig();
    expect(old.acceptsDriveV12, isFalse);
    expect(old.driveEnv, isFalse, reason: 'only a literal true counts');
    expect(old.rfWindow, isFalse);
    final bad = await HttpCmatClient(Uri.parse('https://x.org'),
            client: MockClient((_) async => _json(_site({'driveFormats': 'meshsonar.drive.v1.2'}))))
        .siteConfig();
    expect(bad.acceptsDriveV12, isFalse, reason: 'a malformed list is absent');
  });

  test('capabilities survive the region cache round trip', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => _json(_site(_liveCaps))));
    final back = siteConfigFromJson(siteConfigToJson(await c.siteConfig()))!;
    expect(back.acceptsDriveV12, isTrue);
    expect(back.driveEnv, isTrue);
    expect(back.telemetryFormats, isNotEmpty);
  });

  test('deleteDriveContext: DELETE with the key and category', () async {
    late http.Request seen;
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
      seen = req;
      return _json({'category': 'all', 'sessions': 2, 'pings': 30, 'samples': 7});
    }));
    final r = await c.deleteDriveContext('ms_key', 'all');
    expect(seen.method, 'DELETE');
    expect(seen.url.path, '/api/cmh/drive-context');
    expect(seen.url.queryParameters, {'category': 'all'});
    expect(seen.headers['x-driver-key'], 'ms_key');
    expect((r.sessions, r.pings, r.samples), (2, 30, 7));
  });

  test('deleteDriveContext: 429 and 400 throw CmatException with status', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => _json({'error': 'slow down'}, 429)));
    await expectLater(c.deleteDriveContext('k', 'motion'), throwsA(isA<CmatException>().having((e) => e.status, 'status', 429)));
  });

  test('driveEnv parses snapshots, tolerates nulls, ignores a server-edited attribution', () async {
    late http.Request seen;
    final c = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((req) async {
      seen = req;
      return _json({
        'session': 's1',
        'attribution': 'something else',
        'gridDeg': 0.05,
        'status': 'ready',
        'snapshots': [
          {'at': '2026-10-24T11:00:00Z', 'temperatureC': 12.5, 'humidityPct': null, 'windMs': 4.1},
          {'at': '2026-10-24T10:00:00Z', 'temperatureC': 11.2, 'pressureHpa': 1012.4, 'precipMm': 0.0},
          {'at': 'garbage', 'temperatureC': 1},
        ],
      });
    }));
    final e = await c.driveEnv('ms_key', 's1');
    expect(seen.url.path, '/api/cmh/drive-env');
    expect(seen.url.queryParameters, {'session': 's1'});
    expect(seen.headers['x-driver-key'], 'ms_key');
    expect(e.status, DriveEnvStatus.ready);
    expect(e.attribution, openMeteoCredit);
    expect(e.snapshots.map((s) => s.temperatureC), [11.2, 12.5], reason: 'sorted by hour, garbage dropped');
    expect(e.snapshots.last.humidityPct, isNull);
    expect(e.snapshots.first.precipMm, 0.0);
  });

  test('driveEnv: unknown status word is unavailable; 404 throws', () async {
    final c = HttpCmatClient(Uri.parse('https://x.org'),
        client: MockClient((_) async => _json({'session': 's', 'status': 'weird', 'snapshots': []})));
    expect((await c.driveEnv('k', 's')).status, DriveEnvStatus.unavailable);
    final n = HttpCmatClient(Uri.parse('https://x.org'), client: MockClient((_) async => _json({'error': 'no such session'}, 404)));
    await expectLater(n.driveEnv('k', 's'), throwsA(isA<CmatException>().having((e) => e.status, 'status', 404)));
  });
}
