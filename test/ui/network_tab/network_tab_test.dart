// The Network tab (AZ-3.1; the Analyze tab until build 71). It replaces the old Region area's 13-tab bar
// (test/ui/region/region_hub_tabs_test.dart, removed with that bar): five sections, every old view still reachable,
// the region header (pulse chip from GET /v1/pulse, summary line, Export region report, switcher), the shell states,
// and deep links that open the right section.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart' show CmatException;
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/v1/network_api.dart';
import 'package:meshsonar/ui/region/packet_detail_screen.dart';
import 'package:meshsonar/ui/region/region_report_export_sheet.dart';
import 'package:meshsonar/ui/shell/network_tab.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import '../fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();

/// /v1 answers from the contract fixtures; anything else 404 (not live), so the panels use their own fallbacks.
void useV1Fixtures({bool pulse = true}) {
  resetV1NotLive();
  networkApiFactory = (b) => NetworkApi(b, client: MockClient((r) async {
        switch (r.url.path) {
          case '/v1/summary':
            return http.Response(fixture('summary'), 200, headers: {'content-type': 'application/json'});
          case '/v1/pulse':
            return pulse ? http.Response(fixture('pulse'), 200, headers: {'content-type': 'application/json'}) : http.Response('', 404);
        }
        return http.Response('', 404);
      }));
  addTearDown(() => networkApiFactory = (b) => NetworkApi(b));
}

Future<Harness> pumpNetwork(WidgetTester tester, {List<RegionIndexEntry> regions = const [cmh]}) async {
  useTallScreen(tester);
  final h = Harness();
  h.client.regionsIndexResult = regions;
  await h.pumpApp(tester);
  await tester.pumpAndSettle();
  await openRegionTab(tester);
  await tester.pumpAndSettle();
  return h;
}

Future<void> section(WidgetTester tester, String name, {int? sub}) async {
  await tester.tap(find.byKey(Key('network-section-$name')));
  await tester.pump();
  if (sub != null) {
    await tester.tap(find.byKey(Key('network-sub-$name-$sub')));
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 500));
}

/// A few frames: the link reaches the inbox, the shell switches, the tab takes the request, the page is built.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('the tab is called Network and shows the five sections, Now first', (tester) async {
    useV1Fixtures();
    await pumpNetwork(tester);
    expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text('Network')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text('Analyze')), findsNothing);
    final labels = [for (final s in NetworkSection.values) s.label];
    expect(labels, ['Now', 'Packets', 'Nodes', 'Map', 'Insights']);
    for (final s in NetworkSection.values) {
      expect(find.descendant(of: find.byKey(const Key('network-sections')), matching: find.byKey(Key('network-section-${s.name}'))), findsOneWidget);
    }
    expect(find.byKey(const Key('network-section-body-now')), findsOneWidget);
    expect(find.byKey(const Key('region-title')), findsOneWidget);
    expect(find.text('Columbus, US'), findsOneWidget);
    // The section bar sits below the content on a phone (thumb reach).
    final bar = tester.getCenter(find.byKey(const Key('network-sections')));
    final body = tester.getCenter(find.byKey(const Key('network-section-body-now')));
    expect(bar.dy, greaterThan(body.dy));
  });

  testWidgets('every view of the old 13 tabs is reachable from a section', (tester) async {
    useV1Fixtures();
    await pumpNetwork(tester);
    // Now: Findings (old "Analyze") and Overview.
    expect(find.byKey(const Key('network-now-findings')), findsOneWidget);
    await section(tester, 'now', sub: 1);
    expect(find.byKey(const Key('network-now-overview')), findsOneWidget);
    // Packets: List (old "Packets") and Live (old "Live").
    await section(tester, 'packets', sub: 0);
    expect(find.byKey(const Key('network-packets-list')), findsOneWidget);
    await section(tester, 'packets', sub: 1);
    expect(find.byKey(const Key('network-packets-live')), findsOneWidget);
    // Nodes: Repeaters and Observers.
    await section(tester, 'nodes', sub: 0);
    expect(find.byKey(const Key('network-nodes-repeaters')), findsOneWidget);
    expect(find.byKey(const Key('network-packets-live')), findsNothing, reason: 'a hidden section is not built (no live stream behind it)');
    await section(tester, 'nodes', sub: 1);
    expect(find.byKey(const Key('network-nodes-observers')), findsOneWidget);
    // Map: the placeholder that opens the full map.
    await section(tester, 'map');
    expect(find.byKey(const Key('network-map-placeholder')), findsOneWidget);
    expect(find.byKey(const Key('network-map-open')), findsOneWidget);
    // Insights: Analysis, RF, Growth, Reports, Stats, Silent, Wardrive, each its own page.
    await section(tester, 'insights');
    for (final id in ['analysis', 'rf', 'growth', 'reports', 'stats', 'silent', 'wardrive']) {
      final row = find.byKey(Key('insight-$id'));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(Key('insight-page-$id')), findsOneWidget, reason: id);
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }
    // The section choice survives a trip to another tab.
    await tapShellTab(tester, 'Plan');
    await openRegionTab(tester);
    expect(find.byKey(const Key('network-insights-list')), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('region header: pulse chip from /v1/pulse, summary line, Export opens the sheet', (tester) async {
    useV1Fixtures();
    await pumpNetwork(tester);
    expect(find.byKey(const Key('pulse-chip')), findsOneWidget);
    expect(find.textContaining('Riverside RPT went quiet'), findsOneWidget, reason: 'warn before info');
    expect(find.text('640 packets last hour · 151 repeaters heard · 26 observers online'), findsOneWidget);
    await tester.tap(find.byKey(const Key('pulse-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pulse-sheet')), findsOneWidget);
    expect(find.text('Traffic 2.4x the usual for a Thursday morning'), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('region-report-export')));
    await tester.pump();
    expect(find.byType(RegionReportExportSheet), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('the pulse chip hides itself while the server has no /v1/pulse', (tester) async {
    useV1Fixtures(pulse: false);
    await pumpNetwork(tester);
    expect(find.byKey(const Key('pulse-chip')), findsNothing);
    expect(find.byKey(const Key('pulse-chip-hidden')), findsOneWidget);
  });

  group('shell states', () {
    testWidgets('empty: no region to show', (tester) async {
      useV1Fixtures();
      await pumpNetwork(tester, regions: const []);
      expect(find.byKey(const Key('network-empty')), findsOneWidget);
      expect(find.text('Choose a region'), findsOneWidget);
      expect(find.byKey(const Key('network-sections')), findsNothing);
    });

    testWidgets('offline: the region list never loaded and the server cannot be reached', (tester) async {
      useV1Fixtures();
      useTallScreen(tester);
      final h = Harness();
      h.client.regionsIndexError = const CmatException('No connection to the server.');
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openRegionTab(tester);
      expect(find.byKey(const Key('network-offline')), findsOneWidget);
      h.client.regionsIndexError = null;
      h.client.regionsIndexResult = const [cmh];
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-sections')), findsOneWidget, reason: 'Try again loads the regions');
    });

    testWidgets('error: the server answered with an error', (tester) async {
      useV1Fixtures();
      useTallScreen(tester);
      final h = Harness();
      h.client.regionsIndexError = const CmatException('Server error', status: 500);
      await h.pumpApp(tester);
      await tester.pumpAndSettle();
      await openRegionTab(tester);
      expect(find.byKey(const Key('network-error')), findsOneWidget);
    });
  });

  group('deep links open the right section', () {
    testWidgets('an Insights link opens that page', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      await tapShellTab(tester, 'Plan');
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/insights?tab=signal'));
      await frames(tester);
      expect(find.byKey(const Key('insight-page-rf')), findsOneWidget, reason: 'tab=signal is the RF page');
      expect(find.byType(NetworkTab, skipOffstage: false), findsOneWidget);
      expect(ShellScope.maybeOf(tester.element(find.byType(NetworkTab, skipOffstage: false)))!.tab, AppTab.network);
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('network-insights-list')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a packet link opens Packets and the packet', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('meshsonar://network/packets/C4B06EE8FC39B187?region=cmh'));
      await frames(tester);
      expect(find.byType(PacketDetailScreen), findsOneWidget);
      expect(tester.widget<PacketDetailScreen>(find.byType(PacketDetailScreen)).hash, 'c4b06ee8fc39b187');
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('network-packets-list')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('an observers link opens Nodes > Observers; a plan link still goes to Plan', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/observers'));
      await frames(tester);
      expect(find.byKey(const Key('network-nodes-observers')), findsOneWidget);
      expect(h.state.planInbox.isEmpty, isTrue);
      expect(h.state.offerLink(Uri.parse('https://meshsonar.com/share/plan#abc')), isTrue);
      expect(h.state.networkInbox.isEmpty, isTrue, reason: 'plan links never reach the Network inbox');
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
