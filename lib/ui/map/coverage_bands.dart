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
  const CoverageBandColors(this.band, this.noReplyOutline, this.noReplyPoint);

  Color operator [](int b) => band[b.clamp(0, 6)];

  static CoverageBandColors of(ColourPalette palette, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return switch (palette) {
      ColourPalette.standard => dark ? _standardDark : _standardLight,
      ColourPalette.colourBlind => dark ? _cbDark : _cbLight,
      ColourPalette.highContrast => dark ? _hcDark : _hcLight,
    };
  }
}

const _outlineDark = Color(0xFFFF4D4D), _outlineLight = Color(0xFFC4161C);
const _pointDark = Color(0xFF7A7A7A), _pointLight = Color(0xFF6A6A6A);

//                                     0 fill            1 Edge            2 Weak            3 Fair            4 Good            5 Excellent       6 heard, no SNR
const _standardDark = CoverageBandColors([Color(0xFF333333), Color(0xFFD243AD), Color(0xFFF86F3C), Color(0xFFF0D441), Color(0xFF60AAF3), Color(0xFF55E982), Color(0xFF6E6E6E)], _outlineDark, _pointDark);
const _standardLight = CoverageBandColors([Color(0xFF303030), Color(0xFFC82B8D), Color(0xFF9A3404), Color(0xFFAC8211), Color(0xFF1F6FC4), Color(0xFF05893E), Color(0xFF707070)], _outlineLight, _pointLight);
const _cbDark = CoverageBandColors([Color(0xFF333333), Color(0xFFE14C33), Color(0xFFF4993C), Color(0xFFF7E555), Color(0xFF86DBFD), Color(0xFF438AF1), Color(0xFF6E6E6E)], _outlineDark, _pointDark);
const _cbLight = CoverageBandColors([Color(0xFF5E5E5E), Color(0xFF592B21), Color(0xFFB63202), Color(0xFF9D8904), Color(0xFF3887B8), Color(0xFF2A3EAD), Color(0xFFA0A0A0)], _outlineLight, _pointLight);
const _hcDark = CoverageBandColors([Color(0xFF333333), Color(0xFFFF828D), Color(0xFFFDD3AC), Color(0xFFFAFF04), Color(0xFF53F8F8), Color(0xFF95B2F7), Color(0xFF6E6E6E)], _outlineDark, _pointDark);
const _hcLight = CoverageBandColors([Color(0xFF8C8C8C), Color(0xFF481A1E), Color(0xFF8E2A01), Color(0xFF776E04), Color(0xFF296288), Color(0xFF1E1E86), Color(0xFFBCBCBC)], _outlineLight, _pointLight);

/// Measured cells: style index = band * 2 + (faint ? 1 : 0); 14 styles. Faint = under `meta.faintBelow` (3) attempts.
int measuredStyleIndex(int band, bool faint) => band.clamp(0, 6) * 2 + (faint ? 1 : 0);

/// The measured (and "This drive") styles, colours doc "Measured": bands at 0.85 (faint 0.55); No reply a quiet grey fill
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

/// Predicted opacity `o` (0.15-0.6) in six steps, so cells share styles: 0.1, 0.2, ... 0.6.
int predictedOpacityStep(double o) => ((o * 10).round() - 1).clamp(0, 5);
double predictedOpacityOfStep(int step) => (step + 1) / 10;

/// Predicted cells: style index = band * 6 + opacity step; 36 styles.
int predictedStyleIndex(int band, double o) => band.clamp(0, 5) * 6 + predictedOpacityStep(o);

/// The predicted styles, colours doc "Predicted" (revised Nov 8 so Predicted stays quieter than Measured): fill at o x 0.35
/// with a 2 px hatch at o x 0.6; band 0 is a 1 px point-grey hatch at
/// o x 0.5 and no fill, and is not drawn as a dot. Dots (zoomed out) are 2 px in the band colour at o.
List<CellStyle> predictedStyles(CoverageBandColors c) => [
  for (var b = 0; b <= 5; b++)
    for (var step = 0; step < 6; step++)
      () {
        final o = predictedOpacityOfStep(step);
        const none = Color(0x00000000);
        if (b == 0) return CellStyle(none, none, 0, c.noReplyPoint.withValues(alpha: o * 0.5), none, 1);
        return CellStyle(c[b].withValues(alpha: o * 0.35), none, 0, c[b].withValues(alpha: o * 0.6), c[b].withValues(alpha: o), 2);
      }(),
];
