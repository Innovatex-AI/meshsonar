// The WP1 leftovers moved onto the chart kit (stream 5): the region overview's filled packets-per-hour sparkline
// (SparkStyle.counts + fill + baseline), the Reports panel bar strips (BarStrip), the analysis heatmap painter (moved
// unchanged) and the heard strip (moved; optional semantics label). Same drawing inputs, now with numbers in semantics.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/charts/bar_strip.dart';
import 'package:meshsonar/ui/charts/heard_strip.dart';
import 'package:meshsonar/ui/charts/heatmap.dart';
import 'package:meshsonar/ui/charts/sparkline.dart';
import 'package:meshsonar/ui/sessions_screen.dart' as sessions show HeardStrip;
import 'package:meshsonar/ui/theme.dart';

Widget _wrap(Widget w, {Brightness b = Brightness.light}) =>
    MaterialApp(theme: meshSonarTheme(b), home: Scaffold(body: Center(child: SizedBox(width: 300, child: w))));

void main() {
  testWidgets('counts sparkline: 0..max scale, fill and baseline colours reach the painter; summary is the label', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(const Sparkline(
      key: Key('sparkline'),
      height: 64,
      values: [0, 4, 52, 3],
      color: Colors.teal,
      style: SparkStyle.counts,
      fillColor: Colors.amber,
      baseColor: Colors.grey,
      summary: 'Packets per hour, last 4 hours: peak 52, 59 in all.',
    )));
    final p = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<SparklinePainter>().single;
    expect(p.fillColor, Colors.amber);
    expect(p.baseColor, Colors.grey);
    expect(p.style.includeLo, 0);
    expect(p.style.includeHi, 1);
    expect(p.style.dots, SparkDots.none);
    expect(find.bySemanticsLabel('Packets per hour, last 4 hours: peak 52, 59 in all.'), findsOneWidget);
    // An all-zero day and a single hour paint without throwing.
    await tester.pumpWidget(_wrap(const Sparkline(values: [0, 0, 0], color: Colors.teal, style: SparkStyle.counts, fillColor: Colors.amber, baseColor: Colors.grey, summary: 's')));
    await tester.pumpWidget(_wrap(const Sparkline(values: [5], color: Colors.teal, style: SparkStyle.counts, fillColor: Colors.amber, summary: 's')));
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('BarStrip: one bar per value, its numbers in one semantics label', (tester) async {
    final handle = tester.ensureSemantics();
    final values = [3, 0, 12, 7];
    await tester.pumpWidget(_wrap(BarStrip(
      key: const Key('bars-trend'),
      values: values,
      summary: barStripSummary(values, what: 'Packets per day', labelOf: (i) => ['Oct 21', 'Oct 22', 'Oct 23', 'Oct 24'][i]),
    )));
    expect(find.byType(FractionallySizedBox), findsNWidgets(4));
    expect(find.bySemanticsLabel('Packets per day, 4 bars: peak 12 at Oct 23, total 22, lowest 0.'), findsOneWidget);
    expect(barStripSummary(const [], what: 'Packets per hour'), 'Packets per hour: no values.');
    handle.dispose();
  });

  testWidgets('heatmap painter (moved) paints in both themes', (tester) async {
    final grid = List.generate(7, (d) => List.generate(24, (h) => d * h));
    for (final b in Brightness.values) {
      await tester.pumpWidget(_wrap(SizedBox(height: 140, child: CustomPaint(painter: HeatmapPainter(grid, Colors.teal, Colors.black12, Colors.grey))), b: b));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('heard strip (moved, still exported by sessions_screen): optional label', (tester) async {
    final handle = tester.ensureSemantics();
    expect(sessions.HeardStrip, HeardStrip);
    await tester.pumpWidget(_wrap(const HeardStrip(timeline: [true, false, true], snr: [5, null, -2], summary: 'Heard on 2 of 3 pings.')));
    expect(find.bySemanticsLabel('Heard on 2 of 3 pings.'), findsOneWidget);
    await tester.pumpWidget(_wrap(const HeardStrip(timeline: [true, false])));
    expect(find.bySemanticsLabel(RegExp('Heard on')), findsNothing);
    handle.dispose();
  });
}
