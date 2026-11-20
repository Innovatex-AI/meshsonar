// The phone's own packet decoder (AZ-3.2) against the contract fixtures: the bytes of every packet-detail fixture decode
// on the phone to the same hash and the same byte map (start, end, colour group, field id) as the server's answer, the
// Public and #wardriving messages decrypt, the private channel and the direct message stay encrypted, the TRACE header
// path is read as SNR. Plus the types the fixtures do not carry (ANON_REQ, ACK, CONTROL, MULTIPART, RAW_CUSTOM) and
// pasted input that is not a packet.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/v1/local_decoder.dart';
import 'package:meshsonar/core/v1/packet_models.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';

Map<String, dynamic> detail(String name) => (jsonDecode(File('test/fixtures/analyzer/packet-detail.$name.json').readAsStringSync()) as Map)['data'] as Map<String, dynamic>;

const fixtures = [
  'advert-first-party',
  'grp-txt-outside-ambiguous',
  'grp-txt-hashtag-merged',
  'grp-txt-private-undecodable',
  'txt-msg-encrypted',
  'trace',
];

void main() {
  final wardriving = LocalChannelKey.hashtag('#wardriving');

  group('agrees with the server on every fixture', () {
    for (final name in fixtures) {
      test(name, () {
        final f = detail(name);
        final d = decodePacketLocally(fromHex(f['raw'] as String), hashtagKeys: [wardriving]);
        expect(d.hash, f['hash'], reason: 'the firmware hash rule');
        expect(d.type, f['type']);
        expect(d.typeName, f['typeName']);
        expect(d.route, f['route']);
        expect(d.size, f['size']);
        final server = [for (final b in f['bytes'] as List) ByteRange.tryParse(b)!];
        expect([for (final r in d.bytes) '${r.start}-${r.end} ${byteGroupWire(r.group)} ${r.field}'],
            [for (final r in server) '${r.start}-${r.end} ${byteGroupWire(r.group)} ${r.field}']);
        // Ranges cover the packet exactly, in order, without gaps.
        var at = 0;
        for (final r in d.bytes) {
          expect(r.start, at);
          at = r.end;
        }
        expect(at, (f['raw'] as String).length ~/ 2);
        expect(d.decodedKind, (f['decoded'] as Map).keys.single);
      });
    }
  });

  test('the Public message decrypts with the built-in key', () {
    final d = decodePacketLocally(fromHex(detail('grp-txt-outside-ambiguous')['raw'] as String));
    expect(d.decodedFields['decodeStatus'], 'decrypted');
    expect(d.decodedFields['keySource'], 'builtin_public');
    expect(d.channel!.id, 'public');
    expect(d.message!.sender, 'Kestrel-07');
    expect(d.message!.text, 'anyone hearing Hilltop this morning?');
    expect(d.bytes.last.value, 'decrypted');
    expect([for (final h in d.paths.single.hops) h.prefix], ['e2', 'a7', '3c', '4f']);
    expect(d.paths.single.hops.every((h) => h.confidence == HopConfidence.unknown && h.evidence.contains('not_resolved_on_phone')), isTrue);
  });

  test('#wardriving decrypts only with its hashtag key', () {
    final raw = fromHex(detail('grp-txt-hashtag-merged')['raw'] as String);
    expect(decodePacketLocally(raw).decodedFields['decodeStatus'], 'no_key');
    final d = decodePacketLocally(raw, hashtagKeys: [wardriving]);
    expect(d.decodedFields['decodeStatus'], 'decrypted');
    expect(d.decodedFields['keySource'], 'hashtag_list');
    expect(d.channel!.id, 'tag:wardriving');
    expect(d.message!.text, 'drive loop 3 done, 41 pings, Old Mill answered 38');
    expect(d.hashSize, 2);
  });

  test('a private channel packet stays encrypted, with its scope code bytes', () {
    final d = decodePacketLocally(fromHex(detail('grp-txt-private-undecodable')['raw'] as String), hashtagKeys: [wardriving]);
    expect(d.decodedFields['decodeStatus'], 'no_key');
    expect(d.decodedFields['plaintext'], isNull);
    expect(d.channel!.id, 'enc:62');
    expect(d.message, isNull);
    expect(d.bytes.firstWhere((r) => r.field == 'transportCode1').hex, '989b');
    expect(d.bytes.last.value, 'no_key');
  });

  test('a direct message is encrypted end to end; DIRECT path is the route ahead', () {
    final d = decodePacketLocally(fromHex(detail('txt-msg-encrypted')['raw'] as String));
    expect(d.decodedKind, 'direct');
    expect(d.decodedFields['encrypted'], isTrue);
    expect(d.decodedFields['destHash'], '6b');
    expect(d.decodedFields['srcHash'], 'c4');
    expect(d.paths.single.direction, 'remaining');
    expect([for (final h in d.paths.single.hops) h.prefix], ['4f19', 'a7b2']);
    expect(d.bytes.last.value, 'encrypted');
  });

  test('TRACE: header path bytes are SNR, hops are the payload targets', () {
    final d = decodePacketLocally(fromHex(detail('trace')['raw'] as String));
    final f = d.decodedFields;
    expect(f['tag'], '5a17c0de');
    expect(f['authCode'], 0);
    expect(f['targets'], ['4f', '3c', '91']);
    expect(f['snr'], [10.0, 6.5, -2.5]);
    expect(f['hopsCompleted'], 3);
    expect([for (final h in d.paths.single.hops) h.snrDb], [10.0, 6.5, -2.5]);
  });

  test('an advert decodes name, role, position; the signature is said to be unchecked', () {
    final d = decodePacketLocally(fromHex(detail('advert-first-party')['raw'] as String));
    final f = d.decodedFields;
    expect(f['name'], 'Library Room');
    expect(f['role'], 'room');
    expect((f['position'] as Map)['lat'], closeTo(39.98701, 1e-6));
    expect((f['signature'] as Map)['checked'], isFalse);
    expect(d.origin!.key, '91f7b953529576091add8a19f9105e6572e43ea95429c60ed79ee1c4bf547ea4');
    expect(d.missing, contains('The advert signature is not checked on the phone.'));
  });

  Uint8List pkt(int type, List<int> payload, {int route = RouteType.flood, List<int> path = const []}) =>
      MeshPacket(header: makeHeader(route, type), pathLenByte: encodePathLen(1, path.length), path: [for (final p in path) Uint8List.fromList([p])], payload: Uint8List.fromList(payload)).toBytes();

  test('ANON_REQ, ACK, MULTIPART, CONTROL and RAW_CUSTOM all decode with full byte coverage', () {
    final cases = <Uint8List, String>{
      pkt(PayloadType.anonReq, [0x6b, ...List.filled(32, 0xab), 0x12, 0x34, ...List.filled(16, 0)]): 'anonReq',
      pkt(PayloadType.ack, [0xf5, 0x94, 0xc4, 0xe4], path: [0x4f, 0x3c]): 'ack',
      pkt(PayloadType.multipart, [0x23, 1, 2, 3, 4]): 'multipart',
      pkt(PayloadType.control, [0x80, 0x04, 0xde, 0xc0, 0x17, 0x5a], route: RouteType.direct): 'control',
      pkt(PayloadType.control, [0x92, 0x28, 0xde, 0xc0, 0x17, 0x5a, ...List.filled(8, 0x91)], route: RouteType.direct): 'control',
      pkt(PayloadType.rawCustom, [9, 8, 7]): 'raw',
    };
    for (final e in cases.entries) {
      final d = decodePacketLocally(e.key);
      expect(d.decodedKind, e.value);
      var at = 0;
      for (final r in d.bytes) {
        expect(r.start, at, reason: '${e.value} ${r.field}');
        at = r.end;
      }
      expect(at, e.key.length, reason: e.value);
      expect(d.hash, toHex(packetHash(MeshPacket.tryParse(e.key)!.payloadType, MeshPacket.tryParse(e.key)!.payload)));
    }
    final ack = decodePacketLocally(cases.keys.elementAt(1));
    expect(ack.decodedFields['crc'], 'f594c4e4');
    final req = decodePacketLocally(cases.keys.elementAt(3));
    expect(req.decodedFields['subtype'], 'discover_req');
    expect(req.decodedFields['tag'], '5a17c0de');
    final resp = decodePacketLocally(cases.keys.elementAt(4));
    expect(resp.decodedFields['subtype'], 'discover_resp');
    expect(resp.decodedFields['snr'], 10.0);
    expect(localDecoderKnowsType(PayloadType.rawCustom), isFalse);
    expect(localDecoderKnowsType(13), isFalse);
    expect(localDecoderKnowsType(PayloadType.trace), isTrue);
  });

  test('pasted text: spaces and 0x are fine; junk is refused plainly', () {
    expect(parseHexInput('15 04 e2 a7'), Uint8List.fromList([0x15, 0x04, 0xe2, 0xa7]));
    expect(parseHexInput('0x15:0x04'), Uint8List.fromList([0x15, 0x04]));
    expect(parseHexInput('xyz'), isNull);
    expect(parseHexInput('150'), isNull, reason: 'half a byte');
    expect(() => decodePacketLocally(Uint8List.fromList([0x15])), throwsA(isA<LocalDecodeError>()));
    expect(() => decodePacketLocally(Uint8List.fromList([0x15, 0x3f, 1, 2])), throwsA(isA<LocalDecodeError>()), reason: 'path longer than the bytes');
  });
}
