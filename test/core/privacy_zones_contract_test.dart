// Contract test: the app's privacy-zone rules and client against the website's REAL code (meshcore-insights
// src/lib/platform/zones.ts, the ONE validator, and zone-handlers.ts for driver-privacy), served by bun from
// test/fixtures/zones_server.ts. Skips when bun or the website checkout is missing (CMAT_DIR=<meshcore-insights>, BUN=<bun>).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:path/path.dart' as p;

import 'cmat_env.dart';

const driverKey = 'contract-driver-key-0123456789';

void main() {
  final bun = findBun();
  final skip = contractSkipReason('src/lib/platform/zones.ts') ?? contractSkipReason('src/lib/platform/zone-handlers.ts');

  Process? server;
  late Uri base;
  final stderrBuf = StringBuffer();

  setUpAll(() async {
    if (skip != null) return;
    final script = p.join(Directory.current.path, 'test', 'fixtures', 'zones_server.ts');
    server = await Process.start(bun!, ['run', script, driverKey, cmatDir()]);
    server!.stderr.transform(utf8.decoder).listen(stderrBuf.write);
    final lines = server!.stdout.transform(utf8.decoder).transform(const LineSplitter()).asBroadcastStream();
    final portLine = await lines.firstWhere((l) => l.startsWith('PORT ')).timeout(const Duration(seconds: 20),
        onTimeout: () => throw StateError('bun server did not start: $stderrBuf'));
    lines.listen((_) {});
    base = Uri.parse('http://127.0.0.1:${int.parse(portLine.substring(5).trim())}');
  });

  tearDownAll(() async {
    server?.kill();
    await server?.exitCode.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  });

  Future<Map<String, dynamic>> validate(Map<String, Object?> zone) async {
    final r = await http.post(base.resolve('/__validate'), headers: {'content-type': 'application/json'}, body: jsonEncode(zone));
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  test('the app\'s normalisation equals the website validator on random and tie inputs (4 decimals, radius, label)', skip: skip, () async {
    final rnd = math.Random(20261102);
    final inputs = <Map<String, Object?>>[
      {'lat': 39.96125, 'lon': -82.99875, 'radiusM': 300.0, 'label': 'tie'},
      {'lat': -0.00005, 'lon': 0.00005, 'radiusM': 50.0},
      {'lat': 39.961234567, 'lon': -82.998765432, 'radiusM': 123.6, 'label': '  Home \n'},
      {'lat': 89.99996, 'lon': 179.99996, 'radiusM': 5000.0},
      for (var i = 0; i < 60; i++)
        {
          'lat': (rnd.nextDouble() * 180 - 90),
          'lon': (rnd.nextDouble() * 360 - 180),
          'radiusM': 50 + rnd.nextDouble() * 4950,
          'label': i.isEven ? null : 'z${'x' * rnd.nextInt(60)}',
        },
    ];
    for (final raw in inputs) {
      final theirs = await validate(raw);
      expect(theirs.containsKey('zone'), isTrue, reason: '$raw -> $theirs');
      final ours = PrivacyZone.normalized(
        lat: (raw['lat'] as num).toDouble(),
        lon: (raw['lon'] as num).toDouble(),
        radiusM: (raw['radiusM'] as num).toDouble(),
        label: raw['label'] as String?,
      ).toJson();
      expect(jsonDecode(jsonEncode(ours)), theirs['zone'], reason: 'input $raw');
    }
  });

  test('what the app sends is already what the server would store (the server changes nothing)', skip: skip, () async {
    final z = PrivacyZone.normalized(lat: 39.961234567, lon: 190.123456789, radiusM: 777.7, label: 'Home');
    final back = await validate(z.toJson());
    expect(back['zone'], jsonDecode(jsonEncode(z.toJson())));
  });

  test('driver-privacy: read, write, read back; scope; trim; refusals', skip: skip, () async {
    final c = HttpCmatClient(base);
    final empty = await c.driverPrivacy(driverKey);
    expect(empty.zones, isEmpty);
    expect(empty.trimM, 500);
    expect(empty.scope, ZoneScope.driver);

    final zones = [
      PrivacyZone.normalized(lat: 39.961234, lon: -82.998765, radiusM: 300, label: 'Home'),
      PrivacyZone.normalized(lat: 40.0, lon: 190.5, radiusM: 5000),
    ];
    final put = await c.setDriverPrivacy(driverKey, zones: zones, trimM: 750);
    expect(put.zones, zones);
    expect(put.trimM, 750);
    final got = await c.driverPrivacy(driverKey);
    expect(got.zones, zones);
    expect(got.trimM, 750);

    // Trim alone leaves the zones.
    final t = await c.setDriverPrivacy(driverKey, trimM: 0);
    expect(t.zones, zones);
    expect(t.trimM, 0);

    // The server's plain-words refusals reach the app as CmatException(status 400, message).
    await expectLater(
      c.setDriverPrivacy(driverKey, zones: [for (var i = 0; i < 11; i++) PrivacyZone.normalized(lat: 1.0 * i, lon: 1, radiusM: 100)]),
      throwsA(isA<CmatException>().having((e) => e.status, 'status', 400).having((e) => e.message, 'message', contains('at most 10'))),
    );
    await expectLater(
      c.setDriverPrivacy(driverKey, trimM: 99999),
      throwsA(isA<CmatException>().having((e) => e.status, 'status', 400)),
    );
    await expectLater(
      c.driverPrivacy('not-a-known-key-0123456789012345'),
      throwsA(isA<CmatException>().having((e) => e.status, 'status', 401)),
    );
    final after = await c.driverPrivacy(driverKey);
    expect(after.zones, zones, reason: 'a refused write changes nothing');
  });
}
