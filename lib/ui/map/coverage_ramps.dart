// Colours for the two coverage modes that are NOT signal strength: ping age and noise against the area's typical level.
//
// Colour contract (docs/FEATURES.md "Colour palettes"): grey = mapped, nothing heard; purple = heard, signal unknown;
// green/blue/amber/red are for measured SNR and the share heard. So these two modes draw in ramps no strength step uses:
//  - age: one indigo hue, newest darkest and fading to pale (a sequential ramp: "how fresh", nothing about quality);
//  - noise against typical: teal (quieter) through sand (typical) to ochre and rust (noisier), a diverging ramp.
// Grey and purple still come from the palette in every mode. Link lines stay orange (#FF6D00) and never appear here.
import 'package:flutter/material.dart';

import '../../core/network_coverage.dart';

/// Newest to oldest: within 24 h, 7 d, 30 d, older.
const List<Color> _ageLight = [Color(0xFF1A237E), Color(0xFF3949AB), Color(0xFF7986CB), Color(0xFFC5CAE9)];
const List<Color> _ageDark = [Color(0xFF9FA8DA), Color(0xFF7986CB), Color(0xFF5C6BC0), Color(0xFF3F4A8F)];

/// Quieter, typical, noisier, much noisier.
const List<Color> _noiseLight = [Color(0xFF00897B), Color(0xFFCDBFA6), Color(0xFFC8963E), Color(0xFF8D4B2F)];
const List<Color> _noiseDark = [Color(0xFF4DB6AC), Color(0xFFD7CCC8), Color(0xFFE0A93F), Color(0xFFC0643C)];

/// The ramp colour of [level] in [mode], or null when [mode] is a strength mode or [level] is grey/purple (those come from the
/// palette).
Color? rampColor(CoverageColorBy mode, CoverageLevel level, Brightness brightness) {
  if (mode.isStrength) return null;
  final i = switch (level) {
    CoverageLevel.strong => 0,
    CoverageLevel.good => 1,
    CoverageLevel.fair => 2,
    CoverageLevel.weak => 3,
    _ => -1,
  };
  if (i < 0) return null;
  final dark = brightness == Brightness.dark;
  return switch (mode) {
    CoverageColorBy.age => (dark ? _ageDark : _ageLight)[i],
    CoverageColorBy.noiseDelta => (dark ? _noiseDark : _noiseLight)[i],
    _ => null,
  };
}
