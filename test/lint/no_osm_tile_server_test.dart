// Plan unified-map-system §8b row M2: fail if OpenStreetMap's community tile server appears anywhere in the app. The app
// draws our own tiles (api.meshsonar.com/basemap) with OpenFreeMap as the fallback; the community server's usage policy
// forbids app traffic like ours (no bulk download, no prefetch), and one stray URL would put us back on it.
// Scans every text file the app is built from: lib/, assets/, the platform folders, integration_test/, tool/, scripts/ and
// pubspec.yaml. Docs and tests may name the host (history, this test), the app may not.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Built from parts so this file does not trip its own scan if it is ever added to the scanned set.
final _host = ['tile', 'openstreetmap', 'org'].join('.');

const _roots = ['lib', 'assets', 'ios', 'android', 'macos', 'linux', 'windows', 'web', 'integration_test', 'tool', 'scripts', 'test_driver'];
const _skipDirs = {'build', '.dart_tool', 'Pods', '.symlinks', 'ephemeral', '.gradle', 'DerivedData', 'xcuserdata'};
const _binary = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.ttf', '.otf', '.pmtiles', '.mvt', '.pbf', '.bin', '.jar', '.so', '.a', '.dylib', '.icns', '.ico', '.car', '.mp3', '.wav'};

Iterable<File> _files(Directory d) sync* {
  if (!d.existsSync()) return;
  for (final e in d.listSync(followLinks: false)) {
    final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (e is Directory) {
      if (_skipDirs.contains(name)) continue;
      yield* _files(e);
    } else if (e is File) {
      final dot = name.lastIndexOf('.');
      if (dot >= 0 && _binary.contains(name.substring(dot).toLowerCase())) continue;
      yield e;
    }
  }
}

void main() {
  test('OpenStreetMap\'s community tile server is not used anywhere in the app', () {
    final hits = <String>[];
    var scanned = 0;
    final files = [for (final r in _roots) ..._files(Directory(r)), File('pubspec.yaml')];
    for (final f in files) {
      String text;
      try {
        text = f.readAsStringSync();
      } catch (_) {
        continue; // not UTF-8 text
      }
      scanned++;
      if (text.toLowerCase().contains(_host)) hits.add(f.path);
    }
    expect(scanned, greaterThan(200), reason: 'the scan reached the app sources');
    expect(hits, isEmpty, reason: '$_host found in: ${hits.join(', ')}');
  });

  test('the scan would catch it (self-check)', () {
    expect('https://a.$_host/{z}/{x}/{y}.png'.contains(_host), isTrue);
    expect(_host, 'tile.openstreetmap.org');
  });
}
