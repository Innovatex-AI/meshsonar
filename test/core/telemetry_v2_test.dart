// Phone observer O2 (Nov 8 2026): the privacy rules of `meshsonar-telemetry/2` (contract meshsonar-infra
// docs/planning/phone-observer-contract-v2-2026-11-08.md section 3). Raw bytes only for public types (ADVERT, PATH, TRACE)
// and for group packets whose channel was proven Public / # by MAC; private types never become a record; never lat/lon;
// the cell is an H3 resolution-7 index and never in home mode.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/core/hex_cells.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/crypto.dart' show channelHash;
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/protocol.dart' show AdvType;
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/tools/advert_decode.dart' show buildAdvertPayload;

final _at = DateTime.utc(2026, 11, 8, 12);

RxPacket _pkt(int type, List<int> payload, {int route = RouteType.flood}) => RxPacket(
      at: _at,
      raw: MeshPacket(header: makeHeader(route, type), pathLenByte: 1, path: [Uint8List.fromList([0xa1])], payload: Uint8List.fromList(payload))
          .toBytes(),
      snrDb: 4,
      rssiDbm: -95,
    );

RxPacket _group(List<int> key, {String text = 'meet at noon'}) => RxPacket(
      at: _at,
      raw: MeshPacket(
        header: makeHeader(RouteType.flood, PayloadType.grpTxt),
        pathLenByte: 1,
        path: [Uint8List.fromList([0xa1])],
        payload: buildGroupTextPayload(key, 1000, 'Ann', text),
      ).toBytes(),
      snrDb: 5,
      rssiDbm: -90,
    );

String _hex(List<int> b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();

H3? _loadH3() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib']) {
    if (!File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

void main() {
  final cmh = hashtagSecret16('#cmh');
  final channels = ShareableChannels(
    () => [publicChannelSecret16, cmh],
    named: () => [(name: 'public', key: publicChannelSecret16), (name: '#cmh', key: cmh)],
  );
  final unnamedOnly = ShareableChannels(() => [publicChannelSecret16]);

  test('the v2 wire keys are pinned: v1 keys plus raw, channel, cell (and pos, own since section 8); nothing else', () {
    expect(TelemetryRecord.wireKeys, ['rx_ts', 'type', 'route', 'hash_size', 'path', 'snr', 'rssi', 'pkt_hash']);
    expect(TelemetryRecord.wireKeysV2, [...TelemetryRecord.wireKeys, 'raw', 'channel', 'cell', 'pos', 'own']);
  });

  test('private types (REQ, RESPONSE, TXT_MSG, ANON_REQ) never become a record, whatever is passed', () {
    for (final t in [0, 1, 2, 7]) {
      final r = TelemetryRecord.fromRx(_pkt(t, List.filled(20, 0x42)),
          channelMatch: (_) => 'public', shareableChannel: (_) => true, cell: '872a1072bffffff');
      expect(r, isNull, reason: 'type $t');
      // Even a hand-made record cannot carry raw for them, and the uploader never accepts them.
      final made = TelemetryRecord(at: _at, payloadType: t, routeType: 1, raw: 'abcd');
      expect(made.raw, isNull);
      expect(made.mayLeavePhone, isFalse);
    }
  });

  test('raw only for ADVERT, PATH and TRACE among the non-group types', () {
    for (final t in [PayloadType.advert, PayloadType.path, PayloadType.trace]) {
      final r = TelemetryRecord.fromRx(_pkt(t, List.filled(40, 0x33)))!;
      expect(r.raw, isNotNull, reason: 'type $t');
      expect(r.raw, _hex(_pkt(t, List.filled(40, 0x33)).raw));
      expect(r.toJsonV2()['raw'], r.raw);
      expect(r.toJsonV2().containsKey('channel'), isFalse);
    }
    for (final t in [PayloadType.ack, PayloadType.multipart, PayloadType.control, PayloadType.rawCustom]) {
      final r = TelemetryRecord.fromRx(_pkt(t, List.filled(20, 0x33)))!;
      expect(r.raw, isNull, reason: 'type $t is header only');
      expect(r.toJsonV2().containsKey('raw'), isFalse);
    }
  });

  test('group raw only with MAC proof: Public and a held # channel carry raw + channel', () {
    final pub = TelemetryRecord.fromRx(_group(publicChannelSecret16), channelMatch: channels.match)!;
    expect(pub.channel, 'public');
    expect(pub.raw, _hex(_group(publicChannelSecret16).raw));
    expect(pub.toJsonV2()['channel'], 'public');
    final tag = TelemetryRecord.fromRx(_group(cmh), channelMatch: channels.match)!;
    expect(tag.channel, '#cmh');
    expect(tag.raw, isNotNull);
  });

  test('a group packet proven only under an unnamed key goes header only (no raw, no channel)', () {
    final r = TelemetryRecord.fromRx(_group(publicChannelSecret16), channelMatch: unnamedOnly.match)!;
    expect(r.channelChecked, isTrue);
    expect(r.raw, isNull);
    expect(r.channel, isNull);
    // The v1 path (bool check) never carries raw either.
    final v1 = TelemetryRecord.fromRx(_group(publicChannelSecret16), shareableChannel: channels.call)!;
    expect(v1.raw, isNull);
  });

  test('private channels never become a record, also when their hash byte collides with Public', () {
    final private = Uint8List.fromList(List.generate(16, (i) => 200 - i));
    expect(TelemetryRecord.fromRx(_group(private), channelMatch: channels.match), isNull);
    Uint8List? colliding;
    final want = channelHash(publicChannelSecret16);
    for (var i = 0; i < 100000 && colliding == null; i++) {
      final k = Uint8List.fromList(List.generate(16, (j) => (i * 31 + j * 7 + (i >> 8)) & 0xff));
      if (channelHash(k) == want && _hex(k) != _hex(publicChannelSecret16)) colliding = k;
    }
    expect(TelemetryRecord.fromRx(_group(colliding!), channelMatch: channels.match), isNull);
    expect(TelemetryRecord.fromRx(_group(hashtagSecret16('#elsewhere')), channelMatch: channels.match), isNull);
  });

  test('a group record cannot be given raw without a valid channel, or a channel without raw', () {
    final noChan = TelemetryRecord(at: _at, payloadType: PayloadType.grpTxt, routeType: 1, channelChecked: true, raw: 'abcd');
    expect(noChan.raw, isNull);
    final bad = TelemetryRecord(at: _at, payloadType: PayloadType.grpTxt, routeType: 1, channelChecked: true, raw: 'abcd', channel: 'Secret Club');
    expect(bad.raw, isNull);
    expect(bad.channel, isNull);
    final unchecked = TelemetryRecord(at: _at, payloadType: PayloadType.grpTxt, routeType: 1, raw: 'abcd', channel: 'public');
    expect(unchecked.raw, isNull);
    final chanOnly = TelemetryRecord(at: _at, payloadType: PayloadType.grpTxt, routeType: 1, channelChecked: true, channel: 'public');
    expect(chanOnly.channel, isNull);
    expect(chanOnly.toJsonV2().containsKey('channel'), isFalse);
  });

  test('raw longer than 256 bytes (512 hex) is refused; raw must be even lower hex', () {
    expect(TelemetryRecord(at: _at, payloadType: PayloadType.trace, routeType: 1, raw: 'ab' * 256).raw, isNotNull);
    expect(TelemetryRecord(at: _at, payloadType: PayloadType.trace, routeType: 1, raw: 'ab' * 257).raw, isNull);
    expect(TelemetryRecord(at: _at, payloadType: PayloadType.advert, routeType: 1, raw: 'ABCD').raw, isNull);
    expect(TelemetryRecord(at: _at, payloadType: PayloadType.advert, routeType: 1, raw: 'abc').raw, isNull);
    expect(TelemetryRecord(at: _at, payloadType: PayloadType.advert, routeType: 1, raw: 'a' * 514).raw, isNull);
  });

  test('never latitude/longitude on a packet; the cell is a res-7 index or nothing', () {
    final r = TelemetryRecord.fromRx(_pkt(PayloadType.advert, List.filled(40, 3)), cell: '872a1072bffffff')!;
    final j = r.toJsonV2();
    expect(j.keys.every(TelemetryRecord.wireKeysV2.contains), isTrue);
    for (final k in ['lat', 'lon', 'latitude', 'longitude', 'position', 'gps']) {
      expect(j.containsKey(k), isFalse);
    }
    expect(j['cell'], '872a1072bffffff');
    // Anything that is not a resolution-7 H3 index (a finer cell, coordinates in disguise) is dropped.
    expect(TelemetryRecord(at: _at, payloadType: 4, routeType: 1, cell: '8b2a1072b59afff').cell, isNull);
    expect(TelemetryRecord(at: _at, payloadType: 4, routeType: 1, cell: '39.96,-83.00').cell, isNull);
  });

  test('home mode never carries a cell', () {
    final r = TelemetryRecord.fromRx(_pkt(PayloadType.advert, List.filled(40, 3)), cell: '872a1072bffffff', mode: ObserverMode.home)!;
    expect(r.cell, isNull);
    expect(r.toJsonV2().containsKey('cell'), isFalse);
    expect(r.mode, ObserverMode.home);
  });

  test('the own radio\'s advert is dropped entirely; other adverts keep their raw', () {
    final own = List<int>.generate(32, (i) => i + 1);
    final payload = buildAdvertPayload(own, 1000, AdvType.chat, 'My Radio');
    expect(TelemetryRecord.fromRx(_pkt(PayloadType.advert, payload), ownPublicKey: _hex(own).toUpperCase()), isNull);
    final other = buildAdvertPayload(List.filled(32, 9), 1000, AdvType.repeater, 'Hilltop');
    expect(TelemetryRecord.fromRx(_pkt(PayloadType.advert, other), ownPublicKey: _hex(own))!.raw, isNotNull);
  });

  test('the queue keeps raw / channel / cell / mode, and re-applies every rule when read back', () {
    final r = TelemetryRecord.fromRx(_group(publicChannelSecret16), channelMatch: channels.match, cell: '872a1072bffffff')!;
    final back = TelemetryRecord.tryFromJson(jsonDecode(jsonEncode(r.toQueueJson())))!;
    expect(back.raw, r.raw);
    expect(back.channel, 'public');
    expect(back.cell, '872a1072bffffff');
    final home = TelemetryRecord.fromRx(_pkt(PayloadType.advert, List.filled(40, 3)), mode: ObserverMode.home)!;
    expect(TelemetryRecord.tryFromJson(home.toQueueJson())!.mode, ObserverMode.home);
    // A tampered queue entry cannot widen what is sent.
    final ack = {'rx_ts': '2026-11-08T12:00:00.000Z', 'type': 3, 'route': 1, 'hash_size': 1, 'path': ['a1'], 'raw': 'abcd', 'cell': 'zz'};
    final t = TelemetryRecord.tryFromJson(ack)!;
    expect(t.raw, isNull);
    expect(t.cell, isNull);
    expect(TelemetryRecord.tryFromJson({...ack, 'type': 2}), isNull);
  });

  final h3 = _loadH3();
  test('the cell the app computes is H3 resolution 7, the parent of the res-11 cell', () {
    final id = hexId(hexCellOf(h3!, 39.9612, -82.9988, res: 7));
    expect(id, matches(telemetryCellRe));
    expect(h3.getResolution(BigInt.parse(id, radix: 16)), 7);
    final r = TelemetryRecord.fromRx(_pkt(PayloadType.advert, List.filled(40, 3)), cell: id)!;
    expect(r.toJsonV2()['cell'], id);
  }, skip: h3 == null ? 'libh3 not found (brew install h3)' : false);
}
