import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/telemetry.dart';
import 'package:meshsonar/radio/radio_api.dart';

class _Capture implements TelemetrySink {
  final batches = <List<TelemetryRecord>>[];
  @override
  Future<void> send(List<TelemetryRecord> batch) async => batches.add(batch);
}

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

  test('uploader hands nothing to the sink while off, and drops what was queued', () async {
    final sink = _Capture();
    var on = true;
    final u = TelemetryUploader(sink: sink, enabled: () => on);
    final rec = TelemetryRecord.fromRx(_rx())!;
    expect(u.add(rec), isTrue);
    on = false;
    expect(u.add(rec), isFalse);
    expect(await u.flush(), 0);
    expect(u.queued, 0);
    on = true;
    expect(await u.flush(), 0);
    expect(sink.batches, isEmpty);
  });

  test('uploader batches while on', () async {
    final sink = _Capture();
    final u = TelemetryUploader(sink: sink, enabled: () => true, batchSize: 2);
    final rec = TelemetryRecord.fromRx(_rx())!;
    for (var i = 0; i < 5; i++) {
      u.add(rec);
    }
    expect(await u.flush(), 5);
    expect(sink.batches.map((b) => b.length), [2, 2, 1]);
  });

  test('default sink is a no-op', () async {
    final u = TelemetryUploader(enabled: () => true);
    u.add(TelemetryRecord.fromRx(_rx())!);
    expect(await u.flush(), 1); // accepted by the no-op sink, nothing leaves the phone
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
