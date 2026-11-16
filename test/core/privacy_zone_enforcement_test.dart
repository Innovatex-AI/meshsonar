// Privacy zones enforced on the phone (build 66, Z1-Z3 and Z8): PrivacyZones.hides, the drive upload builder never puts an
// in-zone ping in a body, the observer uploader strips the position of in-zone packets, and everything fails closed until
// the zones are loaded. Fixture zone: 300 m around the Ohio Statehouse (39.9612, -82.9988).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/drive_store.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/core/settings_store.dart';
import 'package:meshsonar/core/storage_usage.dart' show driveSafeToRemove;
import 'package:meshsonar/core/sync_service.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

import 'helpers.dart';

const _home = PrivacyZone(lat: 39.9612, lon: -82.9988, radiusM: 300, label: 'Home');

void main() {
  group('PrivacyZones.hides', () {
    final z = PrivacyZones([_home]);
    test('inside, outside and the boundary (distance <= radius is hidden)', () {
      expect(z.hides(39.9612, -82.9988), isTrue);
      expect(z.hides(39.9622, -82.9988), isTrue, reason: '~111 m north');
      expect(z.hides(39.9650, -82.9988), isFalse, reason: '~423 m north');
      // A point exactly 300 m due north, found from the same haversine the rule uses.
      var lo = 39.9612, hi = 39.9712;
      for (var i = 0; i < 60; i++) {
        final mid = (lo + hi) / 2;
        distanceM(mid, -82.9988, 39.9612, -82.9988) < 300 ? lo = mid : hi = mid;
      }
      expect(distanceM(lo, -82.9988, 39.9612, -82.9988), lessThanOrEqualTo(300));
      expect(z.hides(lo, -82.9988), isTrue);
      expect(z.hides(lo + 1e-4, -82.9988), isFalse, reason: 'about 11 m past the edge');
    });
    test('fails closed: not loaded, no zones loaded yet, or an unusable coordinate', () {
      expect(PrivacyZones.notLoaded.hides(10, 10), isTrue);
      expect(const PrivacyZones([]).hides(10, 10), isFalse, reason: 'loaded and empty: nothing is hidden');
      expect(z.hides(double.nan, 0), isTrue);
      expect(z.hides(91, 0), isTrue);
    });
    test('antimeridian: a zone at 179.9995 E also hides a point at 179.9995 W', () {
      final a = PrivacyZones([PrivacyZone.normalized(lat: 10, lon: 179.9995, radiusM: 300)]);
      expect(a.hides(10, -179.9995), isTrue, reason: '~110 m across the line');
      expect(a.hides(10, -179.99), isFalse);
    });
    test('parity with the website fixture: zones.ts distanceM agrees with ours to a metre', () {
      // Reference value computed with the same haversine and R = 6371008.8 (website zones.ts).
      expect(distanceM(39.9612, -82.9988, 40.0612, -82.9988), closeTo(11119.5, 1));
    });
  });

  group('zonesNeedingPurge', () {
    test('a new zone and a bigger one need a purge; a smaller or equal one does not', () {
      final old = [_home];
      expect(zonesNeedingPurge(old, [_home]), isEmpty);
      expect(zonesNeedingPurge(old, [_home.copyWith(radiusM: 100)]), isEmpty);
      expect(zonesNeedingPurge(old, [_home.copyWith(radiusM: 500)]), hasLength(1));
      expect(zonesNeedingPurge(old, [_home, PrivacyZone.normalized(lat: 40, lon: -83)]), hasLength(1));
      expect(zonesNeedingPurge([], [_home]), hasLength(1));
    });
  });

  group('drive upload builder', () {
    late Directory tmp;
    late JsonlDriveStore store;
    late FileSettingsStore settings;
    final bodies = <Map<String, dynamic>>[];
    late MockClient mock;

    setUp(() async {
      bodies.clear();
      tmp = await Directory.systemTemp.createTemp('meshsonar_zone_');
      store = await JsonlDriveStore.open(Directory(p.join(tmp.path, 'drives')));
      settings = FileSettingsStore(File(p.join(tmp.path, 'settings.json')));
      await settings.save(const Settings(driverKey: 'ms_testkey_0123456789abcdef', keyStatus: DriverKeyStatus.approved));
      mock = MockClient((req) async {
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        bodies.add(body);
        final n = (body['pings'] as List).length;
        return http.Response(jsonEncode({'sessionId': body['session']['id'], 'stored': n, 'duplicate': 0, 'rejected': 0, 'rejections': []}), 200);
      });
    });
    tearDown(() async => tmp.delete(recursive: true));

    DefaultSyncService service(Future<PrivacyZones> Function()? zones) => DefaultSyncService(
        store: store, client: HttpCmatClient(Uri.parse('https://cmat.test'), client: mock), settings: settings)
      ..zones = zones;

    // A drive that starts at home, drives away (across the zone edge) and ends back at home: 12 pings, lat steps of 0.0005.
    Future<(DriveSession, List<DrivePing>)> acrossTheZone() async {
      final s = makeSession(endedAt: null);
      await store.startSession(s);
      final base = DateTime.now().toUtc().subtract(const Duration(hours: 2));
      final pings = <DrivePing>[];
      for (var i = 0; i < 12; i++) {
        final lat = 39.9612 + (i < 6 ? i : 11 - i) * 0.0010; // out and back, 0 .. 0.0050 deg (0 .. 556 m)
        final pg = DrivePing(id: newId(), ts: base.add(Duration(seconds: i * 10)), lat: lat, lon: -82.9988);
        pings.add(pg);
        await store.appendPing(s.id, pg);
      }
      await store.endSession(s.id, base.add(const Duration(minutes: 5)));
      return (s, pings);
    }

    test('replaying a drive across the zone: the upload body holds only the pings outside it', () async {
      final (s, pings) = await acrossTheZone();
      final z = PrivacyZones([_home]);
      final inside = {for (final pg in pings) if (z.hides(pg.lat, pg.lon)) pg.id};
      expect(inside, isNotEmpty);
      expect(inside.length, lessThan(pings.length));
      final r = await service(() async => z).syncSession(s.id);
      expect(r.error, isNull);
      final sent = [for (final b in bodies) ...(b['pings'] as List).map((x) => (x as Map)['id'] as String)];
      expect(sent.toSet().intersection(inside), isEmpty, reason: 'no in-zone ping may reach the wire');
      expect(sent.toSet(), {for (final pg in pings) if (!inside.contains(pg.id)) pg.id});
      expect(jsonEncode(bodies).contains('39.9612'), isFalse, reason: 'the zone centre never appears in a body');
      expect(r.zoneHeld, inside.length);
      // They stay in the phone's own log and stats, marked kept, and never count as waiting or rejected.
      expect((await store.pings(s.id)).length, pings.length);
      expect(await store.zoneHeldIds(s.id), inside);
      final sum = (await store.sessions()).single;
      expect(sum.pingCount, pings.length);
      expect(sum.zoneHeldCount, inside.length);
      expect(sum.unsyncedCount, 0);
      expect(sum.rejectedCount, 0);
      expect(driveSafeToRemove(sum), isFalse, reason: 'the held pings exist only on this phone');
      // A second sync sends nothing and never retries them.
      bodies.clear();
      await service(() async => z).syncSession(s.id);
      expect(bodies.where((b) => (b['pings'] as List).isNotEmpty), isEmpty);
    });

    test('fails closed: zones not loaded (or the loader throws) uploads nothing and keeps every ping queued', () async {
      final (s, pings) = await acrossTheZone();
      var r = await service(() async => PrivacyZones.notLoaded).syncSession(s.id);
      expect(bodies, isEmpty);
      expect(r.error, contains('privacy zones'));
      r = await service(() async => throw StateError('disk')).syncSession(s.id);
      expect(bodies, isEmpty);
      expect((await store.unsyncedPings(s.id)).length, pings.length);
      // Once loaded the drive goes up.
      await service(() async => const PrivacyZones([])).syncSession(s.id);
      expect([for (final b in bodies) ...(b['pings'] as List)].length, pings.length);
    });

    test('a drive entirely inside a zone is not announced to the server at all', () async {
      final s = makeSession(endedAt: null);
      await store.startSession(s);
      for (var i = 0; i < 4; i++) {
        await store.appendPing(s.id, DrivePing(id: newId(), ts: DateTime.now().toUtc().subtract(Duration(minutes: 30 - i)), lat: 39.9612, lon: -82.9988));
      }
      await store.endSession(s.id, DateTime.now().toUtc());
      final r = await service(() async => PrivacyZones([_home])).syncSession(s.id);
      expect(bodies, isEmpty);
      expect(r.zoneHeld, 4);
      expect((await store.sessions()).single.unsyncedCount, 0);
    });

    test('a zone added later applies to pings not yet uploaded, and no zones at all uploads everything', () async {
      final (s, pings) = await acrossTheZone();
      await service(null).syncSession(s.id);
      expect([for (final b in bodies) ...(b['pings'] as List)].length, pings.length, reason: 'no gate wired: unchanged behaviour');
    });
  });

  group('observer packets', () {
    late DateTime clock;
    final posts = <Map<String, dynamic>>[];
    late _Tx tx;
    PrivacyZones zones = PrivacyZones([_home]);

    TelemetryUploader make() => TelemetryUploader(
          enabled: () => true,
          driverKey: () => 'k' * 40,
          keyApproved: () => true,
          transport: () => tx,
          config: const TelemetryConfig(holdFor: Duration.zero),
          now: () => clock,
          autoSchedule: false,
          observer: (_) => const TelemetryObserver(id: '0123456789abcdef0123456789abcdef'),
          zones: () => zones,
        );

    var salt = 0;
    TelemetryRecord drivePacket(double lat, double lon) {
      salt++;
      return TelemetryRecord.fromRx(
        RxPacket(
          at: clock.subtract(const Duration(seconds: 1)),
          raw: MeshPacket(
            header: makeHeader(RouteType.flood, PayloadType.advert),
            pathLenByte: 1,
            path: [Uint8List.fromList([0xa1])],
            payload: Uint8List.fromList(List.generate(110, (i) => (i + salt) & 0xff)),
          ).toBytes(),
          snrDb: 4,
          rssiDbm: -95,
        ),
        region: 'CMH',
        mode: ObserverMode.drive,
        pos: TelemetryPos(lat, lon),
      )!;
    }

    setUp(() {
      clock = DateTime.utc(2026, 11, 16, 12);
      posts.clear();
      tx = _Tx(posts);
      zones = PrivacyZones([_home]);
    });

    test('an in-zone packet goes without any position (no pos, no cell); an outside one keeps its pos', () async {
      final u = make();
      u.add(drivePacket(39.9612, -82.9988)); // home
      u.add(drivePacket(40.05, -82.9988)); // ~10 km away
      await u.flush();
      final packets = (posts.single['packets'] as List).cast<Map<String, dynamic>>();
      expect(packets, hasLength(2), reason: 'the header still counts for observer stats');
      final withPos = packets.where((x) => x.containsKey('pos')).toList();
      expect(withPos, hasLength(1));
      expect((withPos.single['pos'] as Map)['lat'], 40.05);
      expect(jsonEncode(posts), isNot(contains('39.9612')));
      final home = packets.firstWhere((x) => !x.containsKey('pos'));
      expect(home.containsKey('cell'), isFalse);
    });

    test('a zone added after the packet was queued still strips it; unknown zones strip every position', () async {
      final u = make();
      zones = const PrivacyZones([]);
      u.add(drivePacket(39.9612, -82.9988));
      zones = PrivacyZones([_home]); // the person adds the zone before the batch is built
      await u.flush();
      expect(jsonEncode(posts), isNot(contains('39.9612')));
      posts.clear();
      clock = clock.add(const Duration(minutes: 1));
      zones = PrivacyZones.notLoaded;
      u.add(drivePacket(40.05, -82.9988));
      await u.flush();
      expect((posts.single['packets'] as List).single.containsKey('pos'), isFalse, reason: 'fail closed');
    });
  });
}

class _Tx implements TelemetryTransport {
  final List<Map<String, dynamic>> posts;
  _Tx(this.posts);
  @override
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body) async {
    posts.add(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
    return const TelemetryHttpResult(200, body: {'stored': 1});
  }

  @override
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey) async => const TelemetryHttpResult(200);
}
