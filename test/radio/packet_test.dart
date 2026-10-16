// Over-the-air packet parsing and echo recognition. Packet vectors were built independently in Python (hashlib,
// hmac, cryptography AES-ECB) following firmware src/Packet.cpp writeTo(), src/Mesh.cpp createGroupDatagram(),
// src/Utils.cpp encryptThenMAC() and src/helpers/BaseChatMesh.cpp sendGroupMessage().
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';

const pingText = '@[MapperBot] 40.12620, -82.92930 [1.0w]';
const ts = 1767225600;

// FLOOD GRP_TXT (header 0x15), path_len 0x02 (two 1-byte hashes df, 4e), sender "Car", channel #wardriving.
const pktFlood =
    '1502df4e8112f79ac2e671e88e0f0a5472d4c0d7a91fe4cb47c6e3692aff5318442ba3ea6ece4822853fcdec86d8f09369124d67c40df8693647fc4eb7e903636e87a153aaf51a';
// Same payload, TRANSPORT_FLOOD (header 0x14) with codes 0x1234/0x0000, path_len 0x41 = one 2-byte hash df01.
const pktTransport =
    '143412000041df018112f79ac2e671e88e0f0a5472d4c0d7a91fe4cb47c6e3692aff5318442ba3ea6ece4822853fcdec86d8f09369124d67c40df8693647fc4eb7e903636e87a153aaf51a';

void main() {
  final secret = hashtagChannelSecret('#wardriving');

  test('header bits: route 0-1, type 2-5, version 6-7 (src/Packet.h)', () {
    final p = MeshPacket.tryParse(fromHex(pktFlood))!;
    expect(p.header, 0x15);
    expect(p.routeType, RouteType.flood);
    expect(p.payloadType, PayloadType.grpTxt);
    expect(p.payloadVersion, 0);
    expect(p.isFlood, isTrue);
    expect(makeHeader(RouteType.flood, PayloadType.grpTxt), 0x15);
    expect(makeHeader(RouteType.direct, PayloadType.advert), 0x12);
  });

  test('path_len: 1-byte hashes, hop count = entries', () {
    final p = MeshPacket.tryParse(fromHex(pktFlood))!;
    expect(p.pathHashSize, 1);
    expect(p.hopCount, 2);
    expect(p.pathHex, ['df', '4e']);
    expect(p.payload.first, 129); // channel hash of #wardriving
    expect(p.toBytes(), fromHex(pktFlood));
  });

  test('transport codes and 2-byte path hashes (Packet::getPathHashSize = (path_len >> 6) + 1)', () {
    final p = MeshPacket.tryParse(fromHex(pktTransport))!;
    expect(p.routeType, RouteType.transportFlood);
    expect(p.transportCode1, 0x1234);
    expect(p.transportCode2, 0);
    expect(p.pathHashSize, 2);
    expect(p.hopCount, 1);
    expect(p.pathHex, ['df01']);
    expect(p.toBytes(), fromHex(pktTransport));
    expect(encodePathLen(2, 1), 0x41);
    expect(encodePathLen(3, 5), 0x85);
  });

  test('rejects what Packet::readFrom rejects', () {
    expect(MeshPacket.tryParse([0x15]), isNull); // too short
    expect(MeshPacket.tryParse([0x15, 0xC1, 1, 2, 3, 4, 5]), isNull); // hash size 4 reserved
    expect(MeshPacket.tryParse([0x15, 0x02, 0xdf, 0x4e]), isNull); // no payload
    expect(MeshPacket.tryParse([0x15, 0x60, ...List.filled(70, 1)]), isNotNull); // 2 x 32 = 64 bytes: allowed
    expect(MeshPacket.tryParse([0x15, 0x61, ...List.filled(70, 1)]), isNull); // 2 x 33 = 66 > MAX_PATH_SIZE
    expect(MeshPacket.tryParse([0x14, 0x01, 0x02]), isNull); // transport codes truncated
  });

  test('decrypts the GRP_TXT payload: timestamp, flags, "<sender>: <text>"', () {
    final p = MeshPacket.tryParse(fromHex(pktFlood))!;
    final gt = decryptGroupText(secret, p.payload)!;
    expect(gt.timestamp, ts);
    expect(gt.flags, 0);
    expect(gt.text, 'Car: $pingText');
    expect(decryptGroupText(hashtagChannelSecret('#test'), p.payload), isNull);
  });

  test('buildGroupTextPayload reproduces the Python vector byte for byte', () {
    final payload = buildGroupTextPayload(secret, ts, 'Car', pingText);
    expect(toHex(payload), pktFlood.substring(8));
  });

  test('matchEcho: our ping repeated → repeater = first hop, hops = path entries', () {
    final m = matchEcho(MeshPacket.tryParse(fromHex(pktFlood))!, secret, pingText, timestamp: ts)!;
    expect(m.repeater, 'df');
    expect(m.hops, 2);
    expect(m.path, ['df', '4e']);
    final t = matchEcho(MeshPacket.tryParse(fromHex(pktTransport))!, secret, pingText)!;
    expect(t.repeater, 'df01');
    expect(t.hops, 1);
  });

  test('matchEcho rejects: other text, other timestamp, other channel, empty path, non-flood', () {
    final p = MeshPacket.tryParse(fromHex(pktFlood))!;
    expect(matchEcho(p, secret, '@[MapperBot] 40.00000, -82.00000'), isNull);
    expect(matchEcho(p, secret, pingText, timestamp: ts + 1), isNull);
    expect(matchEcho(p, hashtagChannelSecret('#testing'), pingText), isNull);
    final noPath = MeshPacket(header: 0x15, pathLenByte: 0, path: const [], payload: p.payload);
    expect(matchEcho(noPath, secret, pingText), isNull);
    final direct = MeshPacket(header: 0x16, pathLenByte: 1, path: [Uint8List.fromList([0xdf])], payload: p.payload);
    expect(matchEcho(direct, secret, pingText), isNull);
    // Someone else's message that merely contains our text further in is not ours.
    final other = MeshPacket(
        header: 0x15,
        pathLenByte: 1,
        path: [Uint8List.fromList([0xdf])],
        payload: buildGroupTextPayload(secret, ts, 'Bob', 'quoting $pingText !'));
    expect(matchEcho(other, secret, pingText), isNull);
  });
}
