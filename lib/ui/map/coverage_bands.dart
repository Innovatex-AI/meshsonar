// Coverage v2 colours and drawing styles, read from the Map Definition (plan unified-map-system §2.2, phase M2): the band
// colours per palette and theme (`palettes[].themes[theme].bands`, No-reply outline / point), the absolute opacities
// (`drawing`) and the predicted multipliers (`palettes[].predicted[theme]`). No colour is copied into the app: a change on the
// server reaches every map. Band meaning and labels come from the definition's `bands` / `/api/coverage/meta`.
import 'package:flutter/widgets.dart';

import '../../core/colour_palette.dart';
import '../../core/coverage_v2.dart' show CoverageBand;
import '../../core/map_definition.dart';
import 'active_map_definition.dart';
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

  /// The definition and palette these colours came from (opacities and multipliers are read from the same place).
  final MapDefinition definition;
  final String paletteId;
  const CoverageBandColors(this.band, this.noReplyOutline, this.noReplyPoint, {this.dark = false, required this.definition, required this.paletteId});

  Color operator [](int b) => band[b.clamp(0, band.length - 1)];

  static final Map<(String, String, bool), CoverageBandColors> _cache = {};

  /// The colours of [palette] on [brightness], from [definition] (default: the active one).
  static CoverageBandColors of(ColourPalette palette, Brightness brightness, {MapDefinition? definition}) {
    final d = definition ?? ActiveMapDefinition.current;
    final dark = brightness == Brightness.dark;
    return _cache.putIfAbsent((d.version, palette.id, dark), () {
      if (_cache.length > 16) _cache.clear();
      final s = d.signal(palette.id, dark: dark);
      return CoverageBandColors(
        [for (final b in s.bands) Color(b)],
        Color(s.noReplyOutline),
        Color(s.noReplyPoint),
        dark: dark,
        definition: d,
        paletteId: palette.id,
      );
    });
  }

  @override
  bool operator ==(Object other) =>
      other is CoverageBandColors && other.definition.version == definition.version && other.paletteId == paletteId && other.dark == dark;
  @override
  int get hashCode => Object.hash(definition.version, paletteId, dark);
}

/// Measured cells: style index = band * 2 + (faint ? 1 : 0); 14 styles. Faint = under `meta.faintBelow` (3) attempts.
int measuredStyleIndex(int band, bool faint) => band.clamp(0, 6) * 2 + (faint ? 1 : 0);

/// The measured (and "This drive") styles, colours doc "Measured": bands at 0.85 (faint 0.55); No reply a quiet dark-red fill
/// 0.6 / 0.35 under a 1 px red outline 0.9 / 0.55; dots at 0.9 (faint 0.55), No-reply dots in the point grey at 0.6.
List<CellStyle> measuredStyles(CoverageBandColors c) {
  final d = c.definition;
  double v(String k, double f) => d.drawingValue(k, f);
  return [
    for (var b = 0; b <= 6; b++)
      for (final faint in [false, true])
        b == CoverageBand.noReply
            ? CellStyle(
                c[0].withValues(alpha: faint ? v('noReplyFillFaint', 0.35) : v('noReplyFill', 0.6)),
                c.noReplyOutline.withValues(alpha: faint ? v('noReplyLineFaint', 0.55) : v('noReplyLine', 0.9)),
                1,
                null,
                c.noReplyPoint.withValues(alpha: v('noReplyPoint', 0.6)),
              )
            : CellStyle(
                c[b].withValues(alpha: faint ? v('faint', 0.55) : v('measured', 0.85)),
                const Color(0x00000000),
                0,
                null,
                c[b].withValues(alpha: faint ? v('pointFaint', 0.55) : v('point', 0.9)),
              ),
  ];
}

/// The Heard-by-phones styles (meshsonar-infra coverage-v2-colours.md "Heard", same values as the website's HEARD_STYLE):
/// never a fill; hexagons are an outline 1.6 px in the band colour at 0.9; zoomed out a hollow ring (radius 2.2, stroke 1.2,
/// 0.85). Index = band 0..6.
List<CellStyle> heardStyles(CoverageBandColors c) {
  final d = c.definition;
  return [
    for (var b = 0; b <= 6; b++)
      CellStyle(
        const Color(0x00000000),
        c[b].withValues(alpha: d.heardValue('lineOpacity', 0.9)),
        d.heardValue('lineWidth', 1.6),
        null,
        c[b].withValues(alpha: d.heardValue('ringOpacity', 0.85)),
        2,
        d.heardValue('ringWidth', 1.2),
      ),
  ];
}

/// Heard ring dots: radius 2.2 px.
const double kHeardDotPx = 4.4;

/// The predicted multipliers on `o` (coverage-v2-colours.md "Predicted"): light fill 0.35 / hatch 0.6 / band-0 hatch 0.5; the
/// DARK theme is quieter (coordinator decision with Andy's authority, Nov 8, both platforms, doc be25f1e): fill 0.2 / hatch 0.4 /
/// band-0 hatch 0.3, because the bright dark ramp buried the streets in the field shots.
class PredictedOpacity {
  final double fill, hatch, noneHatch;
  const PredictedOpacity(this.fill, this.hatch, this.noneHatch);
  /// From the definition (`palettes[].predicted[theme]`).
  static PredictedOpacity of(CoverageBandColors c) {
    final m = c.definition.predicted(c.paletteId, dark: c.dark);
    return PredictedOpacity(m.fill, m.hatch, m.none);
  }
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
