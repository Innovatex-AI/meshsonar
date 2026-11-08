// Fixed Nov 8 2026 (CR7): telemetry promised "private channels ... are never recorded at all", but the headers of
// private-channel packets (GRP_TXT/GRP_DATA) were recorded and sent. Now a group packet becomes a record only when its MAC
// verifies under a key anyone may know (Public, a # channel this phone holds); everything else fails closed, and group
// records queued before the fix (no mark) are dropped.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/core/telemetry_uploader.dart';
import 'package:meshsonar/radio/crypto.dart' show channelHash;
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/radio_api.dart';

RxPacket groupRx(List<int> secret, {String text = 'hello'}) => RxPacket(
      at: DateTime.utc(2026, 11, 8, 12),
      raw: MeshPacket(
        header: makeHeader(RouteType.flood, PayloadType.grpTxt),
        pathLenByte: 1,
        path: [Uint8List.fromList([0xa1])],
        payload: buildGroupTextPayload(secret, 1000, 'Ann', text),
      ).toBytes(),
      snrDb: 5,
      rssiDbm: -90,
    );

/// A private channel key whose one-byte hash collides with the Public channel's.
Uint8List privateKeyCollidingWithPublic() {
  final want = channelHash(publicChannelSecret16);
  for (var i = 0; i < 100000; i++) {
    final k = Uint8List.fromList(List.generate(16, (j) => (i * 31 + j * 7 + (i >> 8)) & 0xff));
    if (channelHash(k) == want && !_same(k, publicChannelSecret16)) return k;
  }
  throw StateError('no colliding key found');
}

bool _same(List<int> a, List<int> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

void main() {
  final hashtag = hashtagSecret16('#cmh');
  final shareable = ShareableChannels(() => [publicChannelSecret16, hashtag]);

  test('a group packet with no channel check never becomes a record (fail closed)', () {
    expect(TelemetryRecord.fromRx(groupRx(publicChannelSecret16)), isNull);
  });

  test('Public and the phone\'s # channels are shared; the record is marked checked', () {
    final pub = TelemetryRecord.fromRx(groupRx(publicChannelSecret16), shareableChannel: shareable.call)!;
    expect(pub.channelChecked, isTrue);
    expect(TelemetryRecord.fromRx(groupRx(hashtag), shareableChannel: shareable.call), isNotNull);
  });

  test('a private channel is never recorded, even when its hash byte equals Public\'s (the MAC decides)', () {
    final private = Uint8List.fromList(List.generate(16, (i) => 200 - i));
    expect(TelemetryRecord.fromRx(groupRx(private), shareableChannel: shareable.call), isNull);
    final colliding = privateKeyCollidingWithPublic();
    expect(channelHash(colliding), channelHash(publicChannelSecret16));
    expect(TelemetryRecord.fromRx(groupRx(colliding), shareableChannel: shareable.call), isNull);
  });

  test('a # channel the phone does not hold is not shared (it cannot be told from a private one)', () {
    expect(TelemetryRecord.fromRx(groupRx(hashtagSecret16('#elsewhere')), shareableChannel: shareable.call), isNull);
  });

  test('the checked mark stays on the phone: in the queue form, never on the wire', () {
    final r = TelemetryRecord.fromRx(groupRx(publicChannelSecret16), shareableChannel: shareable.call)!;
    expect(r.toJson().keys, TelemetryRecord.wireKeys);
    expect(r.toQueueJson()['channel_checked'], isTrue);
    expect(TelemetryRecord.tryFromJson(r.toQueueJson())!.channelChecked, isTrue);
  });

  test('a group record queued before the fix (no mark) is dropped when the queue is read; other types are kept', () {
    final old = {'rx_ts': '2026-11-08T12:00:00.000Z', 'type': 5, 'route': 1, 'hash_size': 1, 'path': ['a1'], 'snr': 5.0, 'rssi': -90, 'pkt_hash': 'abcd'};
    expect(TelemetryRecord.tryFromJson(old), isNull);
    expect(TelemetryRecord.tryFromJson({...old, 'type': PayloadType.advert}), isNotNull);
  });

  test('the uploader refuses an unchecked group record', () {
    final u = TelemetryUploader(
      enabled: () => true,
      driverKey: () => 'k' * 32,
      keyApproved: () => true,
      transport: () => null,
      autoSchedule: false,
      now: () => DateTime.utc(2026, 11, 8, 12, 1),
    );
    expect(u.add(TelemetryRecord(at: DateTime.utc(2026, 11, 8, 12), payloadType: PayloadType.grpTxt, routeType: 1)), isFalse);
    expect(u.add(TelemetryRecord(at: DateTime.utc(2026, 11, 8, 12), payloadType: PayloadType.grpTxt, routeType: 1, channelChecked: true)), isTrue);
  });
}
