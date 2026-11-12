// Private photo crypto and link (spec photo-e2e-private-2026-11-12.md): key text, blob format, AAD role binding, tamper and
// wrong-key failures, the upload body framing and the golden vector shared with the server (photo-e2e-golden-vector.json).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/private_photo.dart';

Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String toHex(List<int> b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final thumb = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 0xFF, 0xD9]);
  final full = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, ...List.generate(300, (i) => i % 251), 0xFF, 0xD9]);

  group('key', () {
    test('generated keys are 16 random bytes and encode to exactly 22 url-safe characters', () {
      final a = PrivatePhoto.generateKey(), b = PrivatePhoto.generateKey();
      expect(a.length, 16);
      expect(a, isNot(b));
      final t = PrivatePhoto.encodeKey(a);
      expect(t.length, 22);
      expect(t, matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(PrivatePhoto.decodeKey(t), a);
    });

    test('keys of every byte value survive the round trip (url-safe alphabet, no padding)', () {
      for (final k in [List.filled(16, 0xFF), List.filled(16, 0), List.generate(16, (i) => 0xF8 + i % 8)]) {
        final t = PrivatePhoto.encodeKey(k);
        expect(t.length, 22);
        expect(t, isNot(contains('=')));
        expect(t, isNot(contains('+')));
        expect(t, isNot(contains('/')));
        expect(PrivatePhoto.decodeKey(t), k);
      }
    });

    test('wrong lengths and characters are refused with a typed error', () {
      for (final bad in ['', 'AAECAwQFBgcICQoLDA0OD', 'AAECAwQFBgcICQoLDA0ODwA', 'AAECAwQFBgcICQoLDA0OD=', 'AAECAwQFBgcICQoLDA0O+w', 'AAECAwQFBgcICQoLDA0O/w']) {
        expect(() => PrivatePhoto.decodeKey(bad), throwsA(isA<PrivatePhotoException>().having((e) => e.kind, 'kind', PrivatePhotoErrorKind.badKey)), reason: bad);
      }
      expect(() => PrivatePhoto.encodeKey(List.filled(15, 1)), throwsA(isA<PrivatePhotoException>()));
      expect(() => PrivatePhoto.encodeKey(List.filled(17, 1)), throwsA(isA<PrivatePhotoException>()));
    });
  });

  group('blobs', () {
    test('format: 0x01 || nonce(12) || ciphertext || tag(16); each blob has its own nonce; round trip', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      expect(e.key.length, 16);
      for (final (blob, plain) in [(e.thumbBlob, thumb), (e.fullBlob, full)]) {
        expect(blob[0], 1);
        expect(blob.length, 1 + 12 + plain.length + 16);
      }
      expect(e.thumbBlob.sublist(1, 13), isNot(e.fullBlob.sublist(1, 13)));
      expect(await PrivatePhoto.decrypt(e.thumbBlob, e.key, PrivatePhotoRole.thumb), thumb);
      expect(await PrivatePhoto.decrypt(e.fullBlob, e.key, PrivatePhotoRole.full), full);
    });

    test('the ciphertext does not contain the JPEG', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      expect(toHex(e.fullBlob), isNot(contains(toHex(full.sublist(4, 40)))));
    });

    test('a changed byte anywhere (version aside) fails authentication', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      for (final i in [1, 5, 12, 13, 14, e.thumbBlob.length - 17, e.thumbBlob.length - 1]) {
        final b = Uint8List.fromList(e.thumbBlob)..[i] ^= 0x01;
        await expectLater(PrivatePhoto.decrypt(b, e.key, PrivatePhotoRole.thumb),
            throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.authFailed)), reason: 'byte $i');
      }
    });

    test('a thumb blob offered as full (and the reverse) does not open', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      await expectLater(PrivatePhoto.decrypt(e.thumbBlob, e.key, PrivatePhotoRole.full), throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.authFailed)));
      await expectLater(PrivatePhoto.decrypt(e.fullBlob, e.key, PrivatePhotoRole.thumb), throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.authFailed)));
    });

    test('a wrong key does not open; a key of the wrong length is a badKey', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      final other = PrivatePhoto.generateKey();
      await expectLater(PrivatePhoto.decrypt(e.fullBlob, other, PrivatePhotoRole.full), throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.authFailed)));
      await expectLater(PrivatePhoto.decrypt(e.fullBlob, List.filled(15, 0), PrivatePhotoRole.full), throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.badKey)));
    });

    test('too short, truncated or another version byte is malformed or fails, never a crash', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      await expectLater(PrivatePhoto.decrypt(Uint8List(29), e.key, PrivatePhotoRole.thumb), throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.malformed)));
      await expectLater(PrivatePhoto.decrypt(Uint8List(0), e.key, PrivatePhotoRole.thumb), throwsA(isA<PrivatePhotoException>()));
      final v2 = Uint8List.fromList(e.thumbBlob)..[0] = 2;
      await expectLater(PrivatePhoto.decrypt(v2, e.key, PrivatePhotoRole.thumb), throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.malformed)));
      final cut = e.thumbBlob.sublist(0, e.thumbBlob.length - 3);
      await expectLater(PrivatePhoto.decrypt(cut, e.key, PrivatePhotoRole.thumb), throwsA(isA<PrivatePhotoException>().having((x) => x.kind, 'kind', PrivatePhotoErrorKind.authFailed)));
    });

    test('errors never carry the key or the plaintext', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      final text = PrivatePhoto.encodeKey(e.key);
      try {
        await PrivatePhoto.decrypt(e.fullBlob, PrivatePhoto.generateKey(), PrivatePhotoRole.full);
        fail('should throw');
      } on PrivatePhotoException catch (x) {
        expect(x.toString(), isNot(contains(text)));
      }
    });
  });

  group('upload body', () {
    test('u32 big-endian thumb length, then the thumb blob, then the full blob', () async {
      final e = await PrivatePhoto.encrypt(thumb, full);
      final body = e.uploadBody;
      expect(body.length, 4 + e.thumbBlob.length + e.fullBlob.length);
      expect(ByteData.sublistView(body).getUint32(0, Endian.big), e.thumbBlob.length);
      expect(body.sublist(4, 4 + e.thumbBlob.length), e.thumbBlob);
      expect(body.sublist(4 + e.thumbBlob.length), e.fullBlob);
      final big = PrivatePhoto.buildUploadBody(List.filled(0x010203, 7), const [9]);
      expect(big.sublist(0, 4), [0, 1, 2, 3]);
    });
  });

  group('link', () {
    final key = List<int>.generate(16, (i) => i);
    test('55 bytes: 24 + 8 + 1 + 22', () {
      final link = buildPrivatePhotoLink('k3Xq9TzA', key);
      expect(link, 'https://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODw');
      expect(utf8.encode(link).length, privatePhotoLinkBytes);
      expect(160 - privatePhotoLinkBytes - 1, 104);
    });

    test('parsing: valid, wrong id length, wrong key length, trailing key char, extra path, plain link', () {
      final ok = parsePrivatePhotoLink('https://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODw');
      expect(ok?.id, 'k3Xq9TzA');
      expect(ok?.keyText, 'AAECAwQFBgcICQoLDA0ODw');
      expect(ok?.key, key);
      expect(ok?.blobUrl(PrivatePhotoRole.thumb), 'https://meshsonar.com/e/k3Xq9TzA/thumb');
      expect(ok?.blobUrl(PrivatePhotoRole.full), 'https://meshsonar.com/e/k3Xq9TzA/full');
      expect(ok.toString(), isNot(contains('AAECAw')));
      for (final bad in [
        'https://meshsonar.com/e/k3Xq9TzA',
        'https://meshsonar.com/e/k3Xq9TzA#',
        'https://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0OD',
        'https://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODwA',
        'https://meshsonar.com/e/k3Xq9Tz#AAECAwQFBgcICQoLDA0ODw',
        'https://meshsonar.com/e/k3Xq9TzAB#AAECAwQFBgcICQoLDA0ODw',
        'https://meshsonar.com/e/k3Xq9TzA/full#AAECAwQFBgcICQoLDA0ODw',
        'https://meshsonar.com/p/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODw',
        'http://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODw',
        'x https://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODw',
      ]) {
        expect(parsePrivatePhotoLink(bad), isNull, reason: bad);
      }
    });

    test('redact hides the key', () {
      expect(redactPrivatePhotoLink('see https://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODw'), 'see https://meshsonar.com/e/k3Xq9TzA#<key>');
    });
  });

  group('golden vector (shared with the server and the web viewer)', () {
    // A copy of meshsonar-infra docs/planning/photo-e2e-golden-vector.json (the server agent's file; keep the two identical).
    final src = File('test/fixtures/photos/photo-e2e-golden-vector.json');

    test('the vector file is present', () => expect(src.existsSync(), isTrue));

    test('encrypting the vector plaintexts with its key and nonces gives exactly its blobs; decrypting gives its plaintexts', () async {
      final j = jsonDecode(src.readAsStringSync()) as Map<String, dynamic>;
      final key = PrivatePhoto.decodeKey(j['keyB64u'] as String);
      expect(toHex(key), j['keyHex']);
      for (final v in (j['vectors'] as List).cast<Map<String, dynamic>>()) {
        final role = PrivatePhotoRole.values.byName(v['role'] as String);
        expect(role.aad, v['aad']);
        final plain = hex(v['plaintextHex'] as String);
        final blob = hex(v['blobHex'] as String);
        final enc = await PrivatePhoto.encryptBlob(plain, key, role, nonce: hex(v['nonceHex'] as String));
        expect(toHex(enc), toHex(blob), reason: '${v['role']} encrypt');
        expect(toHex(await PrivatePhoto.decrypt(blob, key, role)), toHex(plain), reason: '${v['role']} decrypt');
      }
    });
  });
}
