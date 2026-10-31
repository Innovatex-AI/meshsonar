import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/channel_secret.dart';
import 'package:meshsonar/chat/mesh_links.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/radio/crypto.dart' as radio;

LinkError? err(String s) {
  final r = MeshLinks.parse(s);
  return r is LinkParseError ? r.error : null;
}

void main() {
  group('documented examples (MeshCore docs/qr_codes.md)', () {
    test('channel add', () {
      final r = MeshLinks.parse('meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72') as ChannelLink;
      expect(r.name, 'Public');
      expect(r.secret, publicChannelSecret16);
      expect(base64.encode(r.secret), 'izOH6cXN6mrJ5e26oRXNcg==', reason: 'the same key the docs give in base64');
      expect(r.regionScope, isNull);
    });

    test('contact add', () {
      final r = MeshLinks.parse('meshcore://contact/add?name=Example+Contact&public_key=9cd8fcf22a47333b591d96a2b848b73f457b1bb1a3ea2453a885f9e5787765b1&type=1') as ContactLink;
      expect(r.name, 'Example Contact');
      expect(r.type, ContactType.companion);
      expect(r.publicKey, '9cd8fcf22a47333b591d96a2b848b73f457b1bb1a3ea2453a885f9e5787765b1');
    });

    test('region scope, percent-encoding, plus, uppercase hex and scheme case', () {
      final r = MeshLinks.parse('MESHCORE://channel/add?name=My%20Chan&secret=8B3387E9C5CDEA6AC9E5EDBAA115CD72&region_scope=us%2Doh') as ChannelLink;
      expect(r.name, 'My Chan');
      expect(r.regionScope, 'us-oh');
      expect(MeshLinks.parse('  meshcore://contact/add?public_key=${'ab' * 32}  '), isA<ContactLink>());
    });

    test('legacy advert hex link', () {
      final packet = Uint8List.fromList(List.generate(120, (i) => i));
      final r = MeshLinks.parse(MeshLinks.encodeAdvert(packet)) as AdvertLink;
      expect(r.packet, packet);
      expect(err('meshcore://${'ab' * 97}'), LinkError.badAdvert);
      expect(err('meshcore://${'ab' * 172}'), LinkError.badAdvert);
    });
  });

  group('round trips', () {
    test('channel and contact links survive encode/decode for awkward names', () {
      final rnd = Random(7);
      final names = ['Public', '#wardriving', 'Café ☕', '日本語チャンネル', 'a&b=c?d', 'with space', 'plus+sign', '100% sure', 'x' * 31, 'ü' * 15];
      for (final n in names) {
        final secret = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
        final c = MeshLinks.parse(MeshLinks.encodeChannel(name: n, secret: secret, regionScope: n == 'Public' ? 'us-oh' : null)) as ChannelLink;
        expect(c.name, n, reason: n);
        expect(c.secret, secret);
        final key = toHex(List.generate(32, (_) => rnd.nextInt(256)));
        for (final t in ContactType.values) {
          final k = MeshLinks.parse(MeshLinks.encodeContact(name: n, publicKey: key, type: t)) as ContactLink;
          expect(k.name, n);
          expect(k.publicKey, key);
          expect(k.type, t);
        }
      }
    });

    test('random valid inputs round trip (property)', () {
      final rnd = Random(99);
      const alphabet = 'abcXYZ019 _-+&=?%#é日😀';
      for (var i = 0; i < 300; i++) {
        final chars = alphabet.runes.toList();
        var name = String.fromCharCodes(List.generate(1 + rnd.nextInt(8), (_) => chars[rnd.nextInt(chars.length)])).trim();
        if (name.isEmpty) name = 'n';
        final secret = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
        final back = MeshLinks.parse(MeshLinks.encodeChannel(name: name, secret: secret)) as ChannelLink;
        expect(back.name, name);
        expect(back.secret, secret);
      }
    });

    test('encoders refuse bad input instead of emitting a bad link', () {
      expect(() => MeshLinks.encodeChannel(name: 'x', secret: List.filled(15, 0)), throwsArgumentError);
      expect(() => MeshLinks.encodeChannel(name: '', secret: List.filled(16, 0)), throwsArgumentError);
      expect(() => MeshLinks.encodeChannel(name: 'x' * 32, secret: List.filled(16, 0)), throwsArgumentError);
      expect(() => MeshLinks.encodeContact(name: 'x', publicKey: 'zz' * 32), throwsArgumentError);
    });
  });

  group('hostile input', () {
    final k64 = 'ab' * 32;
    final s32 = 'cd' * 16;
    test('rejects with a reason, never throws', () {
      expect(err(''), LinkError.empty);
      expect(err('   '), LinkError.empty);
      expect(err('https://example.com'), LinkError.notMeshcore);
      expect(err('meshcore://'), LinkError.unknownKind);
      expect(err('meshcore://nonsense/path'), LinkError.unknownKind);
      expect(err('meshcore://channel/add'), LinkError.missingField);
      expect(err('meshcore://channel/add?name=x'), LinkError.missingField);
      expect(err('meshcore://channel/add?name=x&secret=abcd'), LinkError.badSecret);
      expect(err('meshcore://channel/add?name=x&secret=${'zz' * 16}'), LinkError.badSecret);
      expect(err('meshcore://channel/add?name=&secret=$s32'), LinkError.badName);
      expect(err('meshcore://channel/add?name=${'x' * 32}&secret=$s32'), LinkError.badName);
      expect(err('meshcore://channel/add?name=a%00b&secret=$s32'), LinkError.badName);
      expect(err('meshcore://channel/add?name=a%0Ab&secret=$s32'), LinkError.badName);
      expect(err('meshcore://channel/add?name=%E2%80%AEevil&secret=$s32'), LinkError.badName, reason: 'bidi override');
      expect(err('meshcore://channel/add?name=x&secret=$s32&region_scope=${'y' * 40}'), LinkError.badScope);
      expect(err('meshcore://contact/add?name=x'), LinkError.missingField);
      expect(err('meshcore://contact/add?public_key=abc'), LinkError.badPublicKey);
      expect(err('meshcore://contact/add?public_key=$k64&name=a%00'), LinkError.badName);
      expect(err('meshcore://channel/add?name=%ZZ&secret=$s32'), isNotNull, reason: 'bad percent escape');
      expect(err('meshcore://${'x' * 5000}'), LinkError.tooLong);
    });

    test('out of range type is tolerated as unknown; duplicate params use the last', () {
      expect((MeshLinks.parse('meshcore://contact/add?public_key=$k64&type=9') as ContactLink).type, isNull);
      expect((MeshLinks.parse('meshcore://contact/add?public_key=$k64&type=abc') as ContactLink).type, isNull);
      expect((MeshLinks.parse('meshcore://contact/add?public_key=$k64&name=a&name=b') as ContactLink).name, 'b');
    });

    test('fuzz: random strings and mutated valid links never throw', () {
      final rnd = Random(1234);
      final valid = [
        MeshLinks.encodeChannel(name: 'Ohio', secret: List.filled(16, 7), regionScope: 'us-oh'),
        MeshLinks.encodeContact(name: 'Bob', publicKey: k64, type: ContactType.repeater),
      ];
      for (var i = 0; i < 3000; i++) {
        String s;
        if (i.isEven) {
          s = String.fromCharCodes(List.generate(rnd.nextInt(200), (_) => rnd.nextInt(0x3000)));
        } else {
          final cs = valid[rnd.nextInt(2)].codeUnits.toList();
          for (var k = 0; k < 1 + rnd.nextInt(4); k++) {
            final at = rnd.nextInt(cs.length);
            switch (rnd.nextInt(3)) {
              case 0:
                cs[at] = rnd.nextInt(0xffff);
              case 1:
                cs.removeAt(at);
              default:
                cs.insert(at, rnd.nextInt(0x80));
            }
          }
          s = String.fromCharCodes(cs);
        }
        expect(() => MeshLinks.parse(s), returnsNormally);
      }
      expect(() => MeshLinks.parse(null), returnsNormally);
    });
  });

  group('channel secrets', () {
    test('match the radio layer derivations', () {
      expect(publicChannelSecret16, radio.publicChannelSecret);
      for (final n in ['#wardriving', 'Test', '#Mixed Case']) {
        expect(hashtagSecret16(n), radio.hashtagChannelSecret(n), reason: n);
      }
      expect(channelHashByte(publicChannelSecret16), radio.channelHash(radio.publicChannelSecret));
    });
  });
}
