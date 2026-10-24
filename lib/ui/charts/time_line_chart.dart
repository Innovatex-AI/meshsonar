// Line chart over time with a y axis: one or more series, honest gaps (a series breaks where it has no data for longer
// than [TimeLineChart.breakGap], and the x axis runs to [TimeLineChart.xEnd] so a silent observer's line stops where
// its data stops instead of being stretched), an optional dashed reference line (e.g. -100 dBm interference), optional
// "floor marks" (short ticks on the x axis, e.g. pings that heard nothing), an optional soft fill under the first series
// and per-point dots. Replaces the drive report's _SnrPainter (same drawing, see [TimeLineChart.snrStyle] use there).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_scale.dart';

class ChartSeries {
  final String name;

  /// (time, value), any order; sorted when painted.
  final List<(DateTime, double)> points;
  final Color color;
  const ChartSeries({required this.name, required this.points, required this.color});
}

class TimeLineChart extends StatelessWidget {
  final List<ChartSeries> series;

  /// Axis title drawn top-left ("SNR dB", "dBm").
  final String yLabel;

  /// Y grid lines and their labels. Null = round ticks picked from the data.
  final List<double>? gridValues;

  /// Grid values drawn dashed and thicker (e.g. 0 dB).
  final Set<double> dashedGrid;

  /// The y scale always covers this range.
  final double? includeLo, includeHi;

  /// Prefix positive grid labels with "+" (SNR).
  final bool signedTicks;

  /// Round the data range out to whole numbers before scaling (keeps the drive SNR chart's look).
  final bool roundRange;

  /// Dashed reference line + its label at the right (e.g. -100 dBm).
  final double? refLine;
  final String? refLabel;
  final Color? refColor;

  /// Break a series' line where consecutive points are further apart than this. Null = never break.
  final Duration? breakGap;

  /// X domain; defaults to the earliest and latest point of all series and [floorMarks].
  final DateTime? xStart, xEnd;

  /// Short ticks standing on the x axis at these times, in these colours.
  final List<(DateTime, Color)> floorMarks;

  /// Soft gradient under the first series.
  final bool fill;

  /// Dot on every point of the first series, coloured by value (null = no dots; isolated points always get a small dot).
  final Color Function(double v)? dotColor;
  final double dotRadius;

  final String Function(DateTime t) xFormat;

  /// Text in the middle under the axis ("red ticks = heard nothing").
  final String? footer;

  /// Draw a legend line of series names (multi-series charts).
  final bool legend;

  const TimeLineChart({
    super.key,
    required this.series,
    required this.yLabel,
    required this.xFormat,
    this.gridValues,
    this.dashedGrid = const {},
    this.includeLo,
    this.includeHi,
    this.roundRange = false,
    this.signedTicks = false,
    this.refLine,
    this.refLabel,
    this.refColor,
    this.breakGap,
    this.xStart,
    this.xEnd,
    this.floorMarks = const [],
    this.fill = false,
    this.dotColor,
    this.dotRadius = 3,
    this.footer,
    this.legend = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final label = (t.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(color: t.colorScheme.onSurfaceVariant);
    final painter = TimeLinePainter(
      chart: this,
      grid: t.colorScheme.outlineVariant,
      label: label,
      ref: refColor ?? t.colorScheme.error,
    );
    if (!legend || series.length < 2) return CustomPaint(size: Size.infinite, painter: painter);
    return Column(children: [
      Expanded(child: CustomPaint(size: Size.infinite, painter: painter)),
      const SizedBox(height: 4),
      Wrap(spacing: 12, runSpacing: 2, children: [
        for (final s in series)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 12, height: 3, color: s.color),
            const SizedBox(width: 4),
            Text(s.name, style: label),
          ]),
      ]),
    ]);
  }
}

class TimeLinePainter extends CustomPainter {
  final TimeLineChart chart;
  final Color grid, ref;
  final TextStyle label;
  TimeLinePainter({required this.chart, required this.grid, required this.label, required this.ref});

  @override
  void paint(Canvas canvas, Size size) {
    final c = chart;
    final all = [for (final s in c.series) ...s.points];
    final times = [for (final p in all) p.$1, for (final f in c.floorMarks) f.$1];
    if (times.isEmpty) return;
    const left = 34.0, bottom = 22.0, top = 18.0, right = 4.0;
    final w = size.width - left - right, h = size.height - bottom - top;
    if (w <= 0 || h <= 0) return;

    var lo = c.includeLo ?? double.infinity, hi = c.includeHi ?? -double.infinity;
    for (final p in all) {
      lo = math.min(lo, c.roundRange ? p.$2.floorToDouble() : p.$2);
      hi = math.max(hi, c.roundRange ? p.$2.ceilToDouble() : p.$2);
    }
    if (c.refLine != null) {
      lo = math.min(lo, c.refLine!);
      hi = math.max(hi, c.refLine!);
    }
    if (!lo.isFinite || !hi.isFinite) {
      lo = 0;
      hi = 1;
    }
    final ticks = c.gridValues ?? niceTicks(lo, hi);
    if (c.gridValues == null && ticks.isNotEmpty) {
      lo = math.min(lo, ticks.first);
      hi = math.max(hi, ticks.last);
    }
    if (hi - lo < 1e-9) hi = lo + 1;
    double y(double v) => top + h * (1 - (v - lo) / (hi - lo));
    final t0 = (c.xStart ?? times.reduce((a, b) => a.isBefore(b) ? a : b)).millisecondsSinceEpoch.toDouble();
    final t1 = (c.xEnd ?? times.reduce((a, b) => a.isAfter(b) ? a : b)).millisecondsSinceEpoch.toDouble();
    final span = math.max(1.0, t1 - t0);
    double x(DateTime ts) => left + w * ((ts.millisecondsSinceEpoch - t0) / span).clamp(0.0, 1.0);

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in ticks) {
      if (v < lo || v > hi) continue;
      final yy = y(v);
      if (c.dashedGrid.contains(v)) {
        drawDashedH(canvas, left, left + w, yy, Paint()
          ..color = grid
          ..strokeWidth = 1.4);
      } else {
        canvas.drawLine(Offset(left, yy), Offset(left + w, yy), gp);
      }
      final s = tickLabel(v);
      drawChartText(canvas, c.signedTicks && v > 0 ? '+$s' : s, Offset(left - 6, yy), label, align: 1);
    }
    drawChartText(canvas, c.yLabel, const Offset(4, 6), label);

    if (c.refLine != null) {
      final yy = y(c.refLine!);
      drawDashedH(canvas, left, left + w, yy, Paint()
        ..color = ref.withValues(alpha: 0.8)
        ..strokeWidth = 1.2, dash: 6, gap: 4);
      if (c.refLabel != null) drawChartText(canvas, c.refLabel!, Offset(left + w, yy - 8), label.copyWith(color: ref), align: 1);
    }

    for (var si = 0; si < c.series.length; si++) {
      final s = c.series[si];
      final pts = List.of(s.points)..sort((a, b) => a.$1.compareTo(b.$1));
      if (pts.isEmpty) continue;
      // Split into runs at gaps.
      final runs = <List<(DateTime, double)>>[[pts.first]];
      for (var i = 1; i < pts.length; i++) {
        if (c.breakGap != null && pts[i].$1.difference(pts[i - 1].$1) > c.breakGap!) runs.add([]);
        runs.last.add(pts[i]);
      }
      final linePaint = Paint()
        ..color = s.color.withValues(alpha: 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round;
      for (final run in runs) {
        if (run.length == 1) {
          if (c.dotColor == null || si > 0) canvas.drawCircle(Offset(x(run.first.$1), y(run.first.$2)), 2, Paint()..color = s.color);
          continue;
        }
        final path = Path()..moveTo(x(run.first.$1), y(run.first.$2));
        for (final p in run.skip(1)) {
          path.lineTo(x(p.$1), y(p.$2));
        }
        if (c.fill && si == 0) {
          final area = Path.from(path)
            ..lineTo(x(run.last.$1), top + h)
            ..lineTo(x(run.first.$1), top + h)
            ..close();
          canvas.drawPath(
              area,
              Paint()
                ..shader = LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [s.color.withValues(alpha: 0.30), s.color.withValues(alpha: 0.02)],
                ).createShader(Rect.fromLTWH(left, top, w, h)));
        }
        canvas.drawPath(path, linePaint);
      }
      if (si == 0 && c.dotColor != null) {
        for (final p in pts) {
          canvas.drawCircle(Offset(x(p.$1), y(p.$2)), c.dotRadius, Paint()..color = c.dotColor!(p.$2));
        }
      }
    }

    for (final (ts, color) in c.floorMarks) {
      final xx = x(ts);
      canvas.drawLine(Offset(xx, top + h - 7), Offset(xx, top + h), Paint()
        ..color = color.withValues(alpha: 0.9)
        ..strokeWidth = 2);
    }
    canvas.drawLine(Offset(left, top + h), Offset(left + w, top + h), gp);
    final tStart = DateTime.fromMillisecondsSinceEpoch(t0.round(), isUtc: true);
    final tEnd = DateTime.fromMillisecondsSinceEpoch(t1.round(), isUtc: true);
    drawChartText(canvas, c.xFormat(tStart), Offset(left, size.height - 8), label);
    drawChartText(canvas, c.xFormat(tEnd), Offset(left + w, size.height - 8), label, align: 1);
    if (c.footer != null) drawChartText(canvas, c.footer!, Offset(left + w / 2, size.height - 8), label, align: 0);
  }

  @override
  bool shouldRepaint(TimeLinePainter old) => old.chart != chart || old.grid != grid || old.label != label || old.ref != ref;
}
