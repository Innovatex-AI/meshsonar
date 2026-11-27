// Region RF and Growth tabs and the region report export sheet: ready (numbers in semantics, the silent observer named,
// local hours), pending/empty with the server's reason, error + Retry that recovers, 404 "not published", the offline
// "as of" label from the ETag cache, firmware hidden while empty, and exports with the website's file names and bytes.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/ui/region/region_report_export_sheet.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../core/region_report_export_test.dart' as rep;

final _now = DateTime.utc(2026, 10, 24, 22);

Widget _app(Widget child, {Brightness b = Brightness.light}) =>
    MaterialApp(theme: meshSonarTheme(b), home: Scaffold(body: child));

http.Client _json(Object body, {Map<String, String> headers = const {}, int code = 200}) =>
    MockClient((_) async => http.Response(jsonEncode(body), code, headers: headers));

void main() {
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
      // Build 76: the single-table files are folded away until asked for.
      expect(find.byKey(const Key('export-table-coverage')), findsNothing);
      await tester.scrollUntilVisible(find.byKey(const Key('export-tables-toggle')), 200);
      await tester.tap(find.byKey(const Key('export-tables-toggle')));
      await tester.pumpAndSettle();
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
      await tester.scrollUntilVisible(find.byKey(const Key('export-tables-toggle')), 200);
      await tester.tap(find.byKey(const Key('export-tables-toggle')));
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
      await tester.tap(find.byKey(const Key('export-retry')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Offline - as of 2 h ago'), findsOneWidget);
    });
  });
}
