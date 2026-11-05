import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/path_tools.dart';
import 'package:meshsonar/radio/protocol.dart';

void main() {
  group('packed length byte (spike S3)', () {
    test('((size-1)<<6)|hops for 1, 2 and 3 byte hashes', () {
      expect(packPathLen(1, 3), 0x03);
      expect(packPathLen(2, 2), 0x42);
      expect(packPathLen(3, 1), 0x81);
      expect(hopsOfPathLen(0x42), 2);
      expect(hashSizeOfPathLen(0x81), 3);
      expect(hopsOfPathLen(0xFF), 0);
    });

    test('caps are 63 (6-bit count), 32 and 21 hops', () {
      expect([for (final s in pathHashSizes) maxHopsFor(s)], [63, 32, 21]);
      expect(() => packPathLen(3, 22), throwsArgumentError);
      expect(() => packPathLen(4, 1), throwsArgumentError);
    });

    test('validity follows Packet::isValidPathLen', () {
      expect(isValidPathLen(0xFF), isTrue);
      expect(isValidPathLen(0), isTrue);
      expect(isValidPathLen(0xC1), isFalse, reason: 'size 4 is reserved');
      expect(isValidPathLen(0x80 | 22), isFalse, reason: '22 x 3 = 66 > 64');
      expect(isValidPathLen(0x80 | 21), isTrue);
    });

    test('agrees with pathByteLength in the protocol layer', () {
      for (final size in pathHashSizes) {
        for (final n in [0, 1, 5, maxHopsFor(size)]) {
          expect(pathByteLength(packPathLen(size, n)), n * size);
        }
      }
    });
  });

  group('encode / decode round trips', () {
    for (final size in pathHashSizes) {
      test('$size-byte hashes', () {
        final hops = [for (var i = 0; i < 4; i++) [for (var b = 0; b < size; b++) 0x10 * (i + 1) + b]];
        final r = PathRoute(size, hops);
        final enc = encodePath(r);
        expect(enc.pathLen, ((size - 1) << 6) | 4);
        expect(enc.path.length, 4 * size);
        final back = decodePath(enc.pathLen, enc.path);
        expect(back, r);
        expect(back!.hexHops, r.hexHops);
        expect(back.reversed.reversed, r);
      });
    }

    test('unknown, invalid and short paths decode to null', () {
      expect(decodePath(0xFF, const []), isNull);
      expect(decodePath(0xC1, [1, 2, 3, 4]), isNull);
      expect(decodePath(0x42, [1, 2, 3]), isNull);
    });

    test('a direct neighbour is a valid empty route', () {
      final r = decodePath(0, const [])!;
      expect(r.isEmpty, isTrue);
      expect(r.pathLenByte, 0);
    });

    test('hex helpers and text form', () {
      final r = PathRoute.fromHex(['a1b2', 'c3d4']);
      expect(r.hashSize, 2);
      expect(r.text, 'a1b2 > c3d4');
      expect(splitHexHops(joinHexHops(r.hexHops)), r.hexHops);
      expect(splitHexHops(null), isEmpty);
    });

    test('hops must all be the same size', () {
      expect(() => PathRoute(2, [Uint8List.fromList([1])]), throwsArgumentError);
    });
  });

  group('typed route text', () {
    test('aa,bb,cc', () {
      final r = parsePathText('AA, bb ,cc').route!;
      expect(r.hexHops, ['aa', 'bb', 'cc']);
      expect(parsePathText('a1b2 > c3d4').route!.hashSize, 2);
    });
    test('errors are plain sentences', () {
      expect(parsePathText('').error, isNotNull);
      expect(parsePathText('zz').error, contains('not a hash'));
      expect(parsePathText('aa,bbcc').error, contains('same length'));
      expect(parsePathText('aabbccdd').error, contains('1, 2 or 3'));
      expect(parsePathText('a').error, isNotNull);
      expect(parsePathText(List.filled(22, 'aabbcc').join(',')).error, contains('At most 21'));
    });
  });

  group('hash collisions', () {
    final ridge = PathCandidate('a1' * 32, 'Ridge');
    final hill = PathCandidate('a1${'b2' * 31}', 'Hill');
    final far = PathCandidate('c3' * 32, 'Far');

    test('two repeaters sharing the first byte are flagged once, with the plan wording', () {
      final c = findHashCollisions([ridge, far], [ridge, hill, far], 1);
      expect(c, hasLength(1));
      expect(c.single.hash, 'a1');
      expect(c.single.nodes.map((n) => n.name), unorderedEquals(['Ridge', 'Hill']));
      expect(c.single.warning, '2 repeaters share a1; the radio can\'t tell them apart.');
    });

    test('a longer hash tells them apart', () {
      expect(findHashCollisions([ridge], [ridge, hill], 2), isEmpty);
      expect(smallestSafeHashSize([ridge, hill], [ridge, hill, far]), 2);
    });

    test('the same repeater twice in a route is not a collision; an unknown chosen node still counts', () {
      expect(findHashCollisions([ridge, ridge], [ridge], 1), isEmpty);
      expect(findHashCollisions([PathCandidate('a1${'ff' * 31}', 'Typed')], [ridge], 1), hasLength(1));
    });

    test('identical 3-byte prefixes leave no safe size', () {
      final x = PathCandidate('a1b2c3${'00' * 29}', 'X');
      final y = PathCandidate('a1b2c3${'11' * 29}', 'Y');
      expect(smallestSafeHashSize([x], [x, y]), isNull);
    });
  });
}
