// The link's cost in the 160-byte message: 32 bytes plain, 55 private (docs/planning/photo-e2e-private-2026-11-12.md).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/photo_budget.dart';
import 'package:meshsonar/core/private_photo.dart';

void main() {
  test('link bytes match the real links', () {
    expect(plainPhotoLinkBytes, utf8.encode('https://meshsonar.com/p/k3Xq9TzA').length);
    expect(privatePhotoLinkBytesBudget, utf8.encode('https://meshsonar.com/e/k3Xq9TzA#AAECAwQFBgcICQoLDA0ODw').length);
    expect(privatePhotoLinkBytesBudget, privatePhotoLinkBytes);
    expect(photoLinkBytes(private: false), 32);
    expect(photoLinkBytes(private: true), 55);
  });

  test('text left beside the link: DM 127 plain / 104 private', () {
    expect(textBytesBesidePhoto(160, private: false), 127);
    expect(textBytesBesidePhoto(160, private: true), 104);
  });

  test('thumb settings', () {
    expect(privateThumbEdgePx, 480);
    expect(privateThumbQuality, 70);
  });
}
