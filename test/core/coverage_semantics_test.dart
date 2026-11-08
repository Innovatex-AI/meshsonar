// Andy's colour contract, coverage redesign (Nov 8 2026, plan D4-D6, coverage-v2-colours.md):
// - v2 cells are coloured by BAND (mean SNR); No reply (band 0) and Heard-no-direct-signal (band 6) are grey, never a strength
//   colour (No reply is a red: dark red in standard, Andy Nov 8; band 6 grey); No reply carries the red outline; faint (under 3 pings) is drawn at 55%; predicted is hatched and lighter.
// - The old path (a server without coverage v2): mapped with nothing heard is grey, heard without a reading is purple.
// - Ping colours: nothing heard is grey, unknown SNR is never a strength colour.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/theme.dart';

CoverageCell cell({int pings = 10, int heard = 0, double? best}) => CoverageCell(
  lat: 40,
  lon: -83,
  pings: pings,
  heard: heard,
  bestSnr: best,
  medianSnr: best,
  repeaters: heard > 0 && best != null ? 1 : 0,
  lastAt: '2026-10-31T10:00:00Z',
);

void main() {
  group('coverage v2 bands', () {
    for (final p in ColourPalette.values) {
      for (final b in Brightness.values) {
        test('${p.id} ${b.name}: band 6 is grey, No reply is a red, strength bands are coloured and all distinct', () {
          final c = CoverageBandColors.of(p, b);
          expect(HSLColor.fromColor(c[6]).saturation, lessThan(0.05), reason: 'heard-no-SNR is never a strength colour');
          // Andy, Nov 8 2026: none / bad is red. No reply is a red in every palette (dark red in standard).
          expect(HSLColor.fromColor(c[0]).hue, anyOf(lessThan(12), greaterThan(345)), reason: 'No reply is a red: ${c[0]}');
          expect({for (var i = 0; i <= 6; i++) c[i]}, hasLength(7));
          final strength = [for (var i = 1; i <= 5; i++) c[i]];
          expect(strength.toSet(), hasLength(5));
          for (final s in strength) {
            expect(HSLColor.fromColor(s).saturation, greaterThan(0.2), reason: '$s');
          }
          expect(HSLColor.fromColor(c.noReplyOutline).hue, anyOf(lessThan(10), greaterThan(350)), reason: 'the No-reply outline is red');
          if (p == ColourPalette.standard) {
            // red -> yellow -> green, no blue: every band 0-5 has blue as its lowest channel, hue runs 0..150 bad to good.
            for (var i = 0; i <= 5; i++) {
              expect(c[i].b, lessThan(math.max(c[i].r, c[i].g)), reason: 'no blue in the standard ramp: ${c[i]}');
            }
            final hues = [for (var i = 1; i <= 5; i++) HSLColor.fromColor(c[i]).hue];
            for (var i = 1; i < hues.length; i++) {
              expect(hues[i], greaterThan(hues[i - 1] > 300 ? hues[i - 1] - 360 : hues[i - 1]), reason: 'hue rises red -> green: $hues');
            }
            expect(c.noReplyOutline, c[0]);
            expect(c.noReplyPoint, c[0]);
          } else {
            expect(HSLColor.fromColor(c.noReplyPoint).saturation, lessThan(0.05), reason: 'accessible palettes keep the grey No-reply point');
          }
        });
      }
    }

    test('measured styles: bands 0.85 / faint 0.55, No reply quiet grey under a red outline, dots 0.9', () {
      final c = CoverageBandColors.of(ColourPalette.standard, Brightness.dark);
      final st = measuredStyles(c);
      expect(st, hasLength(14));
      expect(st[measuredStyleIndex(5, false)].fill, c[5].withValues(alpha: 0.85));
      expect(st[measuredStyleIndex(5, true)].fill, c[5].withValues(alpha: 0.55));
      expect(st[measuredStyleIndex(5, false)].dot, c[5].withValues(alpha: 0.9));
      final none = st[measuredStyleIndex(0, false)];
      expect(none.fill, c[0].withValues(alpha: 0.6));
      expect(none.border, c.noReplyOutline.withValues(alpha: 0.9));
      expect(none.borderWidth, 1);
      expect(none.dot, c.noReplyPoint.withValues(alpha: 0.6));
      expect(st[measuredStyleIndex(0, true)].fill, c[0].withValues(alpha: 0.35));
    });

    test('predicted styles: fill o x 0.35 with a 2 px hatch at o x 0.6; band 0 is a 1 px grey hatch only and no dot', () {
      final c = CoverageBandColors.of(ColourPalette.standard, Brightness.light);
      final st = predictedStyles(c);
      expect(st, hasLength(60));
      final good = st[predictedStyleIndex(4, 0.6)];
      expect(good.fill.a, closeTo(0.6 * 0.35, 0.01));
      expect(good.hatch!.a, closeTo(0.6 * 0.6, 0.01));
      expect(good.hatchWidth, 2);
      final none = st[predictedStyleIndex(0, 0.4)];
      expect(none.fill.a, 0);
      expect(none.hatch!.a, closeTo(0.4 * 0.5, 0.01));
      expect(none.hatchWidth, 1);
      expect(none.dot!.a, 0, reason: 'predicted band 0 is not drawn zoomed out');
      expect(predictedOpacityOfStep(predictedOpacityStep(0.15)), closeTo(0.15, 1e-9), reason: 'the faintest cells are not rounded up');
      expect(predictedOpacityOfStep(predictedOpacityStep(0.57)), closeTo(0.55, 1e-9));
      expect(predictedOpacityOfStep(predictedOpacityStep(0.6)), closeTo(0.6, 1e-9));
      for (var o = 0.15; o <= 0.6; o += 0.01) {
        expect((predictedOpacityOfStep(predictedOpacityStep(o)) - o).abs(), lessThanOrEqualTo(0.0251), reason: '$o');
      }
    });
  });

  test('DARK predicted is quieter (doc be25f1e): fill o x 0.2, hatch o x 0.4, band-0 hatch o x 0.3; light unchanged', () {
    for (final p in ColourPalette.values) {
      final d = predictedStyles(CoverageBandColors.of(p, Brightness.dark));
      expect(d[predictedStyleIndex(3, 0.5)].fill.a, closeTo(0.5 * 0.2, 0.005), reason: p.id);
      expect(d[predictedStyleIndex(3, 0.5)].hatch!.a, closeTo(0.5 * 0.4, 0.005), reason: p.id);
      expect(d[predictedStyleIndex(0, 0.5)].hatch!.a, closeTo(0.5 * 0.3, 0.005), reason: p.id);
      final l = predictedStyles(CoverageBandColors.of(p, Brightness.light));
      expect(l[predictedStyleIndex(3, 0.5)].fill.a, closeTo(0.5 * 0.35, 0.005), reason: p.id);
      expect(l[predictedStyleIndex(3, 0.5)].hatch!.a, closeTo(0.5 * 0.6, 0.005), reason: p.id);
      expect(l[predictedStyleIndex(0, 0.5)].hatch!.a, closeTo(0.5 * 0.5, 0.005), reason: p.id);
      // Measured is the same in both themes' multipliers.
      expect(measuredStyles(CoverageBandColors.of(p, Brightness.dark))[measuredStyleIndex(4, false)].fill.a, closeTo(0.85, 0.005));
    }
  });

  group('old path (no coverageV2): best-SNR steps', () {
    test('mapped, nothing heard is grey (none)', () {
      expect(levelFor(cell(heard: 0)), CoverageLevel.none);
      expect(levelFor(cell(heard: 0, best: 9)), CoverageLevel.none);
    });
    test('heard with no SNR reading is "unknown", never a strength colour', () {
      expect(levelFor(cell(heard: 4, best: null)), CoverageLevel.unknown);
    });
    test('measured SNR buckets as before', () {
      expect(levelFor(cell(heard: 3, best: 6)), CoverageLevel.strong);
      expect(levelFor(cell(heard: 3, best: 1)), CoverageLevel.good);
      expect(levelFor(cell(heard: 3, best: -3)), CoverageLevel.fair);
      expect(levelFor(cell(heard: 3, best: -9)), CoverageLevel.weak);
    });
  });

  for (final b in Brightness.values) {
    test('ping colours (${b.name}): nothing heard is grey, unknown SNR is not a green/teal strength colour', () {
      final mc = b == Brightness.dark ? MeshSonarColors.dark : MeshSonarColors.light;
      final grey = mc.forPing(heard: false);
      final hsl = HSLColor.fromColor(grey);
      expect(hsl.saturation, lessThan(0.2), reason: 'grey');
      final unknown = mc.forPing(heard: true);
      expect(unknown, mc.heardUnknown);
      expect(unknown, isNot(mc.snrMid));
      expect(unknown, isNot(mc.snrStrong));
      expect(mc.forPing(heard: true, snr: 9), isNot(grey));
    });
  }
}
