import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/meshtrack/interop.dart';
import 'package:meshsonar/core/meshtrack/plus_code.dart';

void main() {
  group('MeshCore-TEAM #TEL:', () {
    // Built byte for byte from TEAM's documented layout [lat i32 BE x1e7][lon i32 BE x1e7][batt][batt][fwd],
    // base64 without padding, as TEAM sends it.
    test('Columbus, unpadded', () {
      final p = parseInterop('#TEL:F9GYxM6HYvyAkAI') as MtInteropPosition;
      expect(p.lat, closeTo(39.96121, 1e-7));
      expect(p.lon, closeTo(-82.99881, 1e-7));
      expect(p.source, MtSource.team);
      expect(p.consume, isTrue);
    });

    test('southern/eastern hemisphere, padded, autonomous battery sentinel', () {
      final p = parseInterop('#TEL:69AIAFogtUgB/wU=') as MtInteropPosition;
      expect(p.lat, closeTo(-33.8688, 1e-7));
      expect(p.lon, closeTo(151.2093, 1e-7));
    });

    test('bad payloads are dropped', () {
      for (final b in ['#TEL:', '#TEL:abc', '#TEL:F9GYxM6HYvyAkAIAAAA', '#TEL:F9GYxM6HYvy*kAI', '#TEL:AAAAAAAAAAAAAAA', '#tel:F9GYxM6HYvyAkAI']) {
        final r = parseInterop(b);
        expect(r is MtInteropPosition, isFalse, reason: b);
      }
    });

    test('#CAP: consumed, no position', () {
      final r = parseInterop('#CAP:something');
      expect(r, isA<MtInteropIgnore>());
      expect(r!.consume, isTrue);
    });
  });

  group('typed', () {
    test('full Plus Code alone or inside text', () {
      final code = PlusCode.encode(39.96121, -82.99881);
      for (final s in [code, 'I am at $code now', '($code).', 'Meet at ${code.toLowerCase()}']) {
        final p = parseInterop(s) as MtInteropPosition;
        expect(p.lat, closeTo(39.96121, 0.0001), reason: s);
        expect(p.source, MtSource.typed);
        expect(p.consume, isFalse);
      }
      final approx = parseInterop(PlusCode.encode(39.96121, -82.99881, codeLength: 8)) as MtInteropPosition;
      expect(approx.accuracyM, greaterThan(100));
    });

    test('short Plus Code recovered near the receiver, ignored without a reference', () {
      final full = PlusCode.encode(39.96121, -82.99881);
      final short = full.substring(4); // e.g. Q2X5+7F2
      final p = parseInterop('$short Columbus, Ohio', refLat: 39.9, refLon: -83.0) as MtInteropPosition;
      expect(p.lat, closeTo(39.96121, 0.0001));
      expect(p.lon, closeTo(-82.99881, 0.0001));
      expect(parseInterop(short), isNull);
    });

    test('lat, lon', () {
      final p = parseInterop(' 39.96121, -82.99881 ') as MtInteropPosition;
      expect(p.lat, 39.96121);
      expect(p.lon, -82.99881);
      expect(p.accuracyM, closeTo(1.1, 0.1));
      expect((parseInterop('(39.961,-82.998)') as MtInteropPosition).accuracyM, closeTo(111, 1));
    });

    test('geo: URIs', () {
      final p = parseInterop('here geo:39.96121,-82.99881;u=35 ok') as MtInteropPosition;
      expect(p.lat, 39.96121);
      expect(p.accuracyM, 35);
      final q = parseInterop('geo:0,0?q=39.5,-82.5(Gate%203)') as MtInteropPosition;
      expect(q.lat, 39.5);
      expect(q.lon, -82.5);
      expect(parseInterop('GEO:39.9,-82.9,250') , isA<MtInteropPosition>());
    });

    test('ordinary chat is not a position', () {
      for (final s in [
        'hello',
        '2+2',
        '22+22 is a lot',
        'C++ rocks',
        'score 3, 4',
        '12, 34',
        '0.0, 0.0',
        'geo:0,0',
        '95.1, 10.2',
        '39.9, 190.5',
        'MT1 hi',
        '',
        'two codes ${PlusCode.encode(40, -83)} ${PlusCode.encode(41, -84)}',
        '87G80000+',
      ]) {
        expect(parseInterop(s), isNull, reason: s);
      }
    });
  });
}
