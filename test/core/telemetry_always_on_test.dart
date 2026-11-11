// Contract section 8 (Andy, Nov 9 2026: "the phone is always the observer"): own-ping echoes go as `own: true` (raw only
// when the ping was public), mode `drive` packets carry the exact `pos` instead of `cell`, `pos` never outside drive mode,
// the drive's end trim downgrades waiting positions, v1 batches leave own echoes out.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

final _at = DateTime.utc(2026, 11, 9, 12);

RxPacket _trace(int salt) /* a PATH packet: its hash ignores the route, like a repeat of a ping */ => RxPacket(
      at: _at,
      raw: MeshPacket(
        header: makeHeader(RouteType.flood, PayloadType.path),
        pathLenByte: 1,
        path: [Uint8List.fromList([0xa1])],
        payload: Uint8List.fromList(List.generate(20, (i) => (i + salt) & 0xff)),
      ).toBytes(),
      snrDb: 5.25,
      rssiDbm: -97,
    );

class _Tx implements TelemetryTransport {
  final posts = <Map<String, dynamic>>[];
  @override
  Future<TelemetryHttpResult> postTelemetry(String k, List<int> body) async {
    posts.add(jsonDecode(utf8.decode(body)) as Map<String, dynamic>);
    return const TelemetryHttpResult(200, body: {'stored': 1});
  }

  @override
  Future<TelemetryHttpResult> deleteTelemetry(String k) async => const TelemetryHttpResult(200);
}

void main() {
  const pos = TelemetryPos(39.96123456789, -82.99876543, accM: 4.37);

  test('wire keys v2 now include pos and own (pinned)', () {
    expect(TelemetryRecord.wireKeysV2, ['rx_ts', 'type', 'route', 'hash_size', 'path', 'snr', 'rssi', 'pkt_hash', 'raw', 'channel', 'cell', 'pos', 'own']);
  });

  test('drive mode: pos instead of cell, 6 decimals, acc_m', () {
    final r = TelemetryRecord.fromRx(_trace(1), mode: ObserverMode.drive, pos: pos, cell: '872a1072bffffff')!;
    final j = r.toJsonV2();
    expect(j['pos'], {'lat': 39.961235, 'lon': -82.998765, 'acc_m': 4.4});
    expect(j.containsKey('cell'), isFalse, reason: 'pos replaces cell');
    for (final k in ['lat', 'lon']) {
      expect(j.containsKey(k), isFalse, reason: 'never a top-level coordinate');
    }
  });

  test('drive mode without pos falls back to the cell', () {
    final r = TelemetryRecord.fromRx(_trace(2), mode: ObserverMode.drive, cell: '872a1072bffffff')!;
    expect(r.toJsonV2()['cell'], '872a1072bffffff');
    expect(r.toJsonV2().containsKey('pos'), isFalse);
  });

  test('pos is never on a background or home packet, and never with a bad fix', () {
    for (final m in [ObserverMode.background, ObserverMode.home]) {
      expect(TelemetryRecord.fromRx(_trace(3), mode: m, pos: pos)!.toJsonV2().containsKey('pos'), isFalse, reason: m.name);
    }
    expect(TelemetryRecord.fromRx(_trace(3), mode: ObserverMode.drive, pos: const TelemetryPos(39.9, -83, accM: 900))!.pos, isNull);
    expect(TelemetryRecord.fromRx(_trace(3), mode: ObserverMode.drive, pos: const TelemetryPos(0, 0))!.pos, isNull);
    expect(TelemetryRecord.fromRx(_trace(3), mode: ObserverMode.drive, pos: const TelemetryPos(95, 0))!.pos, isNull);
  });

  test('queue round trip keeps drive mode, pos and own; a tampered pos on a background record is dropped', () {
    final r = TelemetryRecord.fromRx(_trace(4), mode: ObserverMode.drive, pos: pos)!.asOwn(keepRaw: true);
    final back = TelemetryRecord.tryFromJson(jsonDecode(jsonEncode(r.toQueueJson())))!;
    expect(back.mode, ObserverMode.drive);
    expect(back.own, isTrue);
    expect(back.pos!.lat, closeTo(39.961235, 1e-9));
    final bg = {...TelemetryRecord.fromRx(_trace(5))!.toQueueJson(), 'pos': {'lat': 39.9, 'lon': -83.0}};
    expect(TelemetryRecord.tryFromJson(bg)!.pos, isNull);
  });

  TelemetryUploader make(_Tx tx, {TelemetryObserver? obs = const TelemetryObserver(id: '0123456789abcdef0123456789abcdef')}) => TelemetryUploader(
        enabled: () => true,
        driverKey: () => 'k' * 40,
        keyApproved: () => true,
        transport: () => tx,
        config: const TelemetryConfig(holdFor: Duration(seconds: 90), minGap: Duration.zero),
        now: () => _at.add(const Duration(minutes: 3)),
        autoSchedule: false,
        observer: (_) => obs,
      );

  test('own echo, ping public: own true with raw; ping not public: header only; later echoes are marked too', () async {
    final tx = _Tx();
    final u = make(tx);
    final a = TelemetryRecord.fromRx(_trace(10))!;
    final b = TelemetryRecord.fromRx(_trace(11))!;
    u.add(a);
    u.add(b);
    u.markOwn(a.packetHash!, publicRaw: true);
    u.markOwn(b.packetHash!, publicRaw: false);
    // A later echo of b (another path) arrives after the hash is known.
    final b2 = TelemetryRecord.fromRx(RxPacket(
      at: _at,
      raw: MeshPacket(
        header: makeHeader(RouteType.flood, PayloadType.path),
        pathLenByte: 2,
        path: [Uint8List.fromList([0xa1]), Uint8List.fromList([0xb2])],
        payload: Uint8List.fromList(List.generate(20, (i) => (i + 11) & 0xff)),
      ).toBytes(),
      snrDb: 1,
      rssiDbm: -110,
    ))!;
    expect(b2.packetHash, b.packetHash);
    expect(u.add(b2), isTrue);
    await u.flush();
    final ps = [for (final p in tx.posts.single['packets'] as List) p as Map];
    expect(ps, hasLength(3));
    final pa = ps.firstWhere((p) => p['pkt_hash'] == a.packetHash);
    expect(pa['own'], isTrue);
    expect(pa['raw'], isA<String>());
    for (final p in ps.where((p) => p['pkt_hash'] == b.packetHash)) {
      expect(p['own'], isTrue);
      expect(p.containsKey('raw'), isFalse);
    }
  });

  test('a v1 batch (no observer id) leaves own echoes out; an all-own v1 batch is not sent', () async {
    final tx = _Tx();
    final u = make(tx, obs: null);
    final a = TelemetryRecord.fromRx(_trace(20))!;
    u.add(a);
    u.markOwn(a.packetHash!, publicRaw: true);
    await u.flush();
    expect(tx.posts, isEmpty);
    expect(u.queued, 0);
    u.add(TelemetryRecord.fromRx(_trace(21))!);
    u.add(TelemetryRecord.fromRx(_trace(22))!);
    u.markOwn(TelemetryRecord.fromRx(_trace(22))!.packetHash!, publicRaw: true);
    await u.flush();
    expect((tx.posts.single['packets'] as List), hasLength(1));
    expect(tx.posts.single['format'], 'meshsonar-telemetry/1');
  });

  test('drive end trim: waiting exact positions near the end go out as their cell', () async {
    final tx = _Tx();
    final u = make(tx);
    u.add(TelemetryRecord.fromRx(_trace(30), mode: ObserverMode.drive, pos: const TelemetryPos(39.9600, -83.0000))!);
    u.add(TelemetryRecord.fromRx(_trace(31), mode: ObserverMode.drive, pos: const TelemetryPos(39.9000, -83.0000))!);
    u.trimDriveEnd(39.9601, -83.0001, 500, (la, lo) => '872a1072bffffff');
    await u.flush();
    final ps = [for (final p in tx.posts.single['packets'] as List) p as Map];
    expect(ps[0].containsKey('pos'), isFalse);
    expect(ps[0]['cell'], '872a1072bffffff');
    expect(ps[1]['pos'], {'lat': 39.9, 'lon': -83.0});
    expect((tx.posts.single['observer'] as Map)['mode'], 'drive');
  });
}
