// Small shared helpers for the chart painters: "nice" axis ticks, dashed lines and canvas text.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Round tick values covering [lo]..[hi] (about [count] of them), e.g. (-97, -71) -> [-100, -90, -80, -70].
List<double> niceTicks(double lo, double hi, {int count = 4}) {
  if (!lo.isFinite || !hi.isFinite) return const [];
  if (hi < lo) (lo, hi) = (hi, lo);
  if (hi - lo < 1e-9) return [lo];
  final raw = (hi - lo) / math.max(1, count);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  final step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
  final start = (lo / step).floor();
  final end = (hi / step - 1e-9).ceil();
  final out = <double>[];
  for (var i = start; i <= end; i++) {
    out.add(double.parse((i * step).toStringAsFixed(6)));
  }
  return out;
}

/// Tick label: whole numbers without decimals, otherwise one decimal.
String tickLabel(double v) => v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

void drawDashedH(Canvas canvas, double x0, double x1, double y, Paint p, {double dash = 4, double gap = 4}) {
  for (var x = x0; x < x1; x += dash + gap) {
    canvas.drawLine(Offset(x, y), Offset(math.min(x + dash, x1), y), p);
  }
}

/// Paints [s] with its vertical centre at [at].dy; [align] -1 = left edge at x, 0 = centred, 1 = right edge at x.
void drawChartText(Canvas canvas, String s, Offset at, TextStyle style, {int align = -1}) {
  final tp = TextPainter(text: TextSpan(text: s, style: style), textDirection: TextDirection.ltr, maxLines: 1)..layout();
  final dx = align < 0 ? at.dx : (align == 0 ? at.dx - tp.width / 2 : at.dx - tp.width);
  tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
}
