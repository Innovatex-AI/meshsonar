// APP-6 (V1-PLAN D3): the car radio's RX log stream delivers every heard ADVERT (payload type 4) and drive mode keeps and uploads
// it with its raw bytes, so the server's node_advert sync can verify the signature and name the repeater. Driven from real
// 0x88 LOG_RX_DATA frames through the real MeshCoreCompanionLink, the observer record and the uploader.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/tools/advert_decode.dart' show buildAdvertPayload;

class _Radio implements ByteTransport {
  final c = StreamController<Uint8List>.broadcast();
  @override
  Stream<Uint8List> get incoming => c.stream;
  @override
  Future<void> send(Uint8List frame) async {}
  @override
  Future<void> disconnect() async {}
  @override
  bool get isConnected => true;
}

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

Uint8List _advertRaw(List<int> key, String name, {List<int> hops = const [0x1b], double? lat, double? lon}) => MeshPacket(
      header: makeHeader(RouteType.flood, PayloadType.advert),
      pathLenByte: hops.length,
      path: [for (final h in hops) Uint8List.fromList([h])],
      payload: buildAdvertPayload(key, 1700000000, AdvType.repeater, name, lat: lat, lon: lon),
    ).toBytes();

void main() {
  final at = DateTime.utc(2026, 11, 12, 15);
  late _Radio radio;
  late MeshCoreCompanionLink link;
  late _Tx tx;
  late TelemetryUploader up;
  late List<RxPacket> heard;
  late StreamSubscription<RxPacket> sub;

  setUp(() {
    radio = _Radio();
    link = MeshCoreCompanionLink(radio, timeout: const Duration(seconds: 1));
    tx = _Tx();
    up = TelemetryUploader(
      enabled: () => true,
      driverKey: () => 'k' * 40,
      keyApproved: () => true,
      transport: () => tx,
      config: const TelemetryConfig(holdFor: Duration.zero, minGap: Duration.zero),
      now: () => at.add(const Duration(minutes: 5)),
      autoSchedule: false,
      observer: (_) => const TelemetryObserver(id: '0123456789abcdef0123456789abcdef'),
    );
    heard = [];
    // What AppState._onTelemetryRx does in DRIVE mode (no position given here: a phone position is never part of an advert).
    sub = link.observerRxPackets.listen((rx) {
      heard.add(rx);
      final r = TelemetryRecord.fromRx(rx, mode: ObserverMode.drive);
      if (r != null) up.add(r);
    });
  });

  tearDown(() async {
    await sub.cancel();
    await link.close();
  });

  Future<void> hear(Uint8List raw, {double snr = 4.5, int rssi = -101}) async {
    radio.c.add(encodeLogRxData(snr, rssi, raw));
    await Future<void>.delayed(Duration.zero);
  }

  test('a heard advert survives the radio stream, even while the Rx log screen is paused, and is uploaded raw in drive mode', () async {
    link.rxLogPaused = true; // a remote request is in flight: the in-app Rx log pauses, the observer must not
    final inApp = <RxPacket>[];
    final s2 = link.rxPackets.listen(inApp.add);
    final raw = _advertRaw(List.filled(32, 0x1b), 'Hilltop RPT', lat: 39.96, lon: -82.99);
    await hear(raw);
    await s2.cancel();
    expect(inApp, isEmpty, reason: 'paused in-app stream');
    expect(heard, hasLength(1));
    expect(heard.single.raw, raw);
    expect(up.queued, 1);
    await up.flush();
    final j = tx.posts.single;
    expect((j['observer'] as Map)['mode'], 'drive');
    final pk = (j['packets'] as List).single as Map;
    expect(pk['type'], PayloadType.advert);
    expect(pk['raw'], [for (final b in raw) b.toRadixString(16).padLeft(2, '0')].join(), reason: 'full raw bytes, signature included');
    expect(pk['path'], ['1b']);
    // The advert carries the repeater's own advertised place inside raw; the phone adds no position and no cell of its own.
    expect(pk.containsKey('pos'), isFalse);
    expect(pk.containsKey('cell'), isFalse);
    expect(pk.containsKey('lat'), isFalse);
    expect(pk.containsKey('lon'), isFalse);
    expect(decodeAdvertPacket(raw)!.name, 'Hilltop RPT');
  });

  test('several adverts from different repeaters (1b52, d82f, 550c, 7417 style keys) all queue and go in one batch', () async {
    final keys = [
      [0x1b, 0x52, ...List.filled(30, 1)],
      [0xd8, 0x2f, ...List.filled(30, 2)],
      [0x55, 0x0c, ...List.filled(30, 3)],
      [0x74, 0x17, ...List.filled(30, 4)],
    ];
    for (final k in keys) {
      await hear(_advertRaw(k, 'R${k[0].toRadixString(16)}', hops: [k[0]]));
    }
    expect(up.queued, 4);
    await up.flush();
    final ps = [for (final p in (tx.posts.single['packets'] as List)) p as Map];
    expect(ps, hasLength(4));
    for (var i = 0; i < 4; i++) {
      final raw = ps[i]['raw'] as String;
      // the public key is the first 32 payload bytes: its first two bytes are the repeater's 4-hex id
      final info = decodeAdvertPacket([for (var x = 0; x < raw.length; x += 2) int.parse(raw.substring(x, x + 2), radix: 16)])!;
      expect(info.publicKey.sublist(0, 2), keys[i].sublist(0, 2));
    }
  });

  test('negative: junk, forged-short and non-advert frames neither crash the link nor identify the phone', () async {
    await hear(Uint8List.fromList([0x11])); // header only
    await hear(Uint8List.fromList([0x11, 0x00])); // no payload
    await hear(Uint8List.fromList([0x11, 0x00, 0x01, 0x02])); // forged advert: 3 payload bytes
    await hear(Uint8List.fromList([0xff, 0xff, 0xff, 0xff])); // reserved path size
    await hear(MeshPacket(header: makeHeader(RouteType.flood, PayloadType.advert), pathLenByte: 0, path: const [], payload: Uint8List(100)).toBytes()); // 1 byte short
    radio.c.add(Uint8List.fromList([0x88, 0x01])); // truncated LOG_RX_DATA frame
    await Future<void>.delayed(Duration.zero);
    // a private DM and a request are never recorded either
    await hear(MeshPacket(header: makeHeader(RouteType.flood, PayloadType.txtMsg), pathLenByte: 0, path: const [], payload: Uint8List(40)).toBytes());
    await hear(MeshPacket(header: makeHeader(RouteType.flood, PayloadType.req), pathLenByte: 0, path: const [], payload: Uint8List(40)).toBytes());
    expect(up.queued, 0);
    // the link still works afterwards
    await hear(_advertRaw(List.filled(32, 7), 'Still Works'));
    expect(up.queued, 1);
    await up.flush();
    final body = jsonEncode(tx.posts.single);
    for (final k in ['"pos"', '"cell"', '"lat"', '"lon"', 'name']) {
      expect(body.contains(k), isFalse, reason: k);
    }
  });

  test('an advert of the connected radio itself is not uploaded', () {
    final own = List<int>.generate(32, (i) => i + 1);
    final rx = RxPacket(at: at, raw: _advertRaw(own, 'Truck'), snrDb: 5, rssiDbm: -90);
    final hex = [for (final b in own) b.toRadixString(16).padLeft(2, '0')].join();
    expect(TelemetryRecord.fromRx(rx, mode: ObserverMode.drive, ownPublicKey: hex), isNull);
    expect(TelemetryRecord.fromRx(rx, mode: ObserverMode.drive), isNotNull);
  });
}
