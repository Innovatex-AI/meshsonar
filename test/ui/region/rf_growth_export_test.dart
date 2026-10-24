// Region RF and Growth tabs and the region report export sheet: ready (numbers in semantics, the silent observer named,
// local hours), pending/empty with the server's reason, error + Retry that recovers, 404 "not published", the offline
// "as of" label from the ETag cache, firmware hidden while empty, and exports with the website's file names and bytes.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/ui/region/growth_panel.dart';
import 'package:meshsonar/ui/region/region_report_export_sheet.dart';
import 'package:meshsonar/ui/region/rf_panel.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../core/region_report_export_test.dart' as rep;
import '../../core/region_rf_growth_api_test.dart' as fx;

final _now = DateTime.utc(2026, 10, 24, 22);

Widget _app(Widget child, {Brightness b = Brightness.light}) =>
    MaterialApp(theme: meshSonarTheme(b), home: Scaffold(body: child));

http.Client _json(Object body, {Map<String, String> headers = const {}, int code = 200}) =>
    MockClient((_) async => http.Response(jsonEncode(body), code, headers: headers));

void main() {
  group('RF tab', () {
    testWidgets('ready: finding, figures, silent observer named, charts carry numbers, local hours', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(RfPanel(
          baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _json(fx.rfBody()), utcOffset: const Duration(hours: -5), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.text('CMH RF and noise floor'), findsOneWidget);
      expect(find.byKey(const Key('rf-finding')), findsOneWidget);
      expect(find.textContaining('highest at 20:00 your time'), findsOneWidget); // 01:00 UTC at UTC-5
      expect(find.byKey(const Key('rf-silent-df0136c20a99f519')), findsOneWidget);
      expect(find.textContaining('INNO-OB-2 has sent no noise reading since'), findsOneWidget);
      expect(find.byKey(const Key('rf-silent-e066d11b64aa')), findsNothing);
      expect(find.text('70%'), findsOneWidget); // weak signals
      await tester.scrollUntilVisible(find.byKey(const Key('chart-rf-noise')), 300);
      expect(find.bySemanticsLabel(RegExp(r'^Noise floor by observer .*INNO-OB-2: mean -97\.1 dBm, max -88\.1 dBm, no data since')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-rf-snr')), 300);
      expect(find.bySemanticsLabel(RegExp(r'100 packets\. Most common -2 to 0 dB \(50 packets\)\. 70% at or below 0 dB\.')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('hour table lists local hours; a half-hour zone stays in UTC and says so', (tester) async {
      await tester.pumpWidget(_app(RfPanel(
          baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _json(fx.rfBody()), utcOffset: const Duration(hours: 5, minutes: 30), now: () => _now)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('chart-rf-hours')), 300);
      expect(find.textContaining('Hours are UTC.'), findsOneWidget);
    });

    testWidgets('pending with no data: honest empty text and the server reason', (tester) async {
      await tester.pumpWidget(_app(RfPanel(
          baseUrl: 'https://day.meshsonar.com',
          regionSlug: 'day',
          client: _json({
            'status': {'state': 'pending', 'reason': 'No trusted observers in this region yet.', 'computedAt': '2026-10-24T21:00:00Z'},
            'observers': [],
            'noiseByHour': [],
            'snrHistogram': [],
          }),
          now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-empty')), findsOneWidget);
      expect(find.text('Pending'), findsOneWidget);
      expect(find.text('No trusted observers in this region yet.'), findsOneWidget);
    });

    testWidgets('error with Retry that recovers; 404 says not published, no Retry', (tester) async {
      var fail = true;
      final c = MockClient((_) async => fail ? http.Response('down', 503) : http.Response(jsonEncode(fx.rfBody()), 200));
      await tester.pumpWidget(_app(RfPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: c, now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-error')), findsOneWidget);
      expect(find.textContaining('The server answered 503.'), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-list')), findsOneWidget);

      await tester.pumpWidget(_app(RfPanel(
          key: const ValueKey('nf'), baseUrl: 'https://x.meshsonar.com', regionSlug: 'x', client: _json({}, code: 404), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-notfound')), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('offline copy from the ETag cache is labelled with its age (dark theme)', (tester) async {
      await tester.pumpWidget(_app(
          RfPanel(
              baseUrl: 'https://cmh.meshsonar.com',
              regionSlug: 'cmh',
              client: _json(fx.rfBody(), headers: {'x-meshsonar-cache': 'offline', 'x-meshsonar-as-of': '2026-10-24T19:00:00.000Z'}),
              now: () => _now),
          b: Brightness.dark));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('rf-offline')), findsOneWidget);
      expect(find.textContaining('Offline - as of 3h ago'), findsOneWidget);
    });
  });

  group('Growth tab', () {
    testWidgets('ready: source, totals, cumulative chart numbers, churn, roles; firmware hidden while empty', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_app(GrowthPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _json(fx.growthBody()), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.text('CMH network growth'), findsOneWidget);
      expect(find.text('Source: external sources (CoreScope, MeshCore Map).'), findsOneWidget);
      expect(find.text('40'), findsOneWidget); // known nodes
      expect(find.bySemanticsLabel(RegExp(r'^Known nodes over time\. 37 before Sep 24 2026, 40 by Oct 23 2026: 3 added on 2 days\.')), findsOneWidget);
      expect(find.textContaining('its nodes count from the day MeshSonar first saw them'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-growth-churn')), 300);
      expect(find.bySemanticsLabel(RegExp(r'9 nodes appeared and 1 went quiet over 2 weeks')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-growth-hash')), 300);
      expect(find.byKey(const Key('chart-growth-roles')), findsOneWidget);
      expect(find.byKey(const Key('chart-growth-firmware')), findsNothing);
      handle.dispose();
    });

    testWidgets('empty: honest text', (tester) async {
      await tester.pumpWidget(_app(GrowthPanel(
          baseUrl: 'https://x.meshsonar.com', regionSlug: 'x', client: _json({'status': {'state': 'pending', 'reason': 'No sources yet.'}}), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('growth-empty')), findsOneWidget);
      expect(find.text('No sources yet.'), findsOneWidget);
    });
  });

  group('Export region report', () {
    testWidgets('offers text, JSON, all tables and each table; empty tables disabled; shares the website file', (tester) async {
      final shared = <(String, String)>[];
      final seen = <Uri>[];
      final c = MockClient((req) async {
        seen.add(req.url);
        return http.Response(jsonEncode(rep.body()), 200);
      });
      await tester.pumpWidget(_app(RegionReportExportSheet(
          baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: c, now: () => _now, share: (n, b) async => shared.add((n, b)))));
      await tester.pumpAndSettle();
      expect(seen.single.toString(), 'https://cmh.meshsonar.com/api/cmh/region-report');
      expect(find.text('Export Columbus, US report'), findsOneWidget);
      await tester.tap(find.byKey(const Key('export-json')));
      await tester.pumpAndSettle();
      expect(shared.last.$1, 'cmh-region-report.json');
      await tester.tap(find.byKey(const Key('export-text')));
      await tester.pumpAndSettle();
      expect(shared.last.$2, startsWith('MeshSonar region report: Columbus, US (CMH)'));
      await tester.scrollUntilVisible(find.byKey(const Key('export-table-coverage')), 200);
      await tester.tap(find.byKey(const Key('export-table-coverage')));
      await tester.pumpAndSettle();
      expect(shared.last, ('cmh-coverage.csv', 'metric,value\r\ncells,685\r\ndrives,34\r\nkm,\r\nheard_pct,50\r\n'));
      await tester.scrollUntilVisible(find.byKey(const Key('export-csv-all')), -200);
      await tester.tap(find.byKey(const Key('export-csv-all')));
      await tester.pumpAndSettle();
      expect(shared.last.$1, 'cmh-region-report-all-tables.csv');
      expect(shared, hasLength(4));
    });

    testWidgets('an empty table cannot be exported', (tester) async {
      final b = rep.body();
      (b['hash'] as Map)['collisions'] = [];
      await tester.pumpWidget(_app(RegionReportExportSheet(
          baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _json(b), now: () => _now, share: (n, b) async {})));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('export-table-hash-collisions')), 200);
      expect(tester.widget<ListTile>(find.byKey(const Key('export-table-hash-collisions'))).enabled, isFalse);
    });

    testWidgets('load failure shows Retry; offline copy is labelled', (tester) async {
      var fail = true;
      final c = MockClient((_) async => fail
          ? (throw http.ClientException('down'))
          : http.Response(jsonEncode(rep.body()), 200, headers: {'x-meshsonar-cache': 'offline', 'x-meshsonar-as-of': '2026-10-24T20:00:00.000Z'}));
      await tester.pumpWidget(_app(RegionReportExportSheet(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: c, now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('export-error')), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Offline - as of 2h ago'), findsOneWidget);
    });
  });
}
