// The repeater badge and label colours against the plan's table (6.3, 6.4), and the colour-blind check: the three
// freshness states stay apart in greyscale, protanopia and deuteranopia because of their fill style, not only their hue.
// Set WP5_SHOTS=<dir> to also write the contact sheets as PNGs (design review DR5).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/map_tokens.dart';
import 'package:meshsonar/ui/map/layers/clustered_points_layer.dart' show contrastRatio;
import 'package:meshsonar/ui/map/layers/repeater_sprites.dart';

const _fresh = RepeaterFreshness.fresh, _recent = RepeaterFreshness.recent, _stale = RepeaterFreshness.stale;

void main() {
  group('contrast table of plan 6.3 (formula check against the base colours)', () {
    void table(Brightness b, Color base, List<double> fills, List<double> glyphs) {
      for (final (i, f) in RepeaterFreshness.values.indexed) {
        final c = freshnessColor(f, b);
        expect(contrastRatio(c, base), closeTo(fills[i], 0.02), reason: '${b.name} ${f.name} fill vs base');
        expect(contrastRatio(c, base), greaterThanOrEqualTo(3), reason: 'graphic objects need 3:1');
        expect(contrastRatio(MapTokens.repeaterGlyph(b), c), closeTo(glyphs[i], 0.02), reason: '${b.name} ${f.name} glyph on fill');
        expect(contrastRatio(MapTokens.repeaterGlyph(b), c), greaterThanOrEqualTo(3));
      }
    }

    test('light: fills vs land #F2EFE9 and white glyph on the fills', () {
      table(Brightness.light, MapTokens.landLight, [4.52, 4.11, 4.21], [5.19, 4.72, 4.83]);
    });

    test('dark: fills vs #2B2F36 and #12161B glyph on the fills', () {
      table(Brightness.dark, MapTokens.chartDark, [5.82, 6.67, 5.29], [7.87, 9.01, 7.15]);
    });

    test('the exact palette of the plan', () {
      expect([for (final f in RepeaterFreshness.values) freshnessColor(f, Brightness.light).toARGB32()], [0xFF0072B2, 0xFFB35C00, 0xFF6B7280]);
      expect([for (final f in RepeaterFreshness.values) freshnessColor(f, Brightness.dark).toARGB32()], [0xFF56B4E9, 0xFFF0A92E, 0xFF9CA3AF]);
    });

    test('the rejected research orange #E69F00 would fail 3:1 on the light land (why #B35C00)', () {
      expect(contrastRatio(const Color(0xFFE69F00), MapTokens.landLight), lessThan(3));
    });
  });

  group('label ink (plan 6.4)', () {
    test('ink on halo and on the base colours', () {
      expect(contrastRatio(MapTokens.mapInk(Brightness.light), MapTokens.mapHalo(Brightness.light)), closeTo(16.56, 0.02));
      expect(contrastRatio(MapTokens.mapInk(Brightness.light), MapTokens.landLight), closeTo(14.43, 0.02));
      expect(contrastRatio(MapTokens.mapInk(Brightness.dark), MapTokens.mapHalo(Brightness.dark)), closeTo(16.76, 0.02));
      expect(contrastRatio(MapTokens.mapInk(Brightness.dark), MapTokens.chartDark), closeTo(12.41, 0.02));
    });

    test('stale labels (ink at 70%) still read at 4.5:1 or better on the land', () {
      final ink = Color.alphaBlend(MapTokens.mapInk(Brightness.light).withValues(alpha: 0.7), MapTokens.landLight);
      expect(contrastRatio(ink, MapTokens.landLight), greaterThanOrEqualTo(4.5));
      final dark = Color.alphaBlend(MapTokens.mapInk(Brightness.dark).withValues(alpha: 0.7), MapTokens.chartDark);
      expect(contrastRatio(dark, MapTokens.chartDark), greaterThanOrEqualTo(4.5));
    });
  });

  group('colour-blind and greyscale', () {
    const sims = ['normal', 'grey', 'protan', 'deutan'];

    for (final b in Brightness.values) {
      testWidgets('${b.name}: fresh, recent and stale badges stay apart in greyscale, protanopia and deuteranopia', (t) async {
        final theme = RepeaterSpriteTheme(brightness: b, accent: const Color(0xFF008080), ok: const Color(0xFF2E9E5B));
        final bg = b == Brightness.dark ? MapTokens.chartDark : MapTokens.landLight;
        await t.runAsync(() async {
          for (final room in [false, true]) {
            for (final variant in [SpriteVariant.badge, SpriteVariant.badgeLarge, SpriteVariant.heard]) {
              final crops = <RepeaterFreshness, Uint8List>{};
              final w = 48, h = 48;
              for (final f in RepeaterFreshness.values) {
                final rec = ui.PictureRecorder();
                final c = Canvas(rec);
                c.scale(2);
                c.drawRect(const Rect.fromLTWH(0, 0, 24, 24), Paint()..color = bg);
                paintRepeaterSprite(c, const Offset(12, 12), RepeaterSpriteSpec(f, room, variant), theme);
                final img = await rec.endRecording().toImage(w, h);
                crops[f] = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
              }
              for (final sim in sims) {
                final s = {for (final e in crops.entries) e.key: simulate(e.value, sim)};
                for (final (a, c) in [(_fresh, _recent), (_fresh, _stale), (_recent, _stale)]) {
                  final d = meanAbsDiff(s[a]!, s[c]!);
                  expect(d, greaterThan(6), reason: '${b.name} $sim ${room ? 'room' : 'repeater'} ${variant.name}: ${a.name} vs ${c.name} differ by $d');
                }
              }
            }
          }
        });
      });
    }

    testWidgets('the donut (z9-11) keeps the three states apart too (ring colour + dashes + tint)', (t) async {
      for (final b in Brightness.values) {
        final theme = RepeaterSpriteTheme(brightness: b, accent: const Color(0xFF008080), ok: const Color(0xFF2E9E5B));
        final bg = b == Brightness.dark ? MapTokens.chartDark : MapTokens.landLight;
        await t.runAsync(() async {
          final crops = <RepeaterFreshness, Uint8List>{};
          for (final f in RepeaterFreshness.values) {
            final rec = ui.PictureRecorder();
            final c = Canvas(rec)..scale(4);
            c.drawRect(const Rect.fromLTWH(0, 0, 16, 16), Paint()..color = bg);
            paintRepeaterSprite(c, const Offset(8, 8), RepeaterSpriteSpec(f, false, SpriteVariant.donut), theme);
            final img = await rec.endRecording().toImage(64, 64);
            crops[f] = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          }
          for (final sim in sims) {
            final s = {for (final e in crops.entries) e.key: simulate(e.value, sim)};
            expect(meanAbsDiff(s[_fresh]!, s[_stale]!), greaterThan(3), reason: '${b.name} $sim fresh vs stale');
            expect(meanAbsDiff(s[_fresh]!, s[_recent]!), greaterThan(3), reason: '${b.name} $sim fresh vs recent');
            expect(meanAbsDiff(s[_recent]!, s[_stale]!), greaterThan(3), reason: '${b.name} $sim recent vs stale');
          }
        });
      }
    });

    final out = Platform.environment['WP5_SHOTS'];
    testWidgets('contact sheets for the design review', skip: out == null, (t) async {
      await t.runAsync(() async {
        Directory(out!).createSync(recursive: true);
        for (final b in Brightness.values) {
          final theme = RepeaterSpriteTheme(brightness: b, accent: const Color(0xFF008080), ok: const Color(0xFF2E9E5B));
          final bg = b == Brightness.dark ? MapTokens.chartDark : MapTokens.landLight;
          const cell = 44.0, scale = 4.0;
          final cols = SpriteVariant.values.length, rows = 6;
          final w = (cols * cell * scale).toInt(), h = (rows * cell * scale).toInt();
          final rec = ui.PictureRecorder();
          final c = Canvas(rec)..scale(scale);
          c.drawRect(Rect.fromLTWH(0, 0, cols * cell, rows * cell), Paint()..color = bg);
          var r = 0;
          for (final room in [false, true]) {
            for (final f in RepeaterFreshness.values) {
              for (final (i, v) in SpriteVariant.values.indexed) {
                paintRepeaterSprite(c, Offset((i + 0.5) * cell, (r + 0.5) * cell), RepeaterSpriteSpec(f, room, v), theme);
              }
              r++;
            }
          }
          final img = await rec.endRecording().toImage(w, h);
          final raw = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          for (final sim in sims) {
            final px = simulate(raw, sim);
            final done = Completer<ui.Image>();
            ui.decodeImageFromPixels(px, w, h, ui.PixelFormat.rgba8888, done.complete);
            final png = (await (await done.future).toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
            File('$out/sprites-${b.name}-$sim.png').writeAsBytesSync(png);
          }
        }
      });
    });
  });
}

double _lin(int v) {
  final c = v / 255;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

int _enc(double v) {
  final c = v.clamp(0.0, 1.0);
  return ((c <= 0.0031308 ? c * 12.92 : 1.055 * math.pow(c, 1 / 2.4) - 0.055) * 255).round().clamp(0, 255);
}

/// Machado et al. 2009, severity 1.0, applied in linear RGB; 'grey' is Rec. 709 luminance.
Uint8List simulate(Uint8List rgba, String sim) {
  if (sim == 'normal') return rgba;
  final out = Uint8List(rgba.length);
  const protan = [
    [0.152286, 1.052583, -0.204868],
    [0.114503, 0.786281, 0.099216],
    [-0.003882, -0.048116, 1.051998],
  ];
  const deutan = [
    [0.367322, 0.860646, -0.227968],
    [0.280085, 0.672501, 0.047413],
    [-0.011820, 0.042940, 0.968881],
  ];
  for (var i = 0; i < rgba.length; i += 4) {
    final r = _lin(rgba[i]), g = _lin(rgba[i + 1]), b = _lin(rgba[i + 2]);
    double nr, ng, nb;
    if (sim == 'grey') {
      nr = ng = nb = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    } else {
      final m = sim == 'protan' ? protan : deutan;
      nr = m[0][0] * r + m[0][1] * g + m[0][2] * b;
      ng = m[1][0] * r + m[1][1] * g + m[1][2] * b;
      nb = m[2][0] * r + m[2][1] * g + m[2][2] * b;
    }
    out[i] = _enc(nr);
    out[i + 1] = _enc(ng);
    out[i + 2] = _enc(nb);
    out[i + 3] = rgba[i + 3];
  }
  return out;
}

double meanAbsDiff(Uint8List a, Uint8List b) {
  var sum = 0;
  var n = 0;
  for (var i = 0; i < a.length; i += 4) {
    sum += (a[i] - b[i]).abs() + (a[i + 1] - b[i + 1]).abs() + (a[i + 2] - b[i + 2]).abs();
    n += 3;
  }
  return sum / n;
}
