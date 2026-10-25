// Writes the MapLibre (web) styles for the tiles bucket and the extended manifest.json, from the SAME style code the
// app uses (lib/core/offline_style.dart), so web and app look identical.
//
//   dart run tool/make_web_styles.dart <current manifest.json> <out dir>
//
// Output: <out>/styles/v<N>/light.json, <out>/styles/v<N>/dark.json, <out>/manifest.json (the input manifest plus
// additive top-level fields; pack entries untouched, so the shipped app parser reads it unchanged).
// Glyph PBFs are built separately (see _docs/tiles-upload/README.md: build_pbf_glyphs 1.4.3 on the bundled Barlow TTFs).
import 'dart:convert';
import 'dart:io';

import 'package:meshsonar/core/offline_style.dart';

const base = 'https://tiles.meshsonar.com';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: dart run tool/make_web_styles.dart <manifest.json> <out dir>');
    exit(2);
  }
  final manifest = jsonDecode(await File(args[0]).readAsString()) as Map<String, dynamic>;
  final packs = (manifest['packs'] as List).cast<Map<String, dynamic>>();
  final cmh = packs.firstWhere((p) => p['code'] == 'CMH');
  final out = Directory(args[1]);
  const enc = JsonEncoder.withIndent('  ');
  final styleDir = Directory('${out.path}/styles/v$offlineStyleVersion')..createSync(recursive: true);
  for (final dark in [false, true]) {
    final style = offlineStyle(dark: dark, target: OfflineStyleTarget.web, pmtilesUrl: cmh['url'] as String);
    File('${styleDir.path}/${dark ? 'dark' : 'light'}.json').writeAsStringSync('${enc.convert(style)}\n');
  }
  final extended = <String, dynamic>{
    ...manifest,
    'style_version': offlineStyleVersion,
    'styles': {
      'light': '$base/styles/v$offlineStyleVersion/light.json',
      'dark': '$base/styles/v$offlineStyleVersion/dark.json',
    },
    'glyphs': '$base/fonts/{fontstack}/{range}.pbf',
    'fonts': [webFontRegular, webFontMedium, webFontBold],
  };
  File('${out.path}/manifest.json').writeAsStringSync('${enc.convert(extended)}\n');
  stdout.writeln('styles v$offlineStyleVersion + manifest.json written to ${out.path}');
}
