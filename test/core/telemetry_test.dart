import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/radio/packet.dart' show MeshPacket, decryptGroupText;

import '../support/meshtrack_packets.dart';

// Flood group-text packet: header 0x15 (route 1, type 5), 2 hops (0xA1, 0xB2), payload = recognisable secret bytes.
final _secret = [0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA];
RxPacket _rx() => RxPacket(
      at: DateTime.utc(2026, 10, 23, 12),
      raw: Uint8List.fromList([0x15, 0x02, 0xA1, 0xB2, ..._secret]),
      snrDb: 6.5,
      rssiDbm: -97,
    );

/// Stands in for the channel check where a test is about something else (a shareable group packet).
bool _anyChannel(List<int> _) => true;

void main() {
  test('record keeps header metadata and no payload', () {
    final r = TelemetryRecord.fromRx(_rx(), region: 'CMH', shareableChannel: _anyChannel)!;
    expect(r.payloadType, 5);
    expect(r.routeType, 1);
    expect(r.pathHashes, ['a1', 'b2']);
    final j = r.toJson();
    expect(j.keys.toList(), TelemetryRecord.wireKeys);
    // No payload bytes anywhere in the serialised form, in any encoding we could plausibly emit.
    expect(r.hashSize, 1);
    final text = j.toString().toLowerCase();
    expect(text.contains('deadbeef'), isFalse);
    expect(text.contains('222, 173'), isFalse);
    expect(j.containsKey('payload'), isFalse);
    expect(j.containsKey('raw'), isFalse);
    expect(j.containsKey('text'), isFalse);
    expect(j.containsKey('lat'), isFalse);
  });

  test('non-packets produce no record', () {
    expect(TelemetryRecord.fromRx(RxPacket(at: DateTime.utc(2026), raw: Uint8List.fromList([1]))), isNull);
  });

  test('private packet types never become a record', () {
    for (final t in [0, 1, 2, 7]) {
      final raw = Uint8List.fromList([(t << 2) | 1, 0x00, 0x01, 0x02, 0x03]);
      expect(TelemetryRecord.fromRx(RxPacket(at: DateTime.utc(2026), raw: raw)), isNull, reason: 'type $t');
    }
  });

  // MT-8 privacy pin (MeshTrack plan sections 6 and 9): a MeshTrack position is a GRP_TXT on a private channel; it never
  // becomes a record, heard from a friend or as our own send heard back through repeaters, whatever the observer holds.
  test('a MeshTrack position on a private group channel never becomes a record (friend, and our own send heard back)', () {
    final shareable = ShareableChannels(
      () => [publicChannelSecret16, hashtagSecret16('#ohio')],
      named: () => [(name: 'public', key: publicChannelSecret16), (name: '#ohio', key: hashtagSecret16('#ohio'))],
    );
    for (final rx in [meshTrackRx(name: 'Sam'), meshTrackRx(pathLen: 2), meshTrackRx(pathLen: 5, name: 'KE4BFI')]) {
      // Positive control: the bytes really are the position, readable with the group key.
      expect(decryptGroupText(meshTrackTestKey, MeshPacket.tryParse(rx.raw)!.payload)!.text, contains(meshTrackTestPosition));
      for (final mode in ObserverMode.values) {
        expect(TelemetryRecord.fromRx(rx, region: 'CMH', channelMatch: shareable.match, mode: mode), isNull);
        expect(TelemetryRecord.fromRx(rx, region: 'CMH', shareableChannel: shareable.call, mode: mode), isNull);
        expect(TelemetryRecord.fromRx(rx, region: 'CMH', mode: mode), isNull, reason: 'no channel check at all: fail closed');
      }
    }
    // Control: the same text on Public does become a record.
    expect(TelemetryRecord.fromRx(meshTrackRx(key: publicChannelSecret16, pathLen: 2), channelMatch: shareable.match), isNotNull);
  });

  test('out-of-range signal values are dropped, not sent', () {
    final r = TelemetryRecord.fromRx(RxPacket(at: DateTime.utc(2026), raw: _rx().raw, snrDb: 99, rssiDbm: 12), shareableChannel: _anyChannel)!;
    expect(r.snrDb, isNull);
    expect(r.rssiDbm, isNull);
  });

  test('setting defaults on and persists the opt-out in the settings JSON', () {
    expect(const Settings().telemetryEnabled, isTrue);
    expect(const Settings().toJson().containsKey('telemetry_enabled'), isFalse);
    final off = const Settings().copyWith(telemetryEnabled: false);
    expect(off.toJson()['telemetry_enabled'], false);
    expect(Settings.fromJson(off.toJson()).telemetryEnabled, isFalse);
    expect(Settings.fromJson(const {}).telemetryEnabled, isTrue);
  });
}
