// Contrast of the semantic tokens, both modes (WCAG 2.x). Text pairs need 4.5:1, graphic pairs 3:1.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/ui/design/map_tokens.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../support/colour_science.dart';

void main() {
  for (final b in Brightness.values) {
    for (final pal in ColourPalette.values) {
      group('${b.name} / ${pal.id}', () {
        final c = AppColors.fromTheme(meshSonarTheme(b, palette: pal));
        void text(String name, Color fg, Color bg, [double need = 4.5]) =>
            test('$name >= $need', () => expect(contrastRatio(fg, bg), greaterThanOrEqualTo(need), reason: '${contrastRatio(fg, bg)}'));
        text('bubbleOutText on bubbleOut', c.bubbleOutText, c.bubbleOut);
        text('textPrimary on bg', c.textPrimary, c.bg);
        text('textPrimary on surface', c.textPrimary, c.surface);
        text('textPrimary on surfaceHigh', c.textPrimary, c.surfaceHigh);
        text('textMuted on bg', c.textMuted, c.bg);
        text('textMuted on surface', c.textMuted, c.surface);
        text('textMuted on surfaceHigh', c.textMuted, c.surfaceHigh);
        text('accent (links) on surface', c.accent, c.surface);
        text('onAccent on accent', c.onAccent, c.accent);
        text('danger on surface', c.danger, c.surface);
        text('danger on bg', c.danger, c.bg);
        text('warning on surface', c.warning, c.surface);
        text('warning on surfaceHigh', c.warning, c.surfaceHigh);
        text('outline vs bg (graphic)', c.outline, c.bg, 3);
        text('beacon vs surface (graphic)', c.beacon, c.surface, 3);
        text('ok vs surface (graphic)', c.ok, c.surface, 3);
      });
    }
  }

  group('map tokens (Drive plan 6.3 table)', () {
    // Light: fills vs the OSM land colour, glyph on fill. Dark: fills vs the dark chart colour, glyph on fill.
    test('light fills hold 3:1 against land and the white glyph holds 3:1 on each fill', () {
      const b = Brightness.light;
      for (final fill in [MapTokens.repeaterFresh(b), MapTokens.repeaterAging(b), MapTokens.repeaterStale(b)]) {
        expect(contrastRatio(fill, MapTokens.landLight), greaterThanOrEqualTo(3.0));
        expect(contrastRatio(MapTokens.repeaterGlyph(b), fill), greaterThanOrEqualTo(3.0));
      }
    });
    test('dark fills hold 3:1 against the chart colour and the dark glyph holds 3:1 on each fill', () {
      const b = Brightness.dark;
      for (final fill in [MapTokens.repeaterFresh(b), MapTokens.repeaterAging(b), MapTokens.repeaterStale(b)]) {
        expect(contrastRatio(fill, MapTokens.chartDark), greaterThanOrEqualTo(3.0));
        expect(contrastRatio(MapTokens.repeaterGlyph(b), fill), greaterThanOrEqualTo(3.0));
      }
    });
    test('map ink on its halo is legible in both modes', () {
      for (final b in Brightness.values) {
        expect(contrastRatio(MapTokens.mapInk(b), MapTokens.mapHalo(b)), greaterThanOrEqualTo(4.5));
      }
    });
    test('the three freshness states differ in luminance as well as hue (the fill style is the other cue)', () {
      for (final b in Brightness.values) {
        final l = [MapTokens.repeaterFresh(b), MapTokens.repeaterAging(b), MapTokens.repeaterStale(b)].map((c) => c.computeLuminance()).toList();
        expect((l[0] - l[1]).abs() + (l[1] - l[2]).abs() + (l[0] - l[2]).abs(), greaterThan(0.03));
      }
    });
  });
}
