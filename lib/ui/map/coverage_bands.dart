// Coverage v2 colours and drawing styles. The hex values and opacities are copied EXACTLY from meshsonar-infra
// docs/planning/coverage-v2-colours.md (shared with the website, WP4); change both platforms together. Band meaning and labels
// come from /api/coverage/meta (lib/core/coverage_v2.dart); colours are keyed by band number (token coverage-band-N).
import 'package:flutter/widgets.dart';

import '../../core/colour_palette.dart';
import '../../core/coverage_v2.dart' show CoverageBand;
import 'cell_raster_layer.dart' show CellStyle;

/// One palette's band ramp in one brightness.
@immutable
class CoverageBandColors {
  /// Index = band 0-6: 0 = the No-reply FILL, 1-5 = Edge..Excellent, 6 = Heard, no direct signal.
  final List<Color> band;
  final Color noReplyOutline;

  /// Band 0 as a zoomed-out dot, and the predicted "no coverage" hatch.
  final Color noReplyPoint;

  /// The dark-theme ramp (Predicted is drawn quieter there, [PredictedOpacity.of]).
  final bool dark;
  const CoverageBandColors(this.band, this.noReplyOutline, this.noReplyPoint, {this.dark = false});

  Color operator [](int b) => band[b.clamp(0, 6)];

  static CoverageBandColors of(ColourPalette palette, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (palette) {
      ColourPalette.standard => dark ? _standardDark : _standardLight,
      ColourPalette.colourBlind => dark ? _cbDark : _cbLight,
    };
  }
}

// No-reply outline and z<=12 point: standard uses the band-0 dark red itself (the old bright-red outline would read as Edge); the
// two accessible palettes keep the bright-red outline and the grey point (their Edge is red-orange; a red point would merge with it).
const _outlineDark = Color(0xFFFF4D4D), _outlineLight = Color(0xFFC4161C);
const _pointDark = Color(0xFF7A7A7A), _pointLight = Color(0xFF6A6A6A);

// Standard is red -> yellow -> green, bad to good, no blue (Andy, Nov 8 2026, field feedback on build 49: "the blue is misleading").
// Not promised colour-blind safe: colour-blind users pick colour_blind (warm = bad, cool = good, CVD-safe on all pairs).
//                                     0 No reply        1 Edge            2 Weak            3 Fair            4 Good            5 Excellent       6 heard, no SNR
const _standardDark = CoverageBandColors([Color(0xFFA6302F), Color(0xFFF63647), Color(0xFFFB8F41), Color(0xFFFCE738), Color(0xFF8DCE3C), Color(0xFF0AA349), Color(0xFF6E6E6E)], Color(0xFFA6302F), Color(0xFFA6302F), dark: true);
const _standardLight = CoverageBandColors([Color(0xFF68050F), Color(0xFFB80321), Color(0xFFD36C1D), Color(0xFFE9B907), Color(0xFF749119), Color(0xFF18631D), Color(0xFF707070)], Color(0xFF68050F), Color(0xFF68050F));
const _cbDark = CoverageBandColors([Color(0xFF472024), Color(0xFFE14C33), Color(0xFFF4993C), Color(0xFFF7E555), Color(0xFF86DBFD), Color(0xFF438AF1), Color(0xFF6E6E6E)], _outlineDark, _pointDark, dark: true);
const _cbLight = CoverageBandColors([Color(0xFFEA7267), Color(0xFF592B21), Color(0xFFB63202), Color(0xFF9D8904), Color(0xFF3887B8), Color(0xFF2A3EAD), Color(0xFFA0A0A0)], _outlineLight, _pointLight);

/// Measured cells: style index = band * 2 + (faint ? 1 : 0); 14 styles. Faint = under `meta.faintBelow` (3) attempts.
int measuredStyleIndex(int band, bool faint) => band.clamp(0, 6) * 2 + (faint ? 1 : 0);

/// The measured (and "This drive") styles, colours doc "Measured": bands at 0.85 (faint 0.55); No reply a quiet dark-red fill
/// 0.6 / 0.35 under a 1 px red outline 0.9 / 0.55; dots at 0.9 (faint 0.55), No-reply dots in the point grey at 0.6.
List<CellStyle> measuredStyles(CoverageBandColors c) => [
  for (var b = 0; b <= 6; b++)
    for (final faint in [false, true])
      b == CoverageBand.noReply
          ? CellStyle(
              c[0].withValues(alpha: faint ? 0.35 : 0.6),
              c.noReplyOutline.withValues(alpha: faint ? 0.55 : 0.9),
              1,
              null,
              c.noReplyPoint.withValues(alpha: 0.6),
            )
          : CellStyle(c[b].withValues(alpha: faint ? 0.55 : 0.85), const Color(0x00000000), 0, null, c[b].withValues(alpha: faint ? 0.55 : 0.9)),
];

/// The Heard-by-phones styles (meshsonar-infra coverage-v2-colours.md "Heard", same values as the website's HEARD_STYLE):
/// never a fill; hexagons are an outline 1.6 px in the band colour at 0.9; zoomed out a hollow ring (radius 2.2, stroke 1.2,
/// 0.85). Index = band 0..6.
List<CellStyle> heardStyles(CoverageBandColors c) => [
  for (var b = 0; b <= 6; b++)
    CellStyle(const Color(0x00000000), c[b].withValues(alpha: 0.9), 1.6, null, c[b].withValues(alpha: 0.85), 2, 1.2),
];

/// Heard ring dots: radius 2.2 px.
const double kHeardDotPx = 4.4;

/// The predicted multipliers on `o` (coverage-v2-colours.md "Predicted"): light fill 0.35 / hatch 0.6 / band-0 hatch 0.5; the
/// DARK theme is quieter (coordinator decision with Andy's authority, Nov 8, both platforms, doc be25f1e): fill 0.2 / hatch 0.4 /
/// band-0 hatch 0.3, because the bright dark ramp buried the streets in the field shots.
class PredictedOpacity {
  final double fill, hatch, noneHatch;
  const PredictedOpacity(this.fill, this.hatch, this.noneHatch);
  static const PredictedOpacity light = PredictedOpacity(0.35, 0.6, 0.5);
  static const PredictedOpacity dark = PredictedOpacity(0.2, 0.4, 0.3);
  static PredictedOpacity of(CoverageBandColors c) => c.dark ? dark : light;
}

/// Predicted opacity `o` (0.15-0.6, server) in ten 0.05 steps so cells can share styles: 0.15, 0.20, ... 0.60. At most 0.025 off
/// the server's value either way (the website uses `o` as is).
const int kPredictedOpacitySteps = 10;
int predictedOpacityStep(double o) => ((o - 0.15) / 0.05).round().clamp(0, kPredictedOpacitySteps - 1);
double predictedOpacityOfStep(int step) => 0.15 + step * 0.05;

/// Predicted cells: style index = band * 10 + opacity step; 60 styles.
int predictedStyleIndex(int band, double o) => band.clamp(0, 5) * kPredictedOpacitySteps + predictedOpacityStep(o);

/// The predicted styles, colours doc "Predicted" (revised Nov 8 so Predicted stays quieter than Measured): fill at o x
/// [PredictedOpacity.fill] with a 2 px hatch at o x [PredictedOpacity.hatch]; band 0 is a 1 px hatch in the No-reply point colour at
/// o x 0.5 and no fill, and is not drawn as a dot. Dots (zoomed out) are 2 px in the band colour at o.
List<CellStyle> predictedStyles(CoverageBandColors c) => [
  for (var b = 0; b <= 5; b++)
    for (var step = 0; step < kPredictedOpacitySteps; step++)
      () {
        final o = predictedOpacityOfStep(step);
        const none = Color(0x00000000);
        final k = PredictedOpacity.of(c);
        if (b == 0) return CellStyle(none, none, 0, c.noReplyPoint.withValues(alpha: o * k.noneHatch), none, 1);
        return CellStyle(c[b].withValues(alpha: o * k.fill), none, 0, c[b].withValues(alpha: o * k.hatch), c[b].withValues(alpha: o), 2);
      }(),
];
