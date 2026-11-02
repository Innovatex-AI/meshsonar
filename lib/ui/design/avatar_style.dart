// Avatar colours (chat plan 2.3): a pure function of the public key. 24 hues evenly spaced around the wheel after the
// teal (150..195 deg) and amber (30..55 deg) ranges are removed (those two mean "you/accent" and "repeater" in this app).
// Saturation is fixed per mode; lightness is solved per hue so that BOTH the initials on the avatar AND the sender-name
// text on `bg` / `surfaceHigh` meet 4.5:1 (checked for every hue, both modes, by test/ui/design/avatar_style_test.dart).
import 'package:flutter/material.dart';

import 'tokens.dart';

@immutable
class AvatarStyle {
  /// 0..23, stable for a key.
  final int index;

  /// Avatar disc / rounded-square fill.
  final Color fill;

  /// Initials drawn on [fill].
  final Color initials;

  /// Sender name colour (channel messages) on the page background and on cards.
  final Color name;
  const AvatarStyle(this.index, this.fill, this.initials, this.name);
}

const int avatarHueCount = 24;
const double _minContrast = 4.6; // a little above 4.5 so rounding never lands under it

// Usable arcs of the wheel in degrees: [55,150) and [195,390) (= 195..360 and 0..30).
const double _arcA = 150 - 55;
const double _arcB = 390 - 195;

/// Hue in degrees (0..360) for slot [i] of [avatarHueCount].
double avatarHue(int i) {
  final span = _arcA + _arcB;
  final d = (i + 0.5) * span / avatarHueCount;
  if (d < _arcA) return 55 + d;
  return (195 + (d - _arcA)) % 360;
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Stable slot for a key (any string; hex public keys use their first 32 bits).
int avatarIndex(String keyHex) {
  var h = 0x811C9DC5; // FNV-1a over the first 16 characters: stable across runs and platforms
  final s = keyHex.toLowerCase();
  for (var i = 0; i < s.length && i < 16; i++) {
    h = ((h ^ s.codeUnitAt(i)) * 0x01000193) & 0x7FFFFFFF;
  }
  return h % avatarHueCount;
}

AvatarStyle avatarStyle(String publicKeyHex, AppColors c) {
  final i = avatarIndex(publicKeyHex);
  final hue = avatarHue(i);
  if (c.brightness == Brightness.light) {
    // Fill dark enough for white initials; the same colour is the name text on light backgrounds.
    var l = 0.46;
    Color fill = HSLColor.fromAHSL(1, hue, 0.62, l).toColor();
    while (l > 0.1 &&
        (_contrast(Colors.white, fill) < _minContrast ||
            _contrast(fill, c.bg) < _minContrast ||
            _contrast(fill, c.surfaceHigh) < _minContrast)) {
      l -= 0.01;
      fill = HSLColor.fromAHSL(1, hue, 0.62, l).toColor();
    }
    return AvatarStyle(i, fill, Colors.white, fill);
  }
  // Dark: a deep fill for white initials, and a lighter tint of the same hue for the name on dark surfaces.
  var lf = 0.40;
  Color fill = HSLColor.fromAHSL(1, hue, 0.50, lf).toColor();
  while (lf > 0.1 && _contrast(Colors.white, fill) < _minContrast) {
    lf -= 0.01;
    fill = HSLColor.fromAHSL(1, hue, 0.50, lf).toColor();
  }
  var ln = 0.62;
  Color name = HSLColor.fromAHSL(1, hue, 0.72, ln).toColor();
  while (ln < 0.95 && (_contrast(name, c.bg) < _minContrast || _contrast(name, c.surfaceHigh) < _minContrast)) {
    ln += 0.01;
    name = HSLColor.fromAHSL(1, hue, 0.72, ln).toColor();
  }
  return AvatarStyle(i, fill, Colors.white, name);
}
