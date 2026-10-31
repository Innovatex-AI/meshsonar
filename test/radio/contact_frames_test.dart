// Contact management frames (M2), written BYTE BY BYTE from the firmware source (meshcore-dev/MeshCore at 81dbae5,
// examples/companion_radio/MyMesh.cpp and src/helpers/BaseChatMesh.cpp, MIT) and NOT through this repo's encoders, so an
// encoder mistake cannot hide behind a matching decoder mistake. Line numbers are in those files. Everything here is
// "firmware-only": not yet confirmed on Andy's radio (see docs/PROTOCOL.md section 11 for the hardware checklist).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/protocol.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);
List<int> le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];

void main() {
  final key = List<int>.generate(32, (i) => 0x10 + i);

  group('commands that take a public key: [code][pub_key x32]', () {
    test('RESET_PATH 13 (MyMesh.cpp 1317: `len >= 1 + 32`)', () => expect(encodeResetPath(key), [13, ...key]));
    test('REMOVE_CONTACT 15 (1349)', () => expect(encodeRemoveContact(key), [15, ...key]));
    test('SHARE_CONTACT 16 (1359)', () => expect(encodeShareContact(key), [16, ...key]));
    test('EXPORT_CONTACT 17 with a key (1379-1408); without one it is the radio itself', () {
      expect(encodeExportContact(key), [17, ...key]);
      expect(encodeExportSelfContact(), [17]);
    });
    test('GET_CONTACT_BY_KEY 30 (1371)', () => expect(encodeGetContactByKey(key), [30, ...key]));
    test('a key that is not 32 bytes is refused before it reaches the radio', () {
      expect(() => encodeRemoveContact(List.filled(31, 1)), throwsArgumentError);
      expect(() => encodeResetPath(List.filled(33, 1)), throwsArgumentError);
    });
  });

  group('IMPORT_CONTACT 18 (1409): [18][advert packet...], needs len > 2 + 32 + 64', () {
    test('wraps the packet bytes after the code', () {
      final pkt = List<int>.generate(120, (i) => i);
      expect(encodeImportContact(pkt), [18, ...pkt]);
    });
  });

  group('SET_OTHER_PARAMS 38 (1488-1503): overwrites all four fields it carries', () {
    test('[38][manual_add][telemetry][advert_loc_policy][multi_acks]', () {
      expect(encodeSetOtherParams(manualAdd: 1, telemetryModes: 0x15, advertLocPolicy: 2, multiAcks: 1), [38, 1, 0x15, 2, 1]);
    });
  });

  group('auto-add config 58/59 (2023-2036); bits at 147-151', () {
    test('flag values', () {
      expect(AutoAddFlags.overwriteOldest, 0x01);
      expect(AutoAddFlags.chat, 0x02);
      expect(AutoAddFlags.repeater, 0x04);
      expect(AutoAddFlags.room, 0x08);
      expect(AutoAddFlags.sensor, 0x10);
    });
    test('SET: [58][config] or [58][config][max_hops], max_hops clamped to 64', () {
      expect(encodeSetAutoAddConfig(0x06), [58, 0x06]);
      expect(encodeSetAutoAddConfig(0x06, maxHops: 3), [58, 0x06, 3]);
      expect(encodeSetAutoAddConfig(0x1f, maxHops: 200), [58, 0x1f, 64]);
    });
    test('GET: [59] -> RESP_CODE_AUTOADD_CONFIG 25 [config][max_hops]', () {
      expect(encodeGetAutoAddConfig(), [59]);
      final f = decodeFrame(b([25, 0x0e, 4])) as AutoAddConfigFrame;
      expect((f.config, f.maxHops), (0x0e, 4));
    });
  });

  group('SELF_INFO manual_add (1090-1104)', () {
    // [5][adv_type][tx][max_tx][pub x32][lat i32][lon i32][multi_acks][advert_loc_policy][telemetry][manual_add][freq u32][bw u32][sf][cr][name]
    Uint8List selfInfo({int multi = 0, int loc = 0, int tele = 0, int manual = 0}) => b([
          5, 1, 22, 22, ...key, ...le32(0), ...le32(0), multi, loc, tele, manual, ...le32(910525), ...le32(62500), 7, 5, 0x41, 0x42,
        ]);
    test('byte 47 is manual_add; bit 0 = "ask before adding"', () {
      final f = decodeFrame(selfInfo(manual: 1, tele: 0x2a, loc: 1, multi: 1)) as SelfInfoFrame;
      expect(f.asksBeforeAdding, isTrue);
      expect((f.manualAdd, f.telemetryModes, f.advertLocPolicy, f.multiAcks), (1, 0x2a, 1, 1));
      expect(f.freqKhz, 910525, reason: 'the fields after manual_add did not move');
      expect(f.name, 'AB');
      expect((decodeFrame(selfInfo()) as SelfInfoFrame).asksBeforeAdding, isFalse);
    });
    test('our own radio-side encoder agrees with the hand-built frame', () {
      expect(
          encodeSelfInfo(txPowerDbm: 22, maxTxPowerDbm: 22, publicKey: key, freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: 'AB', manualAdd: 1, telemetryModes: 0x2a, advertLocPolicy: 1, multiAcks: 1),
          selfInfo(manual: 1, tele: 0x2a, loc: 1, multi: 1));
    });
  });

  group('pushes that carry contacts (358-415, 332-356)', () {
    test('PUSH_CODE_NEW_ADVERT 0x8A is a full 148-byte contact frame under its own code', () {
      final raw = b([0x8A, ...key, 2, 0, 0xFF, ...List.filled(64, 0), ...[0x48, 0x69, ...List.filled(30, 0)], ...le32(1730000000), ...le32(40000000), ...le32(-83000000 & 0xffffffff), ...le32(1730000100)]);
      expect(raw.length, 148);
      final f = decodeFrame(raw) as NewAdvertPush;
      expect(f.contact.name, 'Hi');
      expect(f.contact.type, 2);
      expect(f.contact.outPathLen, 0xFF);
      expect(f.contact.lat, closeTo(40.0, 1e-6));
      expect(f.contact.lon, closeTo(-83.0, 1e-6));
      expect(f.contact.lastAdvert, 1730000000);
    });
    test('PUSH_CODE_ADVERT 0x80 is only the key; PATH_UPDATED 0x81 too', () {
      expect((decodeFrame(b([0x80, ...key])) as AdvertPush).publicKey, key);
      expect((decodeFrame(b([0x81, ...key])) as PathUpdatedPush).publicKey, key);
    });
    test('PUSH_CODE_CONTACT_DELETED 0x8F [key] and CONTACTS_FULL 0x90 (332-356)', () {
      expect((decodeFrame(b([0x8F, ...key])) as ContactDeletedPush).publicKey, key);
      expect(decodeFrame(b([0x90])), isA<ContactsFullPush>());
    });
    test('SEND_CONFIRMED 0x82 [ack u32][trip ms u32] (417-436)', () {
      final f = decodeFrame(b([0x82, ...le32(0xdeadbeef), ...le32(1234)])) as SendConfirmedPush;
      expect((f.ack, f.tripMs), (0xdeadbeef, 1234));
    });
  });

  group('multi-byte path hashes in a contact (Packet.h 79-83)', () {
    test('out_path_len 0x42 = 2 hops of 2 bytes: 4 path bytes are kept', () {
      final raw = b([0x03, ...key, 1, 0, 0x42, 1, 2, 3, 4, ...List.filled(60, 0), ...List.filled(32, 0), ...le32(0), ...le32(0), ...le32(0), ...le32(0)]);
      final f = decodeFrame(raw) as ContactFrame;
      expect(f.outPath, [1, 2, 3, 4]);
      expect(pathByteLength(0x42), 4);
      expect(pathByteLength(0xFF), 0);
    });
  });

  group('advert packets (Mesh.cpp 252-290, AdvertDataHelpers.cpp)', () {
    test('build -> parse round trip: key, time, type, name, position', () {
      final raw = buildUnsignedAdvertPacket(key, type: 2, name: 'Hilltop', timestamp: 1730000000, lat: 40.1, lon: -82.9);
      final a = decodeAdvertPacket(raw)!;
      expect(a.publicKey, key);
      expect((a.timestamp, a.type, a.name), (1730000000, 2, 'Hilltop'));
      expect(a.lat, closeTo(40.1, 1e-6));
      expect(a.lon, closeTo(-82.9, 1e-6));
    });
    test('hand-built: flags 0x92 = repeater + position + name; no position when the flag is clear', () {
      // header 0x11 = flood (1) | advert (4) << 2 ; path_len 0 ; payload = key, ts, sig x64, app_data
      final app = [0x92, ...le32(40100000), ...le32(-82900000 & 0xffffffff), 0x52, 0x31];
      final raw = b([0x11, 0, ...key, ...le32(7), ...List.filled(64, 0), ...app]);
      final a = decodeAdvertPacket(raw)!;
      expect((a.type, a.name, a.timestamp), (2, 'R1', 7));
      expect(a.lat, closeTo(40.1, 1e-6));
      final noPos = decodeAdvertPacket(b([0x11, 0, ...key, ...le32(7), ...List.filled(64, 0), 0x81, 0x41]))!;
      expect((noPos.type, noPos.name, noPos.lat), (1, 'A', null));
    });
    test('hostile input never throws: not an advert, cut short, absurd coordinates, junk', () {
      expect(decodeAdvertPacket(const []), isNull);
      expect(decodeAdvertPacket(b([0x15, 0, 1, 2, 3])), isNull, reason: 'a group text, not an advert');
      expect(decodeAdvertPacket(b([0x11, 0, ...key])), isNull, reason: 'payload shorter than key + time + signature');
      final crazy = b([0x11, 0, ...key, ...le32(1), ...List.filled(64, 0), 0x90, ...le32(2000000000), ...le32(2000000000)]);
      expect(decodeAdvertPacket(crazy)?.lat, isNull, reason: 'out of range coordinates are dropped, not trusted');
      for (var seed = 0; seed < 300; seed++) {
        final junk = List<int>.generate(seed % 190, (i) => (i * 31 + seed * 7) & 0xff);
        decodeAdvertPacket(junk); // must not throw
      }
    });
  });
}
