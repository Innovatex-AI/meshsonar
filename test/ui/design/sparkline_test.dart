// Sparkline (chat plan 4.10): points scaling, empty / one point / flat handling, cached Path, VoiceOver sentence, repaint rules.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/sparkline.dart';

void main() {
  const size = Size(60, 24);

  test('empty draws no points, one point sits in the middle, a flat line is centred', () {
    expect(sparklinePoints(const [], size), isEmpty);
    expect(sparklinePoints(const [double.nan], size), isEmpty);
    expect(sparklinePoints(const [4.0], size), [const Offset(30, 12)]);
    final flat = sparklinePoints(const [3, 3, 3], size);
    expect(flat.map((p) => p.dy).toSet(), {12.0});
    expect(flat.first.dx, 2);
    expect(flat.last.dx, 58);
  });

  test('values scale into the box: the high value is at the top, the low at the bottom, time runs left to right', () {
    final p = sparklinePoints(const [1, 3, 2], size);
    expect(p[0], const Offset(2, 22)); // lowest -> bottom (24 - pad)
    expect(p[1], const Offset(30, 2)); // highest -> top
    expect(p[2].dx, 58);
    expect(p[2].dy, closeTo(12, 1e-9));
  });

  test('the Path is built once per size and rebuilt on a new size', () {
    final painter = SparklinePainter(values: const [1, 2, 3], color: Colors.red, baseline: Colors.grey);
    final a = painter.pathFor(size);
    expect(identical(painter.pathFor(size), a), isTrue, reason: 'cached');
    expect(painter.pointCount, 3);
    expect(identical(painter.pathFor(const Size(100, 40)), a), isFalse);
  });

  test('repaints only when data or colours change', () {
    final a = SparklinePainter(values: const [1, 2], color: Colors.red, baseline: Colors.grey);
    expect(a.shouldRepaint(SparklinePainter(values: [1.0, 2.0], color: Colors.red, baseline: Colors.grey)), isFalse);
    expect(a.shouldRepaint(SparklinePainter(values: const [1, 3], color: Colors.red, baseline: Colors.grey)), isTrue);
    expect(a.shouldRepaint(SparklinePainter(values: const [1, 2], color: Colors.blue, baseline: Colors.grey)), isTrue);
  });

  for (final v in <List<double>>[const [], const [5], const [1, 2, 3, 2], const [2, 2, 2]]) {
    test('paints ${v.length} point(s) without throwing', () {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      SparklinePainter(values: v, color: Colors.teal, baseline: Colors.grey).paint(canvas, size);
      final pic = rec.endRecording();
      expect(pic, isNotNull);
      pic.dispose();
    });
  }

  test('the VoiceOver sentence covers empty, one reading and a range', () {
    expect(Sparkline.summary('Battery', const [], unit: 'V'), 'Battery: no history yet.');
    expect(Sparkline.summary('Battery', const [4.05], unit: 'V', decimals: 2), 'Battery: one reading, 4.05 V.');
    expect(Sparkline.summary('Battery', const [3.92, 3.9, 4.08, 4.05], unit: 'V', decimals: 2), 'Battery, last 7 days: 3.92 to 4.05 V, lowest 3.90, highest 4.08.');
  });

  testWidgets('the widget exposes the sentence and has the 60 x 24 size', (t) async {
    await t.pumpWidget(MaterialApp(home: Center(child: Sparkline(values: const [1, 2, 3], semanticLabel: 'Noise, last 7 days: 1 to 3'))));
    expect(t.getSize(find.byType(Sparkline)), const Size(60, 24));
    expect(find.bySemanticsLabel('Noise, last 7 days: 1 to 3'), findsOneWidget);
  });
}
