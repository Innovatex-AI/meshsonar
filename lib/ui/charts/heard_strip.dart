// Heard / not-heard strip (moved unchanged from sessions_screen.dart into the chart kit; sessions_screen.dart re-exports
// HeardStrip so existing imports keep working). One bar per tx ping, bucketed on long drives so each bar is at least
// 3 px wide: coloured by the best SNR when heard, the "silent" colour when nothing answered.
import 'package:flutter/material.dart';

import '../theme.dart';

/// One bar per ping (bucketed on long drives): coloured by SNR when heard, the "silent" colour when nothing heard.
class HeardStrip extends StatelessWidget {
  final List<bool> timeline;
  final List<double?> snr;
  final double height;

  /// When given, the strip is one semantics node with this label (callers that label it themselves leave it null).
  final String? summary;
  const HeardStrip({super.key, required this.timeline, this.snr = const [], this.height = 14, this.summary});

  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    final strip = SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(painter: _StripPainter(timeline, snr, m, Theme.of(context).colorScheme.surfaceContainerHighest)),
    );
    if (summary == null) return strip;
    return Semantics(container: true, image: true, label: summary, excludeSemantics: true, child: strip);
  }
}

class _StripPainter extends CustomPainter {
  final List<bool> t;
  final List<double?> snr;
  final MeshSonarColors m;
  final Color track;
  _StripPainter(this.t, this.snr, this.m, this.track);

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(4));
    canvas.clipRRect(rr);
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    if (t.isEmpty) return;
    // Bucket long drives so each bar is at least 3 px wide.
    final buckets = (size.width / 4).floor().clamp(1, t.length);
    final w = size.width / buckets;
    for (var b = 0; b < buckets; b++) {
      final from = (b * t.length / buckets).floor();
      final to = ((b + 1) * t.length / buckets).ceil().clamp(from + 1, t.length);
      var heard = 0;
      double? best;
      for (var i = from; i < to; i++) {
        if (t[i]) heard++;
        final v = i < snr.length ? snr[i] : null;
        if (v != null && (best == null || v > best)) best = v;
      }
      final frac = heard / (to - from);
      final color = frac == 0 ? m.silent.withValues(alpha: 0.55) : m.forPing(heard: true, snr: best);
      final h = frac == 0 ? size.height * 0.4 : size.height * (0.6 + 0.4 * frac);
      final gap = w > 4 ? 1.5 : 0.75;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(b * w, size.height - h, w - gap, h), const Radius.circular(1.5)),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_StripPainter old) => old.t != t || old.snr != snr || old.m != m;
}
