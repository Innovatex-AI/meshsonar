// RF tab window selector (capability rfWindow) and the repeater detail's 30-day signal trend (capability snrDaily):
// every state, the request each choice makes, the control absent without the capability, 2x text and dark mode.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/repeater_detail_api.dart';
import 'package:meshsonar/ui/region/repeater_detail_screen.dart';
import 'package:meshsonar/ui/region/rf_panel.dart';
import 'package:meshsonar/ui/region/snr_trend_card.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../core/region_rf_growth_api_test.dart' as fx;

final _now = DateTime.utc(2026, 10, 24, 22);

Widget _app(Widget child, {Brightness b = Brightness.light, double text = 1}) => MaterialApp(
      theme: meshSonarTheme(b),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(text)), child: w!),
      home: Scaffold(body: child),
    );

Map<String, dynamic> _win(String bucket, int days) {
  final to = bucket == 'day' ? DateTime.utc(2026, 10, 25) : DateTime.utc(2026, 10, 24, 22);
  final from = to.subtract(Duration(days: days));
  final b = fx.rfBody();
  // The live observer reports in the window; the silent one does not.
  b['bucket'] = bucket;
  b['window'] = {'from': from.toIso8601String(), 'to': to.toIso8601String(), 'histogramFrom': from.toIso8601String()};
  if (bucket == 'day') {
    (b['observers'] as List)[1] = {
      'key': 'e066d11b64aa', 'name': null, 'meanDbm': -77.6, 'maxDbm': -67.8, //
      'series': [
        {'at': '2026-10-22T00:00:00.000Z', 'dbm': -74.0},
        {'at': '2026-10-23T00:00:00.000Z', 'dbm': -73.0},
        {'at': '2026-10-24T00:00:00.000Z', 'dbm': -72.9},
      ],
    };
  }
  return b;
}

void main() {
  group('RF window selector', () {
    testWidgets('without the capability: no control, plain request, as before', (tester) async {
      final urls = <Uri>[];
      final c = MockClient((r) async {
        urls.add(r.url);
        return http.Response(jsonEncode(fx.rfBody()), 200);
      });
      await tester.pumpWidget(_app(RfPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: c, now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-window')), findsNothing);
      expect(urls.single.hasQuery, isFalse);
    });

    testWidgets('with it: 7 days is the start, each choice asks bucket+days, the window is named, daily points are UTC days', (tester) async {
      final urls = <String>[];
      final c = MockClient((r) async {
        urls.add(r.url.query);
        return http.Response(jsonEncode(_win(r.url.queryParameters['bucket']!, int.parse(r.url.queryParameters['days']!))), 200);
      });
      await tester.pumpWidget(_app(RfPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', windows: true, client: c, now: () => _now)));
      await tester.pumpAndSettle();
      expect(urls, ['bucket=hour&days=7']);
      for (final id in ['24h', '7d', '30d', '90d']) {
        expect(find.byKey(Key('rf-window-$id')), findsOneWidget);
      }
      expect(find.text('24 hours'), findsOneWidget);
      await tester.tap(find.byKey(const Key('rf-window-30d')));
      await tester.pumpAndSettle();
      expect(urls.last, 'bucket=day&days=30');
      expect(find.byKey(const Key('rf-window')), findsOneWidget); // the control stays
      await tester.scrollUntilVisible(find.byKey(const Key('chart-rf-noise')), 300,
          scrollable: find.descendant(of: find.byKey(const Key('rf-list')), matching: find.byType(Scrollable)).first);
      expect(find.textContaining('One point per UTC day'), findsOneWidget);
      expect(find.textContaining('Window: Sep 25 (UTC) to Oct 24 (UTC)'), findsOneWidget);
      // INNO-OB-2 stopped on Oct 21: more than 2 days before the window end.
      expect(find.byKey(const Key('rf-silent-df0136c20a99f519')), findsOneWidget);
      await tester.tap(find.byKey(const Key('rf-window-24h')));
      await tester.pumpAndSettle();
      expect(urls.last, 'bucket=hour&days=1');
      expect(find.textContaining('One point per UTC day'), findsNothing);
      expect(urls, hasLength(3));
    });

    testWidgets('loading keeps the control; a 400 says the server cannot show the window and Retry keeps it; recovers', (tester) async {
      var bad = true;
      final c = MockClient((r) async => bad && r.url.queryParameters['days'] == '90'
          ? http.Response('{"error":"nope"}', 400)
          : http.Response(jsonEncode(_win(r.url.queryParameters['bucket']!, int.parse(r.url.queryParameters['days']!))), 200));
      await tester.pumpWidget(_app(RfPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', windows: true, client: c, now: () => _now)));
      expect(find.byKey(const Key('rf-window')), findsOneWidget);
      expect(find.byKey(const Key('rf-loading')), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('rf-window-90d')));
      await tester.pump();
      expect(find.byKey(const Key('rf-loading')), findsOneWidget);
      expect(find.byKey(const Key('rf-window')), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-error')), findsOneWidget);
      expect(find.textContaining('This server cannot show the 90 days window'), findsOneWidget);
      bad = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-list')), findsOneWidget);
      expect(find.text('90 days'), findsOneWidget);
    });

    testWidgets('other failures keep the window; an empty window and the offline copy are explicit (2x text, dark)', (tester) async {
      var mode = 'down';
      final c = MockClient((r) async {
        if (mode == 'down') return http.Response('x', 503);
        if (mode == 'empty') {
          return http.Response(jsonEncode({'status': {'state': 'ready'}, 'bucket': 'hour', 'observers': [], 'noiseByHour': [], 'snrHistogram': []}), 200);
        }
        return http.Response(jsonEncode(_win('hour', 1)), 200,
            headers: {'x-meshsonar-cache': 'offline', 'x-meshsonar-as-of': '2026-10-24T19:00:00.000Z'});
      });
      Widget panel() => _app(RfPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', windows: true, client: c, now: () => _now), b: Brightness.dark, text: 2);
      await tester.pumpWidget(panel());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-error')), findsOneWidget);
      expect(find.byKey(const Key('rf-window')), findsOneWidget);
      mode = 'empty';
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-empty')), findsOneWidget);
      expect(find.textContaining('No RF measurements in the last 7 days'), findsOneWidget);
      mode = 'offline';
      await tester.tap(find.byKey(const Key('rf-window-24h')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-offline')), findsOneWidget);
      expect(find.textContaining('Offline - as of 3h ago'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

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
      expect(find.bySemanticsLabel(RegExp(r'Mean SNR per day \(dB\)\. 13 of 14 days with readings, 39 adverts')), findsOneWidget);
      expect(find.textContaining('Days are UTC dates'), findsOneWidget);
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
      expect(find.textContaining('No direct readings in the last 30 days'), findsOneWidget);
      await tester.pumpWidget(_app(SingleChildScrollView(child: SnrTrendCard(daily: days([5]))), b: Brightness.dark, text: 2));
      expect(find.text('Table'), findsOneWidget); // one point: starts on the table, no one-dot chart
      expect(tester.takeException(), isNull);
    });

    Future<void> screen(WidgetTester t, {required bool? cap, Object? daily}) async {
      t.view.physicalSize = const Size(800, 5000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final j = jsonDecode(File('test/fixtures/region_repeater_cmh.json').readAsStringSync()) as Map<String, dynamic>;
      if (daily != null) j['snrDaily'] = daily;
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: RepeaterDetailScreen(
          key: UniqueKey(),
          baseUrl: 'https://cmh.meshsonar.com',
          regionSlug: 'cmh',
          repeaterKey: 'da5dc89c937225aadced4a1cb8a689c0d34ccab96576a0d0f69f3186c879c854',
          client: MockClient((_) async => http.Response.bytes(utf8.encode(jsonEncode(j)), 200)),
          mapTiles: false,
          now: DateTime.utc(2026, 10, 24, 2),
          snrDaily: cap,
        ),
      ));
      await t.pumpAndSettle();
    }

    final sample = [
      for (var i = 0; i < 10; i++) {'day': '2026-10-${(10 + i).toString().padLeft(2, '0')}', 'meanDb': 3.0 + i % 3, 'n': 2},
    ];

    testWidgets('detail screen: shown with the capability and the field; hidden without either', (t) async {
      await screen(t, cap: true, daily: sample);
      expect(find.byKey(const Key('repdetail-snr-trend')), findsOneWidget);
      await screen(t, cap: false, daily: sample);
      expect(find.byKey(const Key('repdetail-snr-trend')), findsNothing);
      await screen(t, cap: true); // older server: field absent
      expect(find.byKey(const Key('repdetail-snr-trend')), findsNothing);
      expect(find.byKey(const Key('repdetail-sparkline')), findsOneWidget); // the rest of the screen is untouched
    });
  });
}
