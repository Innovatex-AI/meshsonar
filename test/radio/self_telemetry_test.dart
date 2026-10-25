// Radio chip temperature (stream 7, radio_health): CMD_SEND_TELEMETRY_REQ "self" form -> PUSH_CODE_TELEMETRY_RESPONSE
// with CayenneLPP (firmware examples/companion_radio/MyMesh.cpp ~1700-1718 at 81dbae5). Byte fixtures follow the
// firmware's write order: [0x8B][0][pubkey prefix 6][ch 1, LPP_VOLTAGE, u16 BE 0.01 V][ch 1, LPP_TEMPERATURE, i16 BE
// 0.1 °C][...other sensors, maybe GPS].
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/radio/simulator.dart';

const prefix = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF];

class _ErrTransport implements ByteTransport {
  final _in = StreamController<Uint8List>.broadcast();
  final sent = <Uint8List>[];
  @override
  Stream<Uint8List> get incoming => _in.stream;
  @override
  bool get isConnected => true;
  @override
  Future<void> disconnect() async {}
  @override
  Future<void> send(Uint8List frame) async {
    sent.add(frame);
    scheduleMicrotask(() => _in.add(Uint8List.fromList([Resp.err, ErrCode.unsupportedCmd])));
  }
}

void main() {
  test('request bytes: [39][3 reserved] is the self form', () {
    expect(encodeSelfTelemetryReq(), [39, 0, 0, 0]);
  });

  test('decodes channel-1 voltage and MCU temperature', () {
    final f = Uint8List.fromList([0x8B, 0, ...prefix, 1, 116, 0x01, 0x87, 1, 103, 0x01, 0x3B]);
    final t = decodeSelfTelemetryPush(f, selfPrefix: prefix)!;
    expect(t.voltageV, closeTo(3.91, 1e-9));
    expect(t.mcuTempC, closeTo(31.5, 1e-9));
  });

  test('negative temperature; no temperature on boards without an MCU sensor', () {
    final cold = encodeSelfTelemetryPush(prefix6: prefix, voltageV: 3.7, mcuTempC: -12.3);
    expect(decodeSelfTelemetryPush(cold)!.mcuTempC, closeTo(-12.3, 1e-9));
    final none = encodeSelfTelemetryPush(prefix6: prefix, voltageV: 3.7);
    expect(decodeSelfTelemetryPush(none)!.mcuTempC, isNull);
  });

  test('a GPS entry after it is skipped and never surfaced; another node\'s answer is ignored', () {
    final gps = [1, 136, 0x06, 0x1F, 0x00, 0xF3, 0x5A, 0x00, 0x00, 0x27, 0x10];
    final f = encodeSelfTelemetryPush(prefix6: prefix, voltageV: 3.9, mcuTempC: 30, extraLpp: gps);
    final t = decodeSelfTelemetryPush(f, selfPrefix: prefix)!;
    expect(t.mcuTempC, 30);
    expect(decodeSelfTelemetryPush(f, selfPrefix: const [1, 2, 3, 4, 5, 6]), isNull);
  });

  test('short, wrong-code and truncated frames', () {
    expect(decodeSelfTelemetryPush(Uint8List.fromList([0x8B, 0, 1, 2])), isNull);
    expect(decodeSelfTelemetryPush(Uint8List.fromList([0x88, 0, ...prefix, 1, 103, 0, 1])), isNull);
    final trunc = Uint8List.fromList([0x8B, 0, ...prefix, 1, 103, 0x01]);
    expect(decodeSelfTelemetryPush(trunc)!.mcuTempC, isNull);
    final unknownFirst = Uint8List.fromList([0x8B, 0, ...prefix, 1, 240, 3, 1, 1, 1, 103, 0, 100]);
    expect(decodeSelfTelemetryPush(unknownFirst)!.mcuTempC, isNull, reason: 'unknown size: parsing stops');
  });

  test('link + simulator: selfTelemetry answers with the simulated chip temperature', () async {
    final link = MeshCoreCompanionLink(SimulatedTransport(seed: 1));
    await link.start();
    final t = await link.selfTelemetry();
    expect(t, isNotNull);
    expect(t!.mcuTempC, inInclusiveRange(24.0, 32.0));
    expect(t.voltageV, inInclusiveRange(3.4, 4.1));
    await link.close();
  });

  test('ERR unsupported: asked once per link, then null without a command', () async {
    final tr = _ErrTransport();
    final link = MeshCoreCompanionLink(tr, timeout: const Duration(milliseconds: 200));
    expect(await link.selfTelemetry(), isNull);
    expect(await link.selfTelemetry(), isNull);
    expect(tr.sent.where((f) => f[0] == Cmd.sendTelemetryReq), hasLength(1));
  });
}
