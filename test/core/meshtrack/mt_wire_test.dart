import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/meshtrack/mt_wire.dart';
import 'package:meshsonar/core/meshtrack/plus_code.dart';

void main() {
  const code = '87G8Q2X5+7F2';

  group('every message type', () {
    test('position with speed and course', () {
      final m = parseMeshTrack('MT1 @$code s34 c270') as MtPosition;
      expect(m.code, code);
      expect(m.speedKmh, 34);
      expect(m.courseDeg, 270);
      expect(m.parked, isFalse);
      final a = PlusCode.tryDecode(code)!;
      expect(m.lat, a.lat);
      expect(m.lon, a.lon);
    });

    test('position without options, 8 digit and padded codes', () {
      expect((parseMeshTrack('MT1 @$code') as MtPosition).speedKmh, isNull);
      expect((parseMeshTrack('MT1 @87G8Q2X5+') as MtPosition).area.codeLength, 8);
      expect((parseMeshTrack('MT1 @87G8Q2X5+7F') as MtPosition).area.codeLength, 10);
      expect((parseMeshTrack('MT1 @87G80000+') as MtPosition).area.codeLength, 4);
    });

    test('parked', () {
      final m = parseMeshTrack('MT1 @$code s0') as MtPosition;
      expect(m.parked, isTrue);
      expect(m.courseDeg, isNull);
    });

    test('requests', () {
      expect((parseMeshTrack('MT1 ?') as MtRequest).name, isNull);
      expect((parseMeshTrack('MT1 ? Sam Smith ') as MtRequest).name, 'Sam Smith');
      final long = 'N' * 40;
      expect(utf8.encode((parseMeshTrack('MT1 ? $long') as MtRequest).name!).length, kMtMaxNameBytes);
    });

    test('meet and clear', () {
      final m = parseMeshTrack('MT1 !$code Big oak tree') as MtMeet;
      expect(m.code, code);
      expect(m.label, 'Big oak tree');
      expect((parseMeshTrack('MT1 !$code') as MtMeet).label, isNull);
      expect(parseMeshTrack('MT1 !x'), isA<MtMeetClear>());
      expect(parseMeshTrack('MT1 !X'), isA<MtMeetClear>());
      final longLabel = parseMeshTrack('MT1 !$code ${'label ' * 10}') as MtMeet;
      expect(utf8.encode(longLabel.label!).length, lessThanOrEqualTo(kMtMaxLabelBytes));
    });

    test('meet label is plain text: control characters removed', () {
      final m = parseMeshTrack('MT1 !$code a\u0007b​ c') as MtMeet;
      expect(m.label, 'ab​c');
    });

    test('stop', () {
      expect(parseMeshTrack('MT1 x'), isA<MtStop>());
      expect(parseMeshTrack('mt1 X'), isA<MtStop>());
    });
  });

  group('tolerance', () {
    test('trim, collapse spaces, case', () {
      final m = parseMeshTrack('   mt1   @87g8q2x5+7f2    S34\tC270  ') as MtPosition;
      expect(m.code, code);
      expect(m.speedKmh, 34);
      expect(m.courseDeg, 270);
    });

    test('unknown trailing tokens ignored', () {
      final m = parseMeshTrack('MT1 @$code s34 c270 b88 zzz future=1') as MtPosition;
      expect(m.speedKmh, 34);
      expect(parseMeshTrack('MT1 x later'), isA<MtStop>());
    });

    test('bad optional token drops that field only', () {
      final m = parseMeshTrack('MT1 @$code s999 c400') as MtPosition;
      expect(m.speedKmh, isNull);
      expect(m.courseDeg, isNull);
      expect((parseMeshTrack('MT1 @$code s-3 c90') as MtPosition).courseDeg, 90);
      expect((parseMeshTrack('MT1 @$code sabc c12') as MtPosition).courseDeg, 12);
    });

    test('bad code drops the message (not consumed)', () {
      for (final b in ['MT1 @', 'MT1 @87G8Q2X5', 'MT1 @87G8Q2X5+7', 'MT1 @ZZZZZZZZ+', 'MT1 @Q2X5+7F', 'MT1 !87G8QIX5+7F2 x', 'MT1 @87G8Q2X5+7F2é']) {
        expect(parseMeshTrack(b), isNull, reason: b);
      }
    });

    test('not MeshTrack v1: stays chat', () {
      for (final b in ['', 'MT1', 'MT1 hi', 'MT1 hi there', 'MT2 @$code', 'MT10 @$code', 'hello MT1 @$code', 'MS:abcdefghij', 'MT1@$code', 'MT1 ?x', 'MT1 !', 'MT1 @$code\nsecond line']) {
        expect(parseMeshTrack(b), isNull, reason: b);
      }
    });

    test('over 160 bytes not accepted', () {
      expect(parseMeshTrack('MT1 @$code ${'z' * 150}'), isNull);
    });
  });

  group('format', () {
    test('position: course only from 5 km/h', () {
      expect(formatMtPosition(code, speedKmh: 34, courseDeg: 270), 'MT1 @$code s34 c270');
      expect(formatMtPosition(code, speedKmh: 4, courseDeg: 270), 'MT1 @$code s4');
      expect(formatMtPosition(code), 'MT1 @$code');
      expect(formatMtPosition(code, speedKmh: 900), 'MT1 @$code s300');
      expect(formatMtPosition(code, speedKmh: 50, courseDeg: -10), 'MT1 @$code s50 c350');
      expect(formatMtParked(code), 'MT1 @$code s0');
    });

    test('size in the spec: KE4BFI position is 34 text bytes', () {
      expect(utf8.encode('KE4BFI: ${formatMtPosition(code, speedKmh: 34, courseDeg: 270)}').length, 34);
    });

    test('others, round trip', () {
      expect(formatMtRequest(), 'MT1 ?');
      expect(formatMtRequest(' Sam '), 'MT1 ? Sam');
      expect(formatMtMeet(code, label: 'Gate\n3'), 'MT1 !$code Gate3');
      expect(formatMtMeet(code), 'MT1 !$code');
      expect(kMtMeetClearText, 'MT1 !x');
      expect(kMtStopText, 'MT1 x');
      expect(parseMeshTrack(formatMtMeet(code, label: 'Gate 3')), isA<MtMeet>());
      expect((parseMeshTrack(formatMtRequest('Sam')) as MtRequest).name, 'Sam');
    });
  });

  test('fuzz: 10k random strings never throw and never consume non-MT text', () {
    final rnd = math.Random(20261116);
    const alphabet = 'MTmt1 2@?!x+0123456789CFGHJMPQRVWXcfghsSabcz-\té\u{1F600}:#';
    final seeds = ['MT1 @$code s34 c270', 'MT1 ?', 'MT1 ! $code', 'MT1 x', 'hello', 'KE4BFI: MT1 @$code'];
    var consumed = 0;
    for (var i = 0; i < 10000; i++) {
      String s;
      if (i.isEven) {
        final len = rnd.nextInt(60);
        s = String.fromCharCodes(List.generate(len, (_) => alphabet.runes.elementAt(rnd.nextInt(alphabet.runes.length))));
      } else {
        // Mutate a real message: flip, drop or insert characters.
        final chars = seeds[rnd.nextInt(seeds.length)].split('');
        for (var k = rnd.nextInt(4); k >= 0; k--) {
          final at = chars.isEmpty ? 0 : rnd.nextInt(chars.length);
          switch (rnd.nextInt(3)) {
            case 0:
              if (chars.isNotEmpty) chars.removeAt(at);
            case 1:
              chars.insert(at, alphabet[rnd.nextInt(alphabet.length)]);
            default:
              if (chars.isNotEmpty) chars[at] = alphabet[rnd.nextInt(alphabet.length)];
          }
        }
        s = chars.join();
      }
      final MtMessage? m;
      try {
        m = parseMeshTrack(s);
      } catch (e) {
        fail('threw on ${jsonEncode(s)}: $e');
      }
      if (m != null) {
        consumed++;
        final head = s.trim().replaceAll(RegExp(r'[ \t]+'), ' ');
        expect(head.toUpperCase().startsWith('MT1 '), isTrue, reason: jsonEncode(s));
      }
    }
    expect(consumed, greaterThan(0)); // the mutations do produce valid messages too
  });

  test('mtReadable: plain words for every MeshTrack message, null for chat', () {
    expect(mtReadable('MT1 @86GV429W+H34 s40 c46'), 'MeshTrack: shared a position');
    expect(mtReadable('MT1 @86GV429W+H34 s0'), 'MeshTrack: parked here');
    expect(mtReadable('MT1 ?'), 'MeshTrack: asked where everyone is');
    expect(mtReadable('MT1 ? Sam'), 'MeshTrack: asked where Sam is');
    expect(mtReadable('MT1 !86GV429W+H34 Gas station'), 'MeshTrack: meet-up point "Gas station"');
    expect(mtReadable('MT1 !86GV429W+H34'), 'MeshTrack: set a meet-up point');
    expect(mtReadable('MT1 !x'), 'MeshTrack: cleared the meet-up point');
    expect(mtReadable('MT1 x'), 'MeshTrack: stopped sharing');
    expect(mtReadable('see you at 8'), isNull);
    expect(mtReadable('MT1 hello'), isNull);
  });
}
