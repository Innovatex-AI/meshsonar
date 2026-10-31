import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/radio/radio_api.dart';

// Flood group-text packet: header 0x15 (route 1, type 5), 2 one-byte hops (0xA1, 0xB2), then recognisable secret payload bytes.
final _secret = [0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA];
RxPacket _rx(DateTime at, {int salt = 0}) => RxPacket(
      at: at,
      raw: Uint8List.fromList([0x15, 0x02, 0xA1, 0xB2, ..._secret, salt & 0xff]),
      snrDb: 6.5,
      rssiDbm: -97,
    );

class _Tx implements TelemetryTransport {
  final posts = <({String key, String body})>[];
  final deletes = <String>[];
  final results = <Object>[]; // TelemetryHttpResult or an exception to throw; empty = 200
  TelemetryHttpResult deleteResult = const TelemetryHttpResult(200, body: {'deleted': 3});
  @override
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body) async {
    posts.add((key: driverKey, body: utf8.decode(body)));
    if (results.isEmpty) return const TelemetryHttpResult(200, body: {'stored': 1});
    final r = results.removeAt(0);
    if (r is TelemetryHttpResult) return r;
    throw r;
  }

  @override
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey) async {
    deletes.add(driverKey);
    return deleteResult;
  }
}

void main() {
  late DateTime clock;
  late bool on, approved;
  late String? key;
  late _Tx tx;
  late Directory dir;
  File? qf;

  TelemetryUploader make({TelemetryConfig config = const TelemetryConfig(holdFor: Duration.zero, minGap: Duration.zero)}) =>
      TelemetryUploader(
        enabled: () => on,
        driverKey: () => key,
        keyApproved: () => approved,
        transport: () => tx,
        appVersion: '0.18.0',
        platform: 'ios',
        queueFile: qf,
        config: config,
        now: () => clock,
        autoSchedule: false,
      );

  TelemetryRecord rec({int salt = 0, String? region = 'CMH', DateTime? at}) =>
      TelemetryRecord.fromRx(_rx(at ?? clock.subtract(const Duration(seconds: 5)), salt: salt), region: region)!;

  setUp(() {
    clock = DateTime.utc(2026, 10, 24, 12);
    on = true;
    approved = true;
    key = 'k' * 40;
    tx = _Tx();
    dir = Directory.systemTemp.createTempSync('telemetry_q');
    qf = File('${dir.path}/q.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('sends the meshsonar-telemetry/1 body with the driver key', () async {
    final u = make();
    expect(u.add(rec()), isTrue);
    await u.flush();
    expect(tx.posts, hasLength(1));
    expect(tx.posts.single.key, key);
    final j = jsonDecode(tx.posts.single.body) as Map<String, dynamic>;
    expect(j.keys.toSet(), {'format', 'app', 'region', 'packets'});
    expect(j['format'], 'meshsonar-telemetry/1');
    expect(j['app'], {'version': '0.18.0', 'platform': 'ios'});
    expect(j['region'], 'CMH');
    final p = (j['packets'] as List).single as Map<String, dynamic>;
    expect(p.keys.toList(), TelemetryRecord.wireKeys);
    expect(p['type'], 5);
    expect(p['route'], 1);
    expect(p['hash_size'], 1);
    expect(p['path'], ['a1', 'b2']);
    expect(p['snr'], 6.5);
    expect(p['rssi'], -97);
    expect(p['pkt_hash'], matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(p['rx_ts'], matches(RegExp(r'Z$')));
    expect(u.queued, 0);
    expect(u.sent, 1);
  });

  test('PRIVACY: payload bytes, text and coordinates never appear in the serialised body or the disk queue', () async {
    final u = make(config: const TelemetryConfig(holdFor: Duration.zero, minGap: Duration.zero));
    for (var i = 0; i < 3; i++) {
      u.add(rec(salt: i));
    }
    await u.flush();
    final body = tx.posts.single.body.toLowerCase();
    for (final needle in ['deadbeef', '222,173,190,239', 'dead', '11223344', '"payload"', '"raw"', '"text"', '"lat"', '"lon"', '"gps"', 'name']) {
      expect(body.contains(needle), isFalse, reason: needle);
    }
    // Every key anywhere in the body is on the server's allowlist.
    final allowed = {'format', 'app', 'version', 'platform', 'region', 'packets', ...TelemetryRecord.wireKeys};
    void walk(Object? o) {
      if (o is Map) {
        for (final e in o.entries) {
          expect(allowed.contains(e.key), isTrue, reason: 'unexpected key ${e.key}');
          walk(e.value);
        }
      } else if (o is List) {
        o.forEach(walk);
      }
    }

    walk(jsonDecode(tx.posts.single.body));
    // The disk queue holds the same shape, so it carries none either.
    tx.results.add(const TelemetryHttpResult(503));
    final u2 = make();
    u2.add(rec(salt: 9));
    await u2.flush();
    final disk = (await qf!.readAsString()).toLowerCase();
    expect(disk.contains('deadbeef'), isFalse);
    expect(disk.contains('"lat"') || disk.contains('"lon"') || disk.contains('payload'), isFalse);
  });

  test('private packet types are never queued or sent', () async {
    final u = make();
    // Direct TXT_MSG (type 2): header (2<<2)|2 = 0x0A.
    final txt = RxPacket(at: clock, raw: Uint8List.fromList([0x0A, 0x01, 0x11, ..._secret]));
    expect(TelemetryRecord.fromRx(txt), isNull);
    expect(u.add(TelemetryRecord(at: clock, payloadType: 2, routeType: 2)), isFalse);
    await u.flush();
    expect(tx.posts, isEmpty);
  });

  test('opt-out: nothing queued or sent, and the queue (memory + disk) is discarded', () async {
    tx.results.add(const TelemetryHttpResult(503));
    final u = make();
    u.add(rec());
    await u.flush(); // fails, stays queued, written to disk
    expect(qf!.existsSync(), isTrue);
    expect(u.queued, 1);
    on = false;
    expect(u.add(rec(salt: 1)), isFalse);
    await u.flush();
    expect(u.queued, 0);
    expect(qf!.existsSync(), isFalse);
    expect(tx.posts, hasLength(1)); // only the earlier (failed) attempt
  });

  test('no driver key: nothing is collected', () async {
    key = null;
    final u = make();
    expect(u.add(rec()), isFalse);
    key = '';
    expect(u.add(rec()), isFalse);
    await u.flush();
    expect(u.queued, 0);
    expect(tx.posts, isEmpty);
  });

  test('a key that is not approved yet keeps records but sends nothing', () async {
    approved = false;
    final u = make();
    u.add(rec());
    await u.flush();
    expect(tx.posts, isEmpty);
    expect(u.queued, 1);
    approved = true;
    await u.flush();
    expect(tx.posts, hasLength(1));
  });

  test('our own TX pings (and their echoes) are never uploaded', () async {
    final u = make(config: const TelemetryConfig(holdFor: Duration(seconds: 90), minGap: Duration.zero));
    final echo = rec();
    u.add(echo);
    u.add(rec(salt: 1));
    u.excludeHash(echo.packetHash!); // the ping's hash becomes known after its echoes were heard
    expect(u.queued, 1);
    expect(u.add(rec()), isFalse); // a later echo of the same transmission
    clock = clock.add(const Duration(seconds: 120));
    await u.flush();
    final packets = (jsonDecode(tx.posts.single.body)['packets'] as List);
    expect(packets, hasLength(1));
    expect(packets.single['pkt_hash'], isNot(echo.packetHash));
  });

  test('records are held before sending', () async {
    final u = make(config: const TelemetryConfig(holdFor: Duration(seconds: 90), minGap: Duration.zero));
    u.add(rec(at: clock));
    await u.flush();
    expect(tx.posts, isEmpty);
    clock = clock.add(const Duration(seconds: 91));
    await u.flush();
    expect(tx.posts, hasLength(1));
  });

  test('batches are capped, one request per minGap, grouped by region', () async {
    final u = make(config: const TelemetryConfig(holdFor: Duration.zero, minGap: Duration(seconds: 15), batchSize: 2));
    for (var i = 0; i < 3; i++) {
      u.add(rec(salt: i));
    }
    u.add(rec(salt: 50, region: 'DAY'));
    await u.flush();
    await u.flush(); // too soon
    expect(tx.posts, hasLength(1));
    expect((jsonDecode(tx.posts.single.body)['packets'] as List), hasLength(2));
    clock = clock.add(const Duration(seconds: 16));
    await u.flush();
    expect(tx.posts, hasLength(2));
    expect(jsonDecode(tx.posts[1].body)['region'], 'CMH');
    clock = clock.add(const Duration(seconds: 16));
    await u.flush();
    expect(jsonDecode(tx.posts[2].body)['region'], 'DAY');
    expect(u.queued, 0);
  });

  test('queue is bounded (oldest dropped) and intake is rate capped', () async {
    final u = make(config: const TelemetryConfig(maxQueue: 3, maxPerMinute: 5, holdFor: Duration.zero));
    for (var i = 0; i < 8; i++) {
      u.add(rec(salt: i));
    }
    expect(u.queued, 3);
    expect(u.dropped, greaterThanOrEqualTo(3));
    clock = clock.add(const Duration(minutes: 2));
    expect(u.add(rec(salt: 100)), isTrue); // a new minute window
  });

  test('server failures back off exponentially and keep the records', () async {
    tx.results.addAll([const TelemetryHttpResult(500), const SocketException('down'), const TelemetryHttpResult(500)]);
    final u = make(config: const TelemetryConfig(holdFor: Duration.zero, minGap: Duration.zero, baseBackoff: Duration(seconds: 30)));
    u.add(rec());
    await u.flush();
    expect(tx.posts, hasLength(1));
    await u.flush(); // inside the 30 s backoff
    expect(tx.posts, hasLength(1));
    clock = clock.add(const Duration(seconds: 31));
    await u.flush();
    expect(tx.posts, hasLength(2));
    clock = clock.add(const Duration(seconds: 31)); // second failure doubles to 60 s
    await u.flush();
    expect(tx.posts, hasLength(2));
    clock = clock.add(const Duration(seconds: 30));
    await u.flush();
    expect(tx.posts, hasLength(3));
    expect(u.queued, 1);
  });

  test('429 honours Retry-After', () async {
    tx.results.add(const TelemetryHttpResult(429, retryAfterSec: 120));
    final u = make();
    u.add(rec());
    await u.flush();
    clock = clock.add(const Duration(seconds: 100));
    await u.flush();
    expect(tx.posts, hasLength(1));
    clock = clock.add(const Duration(seconds: 25));
    await u.flush();
    expect(tx.posts, hasLength(2));
    expect(u.queued, 0);
  });

  test('401/403 pause for an hour; 400/413 drop the batch', () async {
    tx.results.add(const TelemetryHttpResult(403));
    final u = make();
    u.add(rec());
    await u.flush();
    clock = clock.add(const Duration(minutes: 30));
    await u.flush();
    expect(tx.posts, hasLength(1));
    expect(u.queued, 1);
    tx.results.add(const TelemetryHttpResult(400, body: {'error': 'bad'}));
    clock = clock.add(const Duration(minutes: 31));
    await u.flush();
    expect(tx.posts, hasLength(2));
    expect(u.queued, 0);
    expect(u.dropped, 1);
  });

  test('records older than the server window are dropped, never sent', () async {
    final u = make();
    u.add(rec(at: clock.subtract(const Duration(hours: 40))));
    clock = clock.add(const Duration(hours: 10));
    await u.flush();
    expect(tx.posts, isEmpty);
    expect(u.queued, 0);
  });

  test('the disk queue survives a restart and is bounded', () async {
    tx.results.add(const TelemetryHttpResult(503));
    final u = make();
    for (var i = 0; i < 4; i++) {
      u.add(rec(salt: i));
    }
    await u.flush();
    expect(qf!.existsSync(), isTrue);
    final u2 = make(config: const TelemetryConfig(holdFor: Duration.zero, minGap: Duration.zero, maxQueue: 3));
    await u2.load();
    expect(u2.queued, 3);
    await u2.flush();
    final packets = jsonDecode(tx.posts.last.body)['packets'] as List;
    expect(packets, hasLength(3));
    expect(packets.first['path'], ['a1', 'b2']);
    expect(qf!.existsSync(), isFalse, reason: 'file removed once the queue is empty');
  });

  test('erase: DELETE with the driver key; a failed erase is remembered and retried', () async {
    final u = make();
    u.add(rec());
    expect(await u.eraseServerData(), 3);
    expect(tx.deletes, [key]);
    expect(u.pendingErase, isFalse);

    tx.deleteResult = const TelemetryHttpResult(500);
    expect(await u.eraseServerData(), isNull);
    expect(u.pendingErase, isTrue);
    expect(qf!.existsSync(), isTrue);
    // A restart retries it, even with telemetry off.
    on = false;
    tx.deleteResult = const TelemetryHttpResult(200, body: {'deleted': 7});
    final u2 = make();
    await u2.load();
    expect(u2.pendingErase, isTrue);
    await u2.flush();
    expect(u2.pendingErase, isFalse);
    expect(tx.deletes, hasLength(3));
    expect(qf!.existsSync(), isFalse);
  });

  test('account deleted: the queue and a remembered erase are dropped (the erase could never succeed without the key)', () async {
    final u = make();
    u.add(rec());
    tx.deleteResult = const TelemetryHttpResult(500);
    expect(await u.eraseServerData(), isNull);
    expect(u.pendingErase, isTrue);
    expect(u.queued, 1);
    await u.forgetServerAccount();
    expect(u.pendingErase, isFalse);
    expect(u.queued, 0);
    // a restart finds nothing to send or erase
    final u2 = make();
    await u2.load();
    expect(u2.pendingErase, isFalse);
    expect(u2.queued, 0);
    key = null;
    await u2.flush();
    expect(tx.posts, isEmpty);
    expect(tx.deletes, hasLength(1), reason: 'only the first, failed attempt');
  });

  test('body builder omits invalid app/region claims', () {
    final j = jsonDecode(buildTelemetryBody([rec()], region: 'cmh', appVersion: 'bad version!', platform: 'macOS')) as Map;
    expect(j.containsKey('region'), isFalse);
    expect(j.containsKey('app'), isFalse);
  });
}
