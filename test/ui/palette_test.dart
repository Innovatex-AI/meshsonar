// The three colour palettes: exact hex values (the website copies them), colour-blind separation measured by simulating
// protanopia / deuteranopia / tritanopia and comparing with CIEDE2000, contrast against the map, link-line style, and
// the setting's persistence. Values are written in docs/FEATURES.md and meshsonar-infra/docs/planning/colour-palettes-2026-10-31.md.
import 'dart:ui';

import 'package:flutter/material.dart' show Brightness, Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/ui/theme.dart';

import '../support/colour_science.dart';

Color hex(String h) => Color(0xFF000000 | int.parse(h, radix: 16));

/// strong, good, fair, weak, grey, purple, then the SNR stops.
typedef Spec = ({List<String> steps, List<String> stops, String link, bool dashed});

const dark = <ColourPalette, Spec>{
  ColourPalette.standard: (
    steps: ['79BE69', '6AAEE0', 'E2B04A', 'F07B6B', '8D99A6', 'B59AE0'],
    stops: ['3B8FD6', '3EE0CF', '8CF58A'],
    link: 'FF6D00',
    dashed: false,
  ),
  ColourPalette.colourBlind: (
    steps: ['2B8CE0', '8EDBFF', 'EDDD55', 'D25637', '8D99A6', 'B356A4'],
    stops: ['D25637', 'EDDD55', '8EDBFF', '2B8CE0'],
    link: 'F4F7F9',
    dashed: true,
  ),
  ColourPalette.highContrast: (
    steps: ['86CAFE', 'BDE8F2', 'FEE405', 'FE831A', 'A3AEBA', 'D68BD0'],
    stops: ['FE831A', 'FEE405', 'BDE8F2', '86CAFE'],
    link: 'F4F7F9',
    dashed: true,
  ),
};
const light = <ColourPalette, Spec>{
  ColourPalette.standard: (
    steps: ['2F7A3B', '2A6B9C', 'B07D16', 'B23B2E', '8795A1', '8A63C9'],
    stops: ['2468B8', '00897B', '2E9E3A'],
    link: 'FF6D00',
    dashed: false,
  ),
  ColourPalette.colourBlind: (
    steps: ['0A4FA0', '1E88C8', '9C7F06', '762608', '8795A1', '8E5A8A'],
    stops: ['762608', '9C7F06', '004E66', '0A4FA0'],
    link: '0C1E28',
    dashed: true,
  ),
  ColourPalette.highContrast: (
    steps: ['001365', '0A58C4', '8B640C', '7F2606', '5F6C78', '6E5C91'],
    stops: ['7F2606', '8B640C', '004E66', '001365'],
    link: '0C1E28',
    dashed: true,
  ),
};

const darkTiles = Color(0xFF0D1B26), lightTiles = Color(0xFFE9EFF1);

void main() {
  for (final b in Brightness.values) {
    final table = b == Brightness.dark ? dark : light;
    final tiles = b == Brightness.dark ? darkTiles : lightTiles;
    for (final p in ColourPalette.values) {
      final spec = table[p]!;
      final mc = MeshSonarColors.forPalette(p, b);
      final steps = [mc.levelStrong, mc.levelGood, mc.levelFair, mc.levelWeak, mc.silent, mc.heardUnknown];
      final names = ['strong', 'good', 'fair', 'weak', 'grey', 'purple'];
      group('${p.id} ${b.name}', () {
        test('pins the documented hex values', () {
          expect(steps, [for (final h in spec.steps) hex(h)]);
          expect(mc.snrStops, [for (final h in spec.stops) hex(h)]);
          expect(mc.linkLine, hex(spec.link));
          expect(mc.linkLineDashed, spec.dashed);
          expect(mc.palette, p);
          // forPing's two ends are the first and last stop; grey and purple are never part of the scale.
          expect(mc.forPing(heard: true, snr: -30), mc.snrStops.first);
          expect(mc.forPing(heard: true, snr: 30), mc.snrStops.last);
          expect(mc.forPing(heard: false), mc.silent);
          expect(mc.forPing(heard: true), mc.heardUnknown);
          expect(mc.levelColor(CoverageLevel.none), mc.silent);
          expect(mc.levelColor(CoverageLevel.unknown), mc.heardUnknown);
        });

        test('every step, grey and purple are told apart by normal vision (dE2000 >= 10)', () {
          for (var i = 0; i < steps.length; i++) {
            for (var j = i + 1; j < steps.length; j++) {
              final d = deltaE(steps[i], steps[j], Vision.normal);
              expect(d, greaterThanOrEqualTo(10), reason: '${names[i]} vs ${names[j]} = $d');
            }
          }
        });

        for (final v in [Vision.protan, Vision.deutan, Vision.tritan]) {
          test('separation under ${v.name}', () {
            // standard is documented, not guaranteed; the other two must hold. High contrast trades a little separation
            // for contrast against the map.
            final need = switch (p) { ColourPalette.standard => 0.0, ColourPalette.colourBlind => 10.0, ColourPalette.highContrast => 8.0 };
            var worst = double.infinity;
            String where = '';
            for (var i = 0; i < steps.length; i++) {
              for (var j = i + 1; j < steps.length; j++) {
                final d = deltaE(steps[i], steps[j], v);
                if (d < worst) {
                  worst = d;
                  where = '${names[i]} vs ${names[j]}';
                }
              }
            }
            // ignore: avoid_print
            print('MIN-DE ${p.id} ${b.name} ${v.name}: ${worst.toStringAsFixed(1)} ($where)');
            expect(worst, greaterThanOrEqualTo(need), reason: '$where = $worst');
          });
        }

        test('the ping scale never lands on grey or purple (blended points stay >= 8 dE from both)', () {
          if (p == ColourPalette.standard) return; // the standard scale passes through teal, as it always has
          for (final v in Vision.values) {
            for (var i = 0; i <= 40; i++) {
              final c = mc.snrAt(i / 40);
              expect(deltaE(c, mc.silent, v), greaterThanOrEqualTo(8), reason: '${v.name} t=${i / 40} vs grey');
              expect(deltaE(c, mc.heardUnknown, v), greaterThanOrEqualTo(8), reason: '${v.name} t=${i / 40} vs purple');
            }
          }
        });

        test('contrast against the map tiles', () {
          final need = switch (p) {
            ColourPalette.standard || ColourPalette.colourBlind => 3.0,
            ColourPalette.highContrast => b == Brightness.dark ? 7.0 : 4.5,
          };
          for (final i in [0, 1, 2, 3, 5]) {
            expect(contrastRatio(steps[i], tiles), greaterThanOrEqualTo(need), reason: '${names[i]} ${contrastRatio(steps[i], tiles)}');
          }
          // The standard orange line is the existing look (3 px with a dark casing, 2.4:1 on the light map); the new styles
          // must clear 3:1 on their own.
          if (p != ColourPalette.standard) expect(contrastRatio(mc.linkLine, tiles), greaterThanOrEqualTo(3));
        });

        test('link lines stay distinguishable from the strength colours', () {
          if (!spec.dashed) {
            // standard: orange solid, the same as ever.
            expect(mc.linkLine, hex('FF6D00'));
            return;
          }
          // Achromatic and dashed: no strength colour is a near-grey or white line.
          for (final c in steps.take(4)) {
            expect(c, isNot(mc.linkLine));
          }
          expect(contrastRatio(mc.linkLine, mc.linkLineCasing.withValues(alpha: 1)), greaterThan(8));
        });
      });
    }
  }

  test('theme carries the palette; default is standard', () {
    expect(MeshSonarColors.dark.palette, ColourPalette.standard);
    final t = meshSonarTheme(Brightness.light, palette: ColourPalette.colourBlind);
    expect(t.extension<MeshSonarColors>()!.palette, ColourPalette.colourBlind);
    expect(t.extension<MeshSonarColors>()!.levelStrong, hex('0A4FA0'));
    expect(meshSonarTheme(Brightness.dark).extension<MeshSonarColors>()!.levelStrong, hex('79BE69'));
  });

  test('lerp keeps the stops list valid between palettes of different length', () {
    final a = MeshSonarColors.forPalette(ColourPalette.standard, Brightness.dark);
    final b = MeshSonarColors.forPalette(ColourPalette.colourBlind, Brightness.dark);
    final m = a.lerp(b, 0.5);
    expect(m.snrStops.length, anyOf(3, 4));
    expect(a.lerp(b, 0).levelStrong, a.levelStrong);
    expect(a.lerp(b, 1).levelStrong, b.levelStrong);
  });

  group('setting', () {
    test('defaults to standard and an older settings file reads as standard', () {
      expect(const Settings().colourPalette, ColourPalette.standard);
      expect(Settings.fromJson(const {}).colourPalette, ColourPalette.standard);
      expect(const Settings().toJson().containsKey('colour_palette'), isFalse, reason: 'default settings.json is unchanged');
    });

    test('round-trips and unknown values fall back', () {
      for (final p in ColourPalette.values) {
        final s = const Settings().copyWith(colourPalette: p);
        expect(Settings.fromJson(s.toJson()).colourPalette, p);
      }
      expect(Settings.fromJson(const {'colour_palette': 'rainbow'}).colourPalette, ColourPalette.standard);
      expect(Settings.fromJson(const {'colour_palette': 7}).colourPalette, ColourPalette.standard);
      expect(ColourPalette.values.map((p) => p.id), ['standard', 'colour_blind', 'high_contrast']);
    });
  });

  test('simulation sanity: deuteranopia removes red-green difference, not the lightness one', () {
    // Pure red and pure green differ hugely for normal vision and far less under deuteranopia.
    final n = deltaE(Colors.red, Colors.green, Vision.normal);
    final d = deltaE(Colors.red, Colors.green, Vision.deutan);
    expect(d, lessThan(n));
    expect(deltaE(Colors.white, Colors.white, Vision.deutan), closeTo(0, 1e-9));
    // CIEDE2000 reference pair from Sharma et al. 2005 (pair 1).
    expect(ciede2000([50.0, 2.6772, -79.7751], [50.0, 0.0, -82.7485]), closeTo(2.0425, 1e-3));
  });
}
