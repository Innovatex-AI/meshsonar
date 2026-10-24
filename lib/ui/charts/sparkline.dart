// Sparkline: a small axis-less line of evenly spaced values. One painter for the app's former copies
// (repeater_detail_screen.dart's SparklinePainter, repeater_detail_sheet.dart's _SparkPainter and overview_panel.dart's
// filled SparklinePainter), with their exact drawing kept as presets: [SparkStyle.plain], [SparkStyle.snr] and
// [SparkStyle.counts] (+ fill and baseline colours). Unknown values (null) are gaps, never zero.
// The widget always carries a [summary] with the numbers as its semantics label.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_scale.dart';

enum SparkDots { none, isolated, all }

class SparkStyle {
  final double strokeWidth;

  /// Vertical padding in px at the top and bottom of the scale.
  final double inset;

  /// The scale always includes this range (e.g. -5..+5 dB), whatever the data.
  final double? includeLo, includeHi;

  /// A dashed reference line at this value (e.g. 0 dB).
  final double? ref;
  final SparkDots dots;
  final double dotRadius;

  /// A single value is drawn in the middle (true) or at the left edge (false).
  final bool centreSingle;

  const SparkStyle({
    this.strokeWidth = 1.6,
    this.inset = 3,
    this.includeLo,
    this.includeHi,
    this.ref,
    this.dots = SparkDots.isolated,
    this.dotRadius = 1.5,
    this.centreSingle = false,
  });

  /// Min..max of the data, 3 px inset, 1.6 px line, a dot on points with no neighbour.
  static const plain = SparkStyle();

  /// SNR: the scale always spans -5..+5 dB, dashed 0 dB line, 2 px line, every point a 3 px dot.
  static const snr = SparkStyle(
      strokeWidth: 2, inset: 0, includeLo: -5, includeHi: 5, ref: 0, dots: SparkDots.all, dotRadius: 3, centreSingle: true);

  /// Counts (the region overview's packets per hour, formerly overview_panel.dart's SparklinePainter): scale 0..max
  /// (at least 1, so an all-zero day is a flat line on the floor), 3 px inset, 2 px line, no dots. Pair with
  /// [Sparkline.fillColor] and [Sparkline.baseColor] for that chart's filled look.
  static const counts = SparkStyle(strokeWidth: 2, inset: 3, includeLo: 0, includeHi: 1, dots: SparkDots.none);
}

class Sparkline extends StatelessWidget {
  final List<double?> values;
  final Color color;

  /// The numbers in words; the semantics label.
  final String summary;
  final SparkStyle style;

  /// Per-point dot colour (default: [color]).
  final Color Function(double v)? dotColor;

  /// Reference line colour (default: outline at half opacity).
  final Color? refColor;

  /// Fills under each run of the line down to the bottom edge (null = no fill).
  final Color? fillColor;

  /// A 1 px baseline along the bottom edge (null = none).
  final Color? baseColor;
  final double height;

  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    required this.summary,
    this.style = SparkStyle.plain,
    this.dotColor,
    this.refColor,
    this.fillColor,
    this.baseColor,
    this.height = 56,
  });

  @override
  Widget build(BuildContext context) => Semantics(
        container: true,
        image: true,
        label: summary,
        excludeSemantics: true,
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(
            painter: SparklinePainter(
              values: values,
              color: color,
              style: style,
              dotColor: dotColor,
              refColor: refColor ?? Theme.of(context).colorScheme.outline.withValues(alpha: 0.5),
              fillColor: fillColor,
              baseColor: baseColor,
            ),
          ),
        ),
      );
}

class SparklinePainter extends CustomPainter {
  final List<double?> values;
  final Color color;
  final SparkStyle style;
  final Color Function(double v)? dotColor;
  final Color refColor;
  final Color? fillColor, baseColor;
  SparklinePainter(
      {required this.values, required this.color, required this.style, this.dotColor, required this.refColor, this.fillColor, this.baseColor});

  @override
  void paint(Canvas canvas, Size size) {
    if (baseColor != null) {
      canvas.drawLine(Offset(0, size.height - .5), Offset(size.width, size.height - .5), Paint()
        ..color = baseColor!
        ..strokeWidth = 1);
    }
    final known = [for (final v in values) if (v != null && v.isFinite) v];
    if (known.isEmpty) return;
    if (known.length < 2 && values.length < 2 && style.dots == SparkDots.isolated) return;
    var lo = known.reduce(math.min), hi = known.reduce(math.max);
    if (style.includeLo != null) lo = math.min(lo, style.includeLo!);
    if (style.includeHi != null) hi = math.max(hi, style.includeHi!);
    final span = hi - lo == 0 ? 1.0 : hi - lo;
    final n = values.length;
    double x(int i) => n == 1 ? (style.centreSingle ? size.width / 2 : 0.0) : size.width * i / (n - 1);
    double y(double v) => size.height - style.inset - (size.height - 2 * style.inset) * ((v - lo) / span);

    if (style.ref != null && style.ref! >= lo && style.ref! <= hi) {
      drawDashedH(canvas, 0, size.width, y(style.ref!), Paint()
        ..color = refColor
        ..strokeWidth = 1);
    }

    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = style.strokeWidth
      ..strokeJoin = StrokeJoin.round;
    if (fillColor != null) {
      // One closed area per run of known values, down to the bottom edge.
      final fill = Paint()..color = fillColor!;
      var i = 0;
      while (i < n) {
        if (values[i] == null || !values[i]!.isFinite) {
          i++;
          continue;
        }
        final start = i;
        final area = Path()..moveTo(x(i), y(values[i]!));
        while (i + 1 < n && values[i + 1] != null && values[i + 1]!.isFinite) {
          i++;
          area.lineTo(x(i), y(values[i]!));
        }
        area
          ..lineTo(x(i), size.height)
          ..lineTo(x(start), size.height)
          ..close();
        canvas.drawPath(area, fill);
        i++;
      }
    }

    final path = Path();
    var pen = false;
    for (var i = 0; i < n; i++) {
      final v = values[i];
      if (v == null || !v.isFinite) {
        pen = false;
        continue;
      }
      final o = Offset(x(i), y(v));
      if (pen) {
        path.lineTo(o.dx, o.dy);
      } else {
        path.moveTo(o.dx, o.dy);
        pen = true;
        final next = i + 1 < n ? values[i + 1] : null;
        if (style.dots == SparkDots.isolated && (next == null || !next.isFinite)) {
          canvas.drawCircle(o, style.dotRadius, Paint()..color = color);
        }
      }
    }
    canvas.drawPath(path, line);
    if (style.dots == SparkDots.all) {
      for (var i = 0; i < n; i++) {
        final v = values[i];
        if (v == null || !v.isFinite) continue;
        canvas.drawCircle(Offset(x(i), y(v)), style.dotRadius, Paint()..color = dotColor?.call(v) ?? color);
      }
    }
  }

  @override
  bool shouldRepaint(SparklinePainter old) =>
      old.values != values ||
      old.color != color ||
      old.style != style ||
      old.refColor != refColor ||
      old.fillColor != fillColor ||
      old.baseColor != baseColor;
}

/// "Lowest -3.5, highest 8.0, latest 6.5; 3 of 24 hours have no data" for a sparkline's semantics.
String sparkSummary(List<double?> values, {String unit = '', int decimals = 1, String gapWord = 'points'}) {
  final known = [for (final v in values) if (v != null && v.isFinite) v];
  if (known.isEmpty) return 'No values.';
  String f(double v) => '${v.toStringAsFixed(decimals)}${unit.isEmpty ? '' : ' $unit'}';
  final missing = values.length - known.length;
  final last = values.lastWhere((v) => v != null && v.isFinite, orElse: () => null);
  return 'Lowest ${f(known.reduce(math.min))}, highest ${f(known.reduce(math.max))}, latest ${f(last!)}'
      '${missing > 0 ? '; $missing of ${values.length} $gapWord have no data' : ''}.';
}
