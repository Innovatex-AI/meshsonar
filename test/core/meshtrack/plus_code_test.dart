import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/meshtrack/plus_code.dart';

List<List<String>> _csv(String name) => File('test/fixtures/olc/$name')
    .readAsLinesSync()
    .where((l) => l.trim().isNotEmpty && !l.startsWith('#'))
    .map((l) => l.split(','))
    .toList();

void main() {
  group('upstream vectors (google/open-location-code)', () {
    test('encoding.csv: integers and codes', () {
      final rows = _csv('encoding.csv');
      expect(rows.length, greaterThan(300));
      for (final r in rows) {
        final lat = double.parse(r[0]), lon = double.parse(r[1]);
        final latInt = int.parse(r[2]), lonInt = int.parse(r[3]);
        final len = int.parse(r[4]);
        final want = r[5];
        final (li, lo) = PlusCode.locationToIntegers(lat, lon);
        expect(li, latInt, reason: 'lat int ${r.join(',')}');
        expect(lo, lonInt, reason: 'lon int ${r.join(',')}');
        expect(PlusCode.encodeIntegers(latInt, lonInt, len), want, reason: r.join(','));
      }
    });

    test('encoding.csv: encode() from degrees matches every row', () {
      final rows = _csv('encoding.csv');
      var mismatches = 0;
      for (final r in rows) {
        final got = PlusCode.encode(double.parse(r[0]), double.parse(r[1]), codeLength: int.parse(r[4]));
        if (got != r[5]) mismatches++;
      }
      expect(mismatches, 0);
    });

    test('decoding.csv', () {
      final rows = _csv('decoding.csv');
      expect(rows.length, greaterThan(300));
      for (final r in rows) {
        final a = PlusCode.tryDecode(r[0]);
        expect(a, isNotNull, reason: r[0]);
        expect(a!.codeLength, int.parse(r[1]), reason: r[0]);
        expect(a.latLo, closeTo(double.parse(r[2]), 1e-10), reason: r[0]);
        expect(a.lonLo, closeTo(double.parse(r[3]), 1e-10), reason: r[0]);
        expect(a.latHi, closeTo(double.parse(r[4]), 1e-10), reason: r[0]);
        expect(a.lonHi, closeTo(double.parse(r[5]), 1e-10), reason: r[0]);
      }
    });

    test('validityTests.csv', () {
      for (final r in _csv('validityTests.csv')) {
        expect(PlusCode.isValid(r[0]), r[1] == 'true', reason: 'valid ${r[0]}');
        expect(PlusCode.isShort(r[0]), r[2] == 'true', reason: 'short ${r[0]}');
        expect(PlusCode.isFull(r[0]), r[3] == 'true', reason: 'full ${r[0]}');
      }
    });

    test('shortCodeTests.csv', () {
      for (final r in _csv('shortCodeTests.csv')) {
        final full = r[0], lat = double.parse(r[1]), lon = double.parse(r[2]), short = r[3], type = r[4];
        if (type == 'R' || type == 'B') expect(PlusCode.recoverNearest(short, lat, lon), full, reason: 'recover ${r.join(',')}');
        if (type == 'S' || type == 'B') expect(PlusCode.shorten(full, lat, lon), short, reason: 'shorten ${r.join(',')}');
      }
    });
  });

  group('MeshTrack use', () {
    test('spec example: 11 and 8 digits', () {
      final c = PlusCode.encode(39.96121, -82.99881);
      expect(c.length, 12);
      expect(c[8], '+');
      final approx = PlusCode.encode(39.96121, -82.99881, codeLength: kPlusCodeApproxDigits);
      expect(approx, '${c.substring(0, 8)}+');
    });

    test('round trip at 8, 10 and 11 digits stays inside the code area', () {
      final rnd = math.Random(7);
      for (var i = 0; i < 2000; i++) {
        final lat = rnd.nextDouble() * 179.9 - 89.95;
        final lon = rnd.nextDouble() * 359.9 - 179.95;
        for (final len in [8, 10, 11]) {
          final a = PlusCode.tryDecode(PlusCode.encode(lat, lon, codeLength: len))!;
          expect(lat >= a.latLo - 1e-9 && lat <= a.latHi + 1e-9, isTrue);
          expect(lon >= a.lonLo - 1e-9 && lon <= a.lonHi + 1e-9, isTrue);
          expect(a.codeLength, len);
        }
      }
    });

    test('area sizes: 11 digits about 3 m, 8 digits about 275 m', () {
      expect(PlusCode.tryDecode(PlusCode.encode(40, -83))!.heightM, closeTo(2.78, 0.05));
      expect(PlusCode.tryDecode(PlusCode.encode(40, -83, codeLength: 8))!.heightM, closeTo(278, 5));
    });

    test('invalid characters and shapes decode to null, never throw', () {
      for (final bad in ['', '+', '87G8Q2X5', '87G8Q2X5+7', '87G8Q2X5+7FA', '87G8QIX5+7F', '87G8Q2X5++7F', 'hello', 'ZZ000000+', '87G8Q2X5+7F2é']) {
        expect(PlusCode.tryDecode(bad), isNull, reason: bad);
      }
    });

    test('lower case and padding accepted', () {
      expect(PlusCode.tryDecode('87g8q2x5+7f2'), isNotNull);
      final p = PlusCode.tryDecode('87G80000+')!;
      expect(p.codeLength, 4);
      expect(p.heightM, greaterThan(10000));
    });

    test('poles and antimeridian', () {
      final north = PlusCode.tryDecode(PlusCode.encode(90, 0))!;
      expect(north.latHi, lessThanOrEqualTo(90));
      expect(north.lat, lessThanOrEqualTo(90));
      final south = PlusCode.tryDecode(PlusCode.encode(-90, 0))!;
      expect(south.latLo, -90);
      expect(PlusCode.encode(0, 180), PlusCode.encode(0, -180));
      expect(PlusCode.encode(10, 190), PlusCode.encode(10, -170));
      final e = PlusCode.tryDecode(PlusCode.encode(0, 179.99999))!;
      expect(e.lonHi, lessThanOrEqualTo(180));
    });

    test('bad length throws ArgumentError on encode', () {
      expect(() => PlusCode.encode(1, 1, codeLength: 7), throwsArgumentError);
      expect(() => PlusCode.encode(double.nan, 1), throwsArgumentError);
    });
  });
}
