// Sparkline: a tiny line chart for the dashboard glance cards (chat plan 4.10). A CustomPainter with a cached Path and no
// chart dependency. Empty data draws a faint baseline, one point draws a dot, two or more draw the line with a dot on the
// latest value. [Sparkline.summary] builds the sentence VoiceOver reads instead of the picture.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// The line's points scaled into [size] (inset by [pad]). Pure, so it can be tested without a canvas. A flat series sits in
/// the middle. [values] oldest first; non-finite values are skipped.
List<Offset> sparklinePoints(List<double> values, Size size, {double pad = 2}) {
  final v = [for (final x in values) if (x.isFinite) x];
  if (v.isEmpty || size.isEmpty) return const [];
  final w = size.width - pad * 2, h = size.height - pad * 2;
  if (v.length == 1) return [Offset(size.width / 2, size.height / 2)];
  var lo = v.first, hi = v.first;
  for (final x in v) {
    if (x < lo) lo = x;
    if (x > hi) hi = x;
  }
  final span = hi - lo;
  return [
    for (var i = 0; i < v.length; i++)
      Offset(pad + w * i / (v.length - 1), span == 0 ? size.height / 2 : pad + h * (1 - (v[i] - lo) / span)),
  ];
}

class SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final Color baseline;
  final double strokeWidth;

  SparklinePainter({required this.values, required this.color, required this.baseline, this.strokeWidth = 1.5});

  Size? _pathSize;
  Path? _path;
  List<Offset> _pts = const [];

  /// The line, rebuilt only when the size changes (the painter itself is replaced when the data does).
  Path pathFor(Size size) {
    if (_path != null && _pathSize == size) return _path!;
    _pts = sparklinePoints(values, size);
    final p = Path();
    for (var i = 0; i < _pts.length; i++) {
      i == 0 ? p.moveTo(_pts[i].dx, _pts[i].dy) : p.lineTo(_pts[i].dx, _pts[i].dy);
    }
    _pathSize = size;
    return _path = p;
  }

  /// How many points the last [pathFor] produced (for tests).
  int get pointCount => _pts.length;

  @override
  void paint(Canvas canvas, Size size) {
    final path = pathFor(size);
    if (_pts.isEmpty) {
      canvas.drawLine(Offset(0, size.height / 2), Offset(size.width, size.height / 2), Paint()..color = baseline..strokeWidth = 1);
      return;
    }
    if (_pts.length >= 2) {
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth
            ..strokeJoin = StrokeJoin.round
            ..strokeCap = StrokeCap.round);
    }
    canvas.drawCircle(_pts.last, strokeWidth * 1.4, Paint()..color = color);
  }

  @override
  bool shouldRepaint(SparklinePainter old) => old.color != color || old.baseline != baseline || old.strokeWidth != strokeWidth || !_same(old.values, values);

  static bool _same(List<double> a, List<double> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class Sparkline extends StatelessWidget {
  final List<double> values;
  final double width;
  final double height;
  final Color? color;

  /// Read by VoiceOver in place of the drawing; build it with [Sparkline.summary].
  final String semanticLabel;
  const Sparkline({super.key, required this.values, required this.semanticLabel, this.width = 60, this.height = 24, this.color});

  /// "Battery, last 7 days: 3.92 to 4.05 V, lowest 3.90, highest 4.08." / "No history yet." / "Battery: one reading, 4.05 V."
  static String summary(String what, List<double> values, {String unit = '', int decimals = 1}) {
    final v = [for (final x in values) if (x.isFinite) x];
    String f(double x) => x.toStringAsFixed(decimals);
    final u = unit.isEmpty ? '' : ' $unit';
    if (v.isEmpty) return '$what: no history yet.';
    if (v.length == 1) return '$what: one reading, ${f(v.first)}$u.';
    var lo = v.first, hi = v.first;
    for (final x in v) {
      if (x < lo) lo = x;
      if (x > hi) hi = x;
    }
    return '$what, last 7 days: ${f(v.first)} to ${f(v.last)}$u, lowest ${f(lo)}, highest ${f(hi)}.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size(width, height),
          painter: SparklinePainter(values: values, color: color ?? scheme.primary, baseline: scheme.outlineVariant),
        ),
      ),
    );
  }
}

/// A larger version for the full chart page: the line, with the lowest and highest value written at the left edge.
class SparklineChart extends StatelessWidget {
  final List<double> values;
  final String semanticLabel;
  final String Function(double) format;
  final double height;
  const SparklineChart({super.key, required this.values, required this.semanticLabel, required this.format, this.height = 220});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final v = [for (final x in values) if (x.isFinite) x];
    final lo = v.isEmpty ? null : v.reduce((a, b) => a < b ? a : b);
    final hi = v.isEmpty ? null : v.reduce((a, b) => a > b ? a : b);
    final label = t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant, fontFeatures: const [ui.FontFeature.tabularFigures()]);
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (lo != null && hi != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [Text(format(hi), style: label), Text(format(lo), style: label)]),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => RepaintBoundary(
                child: CustomPaint(
                  size: Size(c.maxWidth, height),
                  painter: SparklinePainter(values: values, color: t.colorScheme.primary, baseline: t.colorScheme.outlineVariant, strokeWidth: 2.5),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
