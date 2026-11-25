// The 30-day signal trend card (now on the /v1 node page): numbers in words, gaps, 2x text and dark mode. (The old RF
// tab and its window selector were retired in build 71.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/repeater_detail_api.dart';
import 'package:meshsonar/ui/region/snr_trend_card.dart';
import 'package:meshsonar/ui/theme.dart';

Widget _app(Widget child, {Brightness b = Brightness.light, double text = 1}) => MaterialApp(
      theme: meshSonarTheme(b),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(text)), child: w!),
      home: Scaffold(body: child),
    );

void main() {
  group('30-day signal trend', () {
    List<DailySnr> days(List<double?> v) => [
          for (var i = 0; i < v.length; i++) DailySnr(DateTime.utc(2026, 10, 1 + i), v[i], v[i] == null ? 0 : 3),
        ];

    testWidgets('numbers in words and semantics, trend sentence, table with gaps and counts', (tester) async {
      final h = tester.ensureSemantics();
      await tester.pumpWidget(_app(SingleChildScrollView(child: SnrTrendCard(daily: days([4, 4, null, 4, 4, 4, 4, 4, 7, 7, 7, 7, 7, 7])))));
      expect(find.text('30-day signal trend'), findsOneWidget);
      expect(find.textContaining('Latest 7.0 dB (Oct 14)'), findsOneWidget);
      expect(find.textContaining('13 of 14 days with readings'), findsOneWidget);
      expect(find.byKey(const Key('snrtrend-sentence')), findsOneWidget);
      expect(find.textContaining('about 3.0 dB stronger'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'Average signal per day \(SNR, dB\)\. 13 of 14 days with readings, 39 adverts')), findsOneWidget);
      expect(find.textContaining('a gap is a day with no reading'), findsOneWidget);
      await tester.tap(find.text('Table'));
      await tester.pumpAndSettle();
      expect(find.text('no reading'), findsOneWidget);
      expect(find.text('Oct 3'), findsOneWidget);
      h.dispose();
    });

    testWidgets('fewer than 7 days with readings: no trend sentence; all gaps: the reason in words', (tester) async {
      await tester.pumpWidget(_app(SingleChildScrollView(child: SnrTrendCard(daily: days([4, null, 5, null, 6])))));
      expect(find.byKey(const Key('snrtrend-sentence')), findsNothing);
      expect(find.byKey(const Key('snrtrend-summary')), findsOneWidget);
      await tester.pumpWidget(_app(SingleChildScrollView(child: SnrTrendCard(daily: days([null, null, null])))));
      expect(find.byKey(const Key('snrtrend-empty')), findsOneWidget);
      expect(find.textContaining('No readings in the last 30 days'), findsOneWidget);
      await tester.pumpWidget(_app(SingleChildScrollView(child: SnrTrendCard(daily: days([5]))), b: Brightness.dark, text: 2));
      expect(find.text('Table'), findsOneWidget); // one point: starts on the table, no one-dot chart
      expect(tester.takeException(), isNull);
    });

  });
}
