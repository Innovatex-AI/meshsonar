// Vertical bar chart with a y axis: one bar per label, or a group of bars per label when there are several series
// (e.g. appeared / gone per week). Bars stand on [BarChart.base] (0 by default; -120 dBm for noise, so a taller bar is a
// noisier hour and negative values do not hang from zero). Null values are drawn as no bar (unknown is not zero).
// Optional dashed reference line and a per-bar colour override (e.g. red above the interference line).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_scale.dart';

class BarSeries {
  final String name;
  final List<double?> values; // one per label
  final Color color;
  const BarSeries({required this.name, required this.values, required this.color});
}

class BarChart extends StatelessWidget {
  final List<String> labels;
  final List<BarSeries> series;
  final double base;
  final double? refLine;
  final String? refLabel;

  /// Colour for bar [i] of the first series with value [v]; null keeps the series colour.
  final Color? Function(int i, double v)? colorOf;

  /// Draw every n-th x label (labels can be dense, e.g. 24 hours).
  final int labelEvery;
  final String? yLabel;
  final bool legend;

  const BarChart({
    super.key,
    required this.labels,
    required this.series,
    this.base = 0,
    this.refLine,
    this.refLabel,
    this.colorOf,
    this.labelEvery = 1,
    this.yLabel,
    this.legend = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final label = (t.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(color: t.colorScheme.onSurfaceVariant);
    final painter = BarPainter(chart: this, grid: t.colorScheme.outlineVariant, label: label, ref: t.colorScheme.error);
    if (!legend || series.length < 2) return CustomPaint(size: Size.infinite, painter: painter);
    return Column(children: [
      Expanded(child: CustomPaint(size: Size.infinite, painter: painter)),
      const SizedBox(height: 4),
      Wrap(spacing: 12, children: [
        for (final s in series)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, color: s.color),
            const SizedBox(width: 4),
            Text(s.name, style: label),
          ]),
      ]),
    ]);
  }
}

class BarPainter extends CustomPainter {
  final BarChart chart;
  final Color grid, ref;
  final TextStyle label;
  BarPainter({required this.chart, required this.grid, required this.label, required this.ref});

  @override
  void paint(Canvas canvas, Size size) {
    final c = chart;
    final n = c.labels.length;
    if (n == 0 || c.series.isEmpty) return;
    const left = 34.0, bottom = 18.0, right = 4.0;
    final top = c.yLabel == null ? 8.0 : 18.0;
    final w = size.width - left - right, h = size.height - bottom - top;
    if (w <= 0 || h <= 0) return;
    var hi = c.base;
    for (final s in c.series) {
      for (final v in s.values) {
        if (v != null && v.isFinite) hi = math.max(hi, v);
      }
    }
    if (c.refLine != null) hi = math.max(hi, c.refLine!);
    final ticks = niceTicks(c.base, hi == c.base ? c.base + 1 : hi);
    final lo = c.base;
    final top0 = ticks.isEmpty ? hi : math.max(hi, ticks.last);
    final range = top0 - lo <= 0 ? 1.0 : top0 - lo;
    double y(double v) => top + h * (1 - (v - lo) / range);

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in ticks) {
      if (v < lo || v > top0) continue;
      canvas.drawLine(Offset(left, y(v)), Offset(left + w, y(v)), gp);
      drawChartText(canvas, tickLabel(v), Offset(left - 6, y(v)), label, align: 1);
    }
    if (c.yLabel != null) drawChartText(canvas, c.yLabel!, const Offset(4, 6), label);

    final slot = w / n;
    final k = c.series.length;
    final barW = math.max(1.0, (slot * 0.8) / k);
    for (var i = 0; i < n; i++) {
      for (var si = 0; si < k; si++) {
        final vals = c.series[si].values;
        final v = i < vals.length ? vals[i] : null;
        if (v == null || !v.isFinite) continue;
        final color = (si == 0 ? c.colorOf?.call(i, v) : null) ?? c.series[si].color;
        final x0 = left + i * slot + slot * 0.1 + si * barW;
        final yy = y(math.max(v, lo));
        canvas.drawRRect(
          RRect.fromRectAndCorners(Rect.fromLTRB(x0, yy, x0 + barW - (k > 1 ? 1 : 0), top + h),
              topLeft: const Radius.circular(2), topRight: const Radius.circular(2)),
          Paint()..color = color,
        );
      }
      if (i % math.max(1, c.labelEvery) == 0) {
        drawChartText(canvas, c.labels[i], Offset(left + i * slot + slot / 2, size.height - 8), label, align: 0);
      }
    }
    canvas.drawLine(Offset(left, top + h), Offset(left + w, top + h), gp);
    if (c.refLine != null) {
      final yy = y(c.refLine!);
      drawDashedH(canvas, left, left + w, yy, Paint()
        ..color = ref.withValues(alpha: 0.8)
        ..strokeWidth = 1.2, dash: 6, gap: 4);
      if (c.refLabel != null) drawChartText(canvas, c.refLabel!, Offset(left + w, yy - 8), label.copyWith(color: ref), align: 1);
    }
  }

  @override
  bool shouldRepaint(BarPainter old) => old.chart != chart || old.grid != grid || old.label != label;
}
