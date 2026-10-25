// Drive weather cache (stream 7 WP6): ready answers are kept long, non-ready ones re-asked only after 5 minutes, a
// failed ask serves the stored copy flagged offline, 404 drops it, and the server is never asked in a burst.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/drive_env_cache.dart';

const _id = '11111111-2222-3333-4444-555555555555';

DriveEnv env(DriveEnvStatus s, {int hours = 2, String attribution = 'edited by the server'}) => DriveEnv(
      session: _id,
      status: s,
      attribution: attribution,
      snapshots: [
        for (var i = 0; i < hours; i++)
          WeatherSnapshot(at: DateTime.utc(2026, 10, 24, 10 + i), temperatureC: 11.5 + i, pressureHpa: 1012.4, windMs: 4.1),
      ],
    );

void main() {
  late Directory dir;
  var now = DateTime.utc(2026, 10, 25, 12);
  setUp(() {
    dir = Directory.systemTemp.createTempSync('de');
    now = DateTime.utc(2026, 10, 25, 12);
  });
  tearDown(() => dir.deleteSync(recursive: true));
  DriveEnvCache cache({Directory? d, int max = 60, int perMinute = 50}) =>
      DriveEnvCache(dir: d ?? dir, clock: () => now, maxEntries: max, maxPerMinute: perMinute);

  test('ready: asked once, then served from the cache for an hour, with the licence line and not the server one', () async {
    final c = cache();
    var asks = 0;
    Future<DriveEnv> ask() async {
      asks++;
      return env(DriveEnvStatus.ready);
    }

    final a = await c.get(_id, ask);
    expect(a.offline, isFalse);
    expect(a.env.attribution, openMeteoCredit);
    expect(a.env.snapshots, hasLength(2));
    now = now.add(const Duration(minutes: 59));
    final b = await c.get(_id, ask);
    expect(asks, 1);
    expect(b.fetchedAt, a.fetchedAt);
    now = now.add(const Duration(minutes: 2)); // past the 1 h ready window
    await c.get(_id, ask);
    expect(asks, 2);
  });

  test('pending / disabled / unavailable: not asked again inside 5 minutes, asked after', () async {
    for (final s in [DriveEnvStatus.pending, DriveEnvStatus.disabled, DriveEnvStatus.unavailable]) {
      now = DateTime.utc(2026, 10, 25, 12);
      final c = cache(d: Directory('${dir.path}/${s.name}'));
      var asks = 0;
      Future<DriveEnv> ask() async {
        asks++;
        return env(s, hours: 0);
      }

      await c.get(_id, ask);
      now = now.add(const Duration(minutes: 4, seconds: 59));
      await c.get(_id, ask);
      expect(asks, 1, reason: s.name);
      now = now.add(const Duration(seconds: 1));
      await c.get(_id, ask);
      expect(asks, 2, reason: s.name);
    }
  });

  test('pending turning ready is picked up on the next ask', () async {
    final c = cache();
    await c.get(_id, () async => env(DriveEnvStatus.pending, hours: 1));
    now = now.add(const Duration(minutes: 6));
    final r = await c.get(_id, () async => env(DriveEnvStatus.ready, hours: 3));
    expect(r.env.status, DriveEnvStatus.ready);
    expect(r.env.snapshots, hasLength(3));
  });

  test('survives a restart: a new cache on the same folder serves the stored answer without asking', () async {
    await cache().get(_id, () async => env(DriveEnvStatus.ready, hours: 3));
    var asks = 0;
    final r = await cache().get(_id, () async {
      asks++;
      return env(DriveEnvStatus.ready);
    });
    expect(asks, 0);
    expect(r.env.snapshots, hasLength(3));
    expect(r.env.snapshots.first.at, DateTime.utc(2026, 10, 24, 10));
    expect(r.env.snapshots.first.temperatureC, 11.5);
    expect(r.env.snapshots.first.humidityPct, isNull);
    expect(r.env.attribution, openMeteoCredit);
  });

  test('offline: a failed ask serves the stored copy with its original time, flagged offline', () async {
    final c = cache();
    final first = await c.get(_id, () async => env(DriveEnvStatus.ready));
    now = now.add(const Duration(days: 2));
    final r = await c.get(_id, () async => throw const CmatException('no route'));
    expect(r.offline, isTrue);
    expect(r.fetchedAt, first.fetchedAt);
    expect(r.env.snapshots, hasLength(2));
    // Also after a restart, and for a 429.
    final r2 = await cache().get(_id, () async => throw const CmatException('slow down', status: 429));
    expect(r2.offline, isTrue);
    expect(r2.env.snapshots, hasLength(2));
  });

  test('nothing stored and the ask fails: the error reaches the screen (Retry), and nothing is cached', () async {
    final c = cache();
    await expectLater(c.get(_id, () async => throw const CmatException('x', status: 500)), throwsA(isA<CmatException>()));
    final r = await c.get(_id, () async => env(DriveEnvStatus.ready));
    expect(r.offline, isFalse);
    expect(c.serverAsks, 2);
  });

  test('404 (the server does not know the drive) drops the stored copy and rethrows', () async {
    final c = cache();
    await c.get(_id, () async => env(DriveEnvStatus.ready));
    now = now.add(const Duration(days: 1));
    await expectLater(c.get(_id, () async => throw const CmatException('no such session', status: 404)),
        throwsA(isA<CmatException>().having((e) => e.status, 'status', 404)));
    expect(dir.listSync().where((f) => f.path.endsWith('.json')), isEmpty);
    await expectLater(c.get(_id, () async => throw const CmatException('no such session', status: 404)), throwsA(isA<CmatException>()));
  });

  test('callers at the same moment share one ask', () async {
    final c = cache();
    var asks = 0;
    Future<DriveEnv> ask() async {
      asks++;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return env(DriveEnvStatus.ready);
    }

    await Future.wait([c.get(_id, ask), c.get(_id, ask), c.get(_id, ask)]);
    expect(asks, 1);
  });

  test('never more than the per-minute budget of asks; it frees up after a minute', () async {
    final c = cache(perMinute: 3);
    for (var i = 0; i < 3; i++) {
      await c.get('0000000$i', () async => env(DriveEnvStatus.pending, hours: 0));
    }
    await expectLater(c.get('00000009', () async => env(DriveEnvStatus.pending, hours: 0)),
        throwsA(isA<CmatException>().having((e) => e.status, 'status', 429)));
    expect(c.serverAsks, 3);
    now = now.add(const Duration(seconds: 61));
    await c.get('00000009', () async => env(DriveEnvStatus.pending, hours: 0));
    expect(c.serverAsks, 4);
  });

  test('a phone clock that went back counts as stale, not as fresh forever', () async {
    final c = cache();
    var asks = 0;
    Future<DriveEnv> ask() async {
      asks++;
      return env(DriveEnvStatus.ready);
    }

    await c.get(_id, ask);
    now = now.subtract(const Duration(days: 1));
    await c.get(_id, ask);
    expect(asks, 2);
  });

  test('unreadable or foreign files are ignored; a session id that is not a plain id never touches the disk', () async {
    File('${dir.path}/de_$_id.json').writeAsStringSync('{not json');
    final c = cache();
    final r = await c.get(_id, () async => env(DriveEnvStatus.ready));
    expect(r.offline, isFalse);
    final odd = await c.get('../../etc/passwd', () async => env(DriveEnvStatus.ready));
    expect(odd.env.snapshots, isNotEmpty);
    expect(dir.listSync().map((e) => e.path).where((p) => p.contains('passwd')), isEmpty);
    expect(decodeDriveEnvResult('{"v":2}', _id), isNull);
    expect(decodeDriveEnvResult('[]', _id), isNull);
  });

  test('the stored file holds no coordinates and no attribution text of the server', () async {
    await cache().get(_id, () async => env(DriveEnvStatus.ready));
    final text = File('${dir.path}/de_$_id.json').readAsStringSync().toLowerCase();
    expect(text, isNot(contains('lat')));
    expect(text, isNot(contains('lon')));
    expect(text, isNot(contains('edited by the server')));
  });

  test('LRU cap: the oldest files go past maxEntries', () async {
    final c = cache(max: 2);
    await c.get('aaaa', () async => env(DriveEnvStatus.ready));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await c.get('bbbb', () async => env(DriveEnvStatus.ready));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await c.get('cccc', () async => env(DriveEnvStatus.ready));
    final names = dir.listSync().map((e) => e.path.split('/').last).where((n) => n.endsWith('.json')).toSet();
    expect(names, {'de_bbbb.json', 'de_cccc.json'});
  });

  test('clear() and forget() remove stored answers', () async {
    final c = cache();
    await c.get(_id, () async => env(DriveEnvStatus.ready));
    await c.get('aaaa', () async => env(DriveEnvStatus.ready));
    await c.forget('aaaa');
    expect(await c.clear(), 1);
    expect(dir.listSync().where((f) => f.path.endsWith('.json')), isEmpty);
  });

  test('memory only (no folder): works, nothing is written', () async {
    final c = DriveEnvCache(clock: () => now);
    var asks = 0;
    for (var i = 0; i < 3; i++) {
      await c.get(_id, () async {
        asks++;
        return env(DriveEnvStatus.ready);
      });
    }
    expect(asks, 1);
  });
}
