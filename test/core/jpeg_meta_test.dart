// The metadata guard of photo messages: a camera-like JPEG with EXIF GPS, XMP GPS and a comment
// (test/fixtures/photos/gps_fixture.jpg, built by tool/make_photo_fixture.py; Apple ImageIO reads GPS 39.7589 N 84.1916 W
// from it) comes out with none of them and still a JPEG.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/jpeg_meta.dart';
import 'package:meshsonar/platform/photo_picker.dart' show compressMinFor;

void main() {
  final fixture = File('test/fixtures/photos/gps_fixture.jpg').readAsBytesSync();

  test('the fixture really carries GPS, EXIF, XMP and a comment', () {
    expect(isJpeg(fixture), isTrue);
    expect(jpegHasExif(fixture), isTrue);
    expect(jpegHasGps(fixture), isTrue);
    expect(String.fromCharCodes(fixture), contains('Example St'));
    expect(String.fromCharCodes(fixture), contains('iPhone 17 Pro'));
  });

  test('stripping removes GPS, EXIF, XMP, comment and camera model; the image data is untouched', () {
    final out = stripJpegMetadata(fixture);
    expect(isJpeg(out), isTrue);
    expect(jpegHasExif(out), isFalse);
    expect(jpegHasGps(out), isFalse);
    final text = String.fromCharCodes(out);
    for (final s in ['Exif', 'GPS', 'Example St', 'iPhone 17 Pro', 'Apple', 'xmpmeta', 'Photoshop']) {
      expect(text, isNot(contains(s)), reason: s);
    }
    // Everything from the first DQT (image data) onwards is byte-identical.
    int firstDqt(Uint8List b) {
      for (var i = 0; i + 1 < b.length; i++) {
        if (b[i] == 0xFF && b[i + 1] == 0xDB) return i;
      }
      return -1;
    }

    final a = firstDqt(fixture), b = firstDqt(out);
    expect(a, greaterThan(0));
    expect(out.sublist(b), fixture.sublist(a));
    expect(out.last, 0xD9);
    expect(out.length, lessThan(fixture.length));
  });

  test('stripping twice changes nothing more', () {
    final once = stripJpegMetadata(fixture);
    expect(stripJpegMetadata(once), once);
  });

  test('JFIF and the ICC colour profile are kept', () {
    final icc = [0xFF, 0xE2, 0x00, 0x10, ...'ICC_PROFILE'.codeUnits, 0, 1, 1];
    final mpf = [0xFF, 0xE2, 0x00, 0x08, ...'MPF'.codeUnits, 0, 0, 0];
    final withIcc = Uint8List.fromList([...fixture.sublist(0, 2), ...icc, ...mpf, ...fixture.sublist(2)]);
    final out = stripJpegMetadata(withIcc);
    expect(String.fromCharCodes(out), contains('ICC_PROFILE'));
    expect(String.fromCharCodes(out), isNot(contains('MPF')));
    expect(String.fromCharCodes(out), contains('JFIF'));
  });

  test('a file that is not a JPEG, or is cut short, is left alone', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]);
    expect(stripJpegMetadata(png), png);
    final cut = Uint8List.fromList(fixture.sublist(0, 30));
    expect(stripJpegMetadata(cut), cut);
  });

  test('compressor size: the long edge lands on the cap for both orientations', () {
    // The compressor keeps BOTH edges at or above the min, i.e. the short edge becomes min.
    expect(compressMinFor(4032, 3024, 2048), 1536);
    expect(compressMinFor(3024, 4032, 2048), 1536);
    expect(compressMinFor(4000, 1000, 2048), 512);
    expect(compressMinFor(1200, 900, 2048), 900); // already small: no upscale
  });
}
