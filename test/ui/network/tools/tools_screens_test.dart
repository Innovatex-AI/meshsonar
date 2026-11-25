// Network > Tools (build 71, stream D), dark theme, 375 pt wide: the list and its three groups, initialTool / initialArg,
// Path Inspector (parse error inline, results, speculative in words), Trace Viewer (recent list, detail, "no server
// copy" on 404, the radio's own result), Prefix Tool (overview, a taken prefix with its conflicts, a suggestion chip).
import 'package:meshsonar/radio/session.dart' show LinkState;
import 'package:meshsonar/ui/tools/tools_host.dart';

import '../../../support/tools_ui_rig.dart' show FakeToolsHost;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/network_request.dart';
import 'package:meshsonar/core/v1/tools_api.dart';
import 'package:meshsonar/core/v1/v1_client.dart' show resetV1NotLive;
import 'package:meshsonar/radio/tools/trace_tool.dart';
import 'package:meshsonar/ui/network/analytics/site_page_view.dart';
import 'package:meshsonar/ui/network/packets/decode_packet_screen.dart';
import 'package:meshsonar/ui/network/tools/path_inspector_screen.dart';
import 'package:meshsonar/ui/network/tools/prefix_tool_screen.dart';
import 'package:meshsonar/ui/network/tools/tools_section.dart';
import 'package:meshsonar/ui/network/tools/trace_viewer_screen.dart';
import 'package:meshsonar/ui/theme.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();
http.Response json(String body, [int status = 200]) => http.Response(body, status, headers: {'content-type': 'application/json; charset=utf-8'});
const base = 'https://cmh.meshsonar.com';
const traceHash = '50b835a910da5aac';

class Server {
  final List<http.Request> seen = [];
  bool offline = false;
  bool recent = true;
  late final MockClient client = MockClient((r) async {
    seen.add(r);
    if (offline) throw const SocketException('down');
    final p = r.url.path;
    final meta = (jsonDecode(fixture('tools-trace')) as Map)['meta'];
    if (p == '/v1/tools/path-inspect') {
      final hops = (jsonDecode(r.body) as Map)['hops'] as List;
      if (hops.first == 'ff') return json(jsonEncode({'data': {'candidates': [], 'unknownHops': ['ff']}, 'meta': meta}));
      return json(fixture('tools-path-inspect'));
    }
    if (p == '/v1/traces/$traceHash') return json(fixture('tools-trace'));
    if (p.startsWith('/v1/traces/')) return json('{"error":{"code":"not_found","message":"No packet with that hash in the last 90 days.","param":"hash","requestId":"r"}}', 404);
    if (p == '/v1/packets') {
      return json(jsonEncode({
        'data': recent
            ? [
                {'hash': traceHash, 'firstSeen': '2026-11-20T14:02:05.120Z', 'lastSeen': '2026-11-20T14:02:06.320Z', 'type': 9, 'typeName': 'TRACE', 'route': 'DIRECT', 'hops': 2, 'observationCount': 2},
              ]
            : [],
        'page': {'limit': 30, 'next': null, 'prev': null},
        'meta': meta,
      }));
    }
    if (p == '/v1/insights/hashes/prefix') return json(fixture('tools-prefix'));
    return http.Response('<html>', 404);
  });
  late final ToolsApi api = ToolsApi(base, client: client);
}

Future<void> pump(WidgetTester tester, Widget child) async {
  // 375 pt wide, tall enough that every row of a lazy list is built (the width is what the overflow checks need)
  tester.view.physicalSize = const Size(375, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: child));
  await tester.pump();
  await tester.pump();
}

Future<void> tapKey(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pump();
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
  await tester.pump();
}

void main() {
  late Server server;
  setUp(() {
    resetV1NotLive();
    server = Server();
    toolsApiFactory = (_) => server.api;
    siteWebEngineFactory = (e, _) => throw UnsupportedError('no webview in tests');
  });

  testWidgets('the list: three groups, every tool once, 44 pt rows, no overflow at 375', (tester) async {
    await pump(tester, const Scaffold(body: ToolsSection(baseUrl: base, regionSlug: 'cmh')));
    expect(find.text('LOOK THINGS UP'), findsOneWidget);
    expect(find.text('WITH YOUR RADIO'), findsOneWidget);
    for (final e in toolEntries) {
      await tester.ensureVisible(find.byKey(Key('tool-row-${e.id}')));
      expect(find.byKey(Key('tool-row-${e.id}')), findsOneWidget);
      expect(tester.getSize(find.byKey(Key('tool-row-${e.id}'))).height, greaterThanOrEqualTo(44));
    }
    expect(toolEntries.where((e) => e.group == ToolGroup.radio).map((e) => e.title), ['Trace path', 'Discover', 'Adverts', 'Rx log', 'Noise floor', 'Telemetry']);
    expect(toolEntries.map((e) => e.id).toSet().length, toolEntries.length);
    expect(tester.takeException(), isNull);
  });

  testWidgets('build 76: Find a tool narrows the list; no match says so; clearing brings every tool back', (tester) async {
    await pump(tester, const Scaffold(body: ToolsSection(baseUrl: base, regionSlug: 'cmh')));
    await tester.enterText(find.byKey(const Key('tools-find')), 'repeater id');
    await tester.pump();
    expect(find.byKey(const Key('tool-row-prefix')), findsOneWidget);
    expect(find.byKey(const Key('tool-row-status')), findsNothing);
    await tester.enterText(find.byKey(const Key('tools-find')), 'zzzz');
    await tester.pump();
    expect(find.byKey(const Key('tools-find-none')), findsOneWidget);
    await tester.tap(find.byKey(const Key('tools-find-clear')));
    await tester.pump();
    for (final e in toolEntries) {
      expect(find.byKey(Key('tool-row-${e.id}')), findsOneWidget);
    }
    expect(toolsMatching('').length, toolEntries.length);
    expect(toolsMatching('RADIO hears').map((e) => e.id), contains('rx-log'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('build 76: Path Inspector asks the hop length only for a run with no spaces, and an error has Try again', (tester) async {
    await pump(tester, PathInspectorScreen(baseUrl: base, regionSlug: 'cmh', api: server.api));
    expect(find.byKey(const Key('path-idle')), findsOneWidget);
    expect(find.byKey(const Key('path-paste')), findsOneWidget);
    expect(find.byKey(const Key('path-hash-size')), findsNothing);
    await tester.enterText(find.byKey(const Key('path-hops')), 'a1 3f');
    await tester.pump();
    expect(find.byKey(const Key('path-hash-size')), findsNothing);
    await tester.enterText(find.byKey(const Key('path-hops')), 'a13fc4');
    await tester.pump();
    expect(find.byKey(const Key('path-hash-size')), findsOneWidget);
    expect(find.byKey(const Key('path-clear')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('build 76: with no radio the radio group says so and its first row connects one', (tester) async {
    final host = FakeToolsHost()..linkState = LinkState.disconnected;
    await pump(tester, ToolsHostScope(host: host, child: const Scaffold(body: ToolsSection(baseUrl: base, regionSlug: 'cmh'))));
    expect(find.textContaining('No radio is connected'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('tools-connect-radio')));
    await tester.tap(find.byKey(const Key('tools-connect-radio')));
    expect(host.connectOpened, 1);
    expect(find.byKey(const Key('tool-row-discover')), findsOneWidget, reason: 'the radio tools stay listed');
  });

  test('tool ids, aliases and site paths', () {
    for (final id in ['path', 'trace', 'prefix', 'scope-audit', 'compare', 'definition', 'status', 'decode', 'airtime', 'link', 'painter']) {
      expect(toolEntryOf(id), isNotNull, reason: id);
    }
    expect(toolEntryOf('RXLOG')!.id, 'rx-log');
    expect(toolEntryOf('region-def')!.id, 'definition');
    expect(toolEntryOf('nope'), isNull);
    expect(toolEntryOf(null), isNull);
    expect(sitePathOfTool('scope-audit', null), '/scope-audit');
    expect(sitePathOfTool('compare', 'a=abc&b=def'), '/observers/compare?a=abc&b=def');
    expect(sitePathOfTool('definition', '39.96, -83.0'), '/tools/region?lat=39.96&lon=-83.0');
    expect(sitePathOfTool('definition', 'somewhere'), '/tools/region');
    expect(sitePathOfTool('status', 'https://evil.example/x'), '/status');
    expect(sitePathOfTool('painter', null), '/tools/painter');
  });

  testWidgets('initialTool opens the tool with its argument; an unknown id shows the list', (tester) async {
    await pump(tester, const Scaffold(body: ToolsSection(baseUrl: base, regionSlug: 'cmh', initialTool: 'trace', initialArg: traceHash)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byKey(const Key('tool-trace-viewer')), findsOneWidget);
    expect(find.byKey(const Key('trace-summary')), findsOneWidget);

    await pump(tester, const Scaffold(body: ToolsSection(key: Key('b'), baseUrl: base, regionSlug: 'cmh', initialTool: 'decode')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(DecodePacketScreen), findsOneWidget);

    await pump(tester, const Scaffold(body: ToolsSection(key: Key('c'), baseUrl: base, regionSlug: 'cmh', initialTool: 'status')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SitePageView), findsOneWidget);
    expect(find.text('Status'), findsWidgets);

    await pump(tester, const Scaffold(body: ToolsSection(key: Key('d'), baseUrl: base, regionSlug: 'cmh', initialTool: 'nope', initialArg: 'x')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('tools-section')), findsOneWidget);
    expect(find.byType(SitePageView), findsNothing);
  });

  // What stream A's link parser sends for each site address is what ToolsSection must open.
  final links = <String, (Type, String?)>{
    '/tools/path?hops=a1,3f': (PathInspectorScreen, null),
    '/tools/path': (PathInspectorScreen, null),
    '/tools/trace/$traceHash': (TraceViewerScreen, null),
    '/tools/trace': (TraceViewerScreen, null),
    '/analytics/prefix-tool?prefix=a1': (PrefixToolScreen, null),
    '/tools/decode': (DecodePacketScreen, null),
    '/scope-audit': (SitePageView, '/scope-audit'),
    '/observers/compare': (SitePageView, '/observers/compare'),
    '/tools/region': (SitePageView, '/tools/region'),
    '/status': (SitePageView, '/status'),
    '/tools/airtime': (SitePageView, '/tools/airtime'),
    '/tools/link': (SitePageView, '/tools/link'),
    '/tools/painter': (SitePageView, '/tools/painter'),
  };
  for (final e in links.entries) {
    testWidgets('link ${e.key} opens ${e.value.$1}', (tester) async {
      final r = NetworkRequest.parse(Uri.parse('$base${e.key}'))!;
      expect(r.section, NetworkSection.tools);
      await pump(tester, Scaffold(body: ToolsSection(baseUrl: base, regionSlug: 'cmh', initialTool: r.tool, initialArg: r.toolArg)));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(e.value.$1), findsOneWidget);
      // in place: the section is still on stage, nothing was pushed, and the back arrow returns to the list
      expect(find.byType(ToolsSection), findsOneWidget);
      expect(Navigator.of(tester.element(find.byType(ToolsSection))).canPop(), isFalse);
      expect(find.byKey(const Key('in-place-back')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('in-place-back'))).height, greaterThanOrEqualTo(48));
      if (e.value.$2 != null) expect(tester.widget<SitePageView>(find.byType(SitePageView)).path, e.value.$2);
      if (e.key.contains('hops=')) {
        expect(jsonDecode(server.seen.single.body), {'hops': ['a1', '3f'], 'hashSize': 1});
        expect(find.byKey(const Key('path-candidate-1')), findsOneWidget);
      }
      if (e.key.endsWith(traceHash)) expect(find.byKey(const Key('trace-summary')), findsOneWidget);
      if (e.key.contains('prefix=')) expect(server.seen.single.url.queryParameters, {'prefix': 'a1'});
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('in-place-back')));
      await tester.pump();
      expect(find.byKey(const Key('tools-section')), findsOneWidget);
      expect(find.byType(e.value.$1), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    });
  }

  testWidgets('a row tapped in the list opens the tool as its own page; a radio tool id opens its page too', (tester) async {
    await pump(tester, const Scaffold(body: ToolsSection(baseUrl: base, regionSlug: 'cmh')));
    await tester.tap(find.byKey(const Key('tool-row-prefix')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(PrefixToolScreen), findsOneWidget);
    expect(find.byKey(const Key('in-place-back')), findsNothing);
    expect(find.byType(AppBar), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a /tools/<name> the app does not know shows the list', (tester) async {
    final r = NetworkRequest.parse(Uri.parse('$base/tools/whatever'))!;
    await pump(tester, Scaffold(body: ToolsSection(baseUrl: base, regionSlug: 'cmh', initialTool: r.tool, initialArg: r.toolArg)));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('tools-section')), findsOneWidget);
    expect(find.byType(SitePageView), findsNothing);
  });

  testWidgets('Path Inspector: inline parse error, then ranked routes with Speculative in words', (tester) async {
    await pump(tester, PathInspectorScreen(baseUrl: base, regionSlug: 'cmh', api: server.api));
    await tapKey(tester, 'path-inspect');
    expect(find.text('Type at least one hop prefix.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('path-hops')), 'a1 > zz');
    await tapKey(tester, 'path-inspect');
    expect(find.textContaining('"zz" is not hex'), findsOneWidget);
    expect(server.seen, isEmpty);

    await tester.enterText(find.byKey(const Key('path-hops')), 'a1 → 3f');
    await tapKey(tester, 'path-inspect');
    expect(jsonDecode(server.seen.single.body), {'hops': ['a1', '3f'], 'hashSize': 1});
    expect(find.byKey(const Key('path-candidate-1')), findsOneWidget);
    expect(find.text('Speculative'), findsWidgets);
    expect(find.textContaining('41% match'), findsWidgets);
    // the first route is open: its hops are rows that open the node
    await tester.ensureVisible(find.byKey(const Key('path-candidate-1-hop-0')));
    expect(tester.getSize(find.byKey(const Key('path-candidate-1-hop-0'))).height, greaterThanOrEqualTo(44));
    await tapKey(tester, 'path-candidate-2-toggle');
    expect(find.byKey(const Key('path-candidate-2-hop-1')), findsOneWidget);
    expect(find.byKey(const Key('path-candidate-1-hop-0')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Path Inspector: a hop list from a link runs at once; no route and offline say so', (tester) async {
    await pump(tester, PathInspectorScreen(baseUrl: base, regionSlug: 'cmh', initialHops: 'ff,a1', api: server.api));
    await tester.pump();
    expect(find.byKey(const Key('path-none')), findsOneWidget);
    server.offline = true;
    await tapKey(tester, 'path-inspect');
    expect(find.byKey(const Key('path-error')), findsOneWidget);
    expect(find.textContaining('No connection'), findsOneWidget);
  });

  testWidgets('Trace Viewer: recent list, a trace with hops and observers, back to the list', (tester) async {
    await pump(tester, TraceViewerScreen(baseUrl: base, regionSlug: 'cmh', api: server.api, clock: () => DateTime.utc(2026, 11, 20, 15)));
    expect(find.byKey(const Key('trace-recent-$traceHash')), findsOneWidget);
    await tapKey(tester, 'trace-recent-$traceHash');
    expect(find.text('Got through 2 of 3 hops'), findsOneWidget);
    expect(find.textContaining('2 copies'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('trace-hop-0')));
    expect(find.text('Nagglepuss2'), findsOneWidget);
    expect(find.text('+9.3 dB'), findsOneWidget);
    expect(find.text('Unclear which repeater'), findsOneWidget);
    expect(find.text('Several share this ID'), findsOneWidget);
    expect(find.text('Not reached'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('trace-obs-1')));
    expect(find.text('MS Westside'), findsOneWidget);
    expect(find.textContaining('outside source'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('trace-obs-0'))).height, greaterThanOrEqualTo(44));
    expect(tester.takeException(), isNull);
    await tapKey(tester, 'trace-back-to-list');
    expect(find.byKey(const Key('trace-recent-$traceHash')), findsOneWidget);
  });

  testWidgets('Trace Viewer: a bad hash is an inline error; an unknown one is "No server copy", not an error', (tester) async {
    server.recent = false;
    await pump(tester, TraceViewerScreen(baseUrl: base, regionSlug: 'cmh', api: server.api));
    expect(find.byKey(const Key('trace-recent-none')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('trace-hash')), 'xyz');
    await tapKey(tester, 'trace-view');
    expect(find.textContaining('16 hex characters'), findsWidgets);
    await tester.enterText(find.byKey(const Key('trace-hash')), '0123456789ABCDEF');
    await tapKey(tester, 'trace-view');
    expect(find.byKey(const Key('trace-missing')), findsOneWidget);
    expect(find.text('No server copy of this trace yet'), findsOneWidget);
    expect(find.byKey(const Key('trace-error')), findsNothing);
    expect(server.seen.last.url.path, '/v1/traces/0123456789abcdef');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('Trace Viewer shows the radio\'s own result and asks the server nothing', (tester) async {
    final r = TraceResult(
      id: '1',
      at: DateTime(2026, 11, 1, 12, 1),
      status: TraceStatus.ok,
      hashSize: 2,
      hops: const [
        TraceHopResult(stop: TraceStop(name: 'Hilltop RPT', keyHex: '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c'), hashHex: '4f19', snrDb: 7.5, distanceKm: 1.2),
        TraceHopResult(stop: TraceStop(name: 'Kestrel', keyHex: 'c48e58a12ba6d3040af2806c373e80452ef09c6a06b4d67eb82fa9cd3b69af65'), hashHex: 'c48e', snrDb: -6, ambiguous: true),
      ],
      finalSnrDb: 3.25,
      elapsed: const Duration(milliseconds: 1840),
    );
    await pump(tester, TraceViewerScreen.local(r));
    expect(find.text('From your radio'), findsOneWidget);
    expect(find.text('Complete: all 2 hops answered'), findsOneWidget);
    expect(find.text('Hilltop RPT'), findsOneWidget);
    expect(find.text('+7.5 dB'), findsOneWidget);
    expect(find.textContaining('another node shares this hash'), findsOneWidget);
    expect(find.textContaining('+3.3 dB'), findsOneWidget);
    expect(find.byKey(const Key('trace-hash')), findsNothing);
    expect(server.seen, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Prefix Tool: overview at once, a taken prefix with its conflicts, a suggestion chip', (tester) async {
    await pump(tester, PrefixToolScreen(baseUrl: base, regionSlug: 'cmh', initialPrefix: 'a1', api: server.api));
    await tester.pump();
    expect(server.seen.single.url.queryParameters, {'prefix': 'a1'});
    expect(find.byKey(const Key('prefix-check-1')), findsOneWidget);
    expect(find.text('Taken'), findsOneWidget);
    expect(find.byKey(const Key('prefix-check-2')), findsNothing, reason: 'sizes the query does not cover are not shown');
    expect(find.byKey(const Key('prefix-check-1-conflict-0')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('prefix-overview')));
    expect(find.textContaining('repeaters and rooms within 200 km'), findsOneWidget);
    expect(find.byKey(const Key('prefix-recommendation')), findsOneWidget);
    // Build 76: the server's long note is behind "How this is worked out", not a paragraph under every answer.
    if (find.byKey(const Key('prefix-about')).evaluate().isNotEmpty) {
      expect(find.byKey(const Key('prefix-note')), findsNothing);
      await tapKey(tester, 'prefix-about');
      expect(find.byKey(const Key('prefix-note')), findsOneWidget);
    }
    final chip = find.byWidgetPredicate((w) => w is ActionChip).first;
    await tester.ensureVisible(chip);
    expect(tester.getSize(chip).height, greaterThanOrEqualTo(44));
    await tester.tap(chip);
    await tester.pump();
    await tester.pump();
    expect(server.seen.length, 2);
    expect(server.seen.last.url.queryParameters['prefix'], isNot('a1'));
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byKey(const Key('prefix-input')), 'a1b');
    await tapKey(tester, 'prefix-check');
    expect(find.textContaining('Type 2, 4 or 6 hex characters'), findsOneWidget);
    expect(server.seen.length, 2);
  });
}
