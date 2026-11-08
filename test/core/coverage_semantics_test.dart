// Andy's colour contract, coverage redesign (Nov 8 2026, plan D4-D6, coverage-v2-colours.md):
// - v2 cells are coloured by BAND (mean SNR); No reply (band 0) and Heard-no-direct-signal (band 6) are grey, never a strength
//   colour; No reply carries the red outline; faint (under 3 pings) is drawn at 55%; predicted is hatched and lighter.
// - The old path (a server without coverage v2): mapped with nothing heard is grey, heard without a reading is purple.
// - Ping colours: nothing heard is grey, unknown SNR is never a strength colour.
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
        test('${p.id} ${b.name}: greys are greys, strength bands are coloured and all distinct', () {
          final c = CoverageBandColors.of(p, b);
          for (final g in [c[0], c[6], c.noReplyPoint]) {
            expect(HSLColor.fromColor(g).saturation, lessThan(0.05), reason: 'No reply / heard-no-SNR are never a strength colour');
          }
          final strength = [for (var i = 1; i <= 5; i++) c[i]];
          expect(strength.toSet(), hasLength(5));
          for (final s in strength) {
            expect(HSLColor.fromColor(s).saturation, greaterThan(0.2), reason: '$s');
          }
          expect(HSLColor.fromColor(c.noReplyOutline).hue, anyOf(lessThan(10), greaterThan(350)), reason: 'the No-reply outline is red');
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
      expect(st, hasLength(36));
      final good = st[predictedStyleIndex(4, 0.6)];
      expect(good.fill.a, closeTo(0.21, 0.01));
      expect(good.hatch!.a, closeTo(0.36, 0.01));
      expect(good.hatchWidth, 2);
      final none = st[predictedStyleIndex(0, 0.4)];
      expect(none.fill.a, 0);
      expect(none.hatch!.a, closeTo(0.2, 0.01));
      expect(none.hatchWidth, 1);
      expect(none.dot!.a, 0, reason: 'predicted band 0 is not drawn zoomed out');
      expect(predictedOpacityStep(0.15), 1);
      expect(predictedOpacityStep(0.57), 5);
    });
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
