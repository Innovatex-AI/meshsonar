import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/avatar_style.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../support/colour_science.dart';

void main() {
  test('24 hues, none in the teal (150..195) or amber (30..55) ranges, evenly spaced along the usable arcs', () {
    final hues = [for (var i = 0; i < avatarHueCount; i++) avatarHue(i)];
    expect(hues.toSet().length, 24);
    for (final h in hues) {
      expect(h >= 150 && h < 195, isFalse, reason: 'teal $h');
      expect(h >= 30 && h < 55, isFalse, reason: 'amber $h');
    }
  });

  test('the style is a pure function of the key and spreads keys across hues', () {
    final c = AppColors.fromTheme(meshSonarTheme(Brightness.light));
    expect(avatarStyle('a1b2c3d4', c).fill, avatarStyle('a1b2c3d4', c).fill);
    expect(avatarStyle('A1B2C3D4', c).index, avatarStyle('a1b2c3d4', c).index, reason: 'case-insensitive');
    final seen = {for (var i = 0; i < 400; i++) avatarStyle('${i.toRadixString(16).padLeft(8, '0')}cafe', c).index};
    expect(seen.length, greaterThan(18), reason: 'most of the 24 slots get used');
  });

  for (final b in Brightness.values) {
    test('${b.name}: initials on the avatar and the sender name on bg and surfaceHigh hold 4.5:1 for every hue', () {
      final c = AppColors.fromTheme(meshSonarTheme(b));
      for (var i = 0; i < avatarHueCount; i++) {
        // Find a key mapping to slot i.
        var n = 0;
        while (avatarIndex('$n') != i) {
          n++;
        }
        final s = avatarStyle('$n', c);
        expect(s.index, i);
        expect(contrastRatio(s.initials, s.fill), greaterThanOrEqualTo(4.5), reason: 'initials hue slot $i');
        expect(contrastRatio(s.name, c.bg), greaterThanOrEqualTo(4.5), reason: 'name on bg slot $i');
        expect(contrastRatio(s.name, c.surfaceHigh), greaterThanOrEqualTo(4.5), reason: 'name on surfaceHigh slot $i');
      }
    });
  }
}
