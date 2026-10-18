// Drive Format v1.1 pkt_hash: MeshCore Packet::calculatePacketHash (src/Packet.cpp line 41) = SHA-256(payload type
// byte ‖ [path_len, TRACE only] ‖ payload), first 8 bytes.
//
// Golden vectors are real: #wardriving pings from MeshSonar on a Wio Tracker L1 companion ("KE4BFI-v4") on the
// Oct 17 2026 drive, as the observer INNO-OB-2 (Heltec V4, observer firmware v1.17.1.5) published them over MQTT
// (`raw` and `hash`). Independently checked in Python (hashlib + `cryptography` AES-ECB/HMAC) over the whole M0
// capture: 456 / 456 GRP_TXT observer hashes recomputed from `raw`, and 301 / 301 MeshSonar copies (109 distinct
// pings) rebuilt byte for byte from (timestamp, node name, ping text) with the #wardriving key.
// Mid-drive points only; these broadcasts were public on the channel.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';

class _Vector {
  final int ts;
  final String name;
  final String text;
  final String raw; // as heard by the observer, after repeats
  final String hash; // the observer's published hash
  final List<String> path;
  const _Vector(this.ts, this.name, this.text, this.raw, this.hash, this.path);
}

const _vectors = [
  _Vector(
    1792259274,
    'KE4BFI-v4',
    '@[MapperBot] 40.10336, -83.04756 [0.2w]',
    '1542509F1BCE8119A8658712A9CB92B162DC15953B8EC298945B010859A76487B0A062470DE20168A5EB1EFA860295D2BCE35B8B2196'
        '1A3D04BB21879B58DB4BDAAD87FBB4A036D970',
    '94AC75928507BFBD',
    ['509f', '1bce'],
  ),
  _Vector(
    1792259736,
    'KE4BFI-v4',
    '@[MapperBot] 40.10802, -82.99761 [0.2w]',
    '15411BCE814F4592BC9C36F0ACC596AF59522505238D635B010859A76487B0A062470DE20168A5370044904BBB6D9ABCFC2D880BA851'
        'E6BB21879B58DB4BDAAD87FBB4A036D970',
    'AD89B558861D5078',
    ['1bce'],
  ),
];

void main() {
  final secret = hashtagChannelSecret('#wardriving');

  group('golden vectors from the Oct 17 observer capture', () {
    for (final v in _vectors) {
      test('${v.ts}: heard packet hash = observer hash = predicted hash', () {
        final pkt = MeshPacket.tryParse(fromHex(v.raw))!;
        expect(pkt.payloadType, PayloadType.grpTxt);
        expect(pkt.pathHex, v.path, reason: 'the repeat path differs per copy and is not hashed');
        expect(pkt.hashHex, v.hash.toLowerCase());

        // What the app predicts from the send command alone matches the bytes on the air exactly.
        final payload = buildGroupTextPayload(secret, v.ts, v.name, v.text);
        expect(toHex(payload), toHex(pkt.payload));
        expect(groupTextPacketHashHex(secret, v.ts, v.name, v.text), v.hash.toLowerCase());

        // And the heard copy is recognised as that ping.
        expect(matchEcho(pkt, secret, v.text, timestamp: v.ts), isNotNull);
      });
    }

    test('one second off (the strictly-increasing rule) or another node name gives another hash', () {
      final v = _vectors.first;
      expect(groupTextPacketHashHex(secret, v.ts + 1, v.name, v.text), isNot(v.hash.toLowerCase()));
      expect(groupTextPacketHashHex(secret, v.ts, 'KE4BFI', v.text), isNot(v.hash.toLowerCase()));
    });
  });

  group('packetHash', () {
    test('route type, transport codes and path do not change the hash', () {
      final payload = buildGroupTextPayload(secret, 1792259274, 'n', 'x');
      final hashes = {
        for (final rt in [RouteType.flood, RouteType.transportFlood])
          for (final hops in [0, 1, 3])
            MeshPacket(
              header: makeHeader(rt, PayloadType.grpTxt),
              transportCode1: 0x1234,
              transportCode2: 0x5678,
              pathLenByte: encodePathLen(2, hops),
              path: [for (var h = 0; h < hops; h++) fromHex('ab${h}c')],
              payload: payload,
            ).hashHex,
      };
      expect(hashes, hasLength(1));
      expect(hashes.single, hasLength(16));
    });

    test('TRACE hashes path_len too; other types do not', () {
      final p = [1, 2, 3, 4];
      expect(toHex(packetHash(PayloadType.trace, p, pathLenByte: 1)), isNot(toHex(packetHash(PayloadType.trace, p, pathLenByte: 2))));
      expect(toHex(packetHash(PayloadType.grpTxt, p, pathLenByte: 1)), toHex(packetHash(PayloadType.grpTxt, p, pathLenByte: 2)));
      // SHA-256(0x09 0x01 01 02 03 04)[0..8] and SHA-256(0x05 01 02 03 04)[0..8], computed with Python hashlib.
      expect(toHex(packetHash(PayloadType.trace, p, pathLenByte: 1)), _py['trace']);
      expect(toHex(packetHash(PayloadType.grpTxt, p)), _py['grp']);
    });

    test('text is cut to MAX_TEXT_LEN − prefix bytes like the firmware', () {
      final long = 'x' * 300;
      final plain = meshMacThenDecrypt(secret, buildGroupTextPayload(secret, 1, 'abc', long).sublist(1))!;
      var end = plain.length;
      while (plain[end - 1] == 0) {
        end--;
      }
      expect(end - 5, maxTextLen, reason: '"abc: " + 155 x');
    });
  });

  test('v1.1 ping fields round-trip through JSON; bad hashes read back as null', () {
    final p = DrivePing(
      id: '00000000-0000-4000-8000-000000000001',
      ts: DateTime.utc(2026, 10, 17, 17, 47, 54, 900),
      lat: 40.10336,
      lon: -83.04756,
      pktHash: '94ac75928507bfbd',
      txEpochS: 1792259274,
      txDbm: 22,
    );
    final j = p.toJson();
    expect(j['pkt_hash'], '94ac75928507bfbd');
    expect(j['tx_epoch_s'], 1792259274);
    expect(j['tx_dbm'], 22.0);
    final back = DrivePing.fromJson(j);
    expect([back.pktHash, back.txEpochS, back.txDbm], ['94ac75928507bfbd', 1792259274, 22.0]);
    expect(DrivePing.fromJson({...j, 'pkt_hash': '94AC75928507BFBD'}).pktHash, '94ac75928507bfbd');
    expect(DrivePing.fromJson({...j, 'pkt_hash': 'zz'}).pktHash, isNull);
    final old = Map.of(j)..remove('pkt_hash')..remove('tx_epoch_s')..remove('tx_dbm');
    final v1 = DrivePing.fromJson(old);
    expect([v1.pktHash, v1.txEpochS, v1.txDbm], [null, null, null], reason: 'pings saved by 0.5.0 still load');
  });
}

const _py = {'trace': '4df640a8e98f2056', 'grp': '52532125f08a5485'};
