// AC-4, AC-6, AC-7 (spec m1-app-0.4.0 §3): the problem-report body is built, redacted, rounded and size-capped in one
// pure-Dart place, and what it returns is exactly what is sent.
//
// API under test (lib/core/report_body.dart; names chosen by Q, the spec names only the behaviour):
//   const int problemReportMaxBytes = 5000000;  const problemReportCategories = ['bug','radio','gps','upload','map','idea','other'];
//   ProblemReport buildProblemReport({required String category, required String description, required AppInfo app,
//       Map<String, Object?> device = const {}, Map<String, Object?>? radio, String? driveId,
//       List<String>? log /* null = "Include app log" off; oldest line first */,
//       List<String> secrets = const [] /* literal strings that must never be sent: driver key, full server URL */,
//       int maxBytes = problemReportMaxBytes})
//   ProblemReport: .body (pretty-printed JSON text, the exact bytes sent), .bytes (UTF-8 length of body),
//       .redacted (Map<String,int>, summed over every string), .removedKeys (all counts except coords),
//       .roundedLocations (coords), .logShortened, .tooLarge
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/report_body.dart';

const app = AppInfo(name: 'MeshSonar', version: '0.4.0', build: '5', platform: 'iOS');
const device = {'os': 'ios', 'osVersion': '26.0.1', 'locale': 'en_US'};
const radio = {'name': 'KE4BFI-v4', 'firmware': '1.9', 'freqMhz': 910.525, 'bwKhz': 62.5, 'sf': 7, 'cr': 5, 'txDbm': 22};
const msKey = 'ms_Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Ab3_-xYz09Q7k';

Map<String, dynamic> decode(ProblemReport r) => jsonDecode(r.body) as Map<String, dynamic>;

void main() {
  test('constants match the CMAT contract (§5): 5,000,000 bytes, 7 categories', () {
    expect(problemReportMaxBytes, 5000000);
    expect(problemReportCategories, ['bug', 'radio', 'gps', 'upload', 'map', 'idea', 'other']);
  });

  test('body has exactly the CMAT §5 fields; app carries name/version/build/platform; no drive pings', () {
    final r = buildProblemReport(
      category: 'upload',
      description: 'Upload failed after the tunnel',
      app: app,
      device: device,
      radio: radio,
      driveId: '0b7e6f5a-1c2d-4e3f-8a9b-0c1d2e3f4a5b',
      log: const ['2026-10-17T14:02:11.000Z sync 0 stored, HTTP 503'],
    );
    final j = decode(r);
    expect(j.keys.toSet(), {'category', 'description', 'app', 'device', 'radio', 'driveId', 'log'});
    expect(j['category'], 'upload');
    expect(j['description'], 'Upload failed after the tunnel');
    expect(j['app'], {'name': 'MeshSonar', 'version': '0.4.0', 'build': '5', 'platform': 'iOS'});
    expect(j['device'], device);
    expect(j['radio'], radio);
    expect(j['driveId'], '0b7e6f5a-1c2d-4e3f-8a9b-0c1d2e3f4a5b');
    expect(j['log'], contains('HTTP 503'));
    expect(r.logShortened, isFalse);
    expect(r.tooLarge, isFalse);
  });

  test('AC-4: body is pretty-printed JSON and bytes is its UTF-8 size (what the preview shows is what is sent)', () {
    final r = buildProblemReport(category: 'bug', description: 'Map froze 😬 near Polaris', app: app, device: device);
    expect(r.body, contains('\n'), reason: 'pretty-printed');
    expect(r.body, matches(RegExp(r'\n[ \t]+"category"')), reason: 'one field per indented line');
    expect(r.bytes, utf8.encode(r.body).length);
    expect(decode(r)['description'], 'Map froze 😬 near Polaris');
    // Building twice from the same input gives the same bytes (the preview can be rebuilt after a restart).
    expect(buildProblemReport(category: 'bug', description: 'Map froze 😬 near Polaris', app: app, device: device).body, r.body);
  });

  test('without the log, without a radio and without a drive those fields are absent or null', () {
    final j = decode(buildProblemReport(category: 'idea', description: 'Dark map tiles please', app: app));
    expect(j['log'], isNull);
    expect(j['radio'], isNull);
    expect(j['driveId'], isNull);
  });

  test('AC-5: description, log and every string in app/device/radio are redacted; coordinate fields rounded (C2)', () {
    final r = buildProblemReport(
      category: 'radio',
      description: 'my key is $msKey and I was at 40.128091,-82.977705',
      app: app,
      device: const {'os': 'ios', 'osVersion': 'token=abc123', 'locale': 'en_US', 'lat': 40.128091, 'lon': -82.977705},
      radio: const {'name': 'password=hunter2', 'firmware': '1.9', 'freqMhz': 910.525},
      log: const [
        '2026-10-17T14:02:12Z jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.abcDEF_123-x',
        '2026-10-17T14:02:13Z Authorization: Bearer abc.def-ghi',
        '2026-10-17T14:02:14Z observer mqtt://obs:hunter2@broker.example:1883',
        '2026-10-17T14:02:15Z > set mqtt1.password x',
      ],
    );
    final j = decode(r);
    expect(j['description'], 'my key is [redacted:driver-key] and I was at 40.128,-82.978');
    expect(j['device']['osVersion'], 'token=[redacted]');
    expect(j['device']['lat'], 40.128);
    expect(j['device']['lon'], -82.978);
    expect(j['radio']['name'], 'password=[redacted]');
    expect(j['radio']['freqMhz'], 910.525, reason: '3 decimals are untouched');
    for (final clear in [msKey, 'abc123', 'hunter2', 'abcDEF_123', 'abc.def-ghi', 'password x', '40.128091', '82.977705']) {
      expect(r.body, isNot(contains(clear)));
    }
    expect(r.redacted, {'driverKey': 1, 'jwt': 1, 'bearer': 1, 'secret': 2, 'mqtt': 2, 'coords': 4});
    expect(r.removedKeys, 7);
    expect(r.roundedLocations, 4);
  });

  test('AC-6: the driver key and the full server URL never appear, even when the log contains them', () {
    const driverKey = 'secretkey-abcdef-1234'; // not ms_-shaped, so only the literal scrub catches it
    const serverUrl = 'https://cmat.example.org/private/path';
    final r = buildProblemReport(
      category: 'upload',
      description: 'pasted $driverKey by mistake',
      app: app,
      log: const ['2026-10-17T14:02:11Z POST $serverUrl/api/cmh/drive-upload x-driver-key $driverKey'],
      secrets: const [driverKey, serverUrl],
    );
    expect(r.body, isNot(contains(driverKey)));
    expect(r.body, isNot(contains(serverUrl)));
    expect(r.body, isNot(contains('/private/path')));
  });

  group('AC-7: 5 MB cap', () {
    List<String> lines(int n, int width) =>
        [for (var i = 0; i < n; i++) 'line ${i.toString().padLeft(4, '0')} ${'x' * width}'];

    test('too big → oldest log lines dropped until it fits; newest kept, contiguous', () {
      final log = lines(400, 100);
      final r = buildProblemReport(category: 'bug', description: 'big log', app: app, log: log, maxBytes: 20000);
      expect(r.logShortened, isTrue);
      expect(r.tooLarge, isFalse);
      expect(r.bytes, lessThanOrEqualTo(20000));
      expect(utf8.encode(r.body).length, r.bytes);
      final sent = (decode(r)['log'] as String).split('\n').where((l) => l.startsWith('line ')).toList();
      expect(sent, isNotEmpty);
      expect(sent.last, log.last, reason: 'newest line kept');
      expect(sent.first, isNot(log.first), reason: 'oldest line dropped');
      expect(sent, log.sublist(log.length - sent.length), reason: 'a contiguous run of the newest lines');
    });

    test('size is counted in UTF-8 bytes, not characters', () {
      final log = [for (var i = 0; i < 300; i++) 'line $i ${'😬' * 50}']; // ~200 bytes, ~100 chars each
      final r = buildProblemReport(category: 'bug', description: 'emoji log', app: app, log: log, maxBytes: 20000);
      expect(r.logShortened, isTrue);
      expect(utf8.encode(r.body).length, lessThanOrEqualTo(20000));
    });

    test('fits → nothing dropped', () {
      final log = lines(10, 20);
      final r = buildProblemReport(category: 'bug', description: 'small', app: app, log: log, maxBytes: 20000);
      expect(r.logShortened, isFalse);
      for (final l in log) {
        expect(decode(r)['log'], contains(l));
      }
    });

    test('still too large with no log at all → tooLarge (Send disabled, "Description too long")', () {
      final r = buildProblemReport(category: 'bug', description: 'd' * 4000, app: app, log: lines(5, 10), maxBytes: 1000);
      expect(r.tooLarge, isTrue);
    });

    test('the real cap: a 6 MB log is cut to ≤ 5,000,000 bytes', () {
      final log = lines(1000, 6000);
      final r = buildProblemReport(category: 'bug', description: 'huge', app: app, log: log);
      expect(r.logShortened, isTrue);
      expect(r.tooLarge, isFalse);
      expect(r.bytes, lessThanOrEqualTo(5000000));
      expect(r.bytes, greaterThan(4900000), reason: 'drops only what it must (one ~6 KB line at a time)');
    });
  });
}
