// Build 77 native pages that replace website pages (Round 2 N-U10, W6, W9): the one Overview (window picker, "Signal
// and traffic", one packets chart, hop counts, kinds of packets), My Repeaters (the app's own stars and claims, filtered
// on the phone: the list is never sent), and Tools > Status (one call, three states, plain words, never a fake 0).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/core/v1/insights_api.dart';
import 'package:meshsonar/core/v1/v1_client.dart' show resetV1NotLive;
import 'package:meshsonar/ui/network/analytics/my_repeaters_panel.dart';
import 'package:meshsonar/ui/network/network_context.dart';
import 'package:meshsonar/ui/network/tools/status_screen.dart';
import 'package:meshsonar/ui/region/overview_panel.dart';
import 'package:meshsonar/ui/region/region_common.dart';
import 'package:meshsonar/ui/theme.dart';

const base = 'https://cmh.meshsonar.com';
const k1 = '4f199584624bb836b6236a1becf56c22dc204f37e5775eda542895a88c4c164c';
const k2 = 'c48e58a12ba6d3040af2806c373e80452ef09c6a06b4d67eb82fa9cd3b69af65';
const k3 = 'd1a761a8d6478b879df8a2278225f4fc2c10d2f925f537c6cdd7921c7f147a0f';

http.Response json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
Map<String, dynamic> meta({String state = 'ready'}) => {
      'apiVersion': '1.0',
      'generatedAt': '2026-11-27T12:00:00.000Z',
      'dataAt': '2026-11-27T11:59:00.000Z',
      'status': {'state': state, 'reason': null},
    };

Map<String, dynamic> insightsOverview(String window) => {
      'data': {
        'bucket': window == '7d' || window == '30d' ? '1d' : '1h',
        'stats': {
          'transmissions': window == '24h' ? 3372 : 140,
          'observations': 9000,
          'observationsWithSignal': 8000,
          'uniqueNodes': 211,
          'snr': {'mean': 4.523, 'min': -18, 'max': 14},
          'rssi': {'mean': -101.2, 'min': -130, 'max': -40},
          'hops': {'mean': 2.46, 'max': 9},
          'activeChannels': 7,
          'decryptableChannels': 3,
          'packetSize': {'mean': 61.4, 'min': 20, 'max': 180},
          'dataSpanH': 24,
        },
        'perBucket': {
          'columns': ['at', 'packets', 'observations'],
          'rows': [
            ['2026-11-27T09:00:00.000Z', 120, 300],
            ['2026-11-27T10:00:00.000Z', 160, 420],
            ['2026-11-27T11:00:00.000Z', 90, 210],
          ],
        },
        'typeMix': [
          {'type': 'GRP_TXT', 'packets': 900, 'share': 0.27},
          {'type': 'ADVERT', 'packets': 2000, 'share': 0.59},
        ],
        'hopDistribution': [
          [0, 400],
          [1, 1200],
          [2, 800],
        ],
        'relayAirtime': {'preset': {}, 'rows': [], 'note': 'x'},
      },
      'meta': meta(),
    };

Widget wrap(Widget child, {bool scroll = true}) =>
    MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Scaffold(body: scroll ? SingleChildScrollView(child: child) : child));

void main() {
  final seen = <Uri>[];
  setUp(() {
    resetV1NotLive();
    seen.clear();
    debugResetNetworkFavourites();
  });
  tearDown(() {
    insightsApiFactory = (b) => InsightsApi(b);
    regionApiFactory = (b) => RegionOverviewApi(b);
  });

  void serve(Future<http.Response> Function(http.Request r) h) {
    final c = MockClient((r) {
      seen.add(r.url);
      return h(r);
    });
    insightsApiFactory = (b) => InsightsApi(b, client: c);
    regionApiFactory = (b) => RegionOverviewApi(b, client: c);
  }

  Map<String, dynamic> regionOverview() => {
        'status': {'state': 'ready', 'computedAt': DateTime.now().toUtc().toIso8601String()},
        'packets24h': 3372,
        'observersOnline': 5,
        'observersTotal': 26,
        'repeaters': 132,
        'repeatersHeard24h': 64,
        'packetsPerHour': [
          {'at': '2026-11-27T10:00:00.000Z', 'n': 7},
        ],
        'lastPacketAt': null,
        'recentEvents': [],
      };

  group('Overview (N-U10)', () {
    testWidgets('one page: window picker, the four cards, Signal and traffic, one packets chart, hop counts, kinds of packets', (t) async {
      t.view.physicalSize = const Size(375, 3000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      serve((r) async {
        if (r.url.path == '/v1/insights/overview') return json(insightsOverview(r.url.queryParameters['window'] ?? '24h'));
        if (r.url.path == '/api/cmh/region-overview') return json(regionOverview());
        return http.Response('<html>', 404);
      });
      await t.pumpWidget(wrap(const OverviewPanel(baseUrl: base, regionSlug: 'cmh')));
      await t.pumpAndSettle();
      expect(seen.where((u) => u.path == '/v1/insights/overview').single.queryParameters['window'], '24h');
      for (final w in ['1h', '24h', '7d', '30d']) {
        expect(find.byKey(Key('overview-window-$w')), findsOneWidget, reason: w);
      }
      expect(find.text('3,372'), findsOneWidget, reason: 'Packets card, once (no "Transmissions" card)');
      expect(find.text('Packets, 24 hours'), findsOneWidget);
      expect(find.text('132'), findsOneWidget);
      expect(find.text('Transmissions'), findsNothing);
      expect(find.textContaining('Data span'), findsNothing);
      expect(t.widget<Text>(find.byKey(const Key('overview-stat-unique'))).data, '211');
      expect(t.widget<Text>(find.byKey(const Key('overview-stat-signal'))).data, '4.52 dB');
      expect(t.widget<Text>(find.byKey(const Key('overview-stat-hops'))).data, '2.5');
      expect(t.widget<Text>(find.byKey(const Key('overview-stat-channels'))).data, '7');
      expect(t.widget<Text>(find.byKey(const Key('overview-stat-size'))).data, '61 bytes');
      expect(find.byKey(const Key('sparkline')), findsOneWidget, reason: 'one packets chart, not two');
      expect(find.byKey(const Key('overview-series')), findsOneWidget);
      expect(find.text('Packets per hour'), findsOneWidget);
      expect(find.byKey(const Key('overview-hops-0')), findsOneWidget);
      expect(find.text('Heard direct'), findsOneWidget);
      expect(find.text('Advert'), findsOneWidget, reason: 'plain names, not ADVERT');
      expect(find.text('Channel message'), findsOneWidget);
      expect(find.textContaining('GRP_TXT'), findsNothing);
      // The amber "132 Repeaters known" is neutral now (W1-A: amber only for warnings).
      final rep = t.widget<Text>(find.byKey(const Key('stat-repeaters')));
      expect(rep.style?.color, isNot(MeshSonarColors.of(t.element(find.byKey(const Key('stat-repeaters')))).warning));
      expect(t.takeException(), isNull);

      // 7 days: the server's days, named as UTC days.
      await t.tap(find.byKey(const Key('overview-window-7d')));
      await t.pumpAndSettle();
      expect(seen.where((u) => u.path == '/v1/insights/overview').last.queryParameters['window'], '7d');
      expect(find.text('Packets, 7 days'), findsOneWidget);
      expect(find.text('Packets per day (UTC)'), findsOneWidget);
      expect(find.textContaining('Signal and traffic, 7 days'), findsOneWidget);
    });

    testWidgets('an older server with no /v1/insights: the 24-hour chart of region-overview, no error', (t) async {
      serve((r) async {
        if (r.url.path == '/api/cmh/region-overview') return json(regionOverview());
        return http.Response('<html>', 404);
      });
      await t.pumpWidget(wrap(const OverviewPanel(baseUrl: base, regionSlug: 'cmh')));
      await t.pumpAndSettle();
      expect(find.text('Packets, 24 h'), findsOneWidget);
      expect(find.byKey(const Key('sparkline')), findsOneWidget);
      expect(find.byKey(const Key('overview-series')), findsNothing);
      expect(find.byKey(const Key('overview-insights-error')), findsNothing);
      expect(find.byKey(const Key('overview-stat-unique')), findsNothing);
    });
  });

  group('My Repeaters (W6)', () {
    Map<String, dynamic> repeaters() => {
          'data': {
            'columns': ['key', 'name', 'role', 'status', 'lastHeardAt', 'relays1h', 'relays24h', 'relays7d', 'adverts7d', 'snrMean7d', 'observers7d', 'trafficShare', 'bridge'],
            'rows': [
              [k1, 'Hilltop RPT', 'repeater', 'active', '2026-11-27T11:50:00.000Z', 3, 1843, 9000, 40, 6.25, 4, 0.123, 0.4],
              [k2, 'Kestrel-07', 'companion', 'active', null, null, null, null, null, null, null, null, null],
              [k3, 'Westside RPT', 'repeater', 'silent', '2026-11-20T11:50:00.000Z', 0, 0, 2, 1, null, 1, 0.0, 0.0],
              ['ab' * 32, 'Someone else', 'repeater', 'active', null, 1, 10, 50, 2, 1.0, 1, 0.01, 0.0],
            ],
            'total': 4,
            'truncated': false,
            'links': null,
            'missing': [],
          },
          'meta': meta(),
        };

    testWidgets('nothing starred: says how to star one, sends nothing', (t) async {
      serve((r) async => json(repeaters()));
      await t.pumpWidget(wrap(const MyRepeatersPanel(baseUrl: base, regionSlug: 'cmh'), scroll: false));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('my-repeaters-empty')), findsOneWidget);
      expect(find.byKey(const Key('my-repeaters-find')), findsOneWidget);
    });

    testWidgets('the starred repeaters with their figures, worst first; the starred list is never sent', (t) async {
      final store = NetworkFavouritesStore();
      debugResetNetworkFavourites(store);
      await store.toggleFavourite(FavouriteKind.node, k1);
      await store.toggleFavourite(FavouriteKind.node, k2);
      await store.toggleFavourite(FavouriteKind.node, k3);
      await store.toggleFavourite(FavouriteKind.node, 'cd' * 32);
      serve((r) async => json(repeaters()));
      await t.pumpWidget(wrap(const MyRepeatersPanel(baseUrl: base, regionSlug: 'cmh'), scroll: false));
      await t.pumpAndSettle();
      final asked = seen.single;
      expect(asked.path, '/v1/insights/repeaters');
      expect(asked.queryParameters.containsKey('keys'), isFalse, reason: 'filtered on the phone');
      expect(asked.toString(), isNot(contains(k1)));
      expect(find.byKey(Key('my-repeater-$k1')), findsOneWidget);
      expect(find.byKey(Key('my-repeater-$k3')), findsOneWidget);
      expect(find.byKey(Key('my-repeater-$k2')), findsNothing, reason: 'a companion is not a repeater');
      expect(find.text('Someone else'), findsNothing);
      expect(t.getTopLeft(find.byKey(Key('my-repeater-$k3'))).dy, lessThan(t.getTopLeft(find.byKey(Key('my-repeater-$k1'))).dy), reason: 'worst first');
      expect(t.widget<Text>(find.byKey(const Key('my-repeaters-figure-total'))).data, '2');
      expect(t.widget<Text>(find.byKey(const Key('my-repeaters-figure-silent'))).data, '1');
      expect(t.widget<Text>(find.byKey(const Key('my-repeaters-figure-relays'))).data, '1,843');
      expect(find.text('Not heard lately'), findsWidgets, reason: 'plain status words');
      expect(find.textContaining('12.3% of traffic'), findsOneWidget);
      expect(t.widget<Text>(find.byKey(const Key('my-repeaters-note'))).data, '1 of your nodes is not in this region; 1 is not a repeater or room.');
      expect(find.byKey(const Key('my-repeaters-updated')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('Status (W9)', () {
    Map<String, dynamic> status({String overall = 'degraded', Object? rate = 1200}) => {
          'data': {
            'api': {'version': '1.0', 'build': 'dev'},
            'overall': overall,
            'ingest': [
              {'pipeline': 'first_party_mqtt', 'state': 'ok', 'lastAt': '2026-11-27T11:59:00.000Z', 'rate1h': rate},
              {'pipeline': 'phones', 'label': 'MeshSonar phones', 'state': 'ok', 'lastAt': null, 'rate1h': null},
              {'pipeline': 'outside_live', 'label': 'Outside feeds', 'state': 'degraded', 'lastAt': '2026-11-27T11:58:00.000Z', 'rate1h': 40, 'sockets': {'connected': 45, 'backoff': 4, 'blocked': 0, 'total': 49}},
            ],
            'stream': {'state': 'ok', 'clients': 0, 'resumeWindowS': 600},
            'rollups': [
              {'name': 'e3_hour', 'state': 'ok', 'lastAt': '2026-11-27T11:00:00.000Z'},
              {'name': 'e6_day', 'label': 'Daily repeater figures', 'state': 'stale', 'lastAt': '2026-11-25T11:00:00.000Z'},
            ],
            'retention': {},
            'features': ['summary', 'packets', 'inspector'],
            'incidents': [
              {'at': '2026-11-27T12:00:00.000Z', 'text': 'Some partner feeds are reconnecting.'},
            ],
          },
          'meta': meta(),
        };

    testWidgets('loading, then the answer in plain words; a count the server did not make is never 0', (t) async {
      t.view.physicalSize = const Size(375, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      serve((r) async => r.url.path == '/v1/status' ? json(status()) : http.Response('<html>', 404));
      await t.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const StatusScreen(baseUrl: base, regionSlug: 'cmh')));
      expect(find.byKey(const Key('status-loading')), findsOneWidget);
      await t.pumpAndSettle();
      expect(seen.where((u) => u.path == '/v1/status'), hasLength(1), reason: 'one call');
      expect(t.widget<Text>(find.byKey(const Key('status-overall'))).data, 'Partly working');
      expect(find.text('MeshSonar listening stations'), findsOneWidget, reason: 'named by the app on an older server');
      expect(t.widget<Text>(find.byKey(const Key('status-source-line-first_party_mqtt'))).data, contains('1,200 packets in the last hour'));
      expect(t.widget<Text>(find.byKey(const Key('status-source-line-phones'))).data, contains('last hour not counted yet'));
      expect(t.widget<Text>(find.byKey(const Key('status-source-line-phones'))).data, contains('not heard yet'));
      expect(t.widget<Text>(find.byKey(const Key('status-source-line-outside_live'))).data, contains('45 of 49 connected'));
      expect(find.text('Daily repeater figures'), findsOneWidget);
      expect(find.byKey(const Key('status-summary-e3_hour')), findsNothing, reason: 'up to date: not listed one by one');
      expect(find.text('Some partner feeds are reconnecting.'), findsOneWidget);
      for (final internal in ['first party mqtt', 'first_party_mqtt', 'e3_hour', 'never', 'inspector', 'API version', '0 watching']) {
        expect(find.textContaining(internal), findsNothing, reason: internal);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('everything fine: Working, and one line for the summaries', (t) async {
      final ok = status(overall: 'ok');
      ((ok['data'] as Map)['rollups'] as List).removeLast();
      serve((r) async => json(ok));
      await t.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const StatusScreen(baseUrl: base)));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const Key('status-overall'))).data, 'Working');
      expect(find.byKey(const Key('status-summaries-ok')), findsOneWidget);
    });

    testWidgets('an error: plain words and Try again; offline: the no-connection view', (t) async {
      var fail = true;
      serve((r) async => fail ? json({'error': {'code': 'internal', 'message': 'boom', 'requestId': 'r-1'}}, 500) : json(status()));
      await t.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const StatusScreen(baseUrl: base)));
      await t.pumpAndSettle();
      expect(t.widget<Text>(find.byKey(const Key('status-error'))).data, "Can't reach MeshSonar.");
      expect(find.textContaining('r-1'), findsNothing, reason: 'no request id on screen');
      fail = false;
      await t.tap(find.byKey(const Key('status-retry')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('status-page')), findsOneWidget);

      insightsApiFactory = (b) => InsightsApi(b, client: MockClient((_) async => throw const SocketException('down')));
      await t.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const StatusScreen(key: Key('b'), baseUrl: base)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('region-offline-empty')), findsOneWidget);
    });
  });
}
