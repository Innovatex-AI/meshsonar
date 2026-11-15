// Golden MQTT payloads (firmware-style `packets` and `status` JSON, observer-firmware-notes.md section 5) and topics.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/mqtt/mqtt_payload.dart';
import 'package:meshsonar/radio/packet.dart';

import 'support.dart';

void main() {
  test('topics: meshcore/{IATA}/{PUBKEY}/packets|status, uppercase', () {
    expect(
      MqttTopics.packets('cmh', rfcPublicHex),
      'meshcore/CMH/D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A/packets',
    );
    expect(
      MqttTopics.status('CMH', rfcPublicHex),
      'meshcore/CMH/D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A/status',
    );
  });

  test('timestamp: ISO 8601 UTC with microseconds and +00:00', () {
    expect(mqttTimestamp(DateTime.utc(2026, 10, 17, 12, 0, 0, 123, 456)), '2026-10-17T12:00:00.123456+00:00');
    expect(mqttTimestamp(DateTime.utc(2026, 1, 2, 3, 4, 5)), '2026-01-02T03:04:05.000000+00:00');
  });

  test('golden packets message: flood TRACE with a path (path only in raw, not as a field)', () {
    final p = rx(
      rawPacket(PayloadType.trace, route: RouteType.flood, path: [0xaa, 0xbb], payload: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]),
    );
    final msg = mqttPacketMessage(filtered(p)!, p, publicKeyHex: rfcPublicHex);
    expect(
      msg,
      '{"origin":"MeshSonar D75A9801",'
      '"origin_id":"D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A",'
      '"timestamp":"2026-11-15T18:04:05.123456+00:00","type":"PACKET","direction":"rx","len":"15","packet_type":"9",'
      '"payload_len":"11","route":"F","raw":"2502AABB0102030405060708090A0B","SNR":"7.3","RSSI":"-92",'
      '"hash":"B4CDDD5BF0401F57","time":"18:04:05","date":"15/11/2026"}',
    );
  });

  test('golden packets message: direct PATH carries the hop list, transport route is still D', () {
    final p = rx(
      rawPacket(PayloadType.path, route: RouteType.transportDirect, path: [0x1f, 0x2e], payload: [9, 9, 9]),
      snr: -3.0,
      rssi: -118,
    );
    final j = mqttPacketJson(filtered(p)!, p, publicKeyHex: rfcPublicHex)!;
    expect(j.keys.toList(), [
      'origin',
      'origin_id',
      'timestamp',
      'type',
      'direction',
      'len',
      'packet_type',
      'payload_len',
      'route',
      'raw',
      'SNR',
      'RSSI',
      'hash',
      'time',
      'date',
      'path',
    ]);
    expect(j['route'], 'D');
    expect(j['path'], ['1f', '2e']);
    expect(j['SNR'], '-3.0');
    expect(j['RSSI'], '-118');
    expect(
      j['raw'],
      '233412785602'
      '1F2E'
      '090909',
    );
    expect(j['len'], '${p.raw.length}');
  });

  test('unknown SNR / RSSI are left out', () {
    final p = rx(rawPacket(PayloadType.advert), snr: null, rssi: null);
    final j = mqttPacketJson(filtered(p)!, p, publicKeyHex: rfcPublicHex)!;
    expect(j.containsKey('SNR'), isFalse);
    expect(j.containsKey('RSSI'), isFalse);
    expect(j['packet_type'], '4');
  });

  test('nothing about the person or place: no name, position, cell, region, mode or channel keys', () {
    final p = rx(rawPacket(PayloadType.grpTxt));
    final j = mqttPacketJson(filtered(p, channel: '#wardriving')!, p, publicKeyHex: rfcPublicHex)!;
    for (final k in ['lat', 'lon', 'pos', 'cell', 'region', 'mode', 'channel', 'name', 'observer', 'own']) {
      expect(j.containsKey(k), isFalse, reason: k);
    }
  });

  test('golden status message', () {
    final s = jsonEncode(
      mqttStatusJson(publicKeyHex: rfcPublicHex, at: DateTime.utc(2026, 11, 15, 18), model: 'Heltec V3', firmware: 'v1.10.0'),
    );
    expect(
      s,
      '{"status":"online","timestamp":"2026-11-15T18:00:00.000000+00:00","origin":"MeshSonar D75A9801",'
      '"origin_id":"D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A","model":"Heltec V3",'
      '"firmware_version":"v1.10.0","client_version":"meshsonar-app/1"}',
    );
    final bare = mqttStatusJson(publicKeyHex: rfcPublicHex, at: DateTime.utc(2026));
    expect(bare.containsKey('model'), isFalse);
    expect(bare.containsKey('firmware_version'), isFalse);
  });

  test('a record that does not match its bytes is refused', () {
    final advert = rx(rawPacket(PayloadType.advert));
    final dm = rx(rawPacket(PayloadType.txtMsg));
    expect(mqttPacketJson(filtered(advert)!, dm, publicKeyHex: rfcPublicHex), isNull);
    final other = rx(rawPacket(PayloadType.advert, path: [1]));
    expect(mqttPacketJson(filtered(advert)!, other, publicKeyHex: rfcPublicHex), isNull);
  });
}
