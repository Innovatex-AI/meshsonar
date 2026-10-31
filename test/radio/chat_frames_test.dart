// Chat-side frames, written out BYTE BY BYTE from the firmware source (meshcore-dev/MeshCore at 81dbae5,
// examples/companion_radio/MyMesh.cpp, MIT) and NOT through this repo's encoders, so a mistake in an encoder cannot hide a
// mistake in the matching decoder. Line numbers are in that file.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/protocol.dart';

Uint8List b(List<int> x) => Uint8List.fromList(x);
List<int> le32(int v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff];
List<int> padded(String s, int n) => [...utf8.encode(s), ...List.filled(n - utf8.encode(s).length, 0)];

/// writeContactRespFrame (171-193): code, pub_key[32], type, flags, out_path_len, out_path[64], name[32] (strzcpy),
/// last_advert u32, gps_lat i32, gps_lon i32, lastmod u32 = 148 bytes.
Uint8List contactFrame(int code, List<int> key, int type, int flags, int pathLen, List<int> path, String name, int lastAdvert, int lat, int lon, int lastMod) =>
    b([code, ...key, type, flags, pathLen, ...path, ...List.filled(64 - path.length, 0), ...padded(name, 32), ...le32(lastAdvert), ...le32(lat), ...le32(lon), ...le32(lastMod)]);

void main() {
  final key = List<int>.generate(32, (i) => 0xA0 + i);

  group('GET_CONTACTS (1238-1258, 2385-2410)', () {
    test('request: [4] for everything, [4][since u32] for the incremental form', () {
      expect(encodeGetContacts(), [4]);
      expect(encodeGetContacts(since: 0x01020304), [4, 0x04, 0x03, 0x02, 0x01]);
    });

    test('CONTACTS_START [2][total u32]: the total on the radio, not the filtered count (1252-1256)', () {
      final f = decodeFrame(b([2, ...le32(350)])) as ContactsStartFrame;
      expect(f.count, 350);
    });

    test('END_OF_CONTACTS [4][most recent lastmod u32] (2404-2408)', () {
      final f = decodeFrame(b([4, ...le32(1730000123)])) as EndOfContactsFrame;
      expect(f.mostRecentLastMod, 1730000123);
    });

    test('CONTACT: every field of the 148-byte frame', () {
      final raw = contactFrame(3, key, 2, 1, 2, [0xAB, 0xCD], 'Hilltop Repeater', 1730000000, 40126200, -82929300, 1730000999);
      expect(raw.length, 148);
      final c = decodeFrame(raw) as ContactFrame;
      expect(c.publicKey, key);
      expect(c.type, AdvType.repeater);
      expect(c.flags, 1);
      expect(c.outPathLen, 2);
      expect(c.outPath, [0xAB, 0xCD]);
      expect(c.name, 'Hilltop Repeater');
      expect(c.lastAdvert, 1730000000);
      expect(c.lat, closeTo(40.1262, 1e-9));
      expect(c.lon, closeTo(-82.9293, 1e-9));
      expect(c.lastMod, 1730000999);
    });

    test('CONTACT with out_path_len 0xFF (OUT_PATH_UNKNOWN) has no path; hash size 2 doubles the path bytes', () {
      final unknown = decodeFrame(contactFrame(3, key, 1, 0, 0xFF, [], 'Ann', 1, 0, 0, 2)) as ContactFrame;
      expect(unknown.outPathLen, 0xFF);
      expect(unknown.outPath, isEmpty);
      // path_len byte: top 2 bits = hash size - 1, low 6 bits = hops (src/Packet.h 79-83): 0b01_000010 = 2 hops of 2 bytes
      final two = decodeFrame(contactFrame(3, key, 1, 0, 0x42, [1, 2, 3, 4], 'Bob', 1, 0, 0, 2)) as ContactFrame;
      expect(two.outPath, [1, 2, 3, 4]);
      expect(pathByteLength(0x42), 4);
      expect(pathByteLength(0xFF), 0);
      expect(pathByteLength(0), 0);
      expect(pathByteLength(3), 3);
    });

    test('CONTACT: a short (pre-lastmod) frame still decodes, with lastmod 0', () {
      final full = contactFrame(3, key, 1, 0, 0xFF, [], 'Old', 5, 0, 0, 9);
      final c = decodeFrame(Uint8List.sublistView(full, 0, 144)) as ContactFrame;
      expect(c.lastMod, 0);
      expect(c.name, 'Old');
    });

    test('NEW_ADVERT 0x8A is a full contact frame under its own code (onDiscoveredContact 358-407)', () {
      final p = decodeFrame(contactFrame(0x8A, key, 1, 0, 0xFF, [], 'Newcomer', 7, 0, 0, 8)) as NewAdvertPush;
      expect(p.contact.name, 'Newcomer');
      expect(p.contact.publicKey, key);
    });
  });

  group('ADD_UPDATE_CONTACT (updateContactFromFrame 195-217)', () {
    test('layout: code, pub, type, flags, out_path_len, out_path[64], name[32], last_advert, lat, lon, lastmod', () {
      final f = encodeAddUpdateContact(key, type: 1, name: 'Ann', flags: 2, outPathLen: 1, outPath: [0x77], lastAdvert: 11, lat: 40.5, lon: -82.5, lastMod: 99);
      expect(f.length, 148);
      expect(f[0], 9);
      expect(f.sublist(1, 33), key);
      expect(f[33], 1);
      expect(f[34], 2);
      expect(f[35], 1);
      expect(f[36], 0x77);
      expect(f.sublist(100, 103), utf8.encode('Ann'));
      final bd = ByteData.sublistView(f);
      expect(bd.getUint32(132, Endian.little), 11);
      expect(bd.getInt32(136, Endian.little), 40500000);
      expect(bd.getInt32(140, Endian.little), -82500000);
      expect(bd.getUint32(144, Endian.little), 99);
    });

    test('without a lastmod the frame is 144 bytes and the radio stamps it (the "optional fields" branch, 205-214)', () {
      expect(encodeAddUpdateContact(key, type: 1, name: 'Ann').length, 144);
    });

    test('the claims form (path unknown, no position) is unchanged', () {
      final f = encodeAddUpdateContact(key, type: AdvType.repeater, name: 'R');
      expect(f[35], 0xFF);
      expect(f.sublist(132), List.filled(12, 0));
    });
  });

  group('DM: SEND_TXT_MSG and its answers (1132-1177)', () {
    test('command [2][txt_type][attempt][timestamp u32][pubkey prefix x6][text]', () {
      final f = encodeSendTxt(txtTypePlain, 5, 0x11223344, key, 'hi');
      expect(f, [2, 0, 1, 0x44, 0x33, 0x22, 0x11, ...key.take(6), 0x68, 0x69], reason: 'attempt is masked to 2 bits');
    });

    test('RESP_CODE_SENT [6][flood][expected_ack u32][est_timeout u32] (1169-1175)', () {
      final s = decodeFrame(b([6, 1, ...le32(0xCAFEBABE), ...le32(2500)])) as SentFrame;
      expect(s.flood, isTrue);
      expect(s.tag, 0xCAFEBABE);
      expect(s.estTimeoutMs, 2500);
      expect((decodeFrame(b([6, 0, ...le32(1), ...le32(1200)])) as SentFrame).flood, isFalse);
    });

    test('PUSH_CODE_SEND_CONFIRMED [0x82][ack u32][trip u32] = 9 bytes (processAck 417-436)', () {
      final c = decodeFrame(b([0x82, ...le32(0xCAFEBABE), ...le32(1840)])) as SendConfirmedPush;
      expect(c.ack, 0xCAFEBABE);
      expect(c.tripMs, 1840);
      expect(() => decodeFrame(b([0x82, 1, 2, 3])), throwsA(isA<ProtocolException>()));
    });

    test('ERR codes: unknown recipient NOT_FOUND, bad text type UNSUPPORTED, pool full TABLE_FULL (1163-1173)', () {
      expect((decodeFrame(b([1, 2])) as ErrFrame).code, ErrCode.notFound);
      expect((decodeFrame(b([1, 1])) as ErrFrame).code, ErrCode.unsupportedCmd);
      expect((decodeFrame(b([1, 3])) as ErrFrame).code, ErrCode.tableFull);
    });
  });

  group('pushes (358-436)', () {
    test('PATH_UPDATED [0x81][pub x32]', () {
      expect((decodeFrame(b([0x81, ...key])) as PathUpdatedPush).publicKey, key);
    });
    test('ADVERT [0x80][pub x32]', () {
      expect((decodeFrame(b([0x80, ...key])) as AdvertPush).publicKey, key);
    });
    test('CONTACT_DELETED [0x8F][pub x32] and CONTACTS_FULL [0x90]', () {
      expect((decodeFrame(b([0x8F, ...key])) as ContactDeletedPush).publicKey, key);
      expect(decodeFrame(b([0x90])), isA<ContactsFullPush>());
    });
  });

  group('inbound messages (queueMessage 441-469, onChannelMessageRecv 558-585)', () {
    test('channel V3: [0x11][snr x4][0][0][ch][path_len][txt_type][ts u32][text]', () {
      final f = decodeFrame(b([0x11, 22, 0, 0, 4, 2, 0, ...le32(1730000000), ...utf8.encode('Ann: hello')])) as ChannelMsgFrame;
      expect(f.snrDb, 5.5);
      expect(f.channelIndex, 4);
      expect(f.pathLen, 2);
      expect(f.txtType, 0);
      expect(f.timestamp, 1730000000);
      expect(f.text, 'Ann: hello');
    });

    test('channel V3 negative SNR is a signed byte: 0xF0 = -4 dB', () {
      final f = decodeFrame(b([0x11, 0xF0, 0, 0, 0, 0xFF, 0, ...le32(1), 0x78])) as ChannelMsgFrame;
      expect(f.snrDb, -4.0);
      expect(f.pathLen, 0xFF);
    });

    test('channel legacy: [0x08][ch][path_len][txt_type][ts u32][text], no SNR', () {
      final f = decodeFrame(b([0x08, 1, 0xFF, 0, ...le32(5), 0x79])) as ChannelMsgFrame;
      expect(f.snrDb, isNull);
      expect(f.channelIndex, 1);
      expect(f.text, 'y');
    });

    test('contact V3: [0x10][snr x4][0][0][prefix x6][path_len][txt_type][ts u32][text]', () {
      final f = decodeFrame(b([0x10, 8, 0, 0, ...key.take(6), 3, 0, ...le32(1730000001), ...utf8.encode('dm')])) as ContactTextFrame;
      expect(f.snrDb, 2.0);
      expect(f.prefixHex, key.take(6).map((x) => x.toRadixString(16).padLeft(2, '0')).join());
      expect(f.pathLen, 3);
      expect(f.txtType, 0);
      expect(f.timestamp, 1730000001);
      expect(f.text, 'dm');
      expect(f.signerPrefixHex, isNull);
    });

    test('contact V3 signed (txt_type 2): a 4-byte signer prefix sits between the timestamp and the text (extra, 441-469)', () {
      final f = decodeFrame(b([0x10, 0, 0, 0, ...key.take(6), 0xFF, 2, ...le32(9), 1, 2, 3, 4, ...utf8.encode('signed')])) as ContactTextFrame;
      expect(f.text, 'signed');
      expect(f.signerPrefixHex, '01020304');
      expect(f.txtType, 2);
    });

    test('CHANNEL_DATA_RECV [27][snr][0][0][ch][path_len][type u16][len u8][data] (onChannelDataRecv)', () {
      final f = decodeFrame(b([27, 4, 0, 0, 3, 0xFF, 0x34, 0x12, 3, 9, 8, 7])) as ChannelDataFrame;
      expect(f.channelIndex, 3);
      expect(f.dataType, 0x1234);
      expect(f.data, [9, 8, 7]);
    });
  });

  group('DEVICE_INFO limits (1056-1075)', () {
    test('max_contacts is sent halved, max_channels as is; the BLE PIN and build info follow', () {
      final raw = Uint8List(82);
      raw[0] = 13;
      raw[1] = 14; // FIRMWARE_VER_CODE
      raw[2] = 175; // MAX_CONTACTS / 2
      raw[3] = 40; // MAX_GROUP_CHANNELS
      raw.setRange(4, 8, le32(123456));
      raw.setRange(8, 8 + 9, utf8.encode('1 Oct 2026'));
      raw.setRange(20, 20 + 9, utf8.encode('Heltec V3'));
      raw.setRange(60, 66, utf8.encode('v1.18.0'));
      raw[80] = 1; // repeat
      raw[81] = 1; // path_hash_mode
      final d = decodeFrame(raw) as DeviceInfoFrame;
      expect(d.firmwareVerCode, 14);
      expect(d.maxContacts, 350);
      expect(d.maxChannels, 40);
      expect(d.manufacturer, 'Heltec V3');
      expect(d.pathHashMode, 1);
    });

    test('a short pre-v3 frame has no limits', () {
      final d = decodeFrame(b([13, 3])) as DeviceInfoFrame;
      expect(d.maxContacts, isNull);
      expect(d.maxChannels, isNull);
    });
  });

  group('channels (1752-1780)', () {
    test('delete = empty name and zero secret in SET_CHANNEL', () {
      final f = encodeSetChannel(3, '', List.filled(16, 0));
      expect(f.length, 50);
      expect(f.sublist(2), List.filled(48, 0));
    });
  });

  group('encoders for the radio side round-trip through the decoders', () {
    test('contact frame', () {
      final c = decodeFrame(encodeContactFrame(key, type: 1, name: 'Zed', lat: 40.25, lon: -82.5, lastMod: 42, lastAdvert: 41, outPathLen: 1, outPath: [0x55], flags: 3)) as ContactFrame;
      expect((c.name, c.lat, c.lon, c.lastMod, c.lastAdvert, c.flags), ('Zed', 40.25, -82.5, 42, 41, 3));
      expect(c.outPath, [0x55]);
    });
    test('channel message and contact text', () {
      final m = decodeFrame(encodeChannelMsg(2, 'A: x', timestamp: 7, pathLen: 4, snrDb: 3.5)) as ChannelMsgFrame;
      expect((m.channelIndex, m.pathLen, m.timestamp, m.snrDb, m.text), (2, 4, 7, 3.5, 'A: x'));
    });
  });
}
