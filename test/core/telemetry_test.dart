import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/radio_api.dart';

// Flood group-text packet: header 0x15 (route 1, type 5), 2 hops (0xA1, 0xB2), payload = recognisable secret bytes.
final _secret = [0xDE, 0xAD, 0xBE, 0xEF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA];
RxPacket _rx() => RxPacket(
      at: DateTime.utc(2026, 10, 23, 12),
      raw: Uint8List.fromList([0x15, 0x02, 0xA1, 0xB2, ..._secret]),
      snrDb: 6.5,
      rssiDbm: -97,
    );

void main() {
  test('record keeps header metadata and no payload', () {
    final r = TelemetryRecord.fromRx(_rx(), region: 'CMH')!;
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

  test('out-of-range signal values are dropped, not sent', () {
    final r = TelemetryRecord.fromRx(RxPacket(at: DateTime.utc(2026), raw: _rx().raw, snrDb: 99, rssiDbm: 12))!;
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
