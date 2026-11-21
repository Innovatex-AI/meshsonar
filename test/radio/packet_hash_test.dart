// Drive Format v1.1 pkt_hash: MeshCore Packet::calculatePacketHash (src/Packet.cpp line 41) = SHA-256(payload type
// byte ‖ [path_len as a u16 little-endian, TRACE only] ‖ payload), first 8 bytes.
//
// Golden vectors are real: #wardriving pings from MeshSonar on a Wio Tracker L1 companion ("KE4BFI-v4") on the
// Oct 17 2026 drive, as the observer INNO-OB-2 (Heltec V4, observer firmware v1.17.1.5) published them over MQTT
// (`raw` and `hash`). Independently checked in Python (hashlib + `cryptography` AES-ECB/HMAC) over the whole M0
// capture: 456 / 456 GRP_TXT observer hashes recomputed from `raw`, and 301 / 301 MeshSonar copies (109 distinct
// pings) rebuilt byte for byte from (timestamp, node name, ping text) with the #wardriving key.
// Mid-drive points only; these broadcasts were public on the channel.
import 'dart:typed_data';

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
      // SHA-256(0x09 0x01 0x00 01 02 03 04)[0..8] (path_len as a u16, little-endian) and SHA-256(0x05 01 02 03 04)[0..8],
      // computed with Python hashlib.
      expect(toHex(packetHash(PayloadType.trace, p, pathLenByte: 1)), _py['trace']);
      expect(toHex(packetHash(PayloadType.grpTxt, p)), _py['grp']);
      // The old one-byte rule (SHA-256(0x09 0x01 01 02 03 04)) is gone.
      expect(toHex(packetHash(PayloadType.trace, p, pathLenByte: 1)), isNot('4df640a8e98f2056'));
    });

    test('only TRACE takes path_len: every other payload type hashes [type, payload] whatever the path_len byte', () {
      final p = [0xde, 0xad, 0xbe, 0xef, 0x00, 0x7f];
      for (var t = 0; t < 16; t++) {
        if (t == PayloadType.trace) continue;
        final plain = toHex(Uint8List.sublistView(sha256([t, ...p]), 0, 8));
        for (final pl in [0, 1, 3, 0x42, 0xbf]) {
          expect(toHex(packetHash(t, p, pathLenByte: pl)), plain, reason: 'type $t path_len $pl');
        }
      }
      for (final pl in [0, 1, 3, 0x42]) {
        expect(toHex(packetHash(PayloadType.trace, p, pathLenByte: pl)), toHex(Uint8List.sublistView(sha256([9, pl, 0, ...p]), 0, 8)));
      }
    });
  });

  // The website's contract fixtures (meshcore-insights src/test/fixtures/packets/analyzer-packet-details.json) and the
  // real TRACE copies in its src/lib/observers/packet-hash.test.ts (published by two CoreScope servers, read Nov 20
  // 2026). The app must give the same id as the server for the same raw bytes.
  group('same hash as the server for the same raw bytes', () {
    test('TRACE fixture (packet-detail.trace.json): path_len hashed as 2 bytes', () {
      final pkt = MeshPacket.tryParse(fromHex('2603281af6dec0175a00000000004f3c91'))!;
      expect(pkt.payloadType, PayloadType.trace);
      expect(pkt.routeType, RouteType.direct);
      expect(pkt.pathLenByte, 3);
      expect(toHex(pkt.payload), 'dec0175a00000000004f3c91');
      expect(pkt.hashHex, '50b835a910da5aac');
      expect(toHex(packetHash(PayloadType.trace, pkt.payload, pathLenByte: 3)), '50b835a910da5aac');
    });

    const traces = {
      '260062D3E975C012F21D014087': '0cbcc74a6fe0c62b',
      '26012E62D3E975C012F21D014087': '4def2dfc40707c39',
      '2600916239C500000000019D6F': '83063df3992acf2b',
      '2600F50280F500000000019D6F': '5c1d934f004d2282',
      '260131F90F026B0000000000364A6FE91820': '682cc0bba1a363b1',
      '2600FAF28E430000000001CF17': '9039b317f4be27b0',
      '2601ebd2a6fc6a00000000029ae11bf2': 'bb5be16cd265a625',
    };
    for (final e in traces.entries) {
      test('real TRACE ${e.key} hashes to the published ${e.value}', () {
        final pkt = MeshPacket.tryParse(fromHex(e.key))!;
        expect(pkt.payloadType, PayloadType.trace);
        expect(pkt.hashHex, e.value);
      });
    }

    test('a TRACE has one hash per hop count (same payload, path_len 0 and 1)', () {
      final a = MeshPacket.tryParse(fromHex('260062D3E975C012F21D014087'))!;
      final b = MeshPacket.tryParse(fromHex('26012E62D3E975C012F21D014087'))!;
      expect(toHex(a.payload), toHex(b.payload));
      expect(a.hashHex, isNot(b.hashHex));
    });

    // Regression: these ids were right before the TRACE fix and must not move.
    const others = [
      (
        'ADVERT, flood',
        PayloadType.advert,
        '11014f91f7b953529576091add8a19f9105e6572e43ea95429c60ed79ee1c4bf547ea48852006bec4aa923f895eef2290881d79464fc7b7c'
            '2db48aa47c17b2b247b309421af6d874db6b7ff90c57a845a57a77b45e57bc9009b5455f81b0f7f270c4975a466a5593422762029c2e0d'
            'fb4c69627261727920526f6f6d',
        '1add53ffce368256',
      ),
      (
        'GRP_TXT, flood, 2-byte hops',
        PayloadType.grpTxt,
        '15423cd04f1981bc904ca80f8e80c9016e6a0e9d56c16d19c149d87b2c7d92e4e443308bb6b5fb99679a25eafa50e4f5bd688a1e53ac48c3'
            '2aa3a3b4ea516dce64e2c5bd2b55419a012c742272bb87ec6589eb1af2e494b61f',
        'a03aaeaf864003ae',
      ),
      (
        'GRP_TXT, flood, 4 hops',
        PayloadType.grpTxt,
        '1504e2a73c4f1179b650a2715967740eff02a15d16198e7b05f6f65cb76077f829347f3852534c014cbb5868785bb4ed138757cf85578644'
            '578cf9e7f6ab00cd72c62dcec2d5472d13',
        'c4b06ee8fc39b187',
      ),
      (
        'GRP_TXT, transport flood',
        PayloadType.grpTxt,
        '14989b000002914f6293492e18ce1ea2e6af3c128c0492a43151f9fa1d70d9d43d5c085cbeb191aa6b5bd45f2aca661b7bec26e3c565be8a'
            '9beb582ae98ce3018b028e83f384b78945036f',
        '1c26c203910896f0',
      ),
      (
        'TXT_MSG, direct',
        PayloadType.txtMsg,
        '0a424f19a7b26bc456c86336c5cc50103c47022b9f69d9516a51b1b543a3ebd6b06f6619c0d0516cbc3d',
        '3d729e68c935af6f',
      ),
    ];
    for (final (name, type, raw, hash) in others) {
      test('unchanged: $name hashes to $hash', () {
        final pkt = MeshPacket.tryParse(fromHex(raw))!;
        expect(pkt.payloadType, type);
        expect(pkt.hashHex, hash);
        // [type, payload] only: no path_len, whatever the path.
        expect(toHex(Uint8List.sublistView(sha256([type, ...pkt.payload]), 0, 8)), hash);
      });
    }
  });

  group('packetHash text', () {
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

const _py = {'trace': 'dd79cbe99f3fc8f5', 'grp': '52532125f08a5485'};
