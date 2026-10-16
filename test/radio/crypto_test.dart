import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';

void main() {
  test('SHA-256 FIPS 180-4 vectors', () {
    expect(toHex(sha256(utf8.encode(''))), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(toHex(sha256(utf8.encode('abc'))), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(toHex(sha256(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  });

  test('HMAC-SHA256 RFC 4231 test case 2', () {
    expect(toHex(hmacSha256(utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?'))),
        '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
  });

  test('AES-128 FIPS 197 appendix C.1', () {
    final aes = Aes128(fromHex('000102030405060708090a0b0c0d0e0f'));
    final ct = aes.encryptBlock(fromHex('00112233445566778899aabbccddeeff'));
    expect(toHex(ct), '69c4e0d86a7b0430d8cdb78070b4c55a');
    expect(toHex(aes.decryptBlock(ct)), '00112233445566778899aabbccddeeff');
  });

  test('hashtag channel secret = sha256("#name")[0..16] (firmware docs/companion_protocol.md, "Channel Types")', () {
    // The firmware docs give this exact value for "#test".
    expect(toHex(hashtagChannelSecret('#test')), '9cd8fcf22a47333b591d96a2b848b73f');
    // MeshMapper lower-cases before hashing (wardrive.js deriveChannelKey).
    expect(toHex(hashtagChannelSecret('#Wardriving')), toHex(hashtagChannelSecret('#wardriving')));
    expect(toHex(hashtagChannelSecret('#wardriving')), 'e3c26491e9cd321e3a6be50d57d54acf'); // python hashlib
  });

  test('channel hash = sha256(secret16)[0] (BaseChatMesh::setChannel)', () {
    expect(channelHash(hashtagChannelSecret('#wardriving')), 129); // python hashlib
    expect(channelHash(hashtagChannelSecret('#test')), 217);
  });

  test('encryptThenMAC / MACThenDecrypt round trip and MAC rejection (src/Utils.cpp)', () {
    final key = hashtagChannelSecret('#wardriving');
    final data = utf8.encode('hello mesh, this is longer than one block');
    final enc = meshEncryptThenMac(key, data);
    expect((enc.length - 2) % 16, 0);
    final dec = meshMacThenDecrypt(key, enc)!;
    expect(dec.sublist(0, data.length), data);
    final bad = List<int>.from(enc)..[5] ^= 1;
    expect(meshMacThenDecrypt(key, bad), isNull);
    expect(meshMacThenDecrypt(hashtagChannelSecret('#other'), enc), isNull);
  });
}
