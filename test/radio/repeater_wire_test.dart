// Parsers against frames measured on a real repeater (INNO-OB-2, Oct 31 2026). The hex strings below are copied from
// meshsonar-infra/docs/planning/research-logs/live-run1.log and live-run3.log (third-party data was never logged; the
// repeater's own key prefix is public). The status block is rebuilt from the logged field values (the log keeps the decoded
// struct, not its hex); the 68-byte frame length and the values match the log.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/repeater_wire.dart';

Uint8List h(String s) => fromHex(s);

void main() {
  group('measured binary answers', () {
    test('neighbours: 6 entries of 9 bytes, zero padded to 60', () {
      const hex = '060006001bcee248951c01001fd4038f3c8b4d010017db24126fec4d0100edf26ae5f813530100f43c4d94a356640100e1c0ffee17bd900100f90000';
      final data = h(hex);
      expect(data.length, 60);
      final p = NeighbourPage.parse(data)!;
      expect(p.total, 6);
      expect(p.entries.length, 6);
      expect(p.entries.first.prefixHex, '1bcee248');
      expect(p.entries.first.secondsAgo, 72853); // CLI `neighbors` said 72715 a moment earlier: same neighbour
      expect(p.entries.first.snrDb, 7.75); // 31 / 4, CLI showed ":31"
      expect(p.entries[1].prefixHex, 'd4038f3c');
      expect(p.entries[1].snrDb, 5.75);
      expect(p.entries[2].prefixHex, 'db24126f');
      expect(p.entries[2].snrDb, -4.75); // 0xed as a signed byte: SNR can be negative
    });

    test('neighbours: a page that claims more entries than it holds is refused, not guessed', () {
      expect(NeighbourPage.parse(h('0600 0600 1bcee248'.replaceAll(' ', ''))), isNull);
      expect(NeighbourPage.parse(Uint8List(2)), isNull);
      final empty = NeighbourPage.parse(Uint8List(16))!;
      expect(empty.total, 0);
      expect(empty.entries, isEmpty);
    });

    test('access list: 2 admins then zero padding', () {
      final acl = parseAclList(h('264770939b7703a9b1acd3a408030000000000000000000000000000'));
      expect(acl.map((e) => e.prefixHex), ['264770939b77', 'a9b1acd3a408']);
      expect(acl.every((e) => e.role == AclRole.admin), isTrue);
    });

    test('access list: guests and padding are skipped', () {
      final acl = parseAclList(h('aabbccddeeff00' '112233445566' '01' '00000000000000'));
      expect(acl.length, 1);
      expect(acl.single.role, AclRole.readOnly);
    });

    test('owner info: version, name, owner', () {
      final o = OwnerInfo.parse(h('76312e31372e312e352d6f627365727665722d373430333036370a494e4e4f2d4f422d320a00000000000000'));
      expect(o.firmware, 'v1.17.1.5-observer-7403067');
      expect(o.name, 'INNO-OB-2');
      expect(o.owner, '');
    });

    test('anonymous clock, regions and owner', () {
      final c = AnonClock.parse(h('2361e66a0000000000000000'))!;
      expect(c.epochSecs, 1793483043); // live-run3: remote_epoch 1793483043
      expect(c.repeatDisabled, isFalse);
      expect(parseAnonRegions(h('095de66a2a2c636d68000000')), ['*', 'cmh']);
      expect(OwnerInfo.parseAnon(h('0a5de66a494e4e4f2d4f422d320a0000000000000000000000000000')).name, 'INNO-OB-2');
      expect(AnonClock.parse(Uint8List(3)), isNull);
      expect(AnonClock.parse(h('00000000 80'.replaceAll(' ', '')))!.repeatDisabled, isTrue);
    });
  });

  group('status block', () {
    final measured = RepeaterStats(
      battMilliVolts: 3877, txQueueLen: 0, noiseFloorDbm: -100, lastRssiDbm: -100, packetsRecv: 1121, packetsSent: 559, airTimeSecs: 163,
      upTimeSecs: 148568, sentFlood: 404, sentDirect: 155, recvFlood: 801, recvDirect: 320, errEvents: 8, lastSnrDb: 0.25,
      directDups: 0, floodDups: 402, rxAirTimeSecs: 316, recvErrors: 191,
    );

    test('56 bytes, little endian, field offsets as in MyMesh.h', () {
      final b = measured.encode();
      expect(b.length, 56);
      expect(b.sublist(0, 2), [0x25, 0x0f]); // 3877 mV
      expect(ByteData.sublistView(b).getUint32(20, Endian.little), 148568); // uptime at offset 20
      expect(ByteData.sublistView(b).getInt16(42, Endian.little), 1); // snr x4 at offset 42
      final p = RepeaterStats.parse(Uint8List.fromList([...b, 0, 0, 0, 0]))!;
      expect(p.battMilliVolts, 3877);
      expect(p.noiseFloorDbm, -100);
      expect(p.packetsRecv, 1121);
      expect(p.sentFlood, 404);
      expect(p.recvDirect, 320);
      expect(p.errEvents, 8);
      expect(p.lastSnrDb, 0.25);
      expect(p.floodDups, 402);
      expect(p.rxAirTimeSecs, 316);
      expect(p.recvErrors, 191);
      expect(p.batteryV, closeTo(3.877, 1e-9));
    });

    test('the whole 68-byte push decodes through the frame layer and keeps the full block', () {
      final frame = Uint8List.fromList([Push.statusResponse, 0, ...h('df0136c20a99'), ...measured.encode(), 0, 0, 0, 0]);
      expect(frame.length, 68);
      final f = decodeFrame(frame) as StatusResponsePush;
      expect(f.prefixHex, 'df0136c20a99');
      expect(f.status.upTimeSecs, 148568);
      expect(RepeaterStats.parse(f.statsBytes!)!.recvErrors, 191);
    });

    test('an older build that sends only the first fields still parses; shorter than that does not', () {
      final b = measured.encode().sublist(0, 24);
      final p = RepeaterStats.parse(b)!;
      expect(p.upTimeSecs, 148568);
      expect(p.recvErrors, 0);
      expect(RepeaterStats.parse(Uint8List(10)), isNull);
    });
  });

  group('telemetry (big endian LPP)', () {
    test('3.86 V and 45.0 C then padding, as measured', () {
      // live-run1: voltage read little endian as 332.81 -> bytes 01 82; temperature -1587.1 -> bytes 01 C2
      final t = RepeaterTelemetry.parse(h('017401820167' '01c2' '00000000'));
      expect(t.voltageV, 3.86);
      expect(t.temperatureC, 45.0);
      expect(t.values.length, 2);
    });

    test('the 44.0 C reading from run 4', () {
      expect(RepeaterTelemetry.parse(h('01740182' '016701b8' '00000000')).temperatureC, 44.0);
    });

    test('negative temperatures, truncated data and unknown types never throw', () {
      expect(RepeaterTelemetry.parse(RepeaterTelemetry.encodeLpp(voltageV: 3.7, temperatureC: -5.5)).temperatureC, -5.5);
      expect(RepeaterTelemetry.parse(h('0174')).voltageV, isNull);
      expect(RepeaterTelemetry.parse(h('01fe0102')).values, isEmpty);
      expect(RepeaterTelemetry.parse(Uint8List(0)).values, isEmpty);
      // all padding
      expect(RepeaterTelemetry.parse(Uint8List(16)).values, isEmpty);
    });

    test('pushes from a remote node decode to a TelemetryResponsePush', () {
      final f = decodeFrame(Uint8List.fromList([Push.telemetryResponse, 0, ...h('df0136c20a99'), ...h('0174018201670 1c200000000'.replaceAll(' ', ''))])) as TelemetryResponsePush;
      expect(f.prefixHex, 'df0136c20a99');
      expect(RepeaterTelemetry.parse(f.lpp).voltageV, 3.86);
    });
  });

  group('request encoders', () {
    final key = h('df0136c20a99f519286d14e5b95e9d807c9472aa83ffefd9a15f8238afdecd48');
    test('neighbours request is the measured 44-byte frame', () {
      final f = encodeSendBinaryReq(key, neighboursRequest(count: 8, offset: 0, order: 0, prefixLen: 4, random: [1, 2, 3, 4]));
      expect(f.length, 44);
      expect(f.sublist(33), [6, 0, 8, 0, 0, 0, 4, 1, 2, 3, 4]);
      expect(f[0], 50);
    });
    test('access list, owner and anonymous requests match the research scripts', () {
      expect(encodeSendBinaryReq(key, accessListRequest).sublist(33), [5, 0, 0]);
      expect(encodeSendBinaryReq(key, ownerRequest).sublist(33), [7]);
      expect(encodeSendAnonReq(key, anonBasicRequest).sublist(33), [3, 0]);
      expect(encodeSendAnonReq(key, anonRegionsRequest).sublist(33), [1, 0]);
      expect(encodeSendAnonReq(key, anonOwnerRequest).sublist(33), [2, 0]);
      expect(encodeSendAnonReq(key, anonBasicRequest)[0], 57);
      expect(encodeSendRemoteTelemetryReq(key).sublist(0, 4), [39, 0, 0, 0]);
      expect(encodeSendRemoteTelemetryReq(key).length, 36);
      expect(() => encodeSendBinaryReq(Uint8List(5), const [1]), throwsArgumentError);
    });
    test('binary response push carries the tag', () {
      final f = decodeFrame(Uint8List.fromList([Push.binaryResponse, 0, 0x85, 0x5c, 0xe6, 0x6a, 1, 2, 3])) as BinaryResponsePush;
      expect(f.tag, 0x6ae65c85);
      expect(f.data, [1, 2, 3]);
    });
    test('login success measured: 14 bytes, admin, perm 3, firmware level 2', () {
      final f = decodeFrame(h('8501df0136c20a99' '2261e66a' '0302')) as LoginSuccessPush;
      expect(f.isAdmin, isTrue);
      expect(f.aclPermissions, 3);
      expect(f.firmwareLevel, 2);
    });
  });
}
