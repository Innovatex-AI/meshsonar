// The Network tab (build 71: the site in the app; AZ-3.1; the Analyze tab until build 71): one header line (region name
// that opens the switcher, pulse chip from GET /v1/pulse, search, one overflow menu with Share link and Export region
// report), ONE scrolling strip of eight sections and no second bottom bar, "All regions" (hub summary, global search,
// busiest regions from GET /v1/regions/busy), the shell states, and deep links that open the right section.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart' show CmatException;
import 'package:meshsonar/core/network_request.dart' show networkHubSections, networkRegionSections;
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/v1/busy_regions_api.dart';
import 'package:meshsonar/core/v1/network_api.dart';
import 'package:meshsonar/core/v1/packets_api.dart' show PacketsApi, packetsApiFactory;
import 'package:meshsonar/ui/network/analytics/analytics_section.dart';
import 'package:meshsonar/ui/network/channels/channels_section.dart';
import 'package:meshsonar/ui/network/network_header.dart';
import 'package:meshsonar/ui/network/network_sections.dart';
import 'package:meshsonar/ui/network/network_share.dart';
import 'package:meshsonar/ui/network/tools/tools_section.dart';
import 'package:meshsonar/ui/network/packets/packet_detail_screen.dart';
import 'package:meshsonar/ui/region/region_report_export_sheet.dart';
import 'package:meshsonar/ui/shell/network_tab.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import '../fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);

const day = RegionIndexEntry(code: 'DAY', slug: 'day', name: 'Dayton, US', url: 'https://day.meshsonar.com', bbox: [-84.6, 39.5, -83.9, 40.1]);

/// `GET /v1/regions/busy` in the contract envelope (the summary fixture's meta), busiest first.
String busyBody(List<Map<String, Object>> rows) {
  final env = jsonDecode(fixture('summary')) as Map<String, dynamic>;
  return jsonEncode({'data': rows, 'meta': env['meta']});
}

final busyRows = [
  {'region': {'slug': 'day', 'name': 'Dayton, US'}, 'packets': 412, 'observations': 900, 'packetsPerMin': 41.2},
  {'region': {'slug': 'cmh', 'name': 'Columbus, US'}, 'packets': 37, 'observations': 80, 'packetsPerMin': 3.7},
];

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();

/// /v1 answers from the contract fixtures; anything else 404 (not live), so the panels use their own fallbacks.
void useV1Fixtures({bool pulse = true, int busyStatus = 200, List<Uri>? requests}) {
  resetV1NotLive();
  networkApiFactory = (b) => NetworkApi(b, client: MockClient((r) async {
        requests?.add(r.url);
        switch (r.url.path) {
          case '/v1/regions/busy':
            return busyStatus == 200 ? http.Response(busyBody(busyRows), 200, headers: {'content-type': 'application/json'}) : http.Response('', busyStatus);
          case '/v1/summary':
            return http.Response(fixture('summary'), 200, headers: {'content-type': 'application/json'});
          case '/v1/pulse':
            return pulse ? http.Response(fixture('pulse'), 200, headers: {'content-type': 'application/json'}) : http.Response('', 404);
        }
        return http.Response('', 404);
      }));
  addTearDown(() => networkApiFactory = (b) => NetworkApi(b));
  // Packets (AZ-3.2): the list and detail from the contract fixtures.
  packetsApiFactory = (b) => PacketsApi(b, client: MockClient((r) async {
        final p = r.url.path;
        if (p == '/v1/packets') return http.Response(fixture('packets'), 200, headers: {'content-type': 'application/json'});
        if (p == '/v1/packets/c4b06ee8fc39b187') return http.Response(fixture('packet-detail.grp-txt-outside-ambiguous'), 200, headers: {'content-type': 'application/json'});
        if (p.endsWith('/observations')) return http.Response(fixture('packet-observations'), 200, headers: {'content-type': 'application/json'});
        return http.Response('', 404);
      }));
  addTearDown(() => packetsApiFactory = (b) => PacketsApi(b));
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
  // The strip scrolls sideways: bring the name into view first.
  await tester.ensureVisible(find.byKey(Key('network-section-$name')));
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.byKey(Key('network-section-$name')));
  await tester.pump();
  if (sub != null) {
    await tester.tap(find.byKey(Key('network-sub-$name-$sub')));
    await tester.pump();
  }
  // Two timed frames: the strip's 200 ms scroll to the picked name starts on the first and ends on the second.
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

/// Closes the pages a section opened over the shell (a site page, a tool, a channel reader).
Future<void> popPages(WidgetTester tester) async {
  tester.state<NavigatorState>(find.byType(Navigator).first).popUntil((r) => r.isFirst);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

/// A few frames: the link reaches the inbox, the shell switches, the tab takes the request, the page is built.
Future<void> frames(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('the tab is called Network and shows ONE strip of seven sections under a one-line header, Live first and no Home, no second bottom bar', (tester) async {
    useV1Fixtures();
    await pumpNetwork(tester);
    expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text('Network')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text('Analyze')), findsNothing);
    final labels = [for (final s in networkRegionSections) s.label];
    expect(labels, ['Live', 'Packets', 'Nodes', 'Channels', 'Observers', 'Analytics', 'Tools']);
    for (final s in networkRegionSections) {
      expect(find.descendant(of: find.byKey(const Key('network-sections')), matching: find.byKey(Key('network-section-${s.name}'), skipOffstage: false)), findsOneWidget,
          reason: s.name);
    }
    // Build 72: no Home section; the tab opens on Live.
    for (final gone in ['network-section-home', 'network-section-regions', 'network-section-body-home', 'network-sub-home', 'network-summary']) {
      expect(find.byKey(Key(gone), skipOffstage: false), findsNothing, reason: gone);
    }
    expect(find.text('Home'), findsNothing);
    expect(find.byKey(const Key('network-section-body-live')), findsOneWidget);
    expect(find.byKey(const Key('live-map')), findsOneWidget, reason: 'the Network tab opens on Live');
    final first = tester.getRect(find.byKey(const Key('network-section-live')));
    for (final s in networkRegionSections.skip(1)) {
      expect(tester.getRect(find.byKey(Key('network-section-${s.name}'), skipOffstage: false)).left, greaterThan(first.left), reason: 'Live is the first name on the strip');
    }
    expect(find.byKey(const Key('region-title')), findsOneWidget);
    expect(find.text('Columbus, US'), findsOneWidget);
    // Header 48 pt, strip 44 pt, then the body: the strip sits ABOVE the content and nothing sits between the body and the tab bar.
    expect(tester.getSize(find.byKey(const Key('network-header'))).height, 48);
    final strip = tester.getRect(find.byType(NetworkSectionStrip));
    expect(strip.height, 44);
    final head = tester.getRect(find.byKey(const Key('network-header')));
    final bodyRect = tester.getRect(find.byKey(const Key('network-section-body-live')));
    expect(head.bottom, lessThanOrEqualTo(strip.top));
    expect(strip.bottom, lessThanOrEqualTo(bodyRect.top));
    final tabs = tester.getRect(find.byKey(const Key('shell-tabs')));
    expect(bodyRect.bottom, closeTo(tabs.top, 1), reason: 'the body runs down to the tab bar: no second bar');
    // The strip scrolls sideways (seven names do not fit a phone).
    await section(tester, 'tools');
    expect(find.byType(ToolsSection), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('every section is reachable; only the shown one is built; Packets has no Live list, Nodes no Observers switch, no Insights rows', (tester) async {
    useV1Fixtures();
    await pumpNetwork(tester);
    // Live first: the tab opens on the live map.
    expect(find.byKey(const Key('live-map')), findsOneWidget);
    // Packets: the list only.
    await section(tester, 'packets');
    expect(find.byKey(const Key('network-packets-list')), findsOneWidget);
    expect(find.byKey(const Key('network-sub-packets')), findsNothing, reason: 'the Live list sub-view is gone');
    expect(find.byKey(const Key('network-packets-live')), findsNothing);
    expect(find.byKey(const Key('live-map')), findsNothing, reason: 'a hidden section is not built');
    // Live: the live map with replay (the old Map).
    await section(tester, 'live');
    expect(find.byKey(const Key('live-map')), findsOneWidget);
    // Build 71: the way to the coverage map is in the Live panel (collapsed on a phone; a tap on its header opens it).
    if (find.byKey(const Key('live-map-open-full')).evaluate().isEmpty) {
      await tester.tap(find.byKey(const Key('live-panel-header')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.byKey(const Key('live-map-open-full')), findsOneWidget);
    expect(find.byKey(const Key('network-packets-list')), findsNothing, reason: 'a hidden section is not built (no polling behind the map)');
    // Nodes: the directory; Observers is its own section.
    await section(tester, 'nodes');
    expect(find.byKey(const Key('network-nodes-directory')), findsOneWidget);
    expect(find.byKey(const Key('network-sub-nodes')), findsNothing);
    expect(find.byKey(const Key('live-map')), findsNothing, reason: 'the live map is not kept alive behind another section');
    await section(tester, 'observers');
    expect(find.byKey(const Key('network-observers')), findsOneWidget);
    expect(find.byKey(const Key('network-nodes-directory')), findsNothing);
    // Channels, Analytics, Tools: the build 71 sections, for the region host.
    await section(tester, 'channels');
    final ch = tester.widget<ChannelsSection>(find.byType(ChannelsSection));
    expect((ch.baseUrl, ch.regionSlug, ch.initialChannelId), ('https://cmh.meshsonar.com', 'cmh', null));
    await section(tester, 'analytics');
    final an = tester.widget<AnalyticsSection>(find.byType(AnalyticsSection));
    expect((an.baseUrl, an.regionSlug, an.initialTab), ('https://cmh.meshsonar.com', 'cmh', null));
    expect(find.byType(ChannelsSection), findsNothing);
    // Build 72: what Home held is the first two rows of Analytics, each opening its native panel in place.
    final findings = find.byKey(const Key('analytics-tab-findings')), overview = find.byKey(const Key('analytics-tab-region-overview'));
    expect(find.descendant(of: findings, matching: find.text('Findings')), findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('Region overview')), findsOneWidget);
    expect(tester.getTopLeft(findings).dy, lessThan(tester.getTopLeft(overview).dy));
    expect(tester.getTopLeft(overview).dy, lessThan(tester.getTopLeft(find.byKey(const Key('analytics-tab-overview'))).dy), reason: 'above the site tabs');
    await tester.tap(findings);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('network-findings')), findsOneWidget);
    expect(find.byKey(const Key('what-changed')), findsOneWidget, reason: 'the "What changed" card moved with Findings');
    expect(find.byKey(const Key('network-sections')), findsOneWidget, reason: 'in place: the strip stays');
    await tester.tap(find.byKey(const Key('in-place-back')));
    await tester.pump();
    expect(find.byKey(const Key('analytics-section')), findsOneWidget);
    await tester.tap(overview);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const Key('network-region-overview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('in-place-back')));
    await tester.pump();
    await section(tester, 'tools');
    final tl = tester.widget<ToolsSection>(find.byType(ToolsSection));
    expect((tl.baseUrl, tl.regionSlug, tl.initialTool), ('https://cmh.meshsonar.com', 'cmh', null));
    // The seven old Insights entries are gone from the Network UI.
    for (final id in ['analysis', 'rf', 'growth', 'reports', 'stats', 'silent', 'wardrive']) {
      expect(find.byKey(Key('insight-$id')), findsNothing, reason: id);
    }
    // The section choice survives a trip to another tab.
    await tapShellTab(tester, 'Plan');
    await openRegionTab(tester);
    expect(find.byType(ToolsSection), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('region header: pulse chip from /v1/pulse, no summary line, Export region report in the overflow menu', (tester) async {
    useV1Fixtures();
    await pumpNetwork(tester);
    expect(find.byKey(const Key('pulse-chip')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('pulse-chip')), matching: find.text('Unusual: Riverside RPT went quiet +1')), findsOneWidget,
        reason: 'warn before info');
    // Build 72: the summary line went with Home (the Live panel header shows observers and the packet count).
    expect(find.text('640 packets last hour · 151 repeaters heard · 26 observers online'), findsNothing);
    expect(find.byKey(const Key('network-summary')), findsNothing);
    await tester.tap(find.byKey(const Key('pulse-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pulse-sheet')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('pulse-sheet')), matching: find.text('Traffic 2.4x the usual for a Thursday morning')), findsOneWidget);
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('region-report-export')), findsNothing, reason: 'one overflow (an action sheet), not a row of icons');
    await tester.tap(find.byKey(const Key('network-overflow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-share')), findsOneWidget);
    await tester.tap(find.byKey(const Key('region-report-export')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RegionReportExportSheet), findsOneWidget);
    await tester.pumpAndSettle();
  });

  for (final width in [320.0, 375.0]) {
    testWidgets('header at ${width.toInt()} pt with a long region name: no overflow; the name gives way first, then the pulse chip; the icons keep 44 pt', (tester) async {
      useV1Fixtures();
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final scale in [1.0, 2.0]) {
        await tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
          home: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              titleSpacing: 0,
              toolbarHeight: NetworkHeaderBar.height,
              title: NetworkHeaderBar(
                title: 'Minneapolis-Saint Paul and the Upper Mississippi Valley, US',
                pulseBaseUrl: 'https://cmh.meshsonar.com',
                onRegion: () {},
                onSearch: () {},
                onShare: () {},
                onExport: () {},
              ),
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(NetworkSectionStrip.height),
                child: NetworkSectionStrip(selected: NetworkSection.live, onChanged: (_) {}),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'no overflow at $width pt, text x$scale');
        final header = tester.getRect(find.byKey(const Key('network-header')));
        expect(header.width, width);
        expect(header.height, 48);
        for (final k in ['network-search', 'network-overflow']) {
          final r = tester.getRect(find.byKey(Key(k)));
          expect(r.size, const Size(44, 44), reason: '$k keeps its full size');
          expect(r.right, lessThanOrEqualTo(width));
        }
        final chip = tester.getRect(find.byKey(const Key('pulse-chip')));
        final name = tester.getRect(find.byKey(const Key('region-title')));
        expect(name.right, lessThanOrEqualTo(chip.left), reason: 'the name ends before the chip');
        expect(chip.right, lessThanOrEqualTo(tester.getRect(find.byKey(const Key('network-search'))).left + 0.01));
        if (width < 375) {
          expect(chip.width, 44, reason: 'narrow: the pulse chip is only its dot');
          expect(find.textContaining('Unusual'), findsNothing);
        } else {
          expect(chip.width, inInclusiveRange(60, 150), reason: 'the chip keeps its label, up to 150 pt');
          expect(find.textContaining('Unusual'), findsOneWidget);
          expect(name.width, greaterThanOrEqualTo(80), reason: 'the ellipsized name still has room');
        }
        final title = tester.renderObject<RenderParagraph>(find.byKey(const Key('region-title')));
        expect(title.didExceedMaxLines || title.size.width < title.getMaxIntrinsicWidth(double.infinity), isTrue, reason: 'the long name is ellipsized');
        // The strip still reaches every section.
        await tester.ensureVisible(find.byKey(const Key('network-section-tools')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('the whole tab at 320 pt: header, strip and Home lay out without overflow', (tester) async {
    useV1Fixtures();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = Harness();
    h.client.regionsIndexResult = const [cmh];
    await h.pumpApp(tester, lastTab: null);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-tab')), findsOneWidget, reason: 'a fresh install opens Network');
    expect(tester.getSize(find.byKey(const Key('network-header'))).width, 320);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('AZ-3.5: the header search icon finds a region locally while /v1 is not live and opens it', (tester) async {
    useV1Fixtures();
    final h = await pumpNetwork(tester);
    await section(tester, 'analytics');
    expect(tester.getSize(find.byKey(const Key('network-search'))), const Size(44, 44));
    await tester.tap(find.byKey(const Key('network-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-search-sheet')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('network-search-input')), 'colum');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-search-local')), findsOneWidget, reason: 'says it searched what the phone has');
    final hit = find.byKey(const ValueKey('network-search-hit-region-Columbus, US'));
    expect(hit, findsOneWidget);
    await tester.tap(hit);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('network-search-sheet')), findsNothing);
    expect(find.byKey(const Key('network-section-body-live')), findsOneWidget, reason: 'a region hit opens the region on Live');
    expect(h.client.regionsIndexResult, isNotEmpty);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('AZ-3.5: Share (overflow menu) sends the region-host link of the shown section', (tester) async {
    useV1Fixtures();
    final shared = <String>[];
    debugNetworkShare = (text, subject) => shared.add(text);
    addTearDown(() => debugNetworkShare = null);
    await pumpNetwork(tester);
    for (final (name, link) in [('nodes', 'https://cmh.meshsonar.com/nodes'), ('live', 'https://cmh.meshsonar.com/live'), ('analytics', 'https://cmh.meshsonar.com/analytics')]) {
      await section(tester, name);
      await tester.tap(find.byKey(const Key('network-overflow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('network-share')));
      await tester.pumpAndSettle();
      expect(shared.last, link);
    }
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('the pulse chip hides itself while the server has no /v1/pulse', (tester) async {
    useV1Fixtures(pulse: false);
    await pumpNetwork(tester);
    expect(find.byKey(const Key('pulse-chip')), findsNothing);
    expect(find.byKey(const Key('pulse-chip-hidden')), findsOneWidget);
  });

  group('All regions', () {
    Future<Harness> openAll(WidgetTester tester, {int busyStatus = 200, List<Uri>? requests}) async {
      useV1Fixtures(busyStatus: busyStatus, requests: requests);
      final h = await pumpNetwork(tester, regions: const [cmh, day]);
      await tester.tap(find.byKey(const Key('network-region-button')));
      await tester.pumpAndSettle();
      final all = find.byKey(const Key('region-all'));
      await tester.ensureVisible(all);
      await tester.pumpAndSettle();
      await tester.tap(all);
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('the switcher entry shows the network summary, the global search and the busiest regions; four sections; no map', (tester) async {
      final requests = <Uri>[];
      final h = await openAll(tester, requests: requests);
      expect(tester.widget<Text>(find.byKey(const Key('region-title'))).data, 'All regions');
      expect(find.byKey(const Key('network-all-regions')), findsOneWidget);
      for (final s in NetworkSection.values) {
        expect(find.byKey(Key('network-section-${s.name}'), skipOffstage: false), networkHubSections.contains(s) ? findsOneWidget : findsNothing, reason: s.name);
      }
      expect(networkHubSections, [NetworkSection.regions, NetworkSection.channels, NetworkSection.analytics, NetworkSection.tools]);
      expect(tester.widget<Text>(find.byKey(const Key('network-section-regions'))).data, 'Regions', reason: 'All regions opens on Regions');
      expect(find.byKey(const Key('all-regions-every-region'), skipOffstage: false), findsOneWidget);
      expect(find.byKey(const Key('network-summary')), findsOneWidget, reason: 'the network summary, from the hub');
      expect(find.byKey(const Key('network-search-field')), findsOneWidget, reason: 'global search');
      expect(find.byKey(const Key('live-map')), findsNothing, reason: 'no world live map on the phone');
      final hub = Uri.parse(h.state.settings.serverUrl).host;
      final busy = requests.where((u) => u.path == '/v1/regions/busy').toList();
      expect(busy.length, 1, reason: 'loaded once, no polling');
      expect(busy.single.host, hub);
      expect(busy.single.queryParameters['limit'], '20');
      // Busiest first, each with its code and rate.
      final dayRow = find.byKey(const Key('busy-region-day')), cmhRow = find.byKey(const Key('busy-region-cmh'));
      expect(find.descendant(of: dayRow, matching: find.text('Dayton, US')), findsOneWidget);
      expect(find.descendant(of: dayRow, matching: find.text('41 packets a minute · DAY')), findsOneWidget);
      expect(find.descendant(of: cmhRow, matching: find.text('3.7 packets a minute · CMH')), findsOneWidget);
      expect(tester.getTopLeft(dayRow).dy, lessThan(tester.getTopLeft(cmhRow).dy));
      // The hub sections get the hub host and no region.
      await section(tester, 'channels');
      final ch = tester.widget<ChannelsSection>(find.byType(ChannelsSection));
      expect((Uri.parse(ch.baseUrl).host, ch.regionSlug), (hub, null));
      await section(tester, 'tools');
      final tl = tester.widget<ToolsSection>(find.byType(ToolsSection));
      expect((Uri.parse(tl.baseUrl).host, tl.regionSlug), (hub, null));
      // The global search opens with no region.
      await section(tester, 'regions');
      await tester.tap(find.byKey(const Key('network-search')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-search-sheet')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('network-search-input')), 'dayt');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('network-search-hit-region-Dayton, US')), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a busiest-regions row opens that region\'s Live section and the region becomes the remembered one', (tester) async {
      final h = await openAll(tester);
      expect(h.state.viewingRegion!.code, 'CMH');
      await tester.tap(find.byKey(const Key('busy-region-day')));
      await frames(tester);
      expect(find.byKey(const Key('network-all-regions')), findsNothing);
      expect(find.byKey(const Key('live-map')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('region-title'))).data, 'Dayton, US');
      expect(h.state.viewingRegion!.code, 'DAY');
      expect(h.state.settings.regionManual, 'DAY', reason: 'saved as the manual pick: remembered across a restart');
      expect(h.settings.saved.regionManual, 'DAY', reason: 'written to settings');
      for (final s in networkRegionSections) {
        expect(find.byKey(Key('network-section-${s.name}'), skipOffstage: false), findsOneWidget, reason: 'the region sections are back');
      }
      expect(find.byKey(const Key('network-section-regions'), skipOffstage: false), findsNothing);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('"Back to <region>" leaves All regions; so does picking a region in the switcher', (tester) async {
      final h = await openAll(tester);
      await tester.tap(find.byKey(const Key('all-regions-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-all-regions')), findsNothing);
      expect(find.byKey(const Key('network-section-body-live')), findsOneWidget, reason: 'back in the region, on Live');
      expect(h.state.viewingRegion!.code, 'CMH');
      // Again, then pick Dayton in the switcher.
      await tester.tap(find.byKey(const Key('network-region-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('region-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-all-regions')), findsOneWidget);
      await tester.tap(find.byKey(const Key('network-region-button')));
      await tester.pumpAndSettle();
      final pick = find.byKey(const Key('region-option-DAY'));
      await tester.scrollUntilVisible(pick, 200, scrollable: find.descendant(of: find.byKey(const Key('region-switcher')), matching: find.byType(Scrollable)).first);
      await tester.tap(pick);
      await frames(tester);
      expect(find.byKey(const Key('network-all-regions')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const Key('region-title'))).data, 'Dayton, US');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('busiest regions: a server without the list says so, and the rest of the screen works', (tester) async {
      await openAll(tester, busyStatus: 404);
      expect(find.byKey(const Key('busy-regions-not-live')), findsOneWidget);
      expect(find.byKey(const Key('network-search-field')), findsOneWidget, reason: 'the rest of the screen still works');
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('busiest regions: a server error says so and Try again loads the list', (tester) async {
      await openAll(tester, busyStatus: 500);
      expect(find.byKey(const Key('busy-regions-error')), findsOneWidget);
      expect(find.byKey(const Key('busy-region-day')), findsNothing);
      useV1Fixtures();
      await tester.tap(find.byKey(const Key('busy-regions-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('busy-region-day')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    test('a busiest-regions row parses the hub shape; a row with no slug is skipped', () {
      final r = BusyRegion.tryParse({'region': {'slug': 'CMH', 'name': 'Columbus, US'}, 'packets': 37, 'observations': 80, 'packetsPerMin': 3.7})!;
      expect((r.slug, r.code, r.name, r.packets, r.observations, r.packetsPerMin), ('cmh', 'CMH', 'Columbus, US', 37, 80, 3.7));
      expect(BusyRegion.tryParse({'region': {'slug': 'day'}, 'packets': 50})!.packetsPerMin, 5.0, reason: 'the rate from the 10 minute count');
      expect(BusyRegion.tryParse({'region': {'name': 'x'}}), isNull);
      expect(BusyRegion.tryParse('nope'), isNull);
    });
  });

  group('shell states', () {
    testWidgets('empty: no region to show (a prompt to choose one, never a blank)', (tester) async {
      useV1Fixtures();
      await pumpNetwork(tester, regions: const []);
      expect(find.byKey(const Key('network-empty')), findsOneWidget);
      expect(find.text('Choose a region'), findsOneWidget);
      expect(find.byKey(const Key('network-sections')), findsNothing);
      expect(find.byKey(const Key('network-header')), findsOneWidget);
    });

    testWidgets('a fresh install opens Network before any region is known: the loading or offline view, then the nearest/default region', (tester) async {
      useV1Fixtures();
      useTallScreen(tester);
      final h = Harness();
      h.client.regionsIndexError = const CmatException('No connection to the server.');
      await h.pumpApp(tester, lastTab: null);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-tab')), findsOneWidget);
      expect(find.byKey(const Key('network-offline')), findsOneWidget, reason: 'not a blank');
      h.client.regionsIndexError = null;
      h.client.regionsIndexResult = const [cmh];
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-sections')), findsOneWidget);
      expect(find.text('Columbus, US'), findsOneWidget, reason: 'with no GPS fix and no pick, the default region shows');
      expect(find.byKey(const Key('network-section-body-live')), findsOneWidget, reason: 'a fresh install opens on Live');
      await tester.pump(const Duration(seconds: 2));
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
    testWidgets('an old Insights link opens its Analytics twin; an /analytics/<slug> link opens that tab', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      await tapShellTab(tester, 'Plan');
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/insights?tab=signal'));
      await frames(tester);
      expect(ShellScope.maybeOf(tester.element(find.byType(NetworkTab, skipOffstage: false)))!.tab, AppTab.network);
      expect(tester.widget<AnalyticsSection>(find.byType(AnalyticsSection, skipOffstage: false)).initialTab, 'rf-signal', reason: 'tab=signal is RF signal on the site');
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/analytics/topology'));
      await frames(tester);
      expect(tester.widget<AnalyticsSection>(find.byType(AnalyticsSection, skipOffstage: false)).initialTab, 'topology');
      // Picking the section by hand afterwards shows its list, not the linked tab again.
      await popPages(tester);
      await section(tester, 'packets');
      await section(tester, 'analytics');
      expect(tester.widget<AnalyticsSection>(find.byType(AnalyticsSection, skipOffstage: false)).initialTab, isNull);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('channel, tool, scope audit and status links reach their section with what they name', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/channels/tag:LongFast'));
      await frames(tester);
      expect(tester.widget<ChannelsSection>(find.byType(ChannelsSection, skipOffstage: false)).initialChannelId, 'tag:LongFast');
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/tools/trace/c4b06ee8fc39b187'));
      await frames(tester);
      var t = tester.widget<ToolsSection>(find.byType(ToolsSection, skipOffstage: false));
      expect((t.initialTool, t.initialArg), ('trace', 'c4b06ee8fc39b187'));
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/scope-audit'));
      await frames(tester);
      t = tester.widget<ToolsSection>(find.byType(ToolsSection, skipOffstage: false));
      expect((t.initialTool, t.initialArg), ('scope-audit', null));
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/analytics/prefix-tool?prefix=a7b2'));
      await frames(tester);
      t = tester.widget<ToolsSection>(find.byType(ToolsSection, skipOffstage: false));
      expect((t.initialTool, t.initialArg), ('prefix', 'a7b2'));
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/status'));
      await frames(tester);
      expect(tester.widget<ToolsSection>(find.byType(ToolsSection, skipOffstage: false)).initialTool, 'status');
      // A new link closes the page the last one opened (a tool, a site page) and shows its own view.
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/live'));
      await frames(tester);
      expect(find.byKey(const Key('live-map')), findsOneWidget, reason: 'not hidden under the Status page');
      expect(find.byType(ToolsSection, skipOffstage: false), findsNothing);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('links to the moved Home panels open them in place under Analytics', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('meshsonar://network/analytics/findings?region=cmh'));
      await frames(tester);
      expect(find.byKey(const Key('analytics-native-findings')), findsOneWidget);
      expect(find.byKey(const Key('network-findings')), findsOneWidget);
      h.incomingLinks.add(Uri.parse('meshsonar://network/analytics/region-overview?region=cmh'));
      await frames(tester);
      expect(find.byKey(const Key('network-region-overview')), findsOneWidget);
      // The old region home link opens Live.
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/'));
      await frames(tester);
      expect(find.byKey(const Key('live-map')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a /pulse link opens Live with the pulse sheet', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      await section(tester, 'nodes');
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/pulse'));
      await frames(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('network-section-body-live')), findsOneWidget);
      expect(find.byKey(const Key('pulse-sheet')), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a packet link opens Packets and the packet', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('meshsonar://network/packets/C4B06EE8FC39B187?region=cmh'));
      await frames(tester);
      expect(find.byType(NetworkPacketScreen), findsOneWidget);
      expect(tester.widget<NetworkPacketScreen>(find.byType(NetworkPacketScreen)).hash, 'c4b06ee8fc39b187');
      expect(find.text('anyone hearing Hilltop this morning?'), findsOneWidget, reason: 'the /v1 detail is shown');
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const Key('network-packets-list')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('AZ-3.3: "Show on map" in the packet detail draws that packet on Network > Live', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('meshsonar://network/packets/c4b06ee8fc39b187?region=cmh'));
      await frames(tester);
      final btn = find.byKey(const Key('packet-show-on-map'));
      await tester.scrollUntilVisible(btn, 300, scrollable: find.descendant(of: find.byType(NetworkPacketScreen), matching: find.byType(Scrollable)).first);
      await tester.pump();
      await tester.tap(btn);
      await frames(tester);
      expect(find.byType(NetworkPacketScreen), findsNothing);
      expect(find.byKey(const Key('live-map')), findsOneWidget);
      expect(find.byKey(const Key('live-focus-card')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('AZ-3.3: the packet replay link (/map?panel=live&packet=) opens the live map on that packet', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/map?panel=live&t=2026-11-20T14:02:05.120Z&packet=c4b06ee8fc39b187'));
      await frames(tester);
      expect(find.byKey(const Key('live-map')), findsOneWidget);
      expect(find.byKey(const Key('live-focus-card')), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a packets list link opens Packets with its filters and window', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/packets?type=GRP_TXT&channel=public&window=24h'));
      await frames(tester);
      expect(find.byKey(const Key('network-packets-list')), findsOneWidget);
      expect(find.byKey(const ValueKey('packets-chip-type:GRP_TXT')), findsOneWidget);
      expect(find.byKey(const ValueKey('packets-chip-channel:public')), findsOneWidget);
      expect(tester.widget<ChoiceChip>(find.byKey(const Key('packets-window-24h'))).selected, isTrue);
      expect(find.textContaining('Kestrel-07'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('an observers link opens the Observers section; a plan link still goes to Plan', (tester) async {
      useV1Fixtures();
      final h = await pumpNetwork(tester);
      h.incomingLinks.add(Uri.parse('https://cmh.meshsonar.com/observers'));
      await frames(tester);
      expect(find.byKey(const Key('network-observers')), findsOneWidget);
      expect(h.state.planInbox.isEmpty, isTrue);
      expect(h.state.offerLink(Uri.parse('https://meshsonar.com/share/plan#abc')), isTrue);
      expect(h.state.networkInbox.isEmpty, isTrue, reason: 'plan links never reach the Network inbox');
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
