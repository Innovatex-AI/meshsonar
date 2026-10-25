// Offline-first behaviour of every Region tab panel (Repeaters is covered by its own tests):
//  - no network, stored copy: the data plus one "Offline - as of" banner (key region-offline-asof);
//  - no network, nothing stored: an honest "No connection" state (key region-offline-empty) whose Retry refetches;
//  - Live: says it needs a connection, never spins forever, and Retry reconnects.
// The stored copy is what EtagClient serves (a 200 with x-meshsonar-cache: offline + x-meshsonar-as-of); the fakes
// below answer exactly that, the real client path is covered in test/core/region_offline_api_test.dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/etag_client.dart';
import 'package:meshsonar/core/live_stream.dart';
import 'package:meshsonar/core/region_analysis_api.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/core/region_packets_api.dart';
import 'package:meshsonar/core/region_reports_api.dart';
import 'package:meshsonar/core/region_stats_api.dart';
import 'package:meshsonar/ui/region/analysis_panel.dart';
import 'package:meshsonar/ui/region/live_screen.dart';
import 'package:meshsonar/ui/region/observers_panel.dart';
import 'package:meshsonar/ui/region/overview_panel.dart';
import 'package:meshsonar/ui/region/packets_panel.dart';
import 'package:meshsonar/ui/region/region_common.dart';
import 'package:meshsonar/ui/region/reports_panel.dart';
import 'package:meshsonar/ui/region/stats_panel.dart';
import 'package:meshsonar/ui/theme.dart';

const _asOfKey = Key('region-offline-asof');
const _emptyKey = Key('region-offline-empty');
const _retryKey = Key('region-offline-retry');

/// How the fake network behaves: [offline] = no connection; [stored] = EtagClient has a copy to serve.
class Net {
  bool offline = true;
  bool stored = false;
  DateTime asOf = DateTime.now().toUtc().subtract(const Duration(hours: 2));
  int calls = 0;

  /// Answers like the app's EtagClient: live 200, the stored copy flagged offline, or a socket error.
  Future<http.Response> answer(http.Request r, Object? Function(String name) body) async {
    calls++;
    final name = r.url.pathSegments.last;
    final b = body(name);
    if (!offline) return http.Response(jsonEncode(b), 200, headers: {'content-type': 'application/json'});
    if (!stored) throw const SocketException('Network is unreachable');
    return http.Response(jsonEncode(b), 200, headers: {
      'content-type': 'application/json',
      cacheSourceHeader: 'offline',
      cacheAsOfHeader: asOf.toIso8601String(),
    });
  }

  MockClient client(Object? Function(String name) body) => MockClient((r) => answer(r, body));
}

const _status = {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T10:00:00Z', 'source': 'meshsonar'};

Object? _overviewBody(String name) => switch (name) {
      'region-overview' => {
          'status': _status,
          'packets24h': 612,
          'observersOnline': 1,
          'observersTotal': 9,
          'repeaters': 326,
          'repeatersHeard24h': 64,
          'packetsPerHour': [],
          'recentEvents': [],
        },
      _ => {
          'status': _status,
          'rows': [
            {'key': 'abcdef0123456789', 'name': 'OH.COL.OBS1', 'online': true},
          ],
        },
    };

Widget _wrap(Widget child, {bool scroll = true}) => MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Scaffold(body: scroll ? SingleChildScrollView(child: child) : child),
    );

Future<void> _tapRetry(WidgetTester t) async {
  await t.ensureVisible(find.byKey(_retryKey));
  await t.tap(find.byKey(_retryKey));
  await t.pumpAndSettle();
}

void main() {
  tearDown(() {
    regionApiFactory = (b) => RegionOverviewApi(b);
    regionStatsApiFactory = (b) => RegionStatsApi(b);
  });

  test('offline label text', () {
    final now = DateTime.utc(2026, 10, 24, 12);
    expect(offlineAsOfText(now.subtract(const Duration(hours: 3)), now: now), 'Offline - as of 3 h ago');
    expect(oldestAsOf([null, now, now.subtract(const Duration(hours: 1))]), now.subtract(const Duration(hours: 1)));
    expect(oldestAsOf([null, null]), isNull);
  });

  group('overview', () {
    testWidgets('stored copy: data plus Offline - as of', (t) async {
      final net = Net()..stored = true;
      regionApiFactory = (b) => RegionOverviewApi(b, client: net.client(_overviewBody));
      await t.pumpWidget(_wrap(const OverviewPanel(baseUrl: 'https://cmh.example', regionSlug: 'cmh')));
      await t.pumpAndSettle();
      expect(find.text('612'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsOneWidget);
      expect(find.textContaining('Offline - as of 2 h ago'), findsOneWidget);
      expect(find.byKey(_emptyKey), findsNothing);
    });

    testWidgets('nothing stored: No connection, Retry loads once online', (t) async {
      final net = Net();
      regionApiFactory = (b) => RegionOverviewApi(b, client: net.client(_overviewBody));
      await t.pumpWidget(_wrap(const OverviewPanel(baseUrl: 'https://cmh.example', regionSlug: 'cmh')));
      await t.pumpAndSettle();
      expect(find.byKey(_emptyKey), findsOneWidget);
      expect(find.text('No connection'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      net.offline = false;
      await _tapRetry(t);
      expect(find.byKey(_emptyKey), findsNothing);
      expect(find.text('612'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsNothing, reason: 'a live answer is not labelled offline');
    });
  });

  group('observers', () {
    testWidgets('stored copy: data plus Offline - as of', (t) async {
      final net = Net()..stored = true;
      regionApiFactory = (b) => RegionOverviewApi(b, client: net.client(_overviewBody));
      await t.pumpWidget(_wrap(const ObserversPanel(baseUrl: 'https://cmh.example', regionSlug: 'cmh')));
      await t.pumpAndSettle();
      expect(find.text('OH.COL.OBS1'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsOneWidget);
    });

    testWidgets('nothing stored: No connection, Retry loads once online', (t) async {
      final net = Net();
      regionApiFactory = (b) => RegionOverviewApi(b, client: net.client(_overviewBody));
      await t.pumpWidget(_wrap(const ObserversPanel(baseUrl: 'https://cmh.example', regionSlug: 'cmh')));
      await t.pumpAndSettle();
      expect(find.byKey(_emptyKey), findsOneWidget);
      net.offline = false;
      await _tapRetry(t);
      expect(find.text('OH.COL.OBS1'), findsOneWidget);
      expect(find.byKey(_emptyKey), findsNothing);
    });
  });

  group('packets', () {
    Object? body(String _) => {
          'status': _status,
          'rows': [
            {'hash': 'a1', 'type': 4, 'route': 1, 'firstAt': DateTime.now().toUtc().toIso8601String(), 'observers': 2, 'minHops': 1},
          ],
        };
    Widget panel(Net net) => _wrap(
        PacketsPanel(
            baseUrl: Uri.parse('https://cmh.example'),
            regionSlug: 'cmh',
            api: HttpRegionPacketsApi(Uri.parse('https://cmh.example'), client: net.client(body))),
        scroll: false);

    testWidgets('stored copy: rows plus Offline - as of', (t) async {
      final net = Net()..stored = true;
      await t.pumpWidget(panel(net));
      await t.pumpAndSettle(const Duration(milliseconds: 1));
      expect(find.text('Advert'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsOneWidget);
      net.offline = false; // the next poll is live: the banner goes away
      await t.pump(const Duration(seconds: 10));
      await t.pump();
      expect(find.byKey(_asOfKey), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('nothing stored: No connection, Retry loads once online', (t) async {
      final net = Net();
      await t.pumpWidget(panel(net));
      await t.pumpAndSettle(const Duration(milliseconds: 1));
      expect(find.byKey(_emptyKey), findsOneWidget);
      expect(find.byKey(const Key('packets-loading')), findsNothing);
      net.offline = false;
      await t.tap(find.byKey(_retryKey));
      await t.pump();
      await t.pump();
      expect(find.byKey(_emptyKey), findsNothing);
      expect(find.text('Advert'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('analysis', () {
    Object? body(String name) => switch (name) {
          'region-activity' => {
              'status': _status,
              'rows': [
                {'at': '2026-10-22T03:00:00.000Z', 'total': 163},
              ],
            },
          'region-hash-stats' => {
              'status': _status,
              'sizes': [
                {'bytes': 1, 'nodes': 22},
              ],
              'collisions': [],
            },
          'region-path-stats' => {
              'status': _status,
              'hopHistogram': [
                {'hops': 2, 'n': 30},
              ],
              'carryShare': [],
            },
          _ => {
              'status': _status,
              'rows': [
                {'role': 'repeater'},
              ],
              'counts': {'active': 1},
            },
        };
    Future<void> pump(WidgetTester t, Net net) async {
      t.view.physicalSize = const Size(800, 4000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(_wrap(
          AnalysisPanel(
              baseUrl: 'https://day.example', regionSlug: 'day', api: RegionAnalysisApi('https://day.example', client: net.client(body))),
          scroll: false));
      await t.pumpAndSettle();
    }

    testWidgets('stored copy: sections plus Offline - as of', (t) async {
      await pump(t, Net()..stored = true);
      expect(find.byKey(const Key('analysis-list')), findsOneWidget);
      expect(find.text('Role mix'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsOneWidget);
      expect(find.byKey(const Key('analysis-partial')), findsNothing);
    });

    testWidgets('nothing stored: No connection, Retry loads once online', (t) async {
      final net = Net();
      await pump(t, net);
      expect(find.byKey(_emptyKey), findsOneWidget);
      expect(find.byKey(const Key('analysis-loading')), findsNothing);
      net.offline = false;
      await _tapRetry(t);
      expect(find.byKey(const Key('analysis-list')), findsOneWidget);
      expect(find.byKey(_asOfKey), findsNothing);
    });
  });

  group('reports', () {
    final now = DateTime.utc(2026, 10, 24, 2);
    String fixture(String n) => File('test/fixtures/$n').readAsStringSync();
    Object? body(String name) =>
        jsonDecode(fixture(name == 'region-report' ? 'region_report_cmh.json' : 'region_sources_cmh.json'));
    Widget panel(Net net) => MaterialApp(
          home: Scaffold(
            body: ReportsPanel(
                baseUrl: 'https://x.test',
                regionSlug: 'cmh',
                api: RegionReportsApi('https://x.test', client: net.client(body)),
                clock: () => now),
          ),
        );

    testWidgets('stored copy: report plus Offline - as of', (t) async {
      final net = Net()
        ..stored = true
        ..asOf = now.subtract(const Duration(hours: 3));
      await t.pumpWidget(panel(net));
      await t.pumpAndSettle();
      expect(find.text('Columbus, US'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsOneWidget);
      expect(find.textContaining('Offline - as of 3 h ago'), findsOneWidget);
    });

    testWidgets('nothing stored: No connection, Retry loads once online', (t) async {
      final net = Net();
      await t.pumpWidget(panel(net));
      await t.pumpAndSettle();
      expect(find.byKey(_emptyKey), findsOneWidget);
      expect(find.byKey(const Key('reports-loading')), findsNothing);
      net.offline = false;
      await _tapRetry(t);
      expect(find.byKey(_emptyKey), findsNothing);
      expect(find.text('Columbus, US'), findsOneWidget);
    });
  });

  group('stats', () {
    Object? body(String name) => switch (name) {
          'public-stats' => {'km': 533.1, 'pings': 1715, 'drives': 45, 'drivers': 6, 'heardPct': 52.5, 'cellsHeardPct': 49.3, 'repeatersHeard': 67},
          'leaderboard' => {'period': '30d', 'rows': []},
          _ => {'activeDrivers': 0, 'drivers': [], 'pings15m': 0, 'lastUploadAt': null},
        };

    testWidgets('stored copy: figures plus Offline - as of; the live chip says it needs a connection', (t) async {
      final net = Net()..stored = true;
      // public-live is never stored: offline it fails even when the others come from the stored copy.
      regionStatsApiFactory = (b) => RegionStatsApi(b, client: MockClient((r) {
            if (r.url.path.endsWith('public-live')) throw const SocketException('Network is unreachable');
            return net.answer(r, body);
          }));
      await t.pumpWidget(_wrap(const StatsPanel(baseUrl: 'https://x.example', regionSlug: 'x'), scroll: false));
      await t.pumpAndSettle();
      expect(find.text('533'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsOneWidget);
      expect(find.text('Live drivers need a connection.'), findsOneWidget);
      expect(find.byKey(_emptyKey), findsNothing);
    });

    testWidgets('nothing stored: No connection, Retry loads once online', (t) async {
      final net = Net();
      regionStatsApiFactory = (b) => RegionStatsApi(b, client: net.client(body));
      await t.pumpWidget(_wrap(const StatsPanel(baseUrl: 'https://x.example', regionSlug: 'x'), scroll: false));
      await t.pumpAndSettle();
      expect(find.byKey(_emptyKey), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      net.offline = false;
      await _tapRetry(t);
      expect(find.byKey(_emptyKey), findsNothing);
      expect(find.text('533'), findsOneWidget);
      expect(find.byKey(_asOfKey), findsNothing);
    });
  });

  group('live', () {
    testWidgets('offline: says Live needs a connection, no spinner; Retry reconnects and packets flow', (t) async {
      var offline = true;
      final body = StreamController<List<int>>();
      final stream = LiveStream(Uri.parse('https://x.test'), connect: (r) async {
        if (offline) throw const SocketException('Network is unreachable');
        return http.StreamedResponse(body.stream, 200);
      });
      await t.pumpWidget(MaterialApp(home: Scaffold(body: LivePanel(baseUrl: 'https://x.test', regionSlug: 'cmh', stream: stream))));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('live-offline')), findsOneWidget);
      expect(find.text('Live needs a connection'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      // Automatic backoff retries keep the honest state instead of flickering.
      await t.pump(const Duration(seconds: 1));
      await t.pump();
      expect(find.byKey(const Key('live-offline')), findsOneWidget);

      offline = false;
      await t.tap(find.byKey(const Key('live-retry')));
      await t.pump();
      await t.pump();
      expect(find.byKey(const Key('live-offline')), findsNothing);
      body.add(utf8.encode('event: packet\ndata: {"kind":"packet","packet":{"hash":"ab12","type":5,"route":1,'
          '"at":"${DateTime.now().toUtc().toIso8601String()}","observations":[{"observer":"o1","snrDb":7.5,"hops":2}],"hops":[]}}\n\n'));
      await t.pump(const Duration(milliseconds: 50));
      await t.pump();
      expect(find.text('Group text'), findsOneWidget);
      expect(stream.state, LiveConnState.live);
      await t.pumpWidget(const SizedBox());
      unawaited(stream.dispose());
      unawaited(body.close());
    });
  });
}
