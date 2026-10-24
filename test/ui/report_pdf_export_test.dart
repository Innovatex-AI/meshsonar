// PDF export from the UI (stream 5 WP5): the drive report's Export menu writes a real .pdf through the share seam (Barlow
// loaded from the app's bundled fonts), says the file shows where you drove, and is disabled when there is nothing to
// put in it; the region export sheet offers the PDF too and hands over PDF bytes with the website-style file name.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/region/region_report_export_sheet.dart';
import 'package:meshsonar/ui/report/drive_report_screen.dart';
import 'package:meshsonar/ui/theme.dart';

import 'fakes.dart';
import 'report_v2_screen_test.dart' show radioDrive, openReport, t0;

/// Real IO (font assets, file writes, the PDF itself) runs outside the fake clock; then its callbacks land.
Future<void> settleIo(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump();
  }
}

void main() {
  testWidgets('drive report Export > PDF shares one .pdf file', (tester) async {
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await tester.tap(find.byKey(const Key('report-export')));
    await tester.pumpAndSettle();
    expect(find.text('Contains where you drove (grid cells)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report-export-pdf')));
    await tester.pump();
    await settleIo(tester, () => h.shared.isNotEmpty);
    expect(h.shared, hasLength(1));
    expect(h.shared.single.path, endsWith('meshsonar-report-rf.pdf'));
    final bytes = (await tester.runAsync(() => h.shared.single.readAsBytes()))!;
    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(4000));
  });

  testWidgets('a drive with no pings: the PDF item is disabled, never an empty file', (tester) async {
    final h = Harness();
    h.store.seed(DriveSession(id: 'empty', startedAt: t0), const []);
    useTallScreen(tester);
    await h.pumpApp(tester);
    openDriveReport(tester.element(find.byType(Scaffold).first), 'empty');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('report-export')));
    await tester.pumpAndSettle();
    expect(tester.widget<PopupMenuItem<String>>(find.byKey(const Key('report-export-pdf'))).enabled, isFalse);
  });

  testWidgets('region export sheet: PDF bytes with the region file name', (tester) async {
    final body = File('test/fixtures/region_report_cmh.json').readAsStringSync();
    final shared = <(String, Uint8List)>[];
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      home: Scaffold(
        body: RegionReportExportSheet(
          baseUrl: 'https://cmh.meshsonar.com',
          regionSlug: 'cmh',
          client: MockClient((_) async => http.Response(body, 200)),
          now: () => DateTime.utc(2026, 10, 24, 3),
          share: (n, c) async {},
          shareBytes: (n, b) async => shared.add((n, b)),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-pdf')));
    await tester.pump();
    await settleIo(tester, () => shared.isNotEmpty);
    expect(shared.single.$1, 'cmh-region-report.pdf');
    expect(latin1.decode(shared.single.$2.sublist(0, 5)), '%PDF-');
  });
}
