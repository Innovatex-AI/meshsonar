// Byte vectors for the companion protocol codec. Layouts come from MeshCore firmware
// examples/companion_radio/MyMesh.cpp (line numbers below refer to the checked-out source at
// /home/claude/meshcore-dev/meshcore) and docs/companion_protocol.md.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/protocol.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);

void main() {
  group('codes (MyMesh.cpp lines 9-140)', () {
    test('command/response/push values', () {
      expect(Cmd.appStart, 1); // line 9
      expect(Cmd.sendChannelTxtMsg, 3); // line 11
      expect(Cmd.setDeviceTime, 6); // line 14
      expect(Cmd.syncNextMessage, 10); // line 18
      expect(Cmd.deviceQuery, 22); // line 30
      expect(Cmd.getChannel, 31); // line 39
      expect(Cmd.setChannel, 32); // line 40
      expect(Cmd.sendControlData, 55); // line 57
      expect(Cmd.getStats, 56); // line 58
      expect(Resp.selfInfo, 5); // line 80
      expect(Resp.deviceInfo, 13); // line 88
      expect(Resp.channelInfo, 18); // line 93
      expect(Resp.stats, 24); // line 99
      expect(Push.msgWaiting, 0x83); // line 120
      expect(Push.logRxData, 0x88); // line 125
      expect(Push.controlData, 0x8E); // line 131
    });
  });

  group('encoders', () {
    test('APP_START: [01][ver][6 reserved][name] — firmware needs len>=8 (line 1076); docs example', () {
      expect(encodeAppStart('mccli'), b([0x01, 0x01, 0, 0, 0, 0, 0, 0, 0x6d, 0x63, 0x63, 0x6c, 0x69]));
    });

    test('DEVICE_QUERY: [16][app_target_ver] (line 1056; docs example "16 03")', () {
      expect(encodeDeviceQuery(3), b([0x16, 0x03]));
    });

    test('SET_DEVICE_TIME: [06][u32 LE] (line 1287)', () {
      expect(encodeSetDeviceTime(0x499602D2), b([0x06, 0xD2, 0x02, 0x96, 0x49]));
    });

    test('GET_CHANNEL: [1F][idx] (line 1752; docs example "1F 01")', () {
      expect(encodeGetChannel(1), b([0x1F, 0x01]));
    });

    test('SET_CHANNEL: [20][idx][name x32][secret x16] = 50 bytes (line 1769)', () {
      final secret = List<int>.generate(16, (i) => i + 1);
      final f = encodeSetChannel(2, '#wardriving', secret);
      expect(f.length, 50);
      expect(f.sublist(0, 2), [0x20, 0x02]);
      expect(utf8.decode(f.sublist(2, 13)), '#wardriving');
      expect(f.sublist(13, 34).every((x) => x == 0), isTrue);
      expect(f.sublist(34), secret);
    });

    test('SEND_CHANNEL_TXT_MSG: [03][00][idx][ts u32][text] (line 1178; docs example)', () {
      expect(encodeSendChannelText(1, 1234567890, 'Hello'),
          b([0x03, 0x00, 0x01, 0xD2, 0x02, 0x96, 0x49, 0x48, 0x65, 0x6C, 0x6C, 0x6F]));
    });

    test('SYNC_NEXT_MESSAGE / GET_STATS(radio) (lines 1415, 1914)', () {
      expect(encodeSyncNextMessage(), b([0x0A]));
      expect(encodeGetStats(StatsType.radio), b([0x38, 0x01]));
    });

    test('NODE_DISCOVER_REQ payload (simple_repeater/MyMesh.cpp 846-857) inside SEND_CONTROL_DATA (line 2015)', () {
      final p = encodeDiscoverRequestPayload(0x01020304);
      expect(p, b([0x80, 0x04, 0x04, 0x03, 0x02, 0x01, 0, 0, 0, 0]));
      expect(encodeSendControlData(p).sublist(0, 2), [0x37, 0x80]);
      expect(() => encodeSendControlData([0x10]), throwsArgumentError);
    });
  });

  group('decoders', () {
    test('OK / ERR (writeOKFrame/writeErrFrame lines 153-163)', () {
      expect(decodeFrame(b([0x00])), isA<OkFrame>());
      final e = decodeFrame(b([0x01, 0x02])) as ErrFrame;
      expect(e.code, ErrCode.notFound);
    });

    test('SELF_INFO (lines 1076-1112)', () {
      final key = List<int>.generate(32, (i) => 0xA0 + (i % 16));
      final f = BytesBuilder()
        ..add([0x05, 0x01, 22, 30]) // code, adv type, tx power, max tx power
        ..add(key)
        ..add([0x30, 0x46, 0x64, 0x02]) // lat 40.126 * 1e6 = 40126000 = 0x02644630
        ..add([0xB0, 0x96, 0x0E, 0xFB]) // lon -82.93 * 1e6 = -82930000 = 0xFB0E96B0
        ..add([0, 0, 0, 0]) // multi_acks, loc policy, telemetry, manual add
        ..add([0xBD, 0xE4, 0x0D, 0x00]) // freq 910525 (= 910.525 MHz * 1000)
        ..add([0x24, 0xF4, 0x00, 0x00]) // bw 62500 (= 62.5 kHz * 1000)
        ..add([7, 5])
        ..add(utf8.encode('Car'));
      final si = decodeFrame(f.toBytes()) as SelfInfoFrame;
      expect(si.txPowerDbm, 22);
      expect(si.maxTxPowerDbm, 30);
      expect(si.publicKey, key);
      expect(si.advLat, closeTo(40.126, 1e-9));
      expect(si.advLon, closeTo(-82.93, 1e-9));
      expect(si.freqMhz, closeTo(910.525, 1e-9));
      expect(si.bwKhz, closeTo(62.5, 1e-9));
      expect(si.sf, 7);
      expect(si.cr, 5);
      expect(si.name, 'Car');
    });

    test('SELF_INFO round-trips through the simulator encoder', () {
      final si = decodeFrame(encodeSelfInfo(
              txPowerDbm: -3, maxTxPowerDbm: 22, publicKey: List.filled(32, 7), freqKhz: 869525, bwHz: 250000, sf: 11, cr: 5, name: 'X'))
          as SelfInfoFrame;
      expect(si.txPowerDbm, -3);
      expect(si.freqMhz, 869.525);
      expect(si.bwKhz, 250);
    });

    test('DEVICE_INFO (lines 1056-1075): ver, max_channels at byte 3, strings at 8/20/60, path_hash_mode at 81', () {
      final f = encodeDeviceInfo(
          firmwareVerCode: 14,
          maxChannels: 40,
          buildDate: '19 Feb 2025',
          manufacturer: 'Heltec V3',
          firmwareVersion: 'v1.18.0',
          pathHashMode: 1);
      expect(f.length, 82);
      expect(f[0], 13);
      expect(f[3], 40);
      final d = decodeFrame(f) as DeviceInfoFrame;
      expect(d.firmwareVerCode, 14);
      expect(d.maxChannels, 40);
      expect(d.buildDate, '19 Feb 2025');
      expect(d.manufacturer, 'Heltec V3');
      expect(d.firmwareVersion, 'v1.18.0');
      expect(d.pathHashMode, 1);
      // Old firmware: short frame, unknown fields null.
      final old = decodeFrame(b([13, 2])) as DeviceInfoFrame;
      expect(old.firmwareVerCode, 2);
      expect(old.maxChannels, isNull);
    });

    test('CHANNEL_INFO (lines 1752-1766): [12][idx][name x32][secret x16]', () {
      final raw = Uint8List(50)
        ..[0] = 0x12
        ..[1] = 0x00
        ..setRange(2, 8, utf8.encode('Public'))
        ..setRange(34, 50, [0x8b, 0x33, 0x87, 0xe9, 0xc5, 0xcd, 0xea, 0x6a, 0xc9, 0xe5, 0xed, 0xba, 0xa1, 0x15, 0xcd, 0x72]);
      final c = decodeFrame(raw) as ChannelInfoFrame;
      expect(c.index, 0);
      expect(c.name, 'Public');
      expect(c.secret.first, 0x8b);
      expect(c.isEmpty, isFalse);
      final empty = decodeFrame(encodeChannelInfo(3, '', Uint8List(16))) as ChannelInfoFrame;
      expect(empty.isEmpty, isTrue);
      expect(() => decodeFrame(b([0x12, 0x00, 0x41])), throwsA(isA<ProtocolException>()));
    });

    test('STATS radio (lines 1928-1942): noise i16, rssi i8, snr i8/4, tx/rx air u32', () {
      final f = b([0x18, 0x01, 0x90, 0xFF, 0xB5, 0x2D, 0x10, 0, 0, 0, 0x20, 0, 0, 0]);
      final s = decodeFrame(f) as RadioStatsFrame;
      expect(s.noiseFloorDbm, -112);
      expect(s.lastRssiDbm, -75);
      expect(s.lastSnrDb, 11.25);
      expect(s.txAirSecs, 16);
      expect(s.rxAirSecs, 32);
      expect(encodeRadioStats(noiseFloorDbm: -112, lastRssiDbm: -75, lastSnrDb: 11.25, txAirSecs: 16, rxAirSecs: 32), f);
      expect(decodeFrame(b([0x18, 0x07, 1, 2])), isA<OtherStatsFrame>(), reason: 'unknown sub-type kept raw');
    });

    // Layouts below re-read from MeshCore main b204f9a (FIRMWARE_VER_CODE 14), examples/companion_radio/MyMesh.cpp.
    // No captured real-radio frame exists yet: these vectors are built from the firmware's memcpy order.
    test('STATS core (lines 1916-1927): battery u16, uptime u32, err_flags u16 bitmask, queue u8 = 11 B', () {
      final f = b([0x18, 0x00, 0x48, 0x0F, 0x03, 0x50, 0x01, 0x00, 0x06, 0x00, 0x02]);
      final s = decodeFrame(f) as CoreStatsFrame;
      expect(s.batteryMv, 3912);
      expect(s.uptimeSecs, 86019);
      expect(s.errFlags, RadioErrFlag.cadTimeout | RadioErrFlag.startRxTimeout);
      expect(s.queueLen, 2);
      expect(encodeCoreStats(batteryMv: 3912, uptimeSecs: 86019, errFlags: 6, queueLen: 2), f);
      expect(() => decodeFrame(b([0x18, 0x00, 1, 2])), throwsA(isA<ProtocolException>()));
      expect(encodeGetStats(StatsType.core), b([0x38, 0x00]));
    });

    test('STATS packets (lines 1943-1962): 7 x u32 = 30 B; the 26 B form has no recv_errors', () {
      final f = encodePacketStats(
          recv: 18233, sent: 412, floodTx: 400, directTx: 12, floodRx: 17001, directRx: 1232, recvErrors: 37);
      expect(f.length, 30);
      expect(f.sublist(0, 6), b([0x18, 0x02, 0x39, 0x47, 0x00, 0x00]));
      expect(f.sublist(26), b([37, 0, 0, 0]));
      final s = decodeFrame(f) as PacketStatsFrame;
      expect([s.recv, s.sent, s.floodTx, s.directTx, s.floodRx, s.directRx, s.recvErrors],
          [18233, 412, 400, 12, 17001, 1232, 37]);
      final old = encodePacketStats(recv: 1, sent: 2, floodTx: 3, directTx: 4, floodRx: 5, directRx: 6, recvErrors: null);
      expect(old.length, 26);
      final o = decodeFrame(old) as PacketStatsFrame;
      expect(o.directRx, 6);
      expect(o.recvErrors, isNull);
      expect(decodeFrame(encodePacketStats(
              recv: 0xFFFFFFFF, sent: 0, floodTx: 0, directTx: 0, floodRx: 0, directRx: 0)) as PacketStatsFrame,
          isA<PacketStatsFrame>().having((x) => x.recv, 'recv', 0xFFFFFFFF));
      expect(() => decodeFrame(old.sublist(0, 25)), throwsA(isA<ProtocolException>()));
    });

    test('BATT_AND_STORAGE (lines 1517-1527): [0C][mv u16][used_kb u32][total_kb u32] = 11 B; 3 B legacy', () {
      expect(Cmd.getBattAndStorage, 20);
      expect(Resp.battAndStorage, 12);
      expect(encodeGetBattAndStorage(), b([0x14]));
      final f = b([0x0C, 0x48, 0x0F, 0x78, 0, 0, 0, 0xC0, 0x07, 0, 0]);
      final s = decodeFrame(f) as BattAndStorageFrame;
      expect(s.batteryMv, 3912);
      expect(s.storageUsedKb, 120);
      expect(s.storageTotalKb, 1984);
      expect(encodeBattAndStorage(batteryMv: 3912, usedKb: 120, totalKb: 1984), f);
      final legacy = decodeFrame(b([0x0C, 0x48, 0x0F])) as BattAndStorageFrame;
      expect(legacy.batteryMv, 3912);
      expect(legacy.storageTotalKb, isNull);
      expect(() => decodeFrame(b([0x0C, 0x48])), throwsA(isA<ProtocolException>()));
    });

    // Edge cases for the stats parsers. Still UNVERIFIED against a real radio: every vector here is built from the
    // documented byte layout (docs/PROTOCOL.md 6.1a "Verification status"), not captured from hardware.
    test('stats parsers: truncation, trailing bytes, signed and extreme values (documented layouts, unverified)', () {
      // radio: 14 B needed; 13 throws, extra trailing bytes (newer firmware) are ignored.
      final radio = b([0x18, 0x01, 0x90, 0xFF, 0xB5, 0x2D, 0x10, 0, 0, 0, 0x20, 0, 0, 0]);
      expect(() => decodeFrame(radio.sublist(0, 13)), throwsA(isA<ProtocolException>()));
      final longer = decodeFrame(b([...radio, 0xAA, 0xBB])) as RadioStatsFrame;
      expect(longer.noiseFloorDbm, -112);
      expect(longer.rxAirSecs, 32);
      // negative SNR (i8 / 4) and the most negative values
      final neg = decodeFrame(encodeRadioStats(noiseFloorDbm: -32768, lastRssiDbm: -128, lastSnrDb: -32)) as RadioStatsFrame;
      expect([neg.noiseFloorDbm, neg.lastRssiDbm, neg.lastSnrDb], [-32768, -128, -32.0]);
      // core: 11 B needed, trailing bytes ignored, u32 uptime above 2^31 stays positive, u16 flags keep high bits
      final core = encodeCoreStats(batteryMv: 65535, uptimeSecs: 0xFFFFFFFF, errFlags: 0x8001, queueLen: 255);
      final c = decodeFrame(b([...core, 9, 9])) as CoreStatsFrame;
      expect([c.batteryMv, c.uptimeSecs, c.errFlags, c.queueLen], [65535, 0xFFFFFFFF, 0x8001, 255]);
      expect(() => decodeFrame(core.sublist(0, 10)), throwsA(isA<ProtocolException>()));
      // packets: 27 to 29 bytes is neither the 26 B nor the 30 B form; the 26 B prefix still decodes, recv_errors absent
      final p30 = encodePacketStats(recv: 1, sent: 2, floodTx: 3, directTx: 4, floodRx: 5, directRx: 6, recvErrors: 7);
      final p28 = decodeFrame(p30.sublist(0, 28)) as PacketStatsFrame;
      expect(p28.directRx, 6);
      expect(p28.recvErrors, isNull);
      // battery and storage: 4 to 10 bytes keeps the battery and drops the storage rather than guessing
      final bs = encodeBattAndStorage(batteryMv: 4200, usedKb: 1, totalKb: 2);
      final part = decodeFrame(bs.sublist(0, 7)) as BattAndStorageFrame;
      expect(part.batteryMv, 4200);
      expect(part.storageTotalKb, isNull);
      expect(part.storageUsedKb, isNull);
    });

    test('LOG_RX_DATA push (logRxRaw line 291): [88][snr*4 i8][rssi i8][raw...]', () {
      final p = decodeFrame(b([0x88, 0xE6, 0xA6, 0x15, 0x01, 0xDF, 0xAA])) as LogRxDataPush;
      expect(p.snrDb, -6.5);
      expect(p.rssiDbm, -90);
      expect(p.raw, [0x15, 0x01, 0xDF, 0xAA]);
      expect(encodeLogRxData(-6.5, -90, [0x15, 0x01, 0xDF, 0xAA]), b([0x88, 0xE6, 0xA6, 0x15, 0x01, 0xDF, 0xAA]));
    });

    test('CONTROL_DATA push (onControlDataRecv line 810) carrying a DISCOVER_RESP (simple_repeater 809-813)', () {
      final key = List<int>.generate(32, (i) => i);
      final frame = encodeControlDataPush(5.0, -80, 0, [0x92, 0xE8, 4, 3, 2, 1, ...key]);
      expect(frame.sublist(0, 4), [0x8E, 20, 0xB0, 0]);
      final p = decodeFrame(frame) as ControlDataPush;
      expect(p.snrDb, 5.0);
      expect(p.rssiDbm, -80);
      final d = DiscoverResponse.tryParse(p.payload)!;
      expect(d.nodeType, 2);
      expect(d.remoteSnrDb, -6.0);
      expect(d.tag, 0x01020304);
      expect(d.publicKey, key);
    });

    test('CHANNEL_MSG_RECV_V3 (lines 560-575) and legacy', () {
      final v3 = b([0x11, 0x14, 0, 0, 0x02, 0x01, 0x00, 0xD2, 0x02, 0x96, 0x49, ...utf8.encode('A: hi')]);
      final m = decodeFrame(v3) as ChannelMsgFrame;
      expect(m.snrDb, 5.0);
      expect(m.channelIndex, 2);
      expect(m.pathLen, 1);
      expect(m.timestamp, 1234567890);
      expect(m.text, 'A: hi');
      final legacy = decodeFrame(b([0x08, 0x02, 0xFF, 0x00, 0xD2, 0x02, 0x96, 0x49, 0x41])) as ChannelMsgFrame;
      expect(legacy.snrDb, isNull);
      expect(legacy.pathLen, 0xFF);
      expect(legacy.text, 'A');
    });

    test('MSG_WAITING, NO_MORE_MESSAGES, unknown, empty', () {
      expect(decodeFrame(b([0x83])), isA<MsgWaitingPush>());
      expect(decodeFrame(b([0x0A])), isA<NoMoreMessagesFrame>());
      expect(decodeFrame(b([0x95, 1])), isA<UnknownFrame>());
      expect(() => decodeFrame(b([])), throwsA(isA<ProtocolException>()));
      expect(isPushCode(0x88), isTrue);
      expect(isPushCode(0x18), isFalse);
    });
  });
}
