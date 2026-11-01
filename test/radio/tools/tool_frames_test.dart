// Tool frames against the real captures (test/support/tools_fixtures.dart) and the firmware layouts.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/lpp.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';

import '../../support/tools_fixtures.dart';

void main() {
  group('trace path', () {
    test('request: [36][tag][auth][flags][hashes]; 2-byte hashes set flags 1 (VERIFIED request shape)', () {
      final f = encodeSendTracePath(1793481996, [0xdf, 0x01], hashSize: 2);
      expect(f, hex('240c5de66a0000000001df01'));
      expect(encodeSendTracePath(1, [0xdf], hashSize: 1)[9], 0);
      expect(encodeSendTracePath(1, [1, 2, 3, 4], hashSize: 4)[9], 2);
    });

    test('request: empty path, ragged path, odd hash size, nine hops are refused before they reach the radio', () {
      expect(() => encodeSendTracePath(1, [], hashSize: 1), throwsArgumentError);
      expect(() => encodeSendTracePath(1, [1, 2, 3], hashSize: 2), throwsArgumentError);
      expect(() => encodeSendTracePath(1, [1, 2, 3], hashSize: 3), throwsArgumentError);
      expect(() => encodeSendTracePath(1, List.filled(9, 7), hashSize: 1), throwsArgumentError);
    });

    test('reply from the live run, 1-byte hash: hop SNR 0.25, final -0.25', () {
      final d = TraceData.tryParse(traceReply1Byte)!;
      expect(d.tag, 1793481996);
      expect(d.auth, 0);
      expect(d.hashSize, 1);
      expect(d.hops, 1);
      expect(d.hopHashHex(0), 'df');
      expect(d.hopSnrDb, [0.25]);
      expect(d.finalSnrDb, -0.25);
    });

    test('reply from the live run, 2-byte hash: path_len counts BYTES, hops = bytes >> (flags & 3)', () {
      final d = TraceData.tryParse(traceReply2Byte)!;
      expect(d.hashes.length, 2);
      expect(d.hashSize, 2);
      expect(d.hops, 1);
      expect(d.hopHashHex(0), 'df01');
      expect(d.hopSnrDb, [1.0]);
      expect(d.finalSnrDb, 3.25);
    });

    test('three hops, negative SNR, round trip through the radio-side encoder', () {
      final f = encodeTraceDataPush(77, [1, 2, 3, 4, 5, 6], [-3.5, 0.0, 7.25], -1.25, hashSize: 2);
      final d = TraceData.tryParse(f)!;
      expect(d.hops, 3);
      expect(d.hopSnrDb, [-3.5, 0.0, 7.25]);
      expect(d.finalSnrDb, -1.25);
      expect([d.hopHashHex(0), d.hopHashHex(1), d.hopHashHex(2)], ['0102', '0304', '0506']);
    });

    test('truncated, wrong code, empty: null, never an exception', () {
      expect(TraceData.tryParse(Uint8List(0)), isNull);
      expect(TraceData.tryParse(traceReply2Byte.sublist(0, 11)), isNull);
      expect(TraceData.tryParse(Uint8List.fromList([0x8A, ...traceReply2Byte.sublist(1)])), isNull);
      // hop SNR bytes cut off: the length check refuses it
      expect(TraceData.tryParse(traceReply2Byte.sublist(0, 13)), isNull);
    });

    test('a frame without the final SNR byte still gives the hops', () {
      final d = TraceData.tryParse(traceReply2Byte.sublist(0, 15))!;
      expect(d.hopSnrDb, [1.0]);
      expect(d.finalSnrDb, isNull);
    });
  });

  group('node discovery', () {
    test('request payload (VERIFIED shape): 0x80, filter 0x04 for repeaters, tag, since', () {
      final p = encodeDiscoverRequestPayload(0x0102, typeFilter: discoverFilterFor(const [2]));
      expect(p, [0x80, 0x04, 2, 1, 0, 0, 0, 0, 0, 0]);
      expect(encodeDiscoverRequestPayload(1, typeFilter: discoverFilterFor(const [2, 3, 4]))[1], 0x1C);
      expect(encodeDiscoverRequestPayload(1, prefixOnly: true)[0], 0x81);
      expect(encodeSendControlData(p)[0], 55);
    });

    test('full-key answer from the live run: repeater, they heard us at -5.25, we heard them at -4.25 / -125 dBm', () {
      final push = decodeFrame(discoverFull()) as ControlDataPush;
      expect(push.snrDb, -4.25);
      expect(push.rssiDbm, -125);
      expect(push.pathLen, 0);
      expect(push.payload.length, 38);
      final r = DiscoverResponse.tryParse(push.payload)!;
      expect(r.nodeType, AdvType.repeater);
      expect(r.remoteSnrDb, -5.25);
      expect(r.tag, 1840446589);
      expect(toHex(r.publicKey).substring(0, 16), repeaterKeyPrefixHex);
      expect(r.publicKey.length, 32);
    });

    test('prefix-only answer (14 bytes): 8-byte key', () {
      final push = decodeFrame(discoverPrefix()) as ControlDataPush;
      expect(push.payload.length, 14);
      final r = DiscoverResponse.tryParse(push.payload)!;
      expect(r.publicKey.length, 8);
      expect(r.tag, 1840447501);
    });
  });

  group('adverts, telemetry, settings', () {
    test('SEND_SELF_ADVERT: [7][0|1]', () {
      expect(encodeSendSelfAdvert(flood: false), [7, 0]);
      expect(encodeSendSelfAdvert(flood: true), [7, 1]);
    });

    test('GET_ADVERT_PATH: [42][0][key]; reply 22 with path_len 0x40 (2-byte hash, 0 hops) as on the live radio', () {
      final key = Uint8List(32)..[0] = 0xdf;
      final f = encodeGetAdvertPath(key);
      expect(f.length, 34);
      expect(f[0], 42);
      final r = AdvertPathFrame.tryParse(encodeAdvertPathResponse(1793480402, 0x40, const []))!;
      expect(r.receivedAtEpoch, 1793480402);
      expect(r.hops, 0);
      expect(r.hashSize, 2);
      final two = AdvertPathFrame.tryParse(encodeAdvertPathResponse(5, 0x42, [1, 2, 3, 4]))!;
      expect(two.hops, 2);
      expect(two.path, [1, 2, 3, 4]);
    });

    test('telemetry request for a contact: [39][0 0 0][key]', () {
      final key = Uint8List(32)..[0] = 0xdf;
      final f = encodeTelemetryReqFor(key);
      expect(f.length, 36);
      expect(f.sublist(0, 4), [39, 0, 0, 0]);
      expect(() => encodeTelemetryReqFor([1, 2]), throwsArgumentError);
    });

    test('telemetry answer from the live run is BIG endian: 3.86 V and 45.0 C (little endian would read 332 V)', () {
      final push = TelemetryPush.tryParse(encodeTelemetryResponsePush(hex('df0136c20a99'), repeaterTelemetryLpp))!;
      expect(push.prefixHex, 'df0136c20a99');
      final r = decodeLpp(push.lpp);
      expect(r.length, 2, reason: 'the zero padding is not a reading');
      expect(r[0].kind, LppKind.voltage);
      expect(r[0].value, closeTo(3.86, 1e-9));
      expect(r[1].kind, LppKind.temperature);
      expect(r[1].value, closeTo(45.0, 1e-9));
      expect(r[0].text, '3.86 V');
      expect(r[1].text, '45.0 °C');
    });

    test('LPP: GPS, humidity, pressure; unknown type stops the parse; negative temperature', () {
      final lpp = Uint8List.fromList([...lppVoltage(3.9), ...lppTemperature(-12.3), ...lppHumidity(55.5), ...lppGps(39.9612, -82.9988, 275.5), 9, 99, 1, 2]);
      final r = decodeLpp(lpp);
      expect(r.map((e) => e.kind), [LppKind.voltage, LppKind.temperature, LppKind.humidity, LppKind.gps]);
      expect(r[1].value, closeTo(-12.3, 1e-9));
      expect(r[2].value, 55.5);
      expect(r[3].lat, closeTo(39.9612, 1e-4));
      expect(r[3].lon, closeTo(-82.9988, 1e-4));
      expect(r[3].altitudeM, closeTo(275.5, 1e-9));
    });

    test('LPP: truncated record and empty input never throw', () {
      expect(decodeLpp(Uint8List(0)), isEmpty);
      expect(decodeLpp(Uint8List.fromList([1, 116, 1])), isEmpty);
    });

    test('settings frames: radio params units (kHz, Hz), tx power, name, position, other params', () {
      final p = encodeSetRadioParams(freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5);
      expect(p.length, 11);
      expect(ByteData.sublistView(p).getUint32(1, Endian.little), 910525);
      expect(ByteData.sublistView(p).getUint32(5, Endian.little), 62500);
      expect(p.sublist(9), [7, 5]);
      expect(encodeSetRadioTxPower(-4), [12, 0xFC]);
      expect(encodeSetAdvertName([0x41, 0x42]), [8, 0x41, 0x42]);
      final ll = encodeSetAdvertLatLon(39.961234, -82.998765);
      expect(ByteData.sublistView(ll).getInt32(1, Endian.little), 39961234);
      expect(ByteData.sublistView(ll).getInt32(5, Endian.little), -82998765);
      expect(encodeSetOtherParams(manualAdd: 1, telemetryModes: 0x15, advertLocPolicy: 1, multiAcks: 1), [38, 1, 0x15, 1, 1]);
    });

    test('SELF_INFO carries the four flags at bytes 44-47 (VERIFIED order: multi_acks, advert_loc_policy, telemetry, manual_add)', () {
      final f = encodeSelfInfo(
          txPowerDbm: 22, maxTxPowerDbm: 22, publicKey: Uint8List(32), freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: 'KE4BFI',
          multiAcks: 1, advertLocPolicy: 2, telemetryModes: 0x15, manualAdd: 1);
      final s = decodeFrame(f) as SelfInfoFrame;
      expect((s.multiAcks, s.advertLocPolicy, s.telemetryModes, s.manualAdd), (1, 2, 0x15, 1));
      expect(s.name, 'KE4BFI');
      expect(s.freqKhz, 910525);
    });
  });

  group('stats (VERIFIED raw frames)', () {
    test('radio stats: noise -120, rssi -117, snr +3.25, tx 41 s, rx 116 s', () {
      final s = decodeFrame(statsRadioFrame) as RadioStatsFrame;
      expect(s.noiseFloorDbm, -120);
      expect(s.lastRssiDbm, -117);
      expect(s.lastSnrDb, 3.25);
      expect(s.txAirSecs, 41);
      expect(s.rxAirSecs, 116);
    });

    test('packet stats: 30 bytes with receive errors', () {
      final s = decodeFrame(statsPacketsFrame) as PacketStatsFrame;
      expect(s.recv, 426);
      expect(s.sent, 197);
      expect(s.recvErrors, 7);
    });
  });
}
