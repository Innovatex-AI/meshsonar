// Chart kit (lib/ui/charts): every chart is one semantics node whose label carries the numbers, the Chart/Table switch
// shows every row, painters take their colours from the theme (light and dark), and the sparkline presets keep the
// drawing rules of the copies they replaced.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/charts/bar_chart.dart';
import 'package:meshsonar/ui/charts/chart_frame.dart';
import 'package:meshsonar/ui/charts/chart_scale.dart';
import 'package:meshsonar/ui/charts/sparkline.dart';
import 'package:meshsonar/ui/charts/time_line_chart.dart';
import 'package:meshsonar/ui/theme.dart';

Widget _wrap(Widget child, {Brightness b = Brightness.light}) =>
    MaterialApp(theme: meshSonarTheme(b), home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(8), child: child))));

final _t0 = DateTime.utc(2026, 10, 21, 12);

ChartFrame _frame(Widget chart) => ChartFrame(
      id: 'noise',
      title: 'Noise floor',
      summary: 'Quietest -97.1 dBm, noisiest -77.6 dBm.',
      table: const ChartTable(head: ['Observer', 'Mean (dBm)'], rows: [['INNO-OB-2', '-97.1'], ['ForestPark', '-77.6']]),
      caption: 'Times are your phone\'s local time.',
      chart: chart,
    );

void main() {
  testWidgets('the chart is one semantics node labelled with the title and the numbers', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(_frame(TimeLineChart(
      series: [ChartSeries(name: 'a', points: [(_t0, -97.1), (_t0.add(const Duration(hours: 1)), -96.0)], color: Colors.teal)],
      yLabel: 'dBm',
      xFormat: (t) => '${t.hour}',
    ))));
    expect(find.bySemanticsLabel('Noise floor. Quietest -97.1 dBm, noisiest -77.6 dBm.'), findsOneWidget);
    expect(find.text('Times are your phone\'s local time.'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the Table switch shows every row and back', (tester) async {
    await tester.pumpWidget(_wrap(_frame(const SizedBox())));
    expect(find.byKey(const Key('chart-noise-chart')), findsOneWidget);
    expect(find.text('INNO-OB-2'), findsNothing);
    await tester.tap(find.text('Table'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chart-noise-table')), findsOneWidget);
    expect(find.text('INNO-OB-2'), findsOneWidget);
    expect(find.text('-77.6'), findsOneWidget);
    expect(find.text('Mean (dBm)'), findsOneWidget);
    await tester.tap(find.text('Chart'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chart-noise-chart')), findsOneWidget);
  });

  testWidgets('an empty table says so instead of drawing an empty grid', (tester) async {
    await tester.pumpWidget(_wrap(const ChartFrame(
        id: 'x', title: 'T', summary: 'No values.', table: ChartTable(head: ['a'], rows: []), chart: SizedBox(), startWithTable: true)));
    expect(find.text('No rows.'), findsOneWidget);
  });

  for (final b in Brightness.values) {
    testWidgets('painters take theme colours ($b)', (tester) async {
      final theme = meshSonarTheme(b);
      await tester.pumpWidget(_wrap(
        Column(children: [
          SizedBox(
            height: 120,
            child: TimeLineChart(
              series: [ChartSeries(name: 'a', points: [(_t0, 1.0)], color: theme.colorScheme.primary)],
              yLabel: 'dB',
              refLine: -100,
              xFormat: (t) => '',
            ),
          ),
          SizedBox(
            height: 120,
            child: BarChart(labels: const ['a'], series: [BarSeries(name: 'n', values: const [3], color: theme.colorScheme.primary)]),
          ),
        ]),
        b: b,
      ));
      final line = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<TimeLinePainter>().single;
      expect(line.grid, theme.colorScheme.outlineVariant);
      expect(line.ref, theme.colorScheme.error);
      expect(line.label.color, theme.colorScheme.onSurfaceVariant);
      final bars = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<BarPainter>().single;
      expect(bars.grid, theme.colorScheme.outlineVariant);
    });
  }

  testWidgets('sparkline: semantics summary, gaps are null, SNR preset dots coloured per value', (tester) async {
    final handle = tester.ensureSemantics();
    final m = MeshSonarColors.light;
    await tester.pumpWidget(_wrap(Sparkline(
      values: const [-3.5, null, 8, 6.5],
      color: m.snrMid,
      style: SparkStyle.snr,
      dotColor: (v) => m.forPing(heard: true, snr: v),
      summary: sparkSummary(const [-3.5, null, 8, 6.5], unit: 'dB', gapWord: 'pings'),
    )));
    expect(find.bySemanticsLabel('Lowest -3.5 dB, highest 8.0 dB, latest 6.5 dB; 1 of 4 pings have no data.'), findsOneWidget);
    final p = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<SparklinePainter>().single;
    expect(p.style.includeLo, -5);
    expect(p.style.ref, 0);
    expect(p.dotColor!(8), m.forPing(heard: true, snr: 8));
    handle.dispose();
  });

  test('sparkSummary with no data', () {
    expect(sparkSummary(const [null, null]), 'No values.');
  });

  test('niceTicks', () {
    expect(niceTicks(-97, -71), [-100, -90, -80, -70]);
    expect(niceTicks(0, 52), [0, 20, 40, 60]);
    expect(niceTicks(3, 3), [3]);
    expect(tickLabel(-100), '-100');
    expect(tickLabel(2.5), '2.5');
  });

  test('Round 5 D-15: dB axes tick in whole steps; other labels print the decimals the step needs', () {
    // Build 76 drew -113, -113.3, -113.5, -113.8, -114 for a narrow RSSI range.
    expect(niceTicks(-114, -113, minStep: minTickStepFor('dBm')), [-114, -113]);
    expect(niceTicks(-114, -110, minStep: minTickStepFor('SNR dB')), [-114, -113, -112, -111, -110]);
    expect(minTickStepFor('%'), 0);
    expect(niceTicks(0, 1), [0, 0.25, 0.5, 0.75, 1]);
    expect(tickLabel(0.25), '0.25');
    expect(tickLabel(-113.5), '-113.5');
  });

  testWidgets('the series palette has six different colours, no amber and no signal-ramp colour', (tester) async {
    late List<Color> pal;
    late MeshSonarColors m;
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Builder(builder: (context) {
        pal = chartPalette(context);
        m = MeshSonarColors.of(context);
        return const SizedBox();
      }),
    ));
    expect(pal.toSet().length, 6);
    expect(pal, isNot(contains(m.beacon)));
    expect(pal, isNot(contains(m.warning)));
    for (final c in m.snrStops) {
      expect(pal, isNot(contains(c)));
    }
  });
}
