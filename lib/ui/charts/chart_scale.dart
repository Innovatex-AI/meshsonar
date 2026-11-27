// Small shared helpers for the chart painters: "nice" axis ticks, dashed lines and canvas text.
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Round tick values covering [lo]..[hi] (about [count] of them), e.g. (-97, -71) -> [-100, -90, -80, -70].
/// [minStep]: the smallest step allowed; dB and dBm axes pass 1 so a narrow range reads -114, -113 rather than
/// -113.3, -113.5 (Round 5 D-15).
List<double> niceTicks(double lo, double hi, {int count = 4, double minStep = 0}) {
  if (!lo.isFinite || !hi.isFinite) return const [];
  if (hi < lo) (lo, hi) = (hi, lo);
  if (hi - lo < 1e-9) return [lo];
  final raw = (hi - lo) / math.max(1, count);
  final mag = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
  final norm = raw / mag;
  var step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10) * mag;
  if (step < minStep) step = minStep;
  final start = (lo / step).floor();
  final end = (hi / step - 1e-9).ceil();
  final out = <double>[];
  for (var i = start; i <= end; i++) {
    out.add(double.parse((i * step).toStringAsFixed(6)));
  }
  return out;
}

/// The step [niceTicks] gives for an axis whose label is [yLabel]: whole numbers for dB and dBm.
double minTickStepFor(String? yLabel) => yLabel != null && yLabel.contains('dB') ? 1 : 0;

/// Tick label: whole numbers without decimals, otherwise as many decimals as the value needs (0.25, not 0.3).
String tickLabel(double v) {
  if (v == v.roundToDouble()) return v.round().toString();
  for (var d = 1; d <= 3; d++) {
    final s = v.toStringAsFixed(d);
    if ((double.parse(s) - v).abs() < 1e-9) return s;
  }
  return v.toStringAsFixed(3);
}

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
