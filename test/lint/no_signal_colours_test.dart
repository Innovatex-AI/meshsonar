// Parity rule (unified-map-system-plan-2026-11-08.md §2.2 test 3, contract map-definition-contract.md rule 1), the app's
// twin of the website's src/test/contract/map-definition-parity.test.ts: no app source file may hard-code a signal colour.
// Every coverage band, No-reply and heard-no-SNR colour lives ONLY in the Map Definition (the server copy, or the bundled
// one generated into lib/core/map_definition_bundled.g.dart); maps, legends, swatches and the theme read it from there.
// Also pins that the legacy colour tables removed in M2 stay removed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';

const _allowed = {'lib/core/map_definition_bundled.g.dart'};

/// Basemap styles (street, rail and land colours of the Protomaps / OpenMapTiles styles, generated from the packages the
/// website uses): a basemap grey that happens to equal a band colour is not a signal colour. Checked for the colour-table
/// patterns below, not for single hexes.
const _basemapStyles = {'lib/core/basemap_styles.g.dart', 'lib/core/offline_style.dart'};

List<File> _dart(Directory d) => [
  for (final e in d.listSync(recursive: true, followLinks: false))
    if (e is File && e.path.endsWith('.dart')) e,
];

String _rel(File f) => f.path.replaceAll('\\', '/').replaceFirst(RegExp(r'^\./'), '');

/// Every signal colour of the definition as RRGGBB (upper case): bands 0-6, No-reply outline and point, both palettes, both
/// themes.
Set<String> signalHexes(MapDefinition d) {
  final out = <String>{};
  for (final p in d.paletteDefs) {
    for (final dark in [false, true]) {
      final s = d.signal(p.id, dark: dark);
      for (final c in [...s.bands, s.noReplyOutline, s.noReplyPoint]) {
        out.add((c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase());
      }
    }
  }
  return out;
}

void main() {
  final hexes = signalHexes(MapDefinition.bundled);
  final sources = [for (final f in _dart(Directory('lib'))) (rel: _rel(f), text: f.readAsStringSync())];

  test('the definition lists the signal colours', () {
    expect(hexes.length, greaterThanOrEqualTo(20));
  });

  test('no app source file contains one (Color(0xAARRGGBB) or #RRGGBB)', () {
    final hits = <String>[];
    final re = RegExp(r'(?:0x[0-9A-Fa-f]{2}|#)([0-9A-Fa-f]{6})\b');
    for (final f in sources) {
      if (_allowed.contains(f.rel) || _basemapStyles.contains(f.rel)) continue;
      for (final m in re.allMatches(f.text)) {
        if (hexes.contains(m.group(1)!.toUpperCase())) hits.add('${f.rel}: ${m.group(0)}');
      }
    }
    expect(hits, isEmpty, reason: 'read signal colours from the Map Definition (CoverageBandColors.of / MeshSonarColors), never a literal');
  });

  test('the legacy colour tables are gone for good', () {
    final banned = [
      RegExp(r'const\s+_(standard|cb|colourBlind)(Dark|Light)\s*='), // the hand-copied band / strength tables
      RegExp(r'const\s+_linkOrange\b'),
      RegExp(r'\bhigh_contrast\s*:'),
    ];
    final hits = [
      for (final f in sources)
        if (!_allowed.contains(f.rel))
          for (final re in banned)
            if (re.hasMatch(f.text)) '${f.rel}: ${re.pattern}',
    ];
    expect(hits, isEmpty);
  });
}
