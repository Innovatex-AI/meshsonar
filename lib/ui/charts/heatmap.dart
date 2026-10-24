// Weekday x hour heatmap painter, moved unchanged from lib/ui/region/analysis_panel.dart into the chart kit (stream 5
// WP1 design: one home for the app's chart painters). 7 rows (Sun..Sat) x 24 columns. The caller wraps it in a
// Semantics label with the busiest cell (analysis_panel.dart _Heatmap).
import 'package:flutter/material.dart';

/// 7 rows (Sun..Sat) x 24 columns; cell opacity scales with packets relative to the busiest cell.
class HeatmapPainter extends CustomPainter {
  final List<List<int>> grid;
  final Color hot, cold, label;
  HeatmapPainter(this.grid, this.hot, this.cold, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    const left = 32.0, top = 14.0;
    var peak = 0;
    for (final r in grid) {
      for (final v in r) {
        if (v > peak) peak = v;
      }
    }
    final cw = (size.width - left) / 24, ch = (size.height - top) / 7;
    const days = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
    void text(String s, Offset o) {
      final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(fontSize: 9, color: label)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, o);
    }

    for (var h = 0; h < 24; h += 6) {
      text('$h', Offset(left + h * cw, 0));
    }
    for (var d = 0; d < 7; d++) {
      text(days[d], Offset(8, top + d * ch + (ch - 11) / 2));
      for (var h = 0; h < 24; h++) {
        final v = grid[d][h];
        final p = Paint()..color = v == 0 || peak == 0 ? cold : Color.lerp(cold, hot, 0.2 + 0.8 * v / peak)!;
        canvas.drawRRect(
            RRect.fromRectAndRadius(Rect.fromLTWH(left + h * cw + 1, top + d * ch + 1, cw - 2, ch - 2), const Radius.circular(2)), p);
      }
    }
  }

  @override
  bool shouldRepaint(HeatmapPainter o) => o.grid != grid || o.hot != hot || o.cold != cold;
}
