// The Region tab registers the RF and Growth tabs (after Analysis, as on the website's /analysis) and the Export
// region report action, which opens the export sheet for the viewed region.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/ui/region/region_report_export_sheet.dart';

import '../fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);

void main() {
  testWidgets('RF and Growth tabs sit after Analysis; Export opens the sheet', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.client.regionsIndexResult = const [cmh];
    await h.pumpApp(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    final labels = tester.widgetList<Tab>(find.byType(Tab)).map((t) => t.text).toList();
    expect(labels, ['Overview', 'Repeaters', 'Observers', 'Packets', 'Analysis', 'RF', 'Growth', 'Reports', 'Stats', 'Live']);
    await tester.tap(find.byKey(const Key('region-report-export')));
    await tester.pump();
    expect(find.byType(RegionReportExportSheet), findsOneWidget);
    await tester.pumpAndSettle();
  });
}
