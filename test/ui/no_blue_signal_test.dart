// Andy, Nov 8 2026 (field report on build 50): the standard palette's signal scale is red -> yellow -> green with NO blue, on every
// path: the coverage v2 bands, the older 4-step network colours (used before site-config arrives, offline, the cell dot and keys) and
// the ping SNR scale. Blue stays only in the two accessible palettes, where it is the colour-blind-safe choice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/network_coverage.dart' show CoverageLevel;
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/theme.dart';

bool isBlue(Color c) {
  final h = HSVColor.fromColor(c);
  return h.saturation > 0.25 && h.hue >= 170 && h.hue <= 265;
}

void main() {
  for (final b in Brightness.values) {
    test('standard palette, $b: no blue in any signal colour', () {
      final mc = MeshSonarColors.forPalette(ColourPalette.standard, b);
      for (final l in [CoverageLevel.strong, CoverageLevel.good, CoverageLevel.fair, CoverageLevel.weak]) {
        expect(isBlue(mc.levelColor(l)), isFalse, reason: 'levelColor($l)');
      }
      for (var t = 0.0; t <= 1.0; t += 0.05) {
        expect(isBlue(mc.snrAt(t)), isFalse, reason: 'snrAt($t)');
      }
      final bands = CoverageBandColors.of(ColourPalette.standard, b);
      for (var i = 0; i <= 5; i++) {
        expect(isBlue(bands[i]), isFalse, reason: 'band $i');
      }
      // the strongest step is green
      final top = HSVColor.fromColor(mc.levelColor(CoverageLevel.strong)).hue;
      expect(top, inInclusiveRange(80, 160));
    });
  }
}
