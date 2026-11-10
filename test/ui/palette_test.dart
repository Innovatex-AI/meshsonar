// The two colour palettes (Standard, Colour-blind safe), read from the Map Definition (M2): the theme's strength colours are
// the definition's bands; colour-blind separation measured by simulating
// protanopia / deuteranopia / tritanopia and comparing with CIEDE2000, contrast against the map, link-line style, and
// the setting's persistence. Values are written in docs/FEATURES.md and meshsonar-infra/docs/planning/colour-palettes-2026-10-31.md.
import 'dart:ui';

import 'package:flutter/material.dart' show Brightness, Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/ui/theme.dart';

import '../support/colour_science.dart';

Color hex(String h) => Color(0xFF000000 | int.parse(h, radix: 16));

const darkTiles = Color(0xFF0D1B26), lightTiles = Color(0xFFE9EFF1);

/// What each palette must hold. The hex values themselves are the Map Definition's (M2: no app table); these are the measured
/// properties of the definition's colours, printed as MEASURE lines so a definition change that weakens them is seen.
void main() {
  final def = MapDefinition.bundled;
  for (final b in Brightness.values) {
    final tiles = b == Brightness.dark ? darkTiles : lightTiles;
    for (final p in ColourPalette.values) {
      final mc = MeshSonarColors.forPalette(p, b);
      final sig = def.signal(p.id, dark: b == Brightness.dark);
      final steps = [mc.levelStrong, mc.levelGood, mc.levelFair, mc.levelWeak, mc.silent, mc.heardUnknown];
      final names = ['strong', 'good', 'fair', 'weak', 'no reply', 'heard no SNR'];
      group('${p.id} ${b.name}', () {
        test('the strength colours are the definition bands (one 5-band scale, plan §2.5)', () {
          expect(steps, [for (final i in [5, 4, 3, 1, 0, 6]) Color(sig.bands[i])]);
          expect(mc.snrStops, [for (final i in [1, 2, 3, 4, 5]) Color(sig.bands[i])]);
          expect(mc.linkLine, Color(sig.link.color));
          expect(mc.linkLineCasing, Color(sig.link.casing).withValues(alpha: sig.link.casingOpacity));
          expect(mc.linkLineDashed, sig.link.dash != null);
          expect(mc.palette, p);
          expect(mc.forPing(heard: true, snr: -30), mc.snrStops.first);
          expect(mc.forPing(heard: true, snr: 30), mc.snrStops.last);
          expect(mc.forPing(heard: false), mc.silent);
          expect(mc.forPing(heard: true), mc.heardUnknown);
          expect(mc.levelColor(CoverageLevel.none), mc.silent);
          expect(mc.levelColor(CoverageLevel.unknown), mc.heardUnknown);
        });

        test('every step is told apart by normal vision (dE2000 >= 10)', () {
          for (var i = 0; i < steps.length; i++) {
            for (var j = i + 1; j < steps.length; j++) {
              final d = deltaE(steps[i], steps[j], Vision.normal);
              expect(d, greaterThanOrEqualTo(10), reason: '${names[i]} vs ${names[j]} = $d');
            }
          }
        });

        test('measured: colour-vision separation and contrast on the map (MEASURE lines)', () {
          for (final v in [Vision.protan, Vision.deutan, Vision.tritan]) {
            var worst = double.infinity;
            var where = '';
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
            print('MEASURE ${p.id} ${b.name} ${v.name}: min dE ${worst.toStringAsFixed(1)} ($where)');
            // Colour-blind safe must hold under every simulated deficiency (standard is documented, not guaranteed).
            if (p == ColourPalette.colourBlind) expect(worst, greaterThanOrEqualTo(10), reason: '$where = $worst');
          }
          for (var i = 0; i < 4; i++) {
            // ignore: avoid_print
            print('MEASURE ${p.id} ${b.name} contrast ${names[i]} ${contrastRatio(steps[i], tiles).toStringAsFixed(2)}');
          }
        });

        test('link lines stay distinguishable from the strength colours', () {
          for (final c in steps.take(4)) {
            expect(c, isNot(mc.linkLine));
          }
          if (mc.linkLineDashed) expect(contrastRatio(mc.linkLine, mc.linkLineCasing.withValues(alpha: 1)), greaterThan(8));
        });
      });
    }
  }

  test('theme carries the palette; default is standard', () {
    expect(MeshSonarColors.dark.palette, ColourPalette.standard);
    final t = meshSonarTheme(Brightness.light, palette: ColourPalette.colourBlind);
    expect(t.extension<MeshSonarColors>()!.palette, ColourPalette.colourBlind);
    expect(t.extension<MeshSonarColors>()!.levelStrong, Color(MapDefinition.bundled.signal('colour_blind', dark: false).bands[5]));
    expect(meshSonarTheme(Brightness.dark).extension<MeshSonarColors>()!.levelStrong, Color(MapDefinition.bundled.signal('standard', dark: true).bands[5]));
  });

  test('lerp keeps the stops list valid between palettes of different length', () {
    final a = MeshSonarColors.forPalette(ColourPalette.standard, Brightness.dark);
    final b = MeshSonarColors.forPalette(ColourPalette.colourBlind, Brightness.dark);
    final m = a.lerp(b, 0.5);
    expect(m.snrStops.length, 5);
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
      expect(ColourPalette.values.map((p) => p.id), ['standard', 'colour_blind']);
    });

    test('a settings file that still says high_contrast (retired) loads as colour-blind safe and saves back as colour_blind', () {
      final s = Settings.fromJson(const {'colour_palette': 'high_contrast'});
      expect(s.colourPalette, ColourPalette.colourBlind);
      expect(s.toJson()['colour_palette'], 'colour_blind');
      expect(ColourPalette.parse('high_contrast'), ColourPalette.colourBlind);
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
